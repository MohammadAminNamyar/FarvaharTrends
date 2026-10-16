// Experimental Dissent-inspired witness-bit investigation. This is a bounded
// local component, NOT an anonymous control transport or automatic expulsion.
// A slot signature must arrive over a separately protected control channel.
// Sending it directly from its owner would identify that owner.
package main

import (
	"bytes"
	"crypto/ed25519"
	"errors"
)

var errNoWitness = errors.New("no safe zero-to-one witness; do not reveal masks")

type accusation struct {
	context   [32]byte
	slot, bit int // bit is relative to the randomized cell, least-significant first
	signature []byte
}

func (a accusation) signed() []byte {
	b := bytes.NewBufferString("FT-WITNESS-ACCUSATION-v1")
	b.Write(a.context[:])
	put16(b, a.slot)
	put64(b, uint64(a.bit))
	return b.Bytes()
}
func (a accusation) digest() [32]byte { return hash(append(a.signed(), a.signature...)) }

type bitReport struct {
	accusation [32]byte
	server     int
	bits       [clients]byte
	signature  []byte
}

func (r bitReport) signed() []byte {
	b := bytes.NewBufferString("FT-WITNESS-BITS-v1")
	b.Write(r.accusation[:])
	put16(b, r.server)
	b.Write(r.bits[:])
	return b.Bytes()
}
func (r bitReport) digest() [32]byte { return hash(append(r.signed(), r.signature...)) }

type roundKeyRebuttal struct {
	accusation, report [32]byte
	client, server     int
	key                [32]byte // only this descriptor's AES key; NEVER the session seed
	signature          []byte
}

func (r roundKeyRebuttal) signed() []byte {
	b := bytes.NewBufferString("FT-WITNESS-REBUTTAL-v1")
	b.Write(r.accusation[:])
	b.Write(r.report[:])
	put16(b, r.client)
	put16(b, r.server)
	b.Write(r.key[:])
	return b.Bytes()
}

type faultFindings struct {
	// A coordinator's signed decomposition conflicts with its signed share.
	CoordinatorContradictions []int
	// These require a rebuttal opportunity; silence is not evidence of guilt.
	ClientCandidates []int
}

// One object per failed descriptor in this in-memory component. Recreating it
// would reset the disclosure budget. Production needs durable, crash-safe state.
type faultAudit struct {
	d            descriptor
	context      [32]byte
	inputs       []input
	votes        []vote
	shares       []share
	output       []byte
	clientPublic [clients]ed25519.PublicKey
	serverPublic [coordinators]ed25519.PublicKey
	slotPublic   [clients]ed25519.PublicKey
	accepted     [clients]*accusation // at most one bit per anonymous slot
	reports      [clients][coordinators]*bitReport
}

func newFaultAudit(f *fixture, d descriptor, xs []input, vs []vote, ss []share) (*faultAudit, error) {
	raw, e := f.combine(d, xs, ss, vs)
	if e != nil {
		return nil, e
	}
	if _, e = f.decode(d, raw); e == nil {
		return nil, errors.New("valid output is not a fault investigation")
	}
	a := &faultAudit{d: d, inputs: copyInputs(xs), votes: copyVotes(vs), output: append([]byte{}, raw...)}
	a.d.slots = append([]int{}, d.slots...)
	for _, s := range ss {
		s.body = append([]byte{}, s.body...)
		s.signature = append([]byte{}, s.signature...)
		a.shares = append(a.shares, s)
	}
	b := bytes.NewBuffer(d.wire())
	b.WriteString("witness-investigation/v1")
	root, _ := f.validate(d, xs)
	b.Write(root[:])
	for _, v := range vs {
		b.Write(v.signed(d))
		b.Write(v.signature)
	}
	for _, s := range ss {
		b.Write(s.signed(d))
		b.Write(s.signature)
	}
	b.Write(raw)
	a.context = hash(b.Bytes())
	for i := range clients {
		a.clientPublic[i] = append([]byte{}, f.clientKeys[i].pub...)
		a.slotPublic[i] = append([]byte{}, f.slotKeys[i].pub...)
	}
	for s := range coordinators {
		a.serverPublic[s] = append([]byte{}, f.serverKeys[s].pub...)
	}
	return a, nil
}
func bitAt(b []byte, bit int) byte { return (b[bit/8] >> uint(bit%8)) & 1 }
func (a *faultAudit) offset(w accusation) (int, error) {
	if w.context != a.context || w.slot < 0 || w.slot >= clients || w.bit < 0 || w.bit >= a.d.cell*8 {
		return 0, errors.New("invalid witness context or position")
	}
	for pos, slot := range a.d.slots {
		if slot == w.slot {
			return pos*a.d.cell*8 + w.bit, nil
		}
	}
	return 0, errors.New("witness outside this schedule")
}
func (a *faultAudit) verify(w accusation) (int, error) {
	bit, e := a.offset(w)
	if e != nil {
		return 0, e
	}
	if bitAt(a.output, bit) != 1 || !ed25519.Verify(a.slotPublic[w.slot], w.signed(), w.signature) {
		return 0, errors.New("witness not one or not authorized by slot")
	}
	return bit, nil
}

// makeAccusation uses only the calling client's keys and its original signed
// contribution. It never reports 1->0 corruption: opening that bit would reveal
// the honest slot owner. A fresh masked round is needed if no 0->1 witness exists.
func (a *faultAudit) makeAccusation(f *fixture, client int) (accusation, error) {
	if client < 0 || client >= clients || f.epoch != a.d.epoch {
		return accusation{}, errors.New("unknown client/epoch")
	}
	slot := f.ownerSlot[client]
	if slot < 0 || slot >= clients || len(f.slotKeys[slot].private) != ed25519.PrivateKeySize {
		return accusation{}, errors.New("caller does not own a slot")
	}
	w := accusation{context: a.context, slot: slot}
	start, e := a.offset(w)
	if e != nil {
		return accusation{}, e
	}
	clear := append([]byte{}, a.inputs[client].body...)
	for s := range coordinators {
		if !f.seedAvailable[client][s] {
			return accusation{}, errors.New("missing local mask")
		}
		if padKeyCommitment(a.d, client, s, f.padKey(client, s, a.d)) != a.inputs[client].keyHashes[s] {
			return accusation{}, errors.New("local mask differs from signed round commitment")
		}
		xor(clear, f.pad(client, s, a.d))
	}
	for bit := range a.d.cell * 8 {
		if bitAt(clear, start+bit) == 0 && bitAt(a.output, start+bit) == 1 {
			w.bit = bit
			w.signature = ed25519.Sign(f.slotKeys[slot].private, w.signed())
			return w, nil
		}
	}
	return accusation{}, errNoWitness
}
func (a *faultAudit) accept(w accusation) error {
	if _, e := a.verify(w); e != nil {
		return e
	}
	old := a.accepted[w.slot]
	if old != nil && old.digest() != w.digest() {
		return errors.New("witness disclosure budget already used for slot")
	}
	w.signature = append([]byte{}, w.signature...)
	a.accepted[w.slot] = &w
	return nil
}
func (a *faultAudit) acceptedBit(w accusation) (int, error) {
	bit, e := a.verify(w)
	if e != nil {
		return 0, e
	}
	if a.accepted[w.slot] == nil || a.accepted[w.slot].digest() != w.digest() {
		return 0, errors.New("witness not accepted")
	}
	return bit, nil
}
func (a *faultAudit) report(f *fixture, server int, w accusation) (bitReport, error) {
	bit, e := a.acceptedBit(w)
	if e != nil {
		return bitReport{}, e
	}
	if server < 0 || server >= coordinators || f.epoch != a.d.epoch || len(f.serverKeys[server].private) != ed25519.PrivateKeySize {
		return bitReport{}, errors.New("not local coordinator")
	}
	if old := a.reports[w.slot][server]; old != nil {
		r := *old
		r.signature = append([]byte{}, old.signature...)
		return r, nil
	}
	r := bitReport{accusation: w.digest(), server: server}
	for c := range clients {
		if !f.seedAvailable[c][server] {
			return bitReport{}, errors.New("missing local coordinator mask")
		}
		if padKeyCommitment(a.d, c, server, f.padKey(c, server, a.d)) != a.votes[server].keyHashes[c] {
			return bitReport{}, errors.New("local coordinator mask differs from commitment")
		}
		r.bits[c] = bitAt(f.pad(c, server, a.d), bit)
	}
	r.signature = ed25519.Sign(f.serverKeys[server].private, r.signed())
	saved := r
	saved.signature = append([]byte{}, r.signature...)
	a.reports[w.slot][server] = &saved
	return r, nil
}
func (a *faultAudit) verifyReport(w accusation, r bitReport) error {
	if _, e := a.acceptedBit(w); e != nil {
		return e
	}
	if r.server < 0 || r.server >= coordinators || r.accusation != w.digest() {
		return errors.New("wrong report context")
	}
	for _, b := range r.bits {
		if b > 1 {
			return errors.New("non-bit report")
		}
	}
	if !ed25519.Verify(a.serverPublic[r.server], r.signed(), r.signature) {
		return errors.New("invalid report signature")
	}
	return nil
}
func (a *faultAudit) investigate(w accusation, reports []bitReport) (faultFindings, error) {
	bit, e := a.acceptedBit(w)
	if e != nil {
		return faultFindings{}, e
	}
	if len(reports) != coordinators {
		return faultFindings{}, errors.New("missing reports; keep queued")
	}
	out := faultFindings{}
	for s, r := range reports {
		if r.server != s {
			return faultFindings{}, errors.New("duplicate/out-of-order report")
		}
		if e = a.verifyReport(w, r); e != nil {
			return faultFindings{}, e
		}
		var b byte
		for _, v := range r.bits {
			b ^= v
		}
		if b != bitAt(a.shares[s].body, bit) {
			out.CoordinatorContradictions = append(out.CoordinatorContradictions, s)
		}
	}
	for c := range clients {
		var b byte
		for _, r := range reports {
			b ^= r.bits[c]
		}
		if b != bitAt(a.inputs[c].body, bit) {
			out.ClientCandidates = append(out.ClientCandidates, c)
		}
	}
	return out, nil
}

// Only an authenticated false report about this client's bit can authorize
// opening this ONE ROUND key. The reporting coordinator already knows this key.
// Matching reports, absent reports, wrong clients and arbitrary requests reveal
// nothing. This is a narrower alternative to opening Dissent's shared seed.
func (a *faultAudit) rebut(f *fixture, client int, w accusation, r bitReport) (roundKeyRebuttal, error) {
	bit, e := a.acceptedBit(w)
	if e != nil {
		return roundKeyRebuttal{}, e
	}
	if e = a.verifyReport(w, r); e != nil {
		return roundKeyRebuttal{}, e
	}
	if client < 0 || client >= clients || f.epoch != a.d.epoch || !f.seedAvailable[client][r.server] || len(f.clientKeys[client].private) != ed25519.PrivateKeySize {
		return roundKeyRebuttal{}, errors.New("not local client")
	}
	k := f.padKey(client, r.server, a.d)
	h := padKeyCommitment(a.d, client, r.server, k)
	if h != a.inputs[client].keyHashes[r.server] || h != a.votes[r.server].keyHashes[client] || bitAt(padFromKey(k, a.d.size()), bit) == r.bits[client] {
		return roundKeyRebuttal{}, errors.New("no proved false report; no key disclosure")
	}
	x := roundKeyRebuttal{accusation: w.digest(), report: r.digest(), client: client, server: r.server, key: k}
	x.signature = ed25519.Sign(f.clientKeys[client].private, x.signed())
	return x, nil
}
func (a *faultAudit) verifyRebuttal(w accusation, r bitReport, x roundKeyRebuttal) error {
	bit, e := a.acceptedBit(w)
	if e != nil {
		return e
	}
	if e = a.verifyReport(w, r); e != nil {
		return e
	}
	if x.client < 0 || x.client >= clients || x.server != r.server || x.accusation != w.digest() || x.report != r.digest() || !ed25519.Verify(a.clientPublic[x.client], x.signed(), x.signature) {
		return errors.New("invalid rebuttal identity/context")
	}
	h := padKeyCommitment(a.d, x.client, x.server, x.key)
	if h != a.inputs[x.client].keyHashes[x.server] || h != a.votes[x.server].keyHashes[x.client] || bitAt(padFromKey(x.key, a.d.size()), bit) == r.bits[x.client] {
		return errors.New("rebuttal does not prove a false report")
	}
	return nil
}
