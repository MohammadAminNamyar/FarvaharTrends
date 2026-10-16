package main

// Local-only publication state. Nothing in this file is a peer RPC endpoint.
// The future application adapter must sign/validate every action before enqueue.
import (
	"bytes"
	"crypto/ed25519"
	"errors"
	"math"
)

const outboxMaxItems = 64
const outboxMaxBytes = 256 << 10
const outboxReceiptLimit = 128

type localSubmission struct {
	Sequence uint64
	Payload  []byte
}
type queuedPublication struct {
	Eligibility *publicationEligibility `json:",omitempty"`
	Sequence    uint64
	Digest      [32]byte
	Payload     []byte
}
type localReceipt struct {
	Sequence          uint64
	Digest            [32]byte
	Status            string
	Epoch, OutputHash [32]byte
	PhaseSequence     uint64
}
type localOutbox struct {
	Next           uint64
	Pending        []queuedPublication
	Released       []localReceipt
	SelectionMade  bool
	SelectionRound uint64
	Pinned         uint64
}

func (o *localOutbox) validate() error {
	if o.Next == 0 || len(o.Pending) > outboxMaxItems || len(o.Released) > outboxReceiptLimit {
		return errors.New("invalid outbox limits")
	}
	var prior uint64
	for _, r := range o.Released {
		if r.Sequence <= prior || r.Sequence >= o.Next || r.Status != "released" || r.Epoch == [32]byte{} || r.OutputHash == [32]byte{} || r.PhaseSequence%2 != 1 {
			return errors.New("invalid release receipt")
		}
		prior = r.Sequence
	}
	total := 0
	for _, p := range o.Pending {
		if p.Sequence <= prior || p.Sequence >= o.Next || len(p.Payload) == 0 || len(p.Payload) > maxCell-cellNonceSize-66 || hash(p.Payload) != p.Digest {
			return errors.New("invalid queued publication")
		}
		prior = p.Sequence
		total += len(p.Payload)
	}
	if total > outboxMaxBytes {
		return errors.New("outbox byte budget exceeded")
	}
	if prior+1 != o.Next {
		return errors.New("outbox high-water mark mismatch")
	}
	if o.Pinned != 0 && (!o.SelectionMade || len(o.Pending) == 0 || o.Pending[0].Sequence != o.Pinned) {
		return errors.New("invalid pinned publication")
	}
	return nil
}

// Recovery must agree with the cryptographic phase, not just the queue's own
// counters. This detects inconsistent authenticated local snapshots; it does
// not turn the journal into rollback-resistant storage.
func (n *roleNode) validateOutboxPhase() error {
	o := n.outbox
	if o == nil {
		return nil
	}
	if n.state == nil {
		if o.SelectionMade || o.Pinned != 0 || len(o.Released) != 0 {
			return errors.New("outbox publication state before setup")
		}
		return nil
	}
	f, i := n.state, n.config.Index
	d := f.expected
	next := f.clientNext[i]
	if next != d.sequence && next != d.sequence+1 {
		return errors.New("outbox client phase counter mismatch")
	}
	wantSelection := d.phase == 1 || next == d.sequence+1
	if o.SelectionMade != wantSelection || (wantSelection && o.SelectionRound != d.sequence/2) {
		return errors.New("outbox selection phase mismatch")
	}
	if next == d.sequence+1 && (n.prepared == nil || n.prepared.client != i || len(n.prepared.body) != d.size() || !ed25519.Verify(f.clientKeys[i].pub, n.prepared.signed(d), n.prepared.signature)) {
		return errors.New("outbox prepared ciphertext mismatch")
	}
	for _, r := range o.Released {
		if r.Epoch != d.epoch || r.PhaseSequence >= d.sequence {
			return errors.New("outbox release receipt outside completed phases")
		}
	}
	return nil
}

func (o *localOutbox) receipt(sequence uint64) (localReceipt, error) {
	for _, p := range o.Pending {
		if p.Sequence == sequence {
			return localReceipt{Sequence: p.Sequence, Digest: p.Digest, Status: "queued"}, nil
		}
	}
	for _, r := range o.Released {
		if r.Sequence == sequence {
			return r, nil
		}
	}
	return localReceipt{}, errors.New("unknown or expired receipt; no publication retried")
}

func (o *localOutbox) checkEnqueue(q localSubmission) (localReceipt, bool, error) {
	if q.Sequence == 0 || len(q.Payload) == 0 || len(q.Payload) > maxCell-cellNonceSize-66 {
		return localReceipt{}, false, errors.New("invalid local submission size or sequence")
	}
	digest := hash(q.Payload)
	if q.Sequence < o.Next {
		r, e := o.receipt(q.Sequence)
		if e != nil {
			return r, false, e
		}
		if r.Digest != digest {
			return localReceipt{}, false, errors.New("local sequence already binds different bytes")
		}
		return r, true, nil
	}
	if q.Sequence != o.Next || o.Next == math.MaxUint64 {
		return localReceipt{}, false, errors.New("local sequence gap or exhaustion")
	}
	total := len(q.Payload)
	for _, p := range o.Pending {
		total += len(p.Payload)
	}
	if len(o.Pending) >= outboxMaxItems || total > outboxMaxBytes {
		return localReceipt{}, false, errors.New("protected outbox full; no direct fallback")
	}
	return localReceipt{Sequence: q.Sequence, Digest: digest, Status: "queued"}, false, nil
}
func (o *localOutbox) enqueue(q localSubmission) (localReceipt, error) {
	return o.enqueueEligible(q, nil)
}
func (o *localOutbox) enqueueEligible(q localSubmission, eligibility *publicationEligibility) (localReceipt, error) {
	r, existing, e := o.checkEnqueue(q)
	if e != nil || existing {
		return r, e
	}
	digest := r.Digest
	var saved *publicationEligibility
	if eligibility != nil {
		v := *eligibility
		saved = &v
	}
	o.Pending = append(o.Pending, queuedPublication{Sequence: q.Sequence, Digest: digest, Payload: bytes.Clone(q.Payload), Eligibility: saved})
	o.Next++
	return r, nil
}

func selectedSlot(d descriptor, slot int) bool {
	for _, s := range d.slots {
		if s == slot {
			return true
		}
	}
	return false
}
func (o *localOutbox) selectPayload(d descriptor, slot int) ([]byte, error) {
	if d.phase == 0 {
		if o.SelectionMade {
			return nil, errors.New("previous local selection not acknowledged")
		}
		o.SelectionMade = true
		o.SelectionRound = d.sequence / 2
		o.Pinned = 0
		if len(o.Pending) > 0 && (o.Pending[0].Eligibility == nil || o.Pending[0].Eligibility.Round <= d.sequence/2) {
			o.Pinned = o.Pending[0].Sequence
			return []byte{1}, nil
		}
		return nil, nil
	}
	if !o.SelectionMade || o.SelectionRound != d.sequence/2 {
		return nil, errors.New("bulk has no committed local selection")
	}
	if o.Pinned == 0 || !selectedSlot(d, slot) {
		return nil, nil
	}
	if len(o.Pending) == 0 || o.Pending[0].Sequence != o.Pinned {
		return nil, errors.New("selected publication missing")
	}
	return o.Pending[0].Payload, nil
}
func (o *localOutbox) accept(d descriptor, slot int, messages map[int][]byte, outputHash [32]byte) error {
	if !o.SelectionMade || o.SelectionRound != d.sequence/2 {
		return errors.New("output has no local selection")
	}
	if d.phase == 0 {
		want := []byte(nil)
		if o.Pinned != 0 {
			want = []byte{1}
		}
		if !bytes.Equal(messages[slot], want) {
			return errors.New("certified reservation changed local intent")
		}
		if len(messages) == 0 {
			o.SelectionMade = false
			o.Pinned = 0
		}
		return nil
	}
	if o.Pinned != 0 && selectedSlot(d, slot) {
		if len(o.Pending) == 0 || o.Pending[0].Sequence != o.Pinned || !bytes.Equal(messages[slot], o.Pending[0].Payload) {
			return errors.New("certified output omitted or changed queued publication")
		}
		p := o.Pending[0]
		r := localReceipt{Sequence: p.Sequence, Digest: p.Digest, Status: "released", Epoch: d.epoch, OutputHash: outputHash, PhaseSequence: d.sequence}
		clear(p.Payload)
		copy(o.Pending, o.Pending[1:])
		o.Pending[len(o.Pending)-1] = queuedPublication{}
		o.Pending = o.Pending[:len(o.Pending)-1]
		if len(o.Released) == outboxReceiptLimit {
			copy(o.Released, o.Released[1:])
			o.Released = o.Released[:outboxReceiptLimit-1]
		}
		o.Released = append(o.Released, r)
	}
	o.SelectionMade = false
	o.Pinned = 0
	return nil
}

func (n *roleNode) enqueueLocal(q localSubmission) (localReceipt, error) {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.outbox == nil || n.journal == nil || n.journal.poisoned {
		return localReceipt{}, errors.New("durable local publication unavailable")
	}
	// Fast idempotent retries never overwrite an in-flight peer request/cache.
	r, existing, e := n.outbox.checkEnqueue(q)
	if e != nil || existing {
		return r, e
	}
	eligibility, e := n.localEligibility()
	if e != nil {
		return localReceipt{}, e
	}
	if e := n.journal.savePending(pendingOperation{Local: &q, Eligibility: eligibility, Attempts: 1}); e != nil {
		return localReceipt{}, n.journal.fail(e)
	}
	if n.journal.afterBegin != nil {
		n.journal.afterBegin()
	}
	return n.journal.completeLocal(n, q, eligibility)
}
func (n *roleNode) localStatus(sequence uint64) (localReceipt, error) {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.outbox == nil || n.journal == nil || n.journal.poisoned {
		return localReceipt{}, errors.New("durable local publication unavailable")
	}
	return n.outbox.receipt(sequence)
}
func (j *roleJournal) completeLocal(n *roleNode, q localSubmission, eligibility *publicationEligibility) (localReceipt, error) {
	if n.outbox == nil {
		return localReceipt{}, j.fail(errors.New("pending local operation without outbox"))
	}
	if !n.validEligibility(eligibility) {
		return localReceipt{}, j.fail(errors.New("invalid pending publication eligibility"))
	}
	r, resultErr := n.outbox.enqueueEligible(q, eligibility)
	if j.afterExecute != nil {
		j.afterExecute()
	}
	if e := j.commitState(n); e != nil {
		return localReceipt{}, j.fail(e)
	}
	if j.afterCommit != nil {
		j.afterCommit()
	}
	return r, resultErr
}
