package main

import (
	"bytes"
	"crypto/ed25519"
	"reflect"
	"testing"
)

func TestCommittedMaskRejectsAdaptiveCoordinatorEvenWithValidSignature(t *testing.T) {
	f := newFixture()
	d := f.reservation(0)
	xs := inputsFor(t, f, d, 0, []byte{1})
	vs := votesFor(t, f, d, xs)
	ss := sharesFor(t, f, d, vs)
	raw, e := f.combine(d, xs, ss, vs)
	if e != nil {
		t.Fatal(e)
	}
	// A last-moving malicious coordinator can see the full output and select a
	// 1->0 corruption, which would have no safe witness. Its signature alone is
	// valid, but the new commitment must reject the changed share.
	bit := -1
	for i := range len(raw) * 8 {
		if bitAt(raw, i) == 1 {
			bit = i
			break
		}
	}
	if bit < 0 {
		t.Fatal("randomized output has no set bit")
	}
	ss[2].body[bit/8] ^= 1 << uint(bit%8)
	ss[2].signature = ed25519.Sign(f.serverKeys[2].private, ss[2].signed(d))
	if !ed25519.Verify(f.serverKeys[2].pub, ss[2].signed(d), ss[2].signature) {
		t.Fatal("not an authenticated malicious share")
	}
	_, e = f.combine(d, xs, ss, vs)
	requireReject(t, e)
}
func TestKeyCommitmentDisagreementStopsBeforeMaskRelease(t *testing.T) {
	f := newFixture()
	d := f.reservation(0)
	xs := inputsFor(t, f, d, 0, []byte{1})
	vs := votesFor(t, f, d, xs)
	bad := copyVotes(vs)
	bad[0].keyHashes[2][0] ^= 1
	bad[0].signature = ed25519.Sign(f.serverKeys[0].private, bad[0].signed(d))
	_, e := f.release(1, d, bad)
	requireReject(t, e)
	if f.servers[1].next != d.sequence || !f.servers[1].committed {
		t.Fatal("rejected request consumed the round")
	}
	sharesFor(t, f, d, vs)
}
func TestRandomizedCellsRoundTripAtCapacityAndDoNotRevealCoverPattern(t *testing.T) {
	for _, size := range []int{reservationCell, maxCell} {
		inner := bytes.Repeat([]byte{0xA5}, size-cellNonceSize)
		a, b := randomizeCell(inner), randomizeCell(inner)
		if bytes.Equal(a, b) || !bytes.Equal(clearCell(a), inner) || !bytes.Equal(clearCell(b), inner) {
			t.Fatal("cell randomization")
		}
	}
	f := newFixture()
	d := f.reservation(0)
	xs := inputsFor(t, f, d, -1, nil)
	vs := votesFor(t, f, d, xs)
	ss := sharesFor(t, f, d, vs)
	raw, e := f.combine(d, xs, ss, vs)
	if e != nil {
		t.Fatal(e)
	}
	if bytes.Equal(raw, make([]byte, len(raw))) {
		t.Fatal("idle output not randomized")
	}
	m, e := f.decode(d, raw)
	if e != nil || len(m) != 0 {
		t.Fatal("idle decode", e)
	}
	f.advance(d, result{raw: raw, messages: m})
	r, e := f.run(f.reservation(1), 0, []byte{1})
	if e != nil {
		t.Fatal(e)
	}
	d = f.bulk(1, r, maxCell)
	p := bytes.Repeat([]byte{0xE4}, cellCapacity(d))
	r, e = f.run(d, 0, p)
	if e != nil || !bytes.Equal(r.messages[f.ownerSlot[0]], p) {
		t.Fatal("full cell", e)
	}
}

// The test fixture deliberately knows every secret so it can deterministically
// choose a zero bit. This is an attack fixture, not a claim an attacker knows it.
func jammedAudit(t *testing.T, serverJam bool) (*fixture, *faultAudit, accusation) {
	t.Helper()
	f := newFixture()
	d := f.reservation(0)
	xs := inputsFor(t, f, d, 0, []byte{1})
	plain := append([]byte{}, xs[0].body...)
	for s := range coordinators {
		xor(plain, f.pad(0, s, d))
	}
	start := f.ownerSlot[0] * d.cell * 8
	bit := -1
	for i := range cellNonceSize * 8 {
		if bitAt(plain, start+i) == 0 {
			bit = start + i
			break
		}
	}
	if bit < 0 {
		t.Fatal("no zero nonce bit")
	}
	if !serverJam {
		xs[1].body[bit/8] ^= 1 << uint(bit%8)
		xs[1].signature = ed25519.Sign(f.clientKeys[1].private, xs[1].signed(d))
	}
	vs := votesFor(t, f, d, xs)
	ss := []share{}
	if serverJam {
		body := f.mask(0, d)
		body[bit/8] ^= 1 << uint(bit%8)
		vs[0].maskHash = maskCommitment(d, 0, vs[0].root, body)
		vs[0].signature = ed25519.Sign(f.serverKeys[0].private, vs[0].signed(d))
		s := share{coordinator: 0, root: vs[0].root, body: body}
		s.signature = ed25519.Sign(f.serverKeys[0].private, s.signed(d))
		ss = append(ss, s)
		for i := 1; i < coordinators; i++ {
			s, e := f.release(i, d, vs)
			if e != nil {
				t.Fatal(e)
			}
			ss = append(ss, s)
		}
	} else {
		ss = sharesFor(t, f, d, vs)
	}
	a, e := newFaultAudit(f, d, xs, vs, ss)
	if e != nil {
		t.Fatal(e)
	}
	w, e := a.makeAccusation(f, 0)
	if e != nil {
		t.Fatal(e)
	}
	if e = a.accept(w); e != nil {
		t.Fatal(e)
	}
	return f, a, w
}
func reportsFor(t *testing.T, f *fixture, a *faultAudit, w accusation) []bitReport {
	t.Helper()
	out := []bitReport{}
	for s := range coordinators {
		r, e := a.report(f, s, w)
		if e != nil {
			t.Fatal(e)
		}
		out = append(out, r)
	}
	return out
}
func TestWitnessAuditIdentifiesCandidateWithoutOpeningPublisherBit(t *testing.T) {
	f, a, w := jammedAudit(t, false)
	rs := reportsFor(t, f, a, w)
	find, e := a.investigate(w, rs)
	if e != nil {
		t.Fatal(e)
	}
	if !reflect.DeepEqual(find.ClientCandidates, []int{1}) || len(find.CoordinatorContradictions) != 0 {
		t.Fatal(find)
	}
	for c := range clients {
		for _, r := range rs {
			_, e = a.rebut(f, c, w, r)
			requireReject(t, e)
		}
	}
	_, e = a.investigate(w, rs[:2])
	requireReject(t, e)
	if f.expected.sequence != a.d.sequence {
		t.Fatal("investigation advanced publication")
	}
}
func TestCommittedCorruptCoordinatorIsContradictedByItsBitReport(t *testing.T) {
	f, a, w := jammedAudit(t, true)
	rs := reportsFor(t, f, a, w)
	find, e := a.investigate(w, rs)
	if e != nil {
		t.Fatal(e)
	}
	if !reflect.DeepEqual(find.CoordinatorContradictions, []int{0}) || len(find.ClientCandidates) != 0 {
		t.Fatal(find)
	}
}
func TestLyingCoordinatorCannotFramePublisherWithUnverifiableClaim(t *testing.T) {
	f, a, w := jammedAudit(t, false)
	rs := reportsFor(t, f, a, w)
	// Preserve the coordinator's aggregate bit while redirecting the apparent
	// client fault from the disruptor to the publisher. Signed bits alone cannot
	// justify excluding that publisher; the rebuttal proves which server lied.
	rs[0].bits[0] ^= 1
	rs[0].bits[1] ^= 1
	rs[0].signature = ed25519.Sign(f.serverKeys[0].private, rs[0].signed())
	find, e := a.investigate(w, rs)
	if e != nil {
		t.Fatal(e)
	}
	if !reflect.DeepEqual(find.ClientCandidates, []int{0}) || len(find.CoordinatorContradictions) != 0 {
		t.Fatal(find)
	}
	x, e := a.rebut(f, 0, w, rs[0])
	if e != nil {
		t.Fatal(e)
	}
	if e = a.verifyRebuttal(w, rs[0], x); e != nil {
		t.Fatal(e)
	}
	if x.key == f.seeds[0][0] {
		t.Fatal("session seed disclosed")
	}
	next := a.d
	next.sequence += 2
	if x.key == f.padKey(0, 0, next) {
		t.Fatal("future round key disclosed")
	}
	other := x
	other.key[0] ^= 1
	other.signature = ed25519.Sign(f.clientKeys[0].private, other.signed())
	requireReject(t, a.verifyRebuttal(w, rs[0], other))
	other = x
	other.client = 1
	other.signature = ed25519.Sign(f.clientKeys[1].private, other.signed())
	requireReject(t, a.verifyRebuttal(w, rs[0], other))
	_, e = a.rebut(f, 0, w, rs[1])
	requireReject(t, e)
	// A fabricated server signature must never trigger a key opening.
	bad := rs[0]
	bad.signature = append([]byte{}, bad.signature...)
	bad.signature[0] ^= 1
	_, e = a.rebut(f, 0, w, bad)
	requireReject(t, e)
}
func TestWitnessAuthorizationBudgetContextAndRetryAreBounded(t *testing.T) {
	f, a, w := jammedAudit(t, false)
	bad := w
	bad.signature = append([]byte{}, w.signature...)
	bad.signature[0] ^= 1
	requireReject(t, a.accept(bad))
	bad = w
	bad.bit = -1
	requireReject(t, a.accept(bad))
	bad = w
	bad.bit = a.d.cell * 8
	requireReject(t, a.accept(bad))
	bad = w
	bad.context[0] ^= 1
	bad.signature = ed25519.Sign(f.slotKeys[w.slot].private, bad.signed())
	requireReject(t, a.accept(bad))
	start, _ := a.offset(accusation{context: a.context, slot: w.slot})
	for bit := range a.d.cell * 8 {
		if bit != w.bit && bitAt(a.output, start+bit) == 1 {
			bad = w
			bad.bit = bit
			bad.signature = ed25519.Sign(f.slotKeys[w.slot].private, bad.signed())
			requireReject(t, a.accept(bad))
			break
		}
	}
	r, e := a.report(f, 0, w)
	if e != nil {
		t.Fatal(e)
	}
	r.signature[0] ^= 1
	r, e = a.report(f, 0, w)
	if e != nil || a.verifyReport(w, r) != nil {
		t.Fatal("cached report aliased", e)
	}
	if e = a.accept(w); e != nil {
		t.Fatal("exact witness retry", e)
	}
	_, other, _ := jammedAudit(t, false)
	requireReject(t, other.accept(w))
	// Honest other clients have no witness, and cannot accidentally reveal their
	// own 1 bit merely because a different anonymous slot was corrupted.
	_, e = a.makeAccusation(f, 2)
	requireReject(t, e)
}
func TestFalseAccusationTargetsAccuserRatherThanAnHonestPeer(t *testing.T) {
	f, a, _ := jammedAudit(t, false)
	w := accusation{context: a.context, slot: f.ownerSlot[2]}
	start, _ := a.offset(w)
	for bit := range a.d.cell * 8 {
		if bitAt(a.output, start+bit) == 1 {
			w.bit = bit
			break
		}
	}
	w.signature = ed25519.Sign(f.slotKeys[w.slot].private, w.signed())
	if e := a.accept(w); e != nil {
		t.Fatal(e)
	}
	rs := reportsFor(t, f, a, w)
	find, e := a.investigate(w, rs)
	if e != nil {
		t.Fatal(e)
	}
	if !reflect.DeepEqual(find.ClientCandidates, []int{2}) {
		t.Fatal(find)
	}
	for _, r := range rs {
		_, e = a.rebut(f, 2, w, r)
		requireReject(t, e)
	}
}
func TestNoInvestigationForHealthyOutputOrUncommittedCorruption(t *testing.T) {
	f := newFixture()
	d := f.reservation(0)
	xs := inputsFor(t, f, d, 0, []byte{1})
	vs := votesFor(t, f, d, xs)
	ss := sharesFor(t, f, d, vs)
	_, e := newFaultAudit(f, d, xs, vs, ss)
	requireReject(t, e)
	ss[0].body[0] ^= 1
	ss[0].signature = ed25519.Sign(f.serverKeys[0].private, ss[0].signed(d))
	_, e = newFaultAudit(f, d, xs, vs, ss)
	requireReject(t, e)
}

func TestInvestigationUsesOnlyRoleLocalSecretsAndRejectsDamagedState(t *testing.T) {
	f, a, w := jammedAudit(t, false)
	client, e := newRoleNode(configFor(f, "client", 0))
	if e != nil {
		t.Fatal(e)
	}
	got, e := a.makeAccusation(client.state, 0)
	if e != nil || got.digest() != w.digest() {
		t.Fatal("local witness", e)
	}
	server, e := newRoleNode(configFor(f, "coordinator", 0))
	if e != nil {
		t.Fatal(e)
	}
	server.state.seeds[0][0][0] ^= 1
	_, e = a.report(server.state, 0, w)
	requireReject(t, e)
	server.state.seeds[0][0][0] ^= 1
	r, e := a.report(server.state, 0, w)
	if e != nil {
		t.Fatal(e)
	}
	r.bits[0] ^= 1
	r.bits[1] ^= 1
	r.signature = ed25519.Sign(server.state.serverKeys[0].private, r.signed())
	x, e := a.rebut(client.state, 0, w, r)
	if e != nil {
		t.Fatal(e)
	}
	if e = a.verifyRebuttal(w, r, x); e != nil {
		t.Fatal(e)
	}
	client.state.seeds[0][1][0] ^= 1
	_, e = a.makeAccusation(client.state, 0)
	requireReject(t, e)
}
