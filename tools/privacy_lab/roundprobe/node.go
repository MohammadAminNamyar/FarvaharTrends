// Role-separated laboratory RPC. TLS sockets carry real protocol messages, but
// an orchestrator still provisions keys and routes the test. Not a peer network.
package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	groupSetup "farvahartrends.local/privacy-lab/setupprobe/setup"
	control "farvahartrends.local/privacy-lab/verdictprobe/control"
)

const maxRPCBytes = 2 * 1024 * 1024

type sharedSeed struct {
	Client, Server int
	Value          []byte
}
type nodeConfig struct {
	FrozenCompletion                                bool `json:",omitempty"`
	AtomicPublication                               bool `json:",omitempty"`
	RequireCommonSchedule                           bool `json:",omitempty"`
	RoleLocalOutbox                                 bool `json:",omitempty"`
	Durable                                         bool
	AnonymousSetup                                  bool
	AllowFaultInjection                             bool
	Role                                            string
	Index                                           int
	Epoch                                           []byte
	SlotLimit                                       int
	ClientPublic, ServerPublic, SlotPublic          [][]byte
	Private                                         []byte
	Slot                                            int
	SlotPrivate                                     []byte
	Seeds                                           []sharedSeed
	Certificate, CertificateKey, ControlCertificate []byte
}

func configFor(f *fixture, role string, index int) nodeConfig {
	c := nodeConfig{Role: role, Index: index, Epoch: append([]byte{}, f.epoch[:]...), SlotLimit: f.slotLimit, Slot: -1}
	for _, k := range f.clientKeys {
		c.ClientPublic = append(c.ClientPublic, k.pub)
	}
	for _, k := range f.serverKeys {
		c.ServerPublic = append(c.ServerPublic, k.pub)
	}
	for _, k := range f.slotKeys {
		c.SlotPublic = append(c.SlotPublic, k.pub)
	}
	if role == "client" {
		c.Private = f.clientKeys[index].private
		c.Slot = f.ownerSlot[index]
		c.SlotPrivate = f.slotKeys[c.Slot].private
		for s := range coordinators {
			c.Seeds = append(c.Seeds, sharedSeed{index, s, f.seeds[index][s][:]})
		}
	} else if role == "coordinator" {
		c.Private = f.serverKeys[index].private
		for i := range clients {
			c.Seeds = append(c.Seeds, sharedSeed{i, index, f.seeds[i][index][:]})
		}
	} else {
		panic("unknown role")
	}
	return c
}
func (c nodeConfig) fixture() (*fixture, error) {
	if len(c.Epoch) != 32 || c.SlotLimit < 1 || c.SlotLimit > clients || len(c.ClientPublic) != clients || len(c.ServerPublic) != coordinators || len(c.SlotPublic) != clients || len(c.Private) != ed25519.PrivateKeySize {
		return nil, errors.New("invalid role configuration")
	}
	f := new(fixture)
	copy(f.epoch[:], c.Epoch)
	f.slotLimit = c.SlotLimit
	for i, p := range c.ClientPublic {
		if len(p) != ed25519.PublicKeySize {
			return nil, errors.New("bad public key")
		}
		f.clientKeys[i].pub = ed25519.PublicKey(p)
		f.ownerSlot[i] = -1
	}
	for i, p := range c.ServerPublic {
		if len(p) != ed25519.PublicKeySize {
			return nil, errors.New("bad public key")
		}
		f.serverKeys[i].pub = ed25519.PublicKey(p)
	}
	for i, p := range c.SlotPublic {
		if len(p) != ed25519.PublicKeySize {
			return nil, errors.New("bad slot key")
		}
		f.slotKeys[i].pub = ed25519.PublicKey(p)
	}
	count := 0
	switch c.Role {
	case "client":
		if c.Index < 0 || c.Index >= clients || c.Slot < 0 || c.Slot >= clients || len(c.SlotPrivate) != ed25519.PrivateKeySize || len(c.Seeds) != coordinators {
			return nil, errors.New("invalid client secrets")
		}
		f.clientKeys[c.Index].private = ed25519.PrivateKey(c.Private)
		f.slotKeys[c.Slot].private = ed25519.PrivateKey(c.SlotPrivate)
		f.ownerSlot[c.Index] = c.Slot
		if !bytes.Equal(f.clientKeys[c.Index].private.Public().(ed25519.PublicKey), f.clientKeys[c.Index].pub) || !bytes.Equal(f.slotKeys[c.Slot].private.Public().(ed25519.PublicKey), f.slotKeys[c.Slot].pub) {
			return nil, errors.New("private/public key mismatch")
		}
	case "coordinator":
		if c.Index < 0 || c.Index >= coordinators || c.Slot != -1 || len(c.SlotPrivate) != 0 || len(c.Seeds) != clients {
			return nil, errors.New("invalid coordinator secrets")
		}
		f.serverKeys[c.Index].private = ed25519.PrivateKey(c.Private)
		if !bytes.Equal(f.serverKeys[c.Index].private.Public().(ed25519.PublicKey), f.serverKeys[c.Index].pub) {
			return nil, errors.New("private/public key mismatch")
		}
	default:
		return nil, errors.New("unknown role")
	}
	for _, s := range c.Seeds {
		if s.Client < 0 || s.Client >= clients || s.Server < 0 || s.Server >= coordinators || len(s.Value) != 32 || f.seedAvailable[s.Client][s.Server] {
			return nil, errors.New("invalid or duplicate seed")
		}
		if c.Role == "client" && s.Client != c.Index || c.Role == "coordinator" && s.Server != c.Index {
			return nil, errors.New("foreign secret in role config")
		}
		copy(f.seeds[s.Client][s.Server][:], s.Value)
		f.seedAvailable[s.Client][s.Server] = true
		count++
	}
	if count != len(c.Seeds) {
		return nil, errors.New("seed count")
	}
	f.expected = f.reservation(0)
	return f, nil
}

type rpcDescriptor struct {
	Epoch    []byte `cbor:"1,keyasint,omitzero"`
	Sequence uint64 `cbor:"2,keyasint,omitzero"`
	Phase    byte   `cbor:"3,keyasint,omitzero"`
	Previous []byte `cbor:"4,keyasint,omitzero"`
	Slots    []int  `cbor:"5,keyasint,omitzero"`
	Cell     int    `cbor:"6,keyasint,omitzero"`
}

func descriptorRPC(d descriptor) rpcDescriptor {
	return rpcDescriptor{d.epoch[:], d.sequence, d.phase, d.previous[:], d.slots, d.cell}
}
func (w rpcDescriptor) value() (descriptor, error) {
	if len(w.Epoch) != 32 || len(w.Previous) != 32 {
		return descriptor{}, errors.New("invalid descriptor hashes")
	}
	d := descriptor{sequence: w.Sequence, phase: w.Phase, slots: w.Slots, cell: w.Cell}
	copy(d.epoch[:], w.Epoch)
	copy(d.previous[:], w.Previous)
	if !d.valid() {
		return d, errors.New("invalid descriptor")
	}
	return d, nil
}

type rpcInput struct {
	Client    int      `cbor:"1,keyasint,omitzero"`
	Body      []byte   `cbor:"2,keyasint,omitzero"`
	Signature []byte   `cbor:"3,keyasint,omitzero"`
	KeyHashes [][]byte `cbor:"4,keyasint,omitzero"`
}
type rpcVote struct {
	Coordinator int      `cbor:"1,keyasint,omitzero"`
	Root        []byte   `cbor:"2,keyasint,omitzero"`
	MaskHash    []byte   `cbor:"3,keyasint,omitzero"`
	Signature   []byte   `cbor:"4,keyasint,omitzero"`
	KeyHashes   [][]byte `cbor:"5,keyasint,omitzero"`
}
type rpcShare struct {
	Coordinator int    `cbor:"1,keyasint,omitzero"`
	Root        []byte `cbor:"2,keyasint,omitzero"`
	Body        []byte `cbor:"3,keyasint,omitzero"`
	Signature   []byte `cbor:"4,keyasint,omitzero"`
}
type rpcRequest struct {
	Schedule            *reservationSchedule   `json:",omitempty" cbor:"11,keyasint,omitzero"`
	ScheduleCertificate *scheduleCertificate   `json:",omitempty" cbor:"12,keyasint,omitzero"`
	Op                  string                 `cbor:"1,keyasint"`
	Descriptor          rpcDescriptor          `cbor:"2,keyasint,omitzero"`
	Payload             []byte                 `cbor:"3,keyasint,omitzero"`
	Inputs              []rpcInput             `cbor:"4,keyasint,omitzero"`
	Votes               []rpcVote              `cbor:"5,keyasint,omitzero"`
	Shares              []rpcShare             `cbor:"6,keyasint,omitzero"`
	Root                []byte                 `cbor:"7,keyasint,omitzero"`
	Output              []byte                 `cbor:"8,keyasint,omitzero"`
	Signatures          [][]byte               `cbor:"9,keyasint,omitzero"`
	SetupRoster         *groupSetup.Roster     `json:",omitempty" cbor:"13,keyasint,omitzero"`
	SetupHellos         []groupSetup.Hello     `json:",omitempty" cbor:"14,keyasint,omitzero"`
	SetupTranscript     *groupSetup.Transcript `json:",omitempty" cbor:"15,keyasint,omitzero"`
	SetupVotes          []groupSetup.Vote      `json:",omitempty" cbor:"16,keyasint,omitzero"`
	SetupRelease        *groupSetup.Release    `json:",omitempty" cbor:"17,keyasint,omitzero"`
	ControlHellos       []control.Hello        `json:",omitempty" cbor:"18,keyasint,omitzero"`
	ControlInputs       []control.Contribution `json:",omitempty" cbor:"19,keyasint,omitzero"`
	ControlVotes        []control.Vote         `json:",omitempty" cbor:"20,keyasint,omitzero"`
	ControlShares       []control.Share        `json:",omitempty" cbor:"21,keyasint,omitzero"`
	ControlOutputs      []control.Output       `json:",omitempty" cbor:"22,keyasint,omitzero"`
	ControlCertificates []control.Certificate  `json:",omitempty" cbor:"23,keyasint,omitzero"`
}
type rpcResponse struct {
	Error                      string                `json:",omitempty" cbor:"1,keyasint,omitzero"`
	Input                      *rpcInput             `json:",omitempty" cbor:"2,keyasint,omitzero"`
	Vote                       *rpcVote              `json:",omitempty" cbor:"3,keyasint,omitzero"`
	Share                      *rpcShare             `json:",omitempty" cbor:"4,keyasint,omitzero"`
	Root                       []byte                `json:",omitempty" cbor:"5,keyasint,omitzero"`
	Output                     []byte                `json:",omitempty" cbor:"6,keyasint,omitzero"`
	Signature                  []byte                `json:",omitempty" cbor:"7,keyasint,omitzero"`
	CPUms                      float64               `cbor:"10,keyasint,omitzero"`
	JournalCommits             uint64                `json:",omitempty" cbor:"11,keyasint,omitzero"`
	JournalPlaintextBytes      uint64                `json:",omitempty" cbor:"12,keyasint,omitzero"`
	JournalFileBytes           int64                 `json:",omitempty" cbor:"13,keyasint,omitzero"`
	JournalPendingTiming       *journalTiming        `json:",omitempty" cbor:"14,keyasint,omitzero"`
	JournalCommitTiming        *journalTiming        `json:",omitempty" cbor:"15,keyasint,omitzero"`
	JournalPendingEncodeTiming *journalTiming        `json:",omitempty" cbor:"16,keyasint,omitzero"`
	JournalPendingWriteTiming  *journalTiming        `json:",omitempty" cbor:"17,keyasint,omitzero"`
	JournalStateEncodeTiming   *journalTiming        `json:",omitempty" cbor:"18,keyasint,omitzero"`
	JournalStateWriteTiming    *journalTiming        `json:",omitempty" cbor:"19,keyasint,omitzero"`
	ReadBytes                  uint64                `cbor:"20,keyasint,omitzero"`
	WrittenBytes               uint64                `cbor:"21,keyasint,omitzero"`
	CacheEntries               int                   `cbor:"22,keyasint,omitzero"`
	PendingInputBytes          int                   `cbor:"23,keyasint,omitzero"`
	Role                       string                `cbor:"24,keyasint,omitzero"`
	Index                      int                   `cbor:"25,keyasint,omitzero"`
	SetupHello                 *groupSetup.Hello     `json:",omitempty" cbor:"30,keyasint,omitzero"`
	SetupInput                 *groupSetup.Input     `json:",omitempty" cbor:"31,keyasint,omitzero"`
	SetupMix                   *groupSetup.Mix       `json:",omitempty" cbor:"32,keyasint,omitzero"`
	SetupVote                  *groupSetup.Vote      `json:",omitempty" cbor:"33,keyasint,omitzero"`
	SetupShare                 *groupSetup.Share     `json:",omitempty" cbor:"34,keyasint,omitzero"`
	SetupFinal                 *groupSetup.Final     `json:",omitempty" cbor:"35,keyasint,omitzero"`
	ControlHello               *control.Hello        `json:",omitempty" cbor:"40,keyasint,omitzero"`
	ControlSession             string                `json:",omitempty" cbor:"41,keyasint,omitzero"`
	ControlDescriptor          *control.Descriptor   `json:",omitempty" cbor:"42,keyasint,omitzero"`
	ControlInput               *control.Contribution `json:",omitempty" cbor:"43,keyasint,omitzero"`
	ControlVote                *control.Vote         `json:",omitempty" cbor:"44,keyasint,omitzero"`
	ControlShare               *control.Share        `json:",omitempty" cbor:"45,keyasint,omitzero"`
	ControlOutput              []control.Output      `json:",omitempty" cbor:"46,keyasint,omitzero"`
	ControlCertificate         *control.Certificate  `json:",omitempty" cbor:"47,keyasint,omitzero"`
	WitnessReports             []rpcBitReport        `json:",omitempty" cbor:"48,keyasint,omitzero"`
}

func nativeInputs(xs []rpcInput) ([]input, error) {
	if len(xs) != clients {
		return nil, errors.New("incomplete input set")
	}
	out := make([]input, len(xs))
	for i, x := range xs {
		if len(x.Body) > clients*maxCell || len(x.Signature) != ed25519.SignatureSize || len(x.KeyHashes) != coordinators {
			return nil, errors.New("invalid input size")
		}
		out[i] = input{client: x.Client, body: x.Body, signature: x.Signature}
		for j, h := range x.KeyHashes {
			if len(h) != 32 {
				return nil, errors.New("invalid input key commitment")
			}
			copy(out[i].keyHashes[j][:], h)
		}
	}
	return out, nil
}
func nativeVotes(vs []rpcVote) ([]vote, error) {
	if len(vs) != coordinators {
		return nil, errors.New("incomplete votes")
	}
	out := make([]vote, len(vs))
	for i, v := range vs {
		if len(v.Root) != 32 || len(v.MaskHash) != 32 || len(v.Signature) != ed25519.SignatureSize || len(v.KeyHashes) != clients {
			return nil, errors.New("invalid vote")
		}
		out[i] = vote{coordinator: v.Coordinator, signature: v.Signature}
		copy(out[i].root[:], v.Root)
		copy(out[i].maskHash[:], v.MaskHash)
		for j, h := range v.KeyHashes {
			if len(h) != 32 {
				return nil, errors.New("invalid coordinator key commitment")
			}
			copy(out[i].keyHashes[j][:], h)
		}
	}
	return out, nil
}
func nativeShares(ss []rpcShare) ([]share, error) {
	if len(ss) != coordinators {
		return nil, errors.New("incomplete shares")
	}
	out := make([]share, len(ss))
	for i, s := range ss {
		if len(s.Root) != 32 || len(s.Body) > clients*maxCell || len(s.Signature) != ed25519.SignatureSize {
			return nil, errors.New("invalid share")
		}
		out[i] = share{coordinator: s.Coordinator, body: s.Body, signature: s.Signature}
		copy(out[i].root[:], s.Root)
	}
	return out, nil
}
func outputSigned(d descriptor, root, body []byte) []byte {
	b := bytes.NewBuffer(d.wire())
	b.WriteString("output")
	b.Write(root)
	b.Write(body)
	return b.Bytes()
}

type cachedResponse struct {
	digest   [32]byte
	response rpcResponse
}
type roleNode struct {
	localOperations []localOperationTiming
	schedule        *scheduleState
	scheduleClock   *scheduleClock
	localNow        func() clockReading
	restored        bool
	mu              sync.Mutex
	outbox          *localOutbox
	journal         *roleJournal
	config          nodeConfig
	state           *fixture
	cache           []cachedResponse
	pending         *acceptedBatch
	setup           *setupRole
	control         *controlRole
	prepared        *input
}

type acceptedBatch struct {
	descriptorHash, root [32]byte
	inputs               []input
	votes                []vote
}

func copyInputs(xs []input) []input {
	out := make([]input, len(xs))
	for i, x := range xs {
		out[i] = input{client: x.client, body: append([]byte{}, x.body...), signature: append([]byte{}, x.signature...), keyHashes: x.keyHashes}
	}
	return out
}
func copyVotes(vs []vote) []vote {
	out := append([]vote{}, vs...)
	for i := range out {
		out[i].signature = append([]byte{}, vs[i].signature...)
	}
	return out
}

func newRoleNode(c nodeConfig) (*roleNode, error) {
	if !validPublicationStorageConfig(c) {
		return nil, errors.New("atomic publication requires an ordinary durable role")
	}
	if !validScheduleConfig(c) {
		return nil, errors.New("common schedule requires durable ordinary roles and client outboxes")
	}
	if c.RoleLocalOutbox && (c.Role != "client" || !c.Durable || c.AllowFaultInjection) {
		return nil, errors.New("local outbox requires an ordinary durable client")
	}
	var n *roleNode
	var e error
	if c.AnonymousSetup {
		n, e = newSetupRoleNode(c)
	} else {
		var f *fixture
		f, e = c.fixture()
		if e == nil {
			n = &roleNode{config: c, state: f}
		}
	}
	if e != nil {
		return nil, e
	}
	if c.RoleLocalOutbox {
		n.outbox = &localOutbox{Next: 1}
	}
	return n, nil
}
func (n *roleNode) handle(q rpcRequest) (response rpcResponse, resultErr error) {
	started := time.Now()
	cpuStarted := cpuTime()
	n.mu.Lock()
	defer n.mu.Unlock()
	locked, journalBefore := time.Now(), observeJournal(n.journal)
	defer func() { n.observeOperation(q, started, locked, cpuStarted, journalBefore, resultErr != nil) }()
	if n.config.RoleLocalOutbox && len(q.Payload) != 0 {
		return rpcResponse{}, errors.New("plaintext submission forbidden on peer-facing RPC")
	}
	if q.Op == "stats" {
		if n.config.RoleLocalOutbox {
			return rpcResponse{Role: n.config.Role, Index: n.config.Index}, nil
		}
		return n.statsLocked(), nil
	}
	if n.journal != nil && n.journal.poisoned {
		return rpcResponse{}, errors.New("durable role requires recovery; cached responses are fenced")
	}
	encoded, e := json.Marshal(q)
	if e != nil {
		return rpcResponse{}, e
	}
	digest := hash(encoded)
	for _, item := range n.cache {
		if item.digest == digest {
			return item.response, nil
		}
	}
	// A clock-window rejection changes no cryptographic phase or proof budget.
	// Reject it before two durable writes; repeated early RPCs must not force
	// storage activity. execute checks again after any intervening disk work.
	if n.config.RequireCommonSchedule && (q.Op == "prepare" || q.Op == "commit" || q.Op == "accept-and-prepare") {
		d, e := q.Descriptor.value()
		if e != nil || n.state == nil || !n.state.allowed(d) {
			return rpcResponse{}, errors.New("unexpected or stale scheduled round")
		}
		if e := n.scheduleAllows(q.Op, d); e != nil {
			return rpcResponse{}, e
		}
	}
	if n.journal != nil {
		return n.journal.execute(n, q, digest)
	}
	return n.executeCached(q, digest)
}
func (n *roleNode) executeCached(q rpcRequest, digest [32]byte) (rpcResponse, error) {
	r, e := n.execute(q)
	if e != nil {
		return rpcResponse{}, e
	}
	if len(n.cache) == 8 {
		copy(n.cache, n.cache[1:])
		n.cache = n.cache[:7]
	}
	n.cache = append(n.cache, cachedResponse{digest, r})
	return r, nil
}
func (n *roleNode) execute(q rpcRequest) (rpcResponse, error) {
	if strings.HasPrefix(q.Op, "setup-") {
		return n.setupCall(q)
	}
	f := n.state
	if f == nil {
		return rpcResponse{}, errors.New("anonymous setup not completed; no publication fallback")
	}
	if strings.HasPrefix(q.Op, "schedule-") {
		return n.scheduleCall(q)
	}
	if strings.HasPrefix(q.Op, "control-") {
		return n.controlCall(q)
	}
	d, e := q.Descriptor.value()
	if e != nil || !f.allowed(d) {
		return rpcResponse{}, errors.New("unexpected or stale round")
	}
	if n.config.RequireCommonSchedule && (q.Op == "prepare" || q.Op == "commit" || q.Op == "accept-and-prepare") {
		if e := n.scheduleAllows(q.Op, d); e != nil {
			return rpcResponse{}, e
		}
	}
	i := n.config.Index
	if n.config.Role == "client" {
		switch q.Op {
		case "prepare", "prepare-corrupt":
			if q.Op == "prepare-corrupt" && !n.config.AllowFaultInjection {
				return rpcResponse{}, errors.New("fault injection not enabled for this laboratory role")
			}
			payload := q.Payload
			if n.outbox != nil {
				if f.clientNext[i] != d.sequence {
					return rpcResponse{}, errors.New("client round already consumed")
				}
				payload, e = n.outbox.selectPayload(d, n.config.Slot)
				if e != nil {
					return rpcResponse{}, e
				}
			}
			x, e := f.prepare(i, d, payload)
			if e != nil {
				return rpcResponse{}, e
			}
			if q.Op == "prepare-corrupt" {
				for j := range x.body {
					x.body[j] ^= 255
				}
				x.signature = ed25519.Sign(f.clientKeys[i].private, x.signed(d))
			}
			prepared := copyInputs([]input{x})[0]
			n.prepared = &prepared
			hashes := [][]byte{}
			for _, h := range x.keyHashes {
				hashes = append(hashes, append([]byte{}, h[:]...))
			}
			return rpcResponse{Input: &rpcInput{x.client, x.body, x.signature, hashes}}, nil
		case "accept", "accept-and-prepare":
			fused := q.Op == "accept-and-prepare"
			if fused && (!n.config.RequireCommonSchedule || n.outbox == nil || d.phase != 0) {
				return rpcResponse{}, errors.New("fused preparation requires a scheduled private reservation")
			}
			if len(q.Root) != 32 || len(q.Output) != d.size() || len(q.Signatures) != coordinators || f.clientNext[i] != d.sequence+1 {
				return rpcResponse{}, errors.New("incomplete output certificate")
			}
			signed := outputSigned(d, q.Root, q.Output)
			for s, k := range f.serverKeys {
				if !ed25519.Verify(k.pub, signed, q.Signatures[s]) {
					return rpcResponse{}, errors.New("invalid output certificate")
				}
			}
			messages, e := f.decode(d, q.Output)
			if e != nil {
				return rpcResponse{}, e
			}
			if n.outbox != nil {
				if e = n.outbox.accept(d, n.config.Slot, messages, hash(q.Output)); e != nil {
					return rpcResponse{}, e
				}
			}
			f.advance(d, result{raw: q.Output, messages: messages})
			// The authenticated certificate completes this descriptor. Its
			// prepared contribution is no longer needed for active-round fault
			// investigation; exact retries remain in the bounded reply cache.
			// Drop the duplicate before the next checkpoint (or fused prepare).
			n.prepared = nil
			if fused && f.expected.phase == 1 {
				// Derive the next descriptor exclusively from the verified common
				// reservation. The outer journal commits both transitions and the
				// cached response before releasing any new contribution. execute
				// rechecks the admitted phase policy and uses the pinned outbox.
				return n.execute(rpcRequest{Op: "prepare", Descriptor: descriptorRPC(f.expected)})
			}
			return rpcResponse{}, nil
		default:
			return rpcResponse{}, errors.New("operation not permitted for client")
		}
	}
	switch q.Op {
	case "commit":
		xs, e := nativeInputs(q.Inputs)
		if e != nil {
			return rpcResponse{}, e
		}
		v, e := f.commit(i, d, xs)
		if e != nil {
			return rpcResponse{}, e
		}
		n.pending = &acceptedBatch{descriptorHash: hash(d.wire()), root: v.root, inputs: copyInputs(xs)}
		hashes := [][]byte{}
		for _, h := range v.keyHashes {
			hashes = append(hashes, append([]byte{}, h[:]...))
		}
		return rpcResponse{Vote: &rpcVote{v.coordinator, v.root[:], v.maskHash[:], v.signature, hashes}}, nil
	case "release":
		if n.pending == nil || n.pending.descriptorHash != hash(d.wire()) {
			return rpcResponse{}, errors.New("missing committed batch before release")
		}
		vs, e := nativeVotes(q.Votes)
		if e != nil {
			return rpcResponse{}, e
		}
		s, e := f.release(i, d, vs)
		if e != nil {
			return rpcResponse{}, e
		}
		n.pending.votes = copyVotes(vs)
		return rpcResponse{Share: &rpcShare{s.coordinator, s.root[:], s.body, s.signature}}, nil
	case "finish":
		if f.servers[i].next != d.sequence+1 || f.servers[i].committed {
			return rpcResponse{}, errors.New("own share not released")
		}
		if len(q.Inputs) != 0 || n.pending == nil || n.pending.descriptorHash != hash(d.wire()) || len(q.Root) != 32 || !bytes.Equal(q.Root, n.pending.root[:]) {
			return rpcResponse{}, errors.New("missing or mismatched committed batch")
		}
		xs := n.pending.inputs
		ss, e := nativeShares(q.Shares)
		if e != nil {
			return rpcResponse{}, e
		}
		raw, root, e := f.combineWithRoot(d, xs, ss, n.pending.votes)
		if e != nil {
			return rpcResponse{}, e
		}
		messages, e := f.decode(d, raw)
		if e != nil {
			return rpcResponse{}, e
		}
		sig := ed25519.Sign(f.serverKeys[i].private, outputSigned(d, root[:], raw))
		f.advance(d, result{raw: raw, messages: messages})
		n.pending = nil
		return rpcResponse{Root: root[:], Output: raw, Signature: sig}, nil
	default:
		return rpcResponse{}, errors.New("operation not permitted for coordinator")
	}
}

type wireCounter struct{ read, written atomic.Uint64 }
type countedConn struct {
	net.Conn
	counter *wireCounter
}

func (c *countedConn) Read(b []byte) (int, error) {
	n, e := c.Conn.Read(b)
	c.counter.read.Add(uint64(n))
	return n, e
}
func (c *countedConn) Write(b []byte) (int, error) {
	n, e := c.Conn.Write(b)
	c.counter.written.Add(uint64(n))
	return n, e
}

type countedListener struct {
	net.Listener
	counter *wireCounter
}

func (l *countedListener) Accept() (net.Conn, error) {
	c, e := l.Listener.Accept()
	if e != nil {
		return nil, e
	}
	return &countedConn{c, l.counter}, nil
}
func laboratoryCertificate(name string) ([]byte, []byte) {
	pub, priv, e := ed25519.GenerateKey(rand.Reader)
	must(e)
	serial, e := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	must(e)
	tmpl := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: name}, NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(24 * time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth}, DNSNames: []string{"localhost"}, IPAddresses: []net.IP{net.ParseIP("127.0.0.1")}}
	der, e := x509.CreateCertificate(rand.Reader, tmpl, tmpl, pub, priv)
	must(e)
	key, e := x509.MarshalPKCS8PrivateKey(priv)
	must(e)
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: key})
}
func serveRole(configPath, listen, wireCodec string) error {
	host, _, e := net.SplitHostPort(listen)
	if e != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() {
		return errors.New("laboratory node must bind loopback")
	}
	data, e := os.ReadFile(configPath)
	if e != nil {
		return e
	}
	var c nodeConfig
	if e = json.Unmarshal(data, &c); e != nil {
		return e
	}
	var node *roleNode
	if c.Durable {
		if _, used := os.Stat(configPath + ".started"); used == nil || !os.IsNotExist(used) {
			return errors.New("cannot adopt a used non-durable configuration")
		}
		node, e = openDurableRole(c, configPath+".state")
	} else {
		node, e = newRoleNode(c)
	}
	if e != nil {
		return e
	}
	if node.journal != nil {
		defer func() { node.mu.Lock(); defer node.mu.Unlock(); _ = node.journal.close() }()
	}
	cert, e := tls.X509KeyPair(c.Certificate, c.CertificateKey)
	if e != nil {
		return e
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(c.ControlCertificate) {
		return errors.New("invalid control certificate")
	}
	if !c.Durable {
		if e = claimRoleConfiguration(configPath); e != nil {
			return e
		}
	}
	raw, e := net.Listen("tcp", listen)
	if e != nil {
		return e
	}
	defer raw.Close()
	counts := new(wireCounter)
	tlsConfig := &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{cert}, ClientAuth: tls.RequireAndVerifyClientCert, ClientCAs: pool}
	if wireCodec == "cbor-framed-v1" {
		server := newFramedRPCServer(&countedListener{raw, counts}, tlsConfig, counts, node.handle)
		must(json.NewEncoder(os.Stdout).Encode(map[string]interface{}{"ready": true, "address": raw.Addr().String(), "role": c.Role, "index": c.Index, "pid": os.Getpid(), "wireCodec": wireCodec, "securityGatePassed": false}))
		go func() { servePrivatePipe(node); server.Close() }()
		return server.Serve()
	}
	listener := tls.NewListener(&countedListener{raw, counts}, tlsConfig)
	busy := make(chan struct{}, 1)
	server := &http.Server{ReadHeaderTimeout: 2 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 8192, Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || r.URL.Path != "/round" {
			http.Error(w, "unknown request", http.StatusNotFound)
			return
		}
		select {
		case busy <- struct{}{}:
			defer func() { <-busy }()
		default:
			http.Error(w, "busy", http.StatusTooManyRequests)
			return
		}
		defer r.Body.Close()
		codec := "json"
		switch r.Header.Get("Content-Type") {
		case "", "application/json":
		case compactRPCContentType:
			codec = "cbor-v1"
		default:
			http.Error(w, "unsupported RPC codec", http.StatusUnsupportedMediaType)
			return
		}
		data, readErr := io.ReadAll(http.MaxBytesReader(w, r.Body, maxRPCBytes))
		var q rpcRequest
		if readErr != nil || decodeRPC(codec, data, &q) != nil {
			http.Error(w, "invalid bounded request", http.StatusBadRequest)
			return
		}
		response, e := node.handle(q)
		status := http.StatusOK
		if e != nil {
			response = rpcResponse{Error: e.Error()}
			status = http.StatusConflict
		}
		response.ReadBytes = counts.read.Load()
		response.WrittenBytes = counts.written.Load()
		encoded, e := encodeRPC(codec, response)
		if e != nil {
			http.Error(w, "response encoding failed", http.StatusInternalServerError)
			return
		}
		if codec == "json" {
			encoded = append(encoded, '\n')
		}
		w.Header().Set("Content-Type", rpcContentType(codec))
		w.WriteHeader(status)
		_, _ = w.Write(encoded)
	})}
	// The parent holds this pipe open. An interrupted/killed controller closes
	// it automatically, so laboratory children do not remain orphaned listeners.
	must(json.NewEncoder(os.Stdout).Encode(map[string]interface{}{"ready": true, "address": raw.Addr().String(), "role": c.Role, "index": c.Index, "pid": os.Getpid(), "wireCodec": wireCodec, "securityGatePassed": false}))
	go func() { servePrivatePipe(node); _ = server.Close() }()
	e = server.Serve(listener)
	if e == http.ErrServerClosed {
		return nil
	}
	return fmt.Errorf("role node: %w", e)
}

func claimRoleConfiguration(path string) error {
	// A one-shot laboratory safeguard against restarting this exact config and
	// reusing its epoch/stream masks. Not a complete anti-rollback journal: copies
	// of configs or malicious filesystem rollback remain outside this fixture.
	f, e := os.OpenFile(path+".started", os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if e != nil {
		return fmt.Errorf("role config already used or cannot be claimed; provision a fresh epoch: %w", e)
	}
	defer f.Close()
	_, e = f.WriteString(time.Now().UTC().Format(time.RFC3339Nano) + "\n")
	if e != nil {
		return e
	}
	return f.Sync()
}
