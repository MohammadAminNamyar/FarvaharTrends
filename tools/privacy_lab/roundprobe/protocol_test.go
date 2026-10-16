package main

import (
	"bytes"
	"crypto/ed25519"
	"testing"
)

func inputsFor(t *testing.T, f *fixture, d descriptor, sender int, payload []byte) []input {
	t.Helper()
	out := []input{}
	for c := range clients {
		var p []byte
		if c == sender {
			p = payload
		}
		x, e := f.prepare(c, d, p)
		if e != nil {
			t.Fatal(e)
		}
		out = append(out, x)
	}
	return out
}
func votesFor(t *testing.T, f *fixture, d descriptor, x []input) []vote {
	t.Helper()
	out := []vote{}
	for s := range coordinators {
		v, e := f.commit(s, d, x)
		if e != nil {
			t.Fatal(e)
		}
		out = append(out, v)
	}
	return out
}
func sharesFor(t *testing.T, f *fixture, d descriptor, v []vote) []share {
	t.Helper()
	out := []share{}
	for s := range coordinators {
		v, e := f.release(s, d, v)
		if e != nil {
			t.Fatal(e)
		}
		out = append(out, v)
	}
	return out
}
func requireReject(t *testing.T, e error) {
	t.Helper()
	if e == nil {
		t.Fatal("unsafe input accepted")
	}
}

func TestFarsiPayloadAndEqualWireSizesForEverySender(t *testing.T) {
	var referenceUp, referenceDown int
	for sender := range clients {
		f := newFixture()
		r, e := f.run(f.reservation(0), sender, []byte{1})
		if e != nil {
			t.Fatal(e)
		}
		d := f.bulk(0, r, maxCell)
		payload := []byte("خبر آزمایشی فارسی؛ این یک دادهٔ بی‌خطر برای اندازه‌گیری انتشار است.")
		b, e := f.run(d, sender, payload)
		if e != nil {
			t.Fatal(e)
		}
		if e = b.verifyPayload(f.ownerSlot[sender], payload); e != nil {
			t.Fatal(e)
		}
		if sender == 0 {
			referenceUp = b.clientUp
			referenceDown = b.clientDown
		} else if b.clientUp != referenceUp || b.clientDown != referenceDown {
			t.Fatal("wire length exposes sender")
		}
	}
}
func TestIdleRoundsContinueWithoutUnscheduledBulk(t *testing.T) {
	f := newFixture()
	for n := range 10 {
		r, e := f.run(f.reservation(uint64(n)), -1, nil)
		if e != nil || len(r.messages) != 0 {
			t.Fatal(e)
		}
		if f.expected.phase != 0 || f.expected.sequence != uint64(2*n+2) {
			t.Fatal("idle schedule advanced incorrectly")
		}
	}
}
func TestDropReplaceDuplicateAndOversizeAreRejected(t *testing.T) {
	f := newFixture()
	d := f.reservation(0)
	xs := inputsFor(t, f, d, 0, []byte{1})
	_, e := f.validate(d, xs[:1])
	requireReject(t, e)
	bad := append([]input{}, xs...)
	bad[1] = bad[0]
	_, e = f.validate(d, bad)
	requireReject(t, e)
	bad = append([]input{}, xs...)
	bad[1].body = make([]byte, d.size())
	_, e = f.validate(d, bad)
	requireReject(t, e)
	bad = append([]input{}, xs...)
	bad[1].body = make([]byte, d.size()+1)
	_, e = f.validate(d, bad)
	requireReject(t, e)
	_, e = f.validate(d, append(xs, xs[0]))
	requireReject(t, e)
}
func TestEquivocationWithValidMaliciousClientSignatures(t *testing.T) {
	f := newFixture()
	d := f.reservation(0)
	xs := inputsFor(t, f, d, 0, []byte{1})
	v0, e := f.commit(0, d, xs)
	if e != nil {
		t.Fatal(e)
	}
	fork := append([]input{}, xs...)
	fork[1].body = append([]byte{}, xs[1].body...)
	fork[1].body[0] ^= 1
	fork[1].signature = ed25519.Sign(f.clientKeys[1].private, fork[1].signed(d))
	v1, e := f.commit(1, d, fork)
	if e != nil {
		t.Fatal(e)
	}
	v2, e := f.commit(2, d, xs)
	if e != nil {
		t.Fatal(e)
	}
	votes := []vote{v0, v1, v2}
	for s := range coordinators {
		_, e = f.release(s, d, votes)
		requireReject(t, e)
	}
	_, e = f.commit(0, d, fork)
	requireReject(t, e)
}
func TestReplayEpochPhaseAndInventedScheduleRejected(t *testing.T) {
	f := newFixture()
	d := f.reservation(0)
	xs := inputsFor(t, f, d, 0, []byte{1})
	_, e := f.prepare(0, d, []byte{1})
	requireReject(t, e)
	votes := votesFor(t, f, d, xs)
	sharesFor(t, f, d, votes)
	_, e = f.release(0, d, votes)
	requireReject(t, e)
	fresh := newFixture()
	_, e = fresh.validate(d, xs)
	requireReject(t, e)
	wrong := fresh.reservation(0)
	wrong.epoch = d.epoch
	_, e = fresh.prepare(0, wrong, nil)
	requireReject(t, e)
	wrong = fresh.reservation(0)
	wrong.previous[0] = 1
	_, e = fresh.prepare(0, wrong, nil)
	requireReject(t, e)
	wrong = fresh.reservation(0)
	wrong.phase = 1
	_, e = fresh.prepare(0, wrong, nil)
	requireReject(t, e)
}
func TestLostCoordinatorNeverReleasesOrDowngrades(t *testing.T) {
	f := newFixture()
	d := f.reservation(0)
	xs := inputsFor(t, f, d, 0, []byte{1})
	votes := votesFor(t, f, d, xs)
	_, e := f.release(0, d, votes[:2])
	requireReject(t, e)
	shares := sharesFor(t, f, d, votes)
	_, e = f.combine(d, xs, shares[:2], votes)
	requireReject(t, e)
	// A fresh epoch is a new setup, not automatic membership shrinkage.
	fresh := newFixture()
	_, e = fresh.validate(fresh.reservation(0), xs)
	requireReject(t, e)
}
func TestAnonymousJammingIsDetectedButNotSolved(t *testing.T) {
	f := newFixture()
	d := f.reservation(0)
	xs := inputsFor(t, f, d, 0, []byte{1})
	// A legitimate malicious member can sign arbitrary DC-net input. Ordinary
	// signatures prove who supplied it, not that its pads/slot usage are valid.
	xs[1].body[0] ^= 0x80
	xs[1].signature = ed25519.Sign(f.clientKeys[1].private, xs[1].signed(d))
	votes := votesFor(t, f, d, xs)
	shares := sharesFor(t, f, d, votes)
	raw, e := f.combine(d, xs, shares, votes)
	if e != nil {
		t.Fatal(e)
	}
	_, e = f.decode(d, raw)
	requireReject(t, e)
	// Do not count this as abuse resistance: no safe blame/recovery exists.
}
func TestSevenColludingClientsRecoverTheEighthDespiteHonestCoordinator(t *testing.T) {
	f := newFixture()
	d := f.reservation(0)
	target := 3
	payload := []byte("test publisher")
	xs := inputsFor(t, f, d, target, payload)
	votes := votesFor(t, f, d, xs)
	shares := sharesFor(t, f, d, votes)
	// Coordinators 0 and 1 collude. Coordinator 2 is honest. Seven colluding
	// clients know their OWN shared secrets with coordinator 2. They remove
	// their masks from its public aggregate, leaving the victim's mask.
	victimHonestMask := append([]byte{}, shares[2].body...)
	for c := range clients {
		if c != target {
			xor(victimHonestMask, f.pad(c, 2, d))
		}
	}
	recovered := append([]byte{}, xs[target].body...)
	xor(recovered, f.pad(target, 0, d))
	xor(recovered, f.pad(target, 1, d))
	xor(recovered, victimHonestMask)
	// Other clients' randomized cover slots are not part of this client's
	// plaintext. Copy their already-public cells only for the full decoder.
	public, e := f.combine(d, xs, shares, votes)
	if e != nil {
		t.Fatal(e)
	}
	for pos, slot := range d.slots {
		if slot != f.ownerSlot[target] {
			copy(recovered[pos*d.cell:(pos+1)*d.cell], public[pos*d.cell:(pos+1)*d.cell])
		}
	}
	messages, e := f.decode(d, recovered)
	if e != nil {
		t.Fatal(e)
	}
	if !bytes.Equal(messages[f.ownerSlot[target]], payload) {
		t.Fatal("expected Sybil/isolation limitation was hidden")
	}
}
func TestRoundAndEpochMasksDiffer(t *testing.T) {
	f := newFixture()
	d := f.reservation(0)
	next := f.reservation(1)
	other := newFixture().reservation(0)
	if bytes.Equal(f.pad(0, 0, d), f.pad(0, 0, next)) || bytes.Equal(f.pad(0, 0, d), f.pad(0, 0, other)) {
		t.Fatal("pad reuse")
	}
}
func TestExcessReservationsAreBoundedAndDeterministic(t *testing.T) {
	f := newFixture()
	r := result{messages: map[int][]byte{}}
	for i := range clients {
		r.messages[i] = []byte{1}
	}
	seen := map[int]bool{}
	for round := range 4 {
		d := f.bulk(uint64(round), r, maxCell)
		if len(d.slots) != maxBulkSlots {
			t.Fatal("unbounded bulk allocation")
		}
		for _, s := range d.slots {
			seen[s] = true
		}
	}
	if len(seen) != clients {
		t.Fatal("reservation starvation in fixed test")
	}
	// A two-cell cap necessarily queues some traffic; this test is not a
	// five-second guarantee at arbitrary load.
}

func TestEightPublisherBurstRequiresFourRoundsAtTwoSlots(t *testing.T) {
	f := newFixture()
	pending := map[int][]byte{}
	for c := range clients {
		pending[c] = []byte("خبر فارسی هم‌زمان؛ دادهٔ آزمایشی")
	}
	served := map[int]bool{}
	for round := range 4 {
		requests := map[int][]byte{}
		for c := range pending {
			requests[c] = []byte{1}
		}
		r, e := f.runMany(f.reservation(uint64(round)), requests)
		if e != nil {
			t.Fatal(e)
		}
		d := f.bulk(uint64(round), r, maxCell)
		selected := map[int][]byte{}
		for c, p := range pending {
			for _, slot := range d.slots {
				if f.ownerSlot[c] == slot {
					selected[c] = p
				}
			}
		}
		b, e := f.runMany(d, selected)
		if e != nil {
			t.Fatal(e)
		}
		if len(b.messages) != 2 {
			t.Fatal("wrong burst allocation")
		}
		for c, p := range selected {
			if served[c] || !bytes.Equal(b.messages[f.ownerSlot[c]], p) {
				t.Fatal("duplicate, lost or corrupted publication")
			}
			served[c] = true
			delete(pending, c)
		}
		if len(served) != (round+1)*2 {
			t.Fatal("unexpected progress")
		}
	}
	if len(pending) != 0 || len(served) != clients {
		t.Fatal("burst not drained")
	}
	// At two-second reservation slots the four releases can occur at t=2,4,6,8
	// for arrivals just after t=0, EVEN WITH ZERO NETWORK/CPU COST. This makes
	// the current two-slot design insufficient for a five-second burst bound.
}

func TestOversizedPublicationDoesNotConsumeClientRound(t *testing.T) {
	f := newFixture()
	r, e := f.run(f.reservation(0), 0, []byte{1})
	if e != nil {
		t.Fatal(e)
	}
	d := f.bulk(0, r, maxCell)
	_, e = f.prepare(0, d, make([]byte, maxCell))
	requireReject(t, e)
	_, e = f.prepare(0, d, []byte("bounded retry"))
	if e != nil {
		t.Fatal("rejected payload consumed round", e)
	}
}

func TestEightSlotVariantReleasesEntireBurstInOneRound(t *testing.T) {
	f := newFixtureWithLimit(clients)
	requests := map[int][]byte{}
	payloads := map[int][]byte{}
	for c := range clients {
		requests[c] = []byte{1}
		payloads[c] = payloadFixture(4288)
		payloads[c][0] = byte(c)
	}
	r, e := f.runMany(f.reservation(0), requests)
	if e != nil {
		t.Fatal(e)
	}
	d := f.bulk(0, r, maxCell)
	if len(d.slots) != clients || d.size() != clients*maxCell {
		t.Fatal("wrong bounded burst capacity")
	}
	b, e := f.runMany(d, payloads)
	if e != nil {
		t.Fatal(e)
	}
	if len(b.messages) != clients {
		t.Fatal("lost burst items")
	}
	for c, p := range payloads {
		if !bytes.Equal(b.messages[f.ownerSlot[c]], p) {
			t.Fatal("lost or swapped payload")
		}
	}
}

func TestSameEpochCanResumeAfterTemporaryMissingContribution(t *testing.T) {
	f := newFixture()
	d := f.reservation(0)
	xs := inputsFor(t, f, d, 0, []byte{1})
	// A transport may retain the already signed ciphertext while unreachable.
	// Reusing that stored ciphertext is different from generating another mask.
	_, e := f.commit(0, d, xs[:clients-1])
	requireReject(t, e)
	votes := votesFor(t, f, d, xs)
	s0, e := f.release(0, d, votes)
	if e != nil {
		t.Fatal(e)
	}
	_, e = f.combine(d, xs, []share{s0}, votes)
	requireReject(t, e)
	s1, e := f.release(1, d, votes)
	if e != nil {
		t.Fatal(e)
	}
	s2, e := f.release(2, d, votes)
	if e != nil {
		t.Fatal(e)
	}
	raw, e := f.combine(d, xs, []share{s0, s1, s2}, votes)
	if e != nil {
		t.Fatal(e)
	}
	messages, e := f.decode(d, raw)
	if e != nil || !bytes.Equal(messages[f.ownerSlot[0]], []byte{1}) {
		t.Fatal("same-epoch recovery failed", e)
	}
	// All state is in memory in this component: this does not test phone restart,
	// durable encrypted outbox, elapsed expiry, discovery or a physical partition.
}

func TestMalformedFloodDoesNotAdvanceCoordinatorState(t *testing.T) {
	f := newFixture()
	d := f.reservation(0)
	for i := 0; i < 10000; i++ {
		_, e := f.commit(0, d, nil)
		requireReject(t, e)
	}
	if f.servers[0].next != 0 || f.servers[0].committed {
		t.Fatal("malformed input changed state")
	}
	// The API's exact-count check avoids signature work for these malformed
	// cases. There is no socket parser, ingress limiter or sustained DoS claim.
}

func TestRejectedLocalBatchLeavesEveryClientRoundAvailable(t *testing.T) {
	f := newFixture()
	d := f.reservation(0)
	_, e := f.runMany(d, map[int][]byte{7: make([]byte, reservationCell)})
	requireReject(t, e)
	_, e = f.runMany(d, map[int][]byte{clients: []byte{1}})
	requireReject(t, e)
	for c := range clients {
		if f.clientNext[c] != 0 {
			t.Fatal("rejected batch consumed another client round")
		}
	}
	_, e = f.run(d, 0, []byte{1})
	if e != nil {
		t.Fatal("valid round failed after rejected batch", e)
	}
}
