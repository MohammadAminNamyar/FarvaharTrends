// Isolated DC-net bulk-round component. This is not Dissent, Verdict, an
// anonymity proof, or an application transport. The fixture knows every secret
// and assigns anonymous slots centrally. Never use its keys for actual news.
package main

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"sort"
)

const clients = 8
const coordinators = 3
const reservationCell = 96
const maxCell = 8192
const maxBulkSlots = 2              // original conservative fixture; measured variant allows eight
const cellNonceSize = aes.BlockSize // randomization only, not payload encryption

type identity struct {
	pub     ed25519.PublicKey
	private ed25519.PrivateKey
}

func key() identity                   { p, s, e := ed25519.GenerateKey(rand.Reader); must(e); return identity{p, s} }
func hash(b []byte) [32]byte          { return sha256.Sum256(b) }
func put16(b *bytes.Buffer, x int)    { must(binary.Write(b, binary.BigEndian, uint16(x))) }
func put64(b *bytes.Buffer, x uint64) { must(binary.Write(b, binary.BigEndian, x)) }
func xor(dst, src []byte) {
	if len(dst) != len(src) {
		panic("unequal xor")
	}
	for i := range dst {
		dst[i] ^= src[i]
	}
}

type descriptor struct {
	epoch    [32]byte
	sequence uint64
	phase    byte
	previous [32]byte
	slots    []int
	cell     int
}

func (d descriptor) valid() bool {
	if d.phase > 1 || d.sequence%2 != uint64(d.phase) {
		return false
	}
	if d.phase == 0 && (d.cell != reservationCell || len(d.slots) != clients) {
		return false
	}
	if d.phase == 1 && (d.cell < 96 || d.cell > maxCell || len(d.slots) < 1 || len(d.slots) > clients) {
		return false
	}
	last := -1
	for _, s := range d.slots {
		if s <= last || s >= clients {
			return false
		}
		last = s
	}
	return true
}
func (d descriptor) wire() []byte {
	b := new(bytes.Buffer)
	b.WriteString("FT-ROUND-COMPONENT-v2")
	b.Write(d.epoch[:])
	put64(b, d.sequence)
	b.WriteByte(d.phase)
	b.Write(d.previous[:])
	put16(b, d.cell)
	put16(b, len(d.slots))
	for _, s := range d.slots {
		put16(b, s)
	}
	return b.Bytes()
}
func (d descriptor) size() int { return len(d.slots) * d.cell }

type input struct {
	client          int
	body, signature []byte
	keyHashes       [coordinators][32]byte
}

func (x input) signed(d descriptor) []byte {
	b := bytes.NewBuffer(d.wire())
	put16(b, x.client)
	for _, h := range x.keyHashes {
		b.Write(h[:])
	}
	b.Write(x.body)
	return b.Bytes()
}
func (x input) wire(d descriptor) []byte { return append(x.signed(d), x.signature...) }

type vote struct {
	coordinator int
	root        [32]byte
	maskHash    [32]byte
	keyHashes   [clients][32]byte
	signature   []byte
}

func (v vote) signed(d descriptor) []byte {
	b := bytes.NewBuffer(d.wire())
	b.WriteString("commit")
	put16(b, v.coordinator)
	b.Write(v.root[:])
	b.Write(v.maskHash[:])
	for _, h := range v.keyHashes {
		b.Write(h[:])
	}
	return b.Bytes()
}

type share struct {
	coordinator     int
	root            [32]byte
	body, signature []byte
}

func (s share) signed(d descriptor) []byte {
	b := bytes.NewBuffer(d.wire())
	b.WriteString("share")
	put16(b, s.coordinator)
	b.Write(s.root[:])
	b.Write(s.body)
	return b.Bytes()
}

type serverState struct {
	next      uint64
	committed bool
	root      [32]byte
	maskHash  [32]byte
	keyHashes [clients][coordinators][32]byte
}
type fixture struct {
	epoch         [32]byte
	clientKeys    [clients]identity
	serverKeys    [coordinators]identity
	slotKeys      [clients]identity
	ownerSlot     [clients]int
	seeds         [clients][coordinators][32]byte
	seedAvailable [clients][coordinators]bool
	clientNext    [clients]uint64
	servers       [coordinators]serverState
	expected      descriptor
	slotLimit     int
}

func newFixture() *fixture {
	return newFixtureWithLimit(maxBulkSlots)
}
func newFixtureWithLimit(limit int) *fixture {
	if limit < 1 || limit > clients {
		panic("invalid slot capacity")
	}
	f := new(fixture)
	f.slotLimit = limit
	_, e := rand.Read(f.epoch[:])
	must(e)
	for i := range clients {
		f.clientKeys[i] = key()
		f.slotKeys[i] = key()
		f.ownerSlot[i] = i
		for s := range coordinators {
			_, e = rand.Read(f.seeds[i][s][:])
			must(e)
			f.seedAvailable[i][s] = true
		}
	}
	for s := range coordinators {
		f.serverKeys[s] = key()
	}
	// A central Fisher-Yates assignment is ONLY a fixture, not a distributed
	// anonymous key shuffle. Its absence is an explicit integration blocker.
	for i := clients - 1; i > 0; i-- {
		var b [1]byte
		limit := 256 - 256%(i+1)
		for {
			_, e = rand.Read(b[:])
			must(e)
			if int(b[0]) < limit {
				break
			}
		}
		j := int(b[0]) % (i + 1)
		f.ownerSlot[i], f.ownerSlot[j] = f.ownerSlot[j], f.ownerSlot[i]
	}
	// Bind the fixture roster to the random epoch. No unauthenticated join API.
	b := bytes.NewBuffer(f.epoch[:])
	put16(b, limit)
	for _, k := range f.clientKeys {
		b.Write(k.pub)
	}
	for _, k := range f.serverKeys {
		b.Write(k.pub)
	}
	for _, k := range f.slotKeys {
		b.Write(k.pub)
	}
	f.epoch = hash(b.Bytes())
	f.expected = f.reservation(0)
	return f
}
func (f *fixture) allowed(d descriptor) bool {
	return d.valid() && d.epoch == f.epoch && bytes.Equal(d.wire(), f.expected.wire())
}
func (f *fixture) padKey(client, server int, d descriptor) [32]byte {
	if !f.seedAvailable[client][server] {
		panic("role does not possess this shared secret")
	}
	// A fresh domain-separated AES key per sequence/phase/descriptor avoids
	// stream reuse inside a fixture. Production needs a durable round journal,
	// authenticated DH and key erasure; this component provides none of those.
	h := hmac.New(sha256.New, f.seeds[client][server][:])
	h.Write([]byte("mask-key/v1"))
	h.Write(d.wire())
	var key [32]byte
	copy(key[:], h.Sum(nil))
	return key
}
func padFromKey(key [32]byte, size int) []byte {
	c, e := aes.NewCipher(key[:])
	must(e)
	out := make([]byte, size)
	cipher.NewCTR(c, make([]byte, aes.BlockSize)).XORKeyStream(out, out)
	return out
}
func (f *fixture) pad(client, server int, d descriptor) []byte {
	return padFromKey(f.padKey(client, server, d), d.size())
}
func padKeyCommitment(d descriptor, client, server int, key [32]byte) [32]byte {
	b := bytes.NewBuffer(d.wire())
	b.WriteString("round-pad-key/v1")
	put16(b, client)
	put16(b, server)
	b.Write(key[:])
	return hash(b.Bytes())
}
func cellCapacity(d descriptor) int { return d.cell - cellNonceSize - 2 - ed25519.SignatureSize }

// Dissent section 3.9 randomizes all slot bits before XOR masking so a disruptor
// cannot deliberately flip only known ones to zero. The clear nonce is not an
// encryption key protecting message confidentiality; pairwise DC-net masks do
// that. Never replace a randomized failed submission using the same round masks.
func randomizeCell(inner []byte) []byte {
	out := make([]byte, cellNonceSize+len(inner))
	_, e := rand.Read(out[:cellNonceSize])
	must(e)
	c, e := aes.NewCipher(out[:cellNonceSize])
	must(e)
	cipher.NewCTR(c, make([]byte, aes.BlockSize)).XORKeyStream(out[cellNonceSize:], inner)
	return out
}
func clearCell(cell []byte) []byte {
	c, e := aes.NewCipher(cell[:cellNonceSize])
	must(e)
	out := make([]byte, len(cell)-cellNonceSize)
	cipher.NewCTR(c, make([]byte, aes.BlockSize)).XORKeyStream(out, cell[cellNonceSize:])
	return out
}
func slotMessage(d descriptor, slot int, payload []byte) []byte {
	b := bytes.NewBuffer(d.wire())
	b.WriteString("anonymous-slot")
	put16(b, slot)
	put16(b, len(payload))
	b.Write(payload)
	return b.Bytes()
}
func (f *fixture) prepare(client int, d descriptor, payload []byte) (input, error) {
	if client < 0 || client >= clients || !f.allowed(d) || f.clientNext[client] != d.sequence {
		return input{}, errors.New("invalid or reused client round")
	}
	if len(payload) > cellCapacity(d) {
		return input{}, errors.New("oversized slot payload")
	}
	body := make([]byte, d.size())
	owned := f.ownerSlot[client]
	included := false
	for pos, slot := range d.slots {
		if slot == owned {
			included = true
			cell := make([]byte, d.cell-cellNonceSize)
			if len(payload) > 0 {
				binary.BigEndian.PutUint16(cell, uint16(len(payload)))
				copy(cell[2:], payload)
				copy(cell[2+len(payload):], ed25519.Sign(f.slotKeys[owned].private, slotMessage(d, slot, payload)))
			}
			copy(body[pos*d.cell:(pos+1)*d.cell], randomizeCell(cell))
		}
	}
	if len(payload) > 0 && !included {
		return input{}, errors.New("unreserved slot; queue instead")
	}
	x := input{client: client, body: body}
	for s := range coordinators {
		k := f.padKey(client, s, d)
		x.keyHashes[s] = padKeyCommitment(d, client, s, k)
		xor(body, padFromKey(k, d.size()))
	}
	x.signature = ed25519.Sign(f.clientKeys[client].private, x.signed(d))
	f.clientNext[client]++
	return x, nil
}
func (f *fixture) validate(d descriptor, inputs []input) ([32]byte, error) {
	if !f.allowed(d) || len(inputs) != clients {
		return [32]byte{}, errors.New("incomplete fixed cohort or invalid descriptor")
	}
	b := bytes.NewBuffer(d.wire())
	for i, x := range inputs {
		if x.client != i || len(x.body) != d.size() || len(x.signature) != ed25519.SignatureSize {
			return [32]byte{}, errors.New("noncanonical, duplicate or oversized input")
		}
		if !ed25519.Verify(f.clientKeys[i].pub, x.signed(d), x.signature) {
			return [32]byte{}, errors.New("unauthenticated contribution")
		}
		b.Write(x.wire(d))
	}
	return hash(b.Bytes()), nil
}
func (f *fixture) commit(server int, d descriptor, inputs []input) (vote, error) {
	if server < 0 || server >= coordinators {
		return vote{}, errors.New("unknown coordinator")
	}
	st := &f.servers[server]
	if st.committed || st.next != d.sequence {
		return vote{}, errors.New("replayed or equivocated commitment")
	}
	root, e := f.validate(d, inputs)
	if e != nil {
		return vote{}, e
	}
	// Commit to the actual mask before seeing another coordinator's share.
	// Committing only to the client input set permits adaptive corruption.
	v := vote{coordinator: server, root: root, maskHash: maskCommitment(d, server, root, f.mask(server, d))}
	for c := range clients {
		v.keyHashes[c] = padKeyCommitment(d, c, server, f.padKey(c, server, d))
		if inputs[c].keyHashes[server] != v.keyHashes[c] {
			return vote{}, errors.New("pairwise round key commitments disagree")
		}
	}
	v.signature = ed25519.Sign(f.serverKeys[server].private, v.signed(d))
	st.root = root
	st.maskHash = v.maskHash
	for c := range clients {
		st.keyHashes[c] = inputs[c].keyHashes
	}
	st.committed = true
	return v, nil
}
func (f *fixture) release(server int, d descriptor, votes []vote) (share, error) {
	if server < 0 || server >= coordinators || len(votes) != coordinators {
		return share{}, errors.New("missing coordinator")
	}
	st := &f.servers[server]
	if !d.valid() || d.epoch != f.epoch || !st.committed || st.next != d.sequence {
		return share{}, errors.New("uncommitted or replayed release")
	}
	if e := f.validateVotes(d, st.root, votes); e != nil {
		return share{}, e
	}
	if votes[server].maskHash != st.maskHash {
		return share{}, errors.New("own mask commitment replaced")
	}
	for c := range clients {
		for s := range coordinators {
			if votes[s].keyHashes[c] != st.keyHashes[c][s] {
				return share{}, errors.New("pairwise commitments changed before release")
			}
		}
	}
	s := share{coordinator: server, root: st.root, body: f.mask(server, d)}
	if maskCommitment(d, server, st.root, s.body) != st.maskHash {
		return share{}, errors.New("committed mask changed")
	}
	s.signature = ed25519.Sign(f.serverKeys[server].private, s.signed(d))
	st.next++
	st.committed = false
	return s, nil
}
func (f *fixture) mask(server int, d descriptor) []byte {
	body := make([]byte, d.size())
	for c := range clients {
		xor(body, f.pad(c, server, d))
	}
	return body
}
func maskCommitment(d descriptor, server int, root [32]byte, body []byte) [32]byte {
	b := bytes.NewBuffer(d.wire())
	b.WriteString("coordinator-mask-commitment/v1")
	put16(b, server)
	b.Write(root[:])
	b.Write(body)
	return hash(b.Bytes())
}
func (f *fixture) validateVotes(d descriptor, root [32]byte, votes []vote) error {
	if len(votes) != coordinators {
		return errors.New("missing mask commitments")
	}
	for i, v := range votes {
		if v.coordinator != i || v.root != root || !ed25519.Verify(f.serverKeys[i].pub, v.signed(d), v.signature) {
			return errors.New("inconsistent signed input/mask commitment")
		}
	}
	return nil
}
func (f *fixture) combine(d descriptor, inputs []input, shares []share, votes []vote) ([]byte, error) {
	body, _, e := f.combineWithRoot(d, inputs, shares, votes)
	return body, e
}

// Return the authenticated root from the same complete validation pass that
// produced the output. Callers must not reconstruct it from unverified input.
func (f *fixture) combineWithRoot(d descriptor, inputs []input, shares []share, votes []vote) ([]byte, [32]byte, error) {
	root, e := f.validate(d, inputs)
	if e != nil {
		return nil, [32]byte{}, e
	}
	if e = f.validateVotes(d, root, votes); e != nil {
		return nil, [32]byte{}, e
	}
	for c := range clients {
		for s := range coordinators {
			if inputs[c].keyHashes[s] != votes[s].keyHashes[c] {
				return nil, [32]byte{}, errors.New("inconsistent round key commitments")
			}
		}
	}
	if len(shares) != coordinators {
		return nil, [32]byte{}, errors.New("missing mask share")
	}
	body := make([]byte, d.size())
	for _, x := range inputs {
		xor(body, x.body)
	}
	for i, s := range shares {
		if s.coordinator != i || s.root != root || len(s.body) != len(body) || !ed25519.Verify(f.serverKeys[i].pub, s.signed(d), s.signature) {
			return nil, [32]byte{}, errors.New("invalid mask share")
		}
		if maskCommitment(d, i, root, s.body) != votes[i].maskHash {
			return nil, [32]byte{}, errors.New("mask share differs from prior commitment")
		}
		xor(body, s.body)
	}
	return body, root, nil
}
func (f *fixture) decode(d descriptor, body []byte) (map[int][]byte, error) {
	if len(body) != d.size() {
		return nil, errors.New("invalid output size")
	}
	out := map[int][]byte{}
	for pos, slot := range d.slots {
		cell := clearCell(body[pos*d.cell : (pos+1)*d.cell])
		n := int(binary.BigEndian.Uint16(cell))
		if n == 0 {
			for _, b := range cell {
				if b != 0 {
					return nil, errors.New("corrupted cover")
				}
			}
			continue
		}
		if n > cellCapacity(d) {
			return nil, errors.New("corrupted length")
		}
		payload := cell[2 : 2+n]
		sig := cell[2+n : 2+n+ed25519.SignatureSize]
		if !ed25519.Verify(f.slotKeys[slot].pub, slotMessage(d, slot, payload), sig) {
			return nil, errors.New("jammed anonymous slot")
		}
		for _, b := range cell[2+n+ed25519.SignatureSize:] {
			if b != 0 {
				return nil, errors.New("noncanonical padding")
			}
		}
		out[slot] = append([]byte{}, payload...)
	}
	return out, nil
}

type result struct {
	transportBytes                         uint64
	phaseTimings                           map[string]float64
	inputs                                 []input
	shares                                 []share
	raw                                    []byte
	messages                               map[int][]byte
	clientUp, clientDown, interCoordinator int
}

func (f *fixture) run(d descriptor, sender int, payload []byte) (result, error) {
	messages := map[int][]byte{}
	if sender >= 0 {
		messages[sender] = payload
	}
	return f.runMany(d, messages)
}

func (f *fixture) runMany(d descriptor, messages map[int][]byte) (result, error) {
	r := result{}
	// Reject a bad local batch before consuming any participant's round state.
	if !f.allowed(d) {
		return r, errors.New("unexpected round")
	}
	for c := range clients {
		if f.clientNext[c] != d.sequence {
			return r, errors.New("client round unavailable")
		}
	}
	for c, p := range messages {
		if c < 0 || c >= clients || len(p) > cellCapacity(d) {
			return r, errors.New("invalid local batch")
		}
		if len(p) > 0 {
			owned := false
			for _, slot := range d.slots {
				if slot == f.ownerSlot[c] {
					owned = true
				}
			}
			if !owned {
				return r, errors.New("unreserved local payload")
			}
		}
	}
	for c := range clients {
		x, e := f.prepare(c, d, messages[c])
		if e != nil {
			return r, e
		}
		r.inputs = append(r.inputs, x)
	}
	votes := []vote{}
	for s := range coordinators {
		v, e := f.commit(s, d, r.inputs)
		if e != nil {
			return r, e
		}
		votes = append(votes, v)
	}
	for s := range coordinators {
		v, e := f.release(s, d, votes)
		if e != nil {
			return r, e
		}
		r.shares = append(r.shares, v)
	}
	var e error
	r.raw, e = f.combine(d, r.inputs, r.shares, votes)
	if e != nil {
		return r, e
	}
	r.messages, e = f.decode(d, r.raw)
	if e != nil {
		return r, e
	}
	// Model a complete output certificate; all coordinators sign only a locally
	// validated output. These signatures do NOT conceal raw intermediate output.
	output := bytes.NewBuffer(d.wire())
	output.WriteString("output")
	root, _ := f.validate(d, r.inputs)
	output.Write(root[:])
	output.Write(r.raw)
	wire := output.Len()
	for _, k := range f.serverKeys {
		sig := ed25519.Sign(k.private, output.Bytes())
		if !ed25519.Verify(k.pub, output.Bytes(), sig) {
			return r, errors.New("output authentication failed")
		}
		wire += len(sig)
	}
	r.clientUp = len(r.inputs[0].wire(d))
	r.clientDown = wire
	// Explicit topology for byte accounting: one collector sends all signed
	// inputs to two other coordinators; each sends its vote/share to both others.
	for _, x := range r.inputs {
		r.interCoordinator += len(x.wire(d)) * (coordinators - 1)
	}
	for _, v := range votes {
		r.interCoordinator += (len(v.signed(d)) + len(v.signature)) * (coordinators - 1)
	}
	for _, s := range r.shares {
		r.interCoordinator += (len(s.signed(d)) + len(s.signature)) * (coordinators - 1)
	}
	f.advance(d, r)
	return r, nil
}
func (f *fixture) advance(d descriptor, r result) {
	if d.phase == 0 && len(r.messages) > 0 {
		f.expected = f.bulk(d.sequence/2, r, maxCell)
	} else {
		if d.phase == 0 {
			for c := range clients {
				f.clientNext[c]++
			}
			for s := range coordinators {
				f.servers[s].next++
			}
		}
		f.expected = f.reservation(d.sequence/2 + 1)
	}
}
func (f *fixture) reservation(round uint64) descriptor {
	slots := []int{}
	for i := range clients {
		slots = append(slots, i)
	}
	return descriptor{epoch: f.epoch, sequence: 2 * round, phase: 0, slots: slots, cell: reservationCell}
}
func (f *fixture) bulk(round uint64, reservation result, cell int) descriptor {
	slots := []int{}
	for offset := range clients {
		i := (int(round)*f.slotLimit + offset) % clients
		if len(reservation.messages[i]) > 0 {
			slots = append(slots, i)
		}
		if len(slots) == f.slotLimit {
			break
		}
	}
	sort.Ints(slots)
	return descriptor{epoch: f.epoch, sequence: 2*round + 1, phase: 1, previous: hash(reservation.raw), slots: slots, cell: cell}
}
func must(e error) {
	if e != nil {
		panic(e)
	}
}
func payloadFixture(size int) []byte {
	phrase := []byte("آزمایش فارسی انتشار امن خبر با متن بلند؛ دریافت و بازنشر خبر. ")
	out := bytes.Repeat(phrase, (size+len(phrase)-1)/len(phrase))
	return out[:size]
}
func (r result) verifyPayload(slot int, payload []byte) error {
	if len(r.messages) != 1 || !bytes.Equal(r.messages[slot], payload) {
		return fmt.Errorf("payload not delivered exactly once")
	}
	return nil
}
