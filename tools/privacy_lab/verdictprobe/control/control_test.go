package control

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"fmt"
	"testing"

	"go.dedis.ch/kyber/v4"
	"go.dedis.ch/kyber/v4/proof"
)

type testGroup struct {
	r       Roster
	hs      []Hello
	v       *View
	clients []*Client
	servers []*Coordinator
	d       Descriptor
}

func makeGroup(t *testing.T) *testGroup {
	t.Helper()
	g := &testGroup{r: Roster{Epoch: hash("test setup epoch")}}
	var ids, slots []ed25519.PrivateKey
	for range Clients + Coordinators {
		p, k, e := ed25519.GenerateKey(rand.Reader)
		if e != nil {
			t.Fatal(e)
		}
		ids = append(ids, k)
		if len(ids) <= Clients {
			g.r.ClientKeys = append(g.r.ClientKeys, p)
		} else {
			g.r.CoordinatorKeys = append(g.r.CoordinatorKeys, p)
		}
	}
	for range Clients {
		p, k, e := ed25519.GenerateKey(rand.Reader)
		if e != nil {
			t.Fatal(e)
		}
		g.r.SlotKeys = append(g.r.SlotKeys, p)
		slots = append(slots, k)
	}
	for i := range Coordinators {
		c, e := NewCoordinator(g.r, i, ids[Clients+i])
		if e != nil {
			t.Fatal(e)
		}
		g.servers = append(g.servers, c)
		g.hs = append(g.hs, c.Hello())
	}
	var e error
	g.v, e = NewView(g.r, g.hs)
	if e != nil {
		t.Fatal(e)
	}
	for i := range Clients {
		v, e := NewView(g.r, g.hs)
		if e != nil {
			t.Fatal(e)
		}
		slot := (i + 3) % Clients
		c, e := NewClient(v, i, slot, ids[i], slots[slot])
		if e != nil {
			t.Fatal(e)
		}
		g.clients = append(g.clients, c)
	}
	for _, s := range g.servers {
		if e = s.Bind(g.hs); e != nil {
			t.Fatal(e)
		}
	}
	g.d = Descriptor{Session: g.v.Session(), Sequence: 1, Context: hash("authenticated failed transcript")}
	g.begin(t, g.d)
	return g
}
func (g *testGroup) begin(t *testing.T, d Descriptor) {
	t.Helper()
	for _, c := range g.clients {
		if e := c.Begin(d); e != nil {
			t.Fatal(e)
		}
	}
	for _, s := range g.servers {
		if e := s.Begin(d); e != nil {
			t.Fatal(e)
		}
	}
	g.d = d
}
func (g *testGroup) prepare(t *testing.T, messages map[int][]byte) []Contribution {
	t.Helper()
	var xs []Contribution
	for i, c := range g.clients {
		x, e := c.Prepare(messages[i])
		if e != nil {
			t.Fatal(e)
		}
		xs = append(xs, x)
	}
	return xs
}
func (g *testGroup) release(t *testing.T, xs []Contribution) ([]Vote, []Share) {
	t.Helper()
	var vs []Vote
	var ss []Share
	for _, s := range g.servers {
		v, e := s.Commit(xs)
		if e != nil {
			t.Fatal(e)
		}
		vs = append(vs, v)
	}
	for _, s := range g.servers {
		x, e := s.Release(vs)
		if e != nil {
			t.Fatal(e)
		}
		ss = append(ss, x)
	}
	return vs, ss
}
func reject(t *testing.T, e error) {
	t.Helper()
	if e == nil {
		t.Fatal("unsafe input accepted")
	}
}
func payload(b byte) []byte { return bytes.Repeat([]byte{b}, PayloadBytes) }

func TestCompleteRoleLocalBatchEqualSizesRetryAndNextRound(t *testing.T) {
	g := makeGroup(t)
	xs := g.prepare(t, map[int][]byte{0: payload(73), 6: payload(74)})
	for _, x := range xs {
		if len(encode(x)) != len(encode(xs[0])) {
			t.Fatal("owner/cover shape differs")
		}
	}
	a, e := g.clients[0].Prepare(payload(73))
	if e != nil || hash(a) != hash(xs[0]) {
		t.Fatal("retry", e)
	}
	_, e = g.clients[0].Prepare(payload(99))
	reject(t, e)
	vs, ss := g.release(t, xs)
	for _, s := range g.servers {
		v, e := s.Commit(xs)
		if e != nil || hash(v) != hash(vs[s.index]) {
			t.Fatal("commit retry", e)
		}
		sh, e := s.Release(vs)
		if e != nil || hash(sh) != hash(ss[s.index]) {
			t.Fatal("release retry", e)
		}
		if _, e = s.Accept(vs, ss); e != nil {
			t.Fatal(e)
		}
	}
	for _, c := range g.clients {
		out, e := c.Accept(xs, vs, ss)
		if e != nil {
			t.Fatal(e)
		}
		for slot, x := range out {
			if x.Invalid {
				t.Fatal("invalid output")
			}
			want := []byte(nil)
			if slot == g.clients[0].slot {
				want = payload(73)
			}
			if slot == g.clients[6].slot {
				want = payload(74)
			}
			if !bytes.Equal(x.Payload, want) {
				t.Fatal("payload", slot)
			}
		}
		again, e := c.Accept(xs, vs, ss)
		if e != nil || hash(again) != hash(out) {
			t.Fatal("accept retry", e)
		}
	}
	d := g.d
	d.Sequence++
	d.Context = hash("next failed transcript")
	g.begin(t, d)
	xs = g.prepare(t, nil)
	vs, ss = g.release(t, xs)
	out, e := g.v.Reveal(d, xs, vs, ss)
	if e != nil {
		t.Fatal(e)
	}
	for _, x := range out {
		if x.Invalid || x.Payload != nil {
			t.Fatal("cover decoded as payload")
		}
	}
}
func TestBorrowedCiphertextNeedsUnknownEphemeralSecret(t *testing.T) {
	g := makeGroup(t)
	xs := g.prepare(t, map[int][]byte{0: payload(61)})
	victimSlot := g.clients[0].slot
	attacker := g.clients[1]
	ownSlot := attacker.slot
	if g.v.sums[victimSlot].Equal(g.v.sums[ownSlot]) {
		t.Fatal("slots share encryption key")
	}
	bad := clone(xs[1])
	bad.Cells[ownSlot].R = clone(xs[0].Cells[victimSlot].R)
	bad.Cells[ownSlot].C = clone(xs[0].Cells[victimSlot].C)
	p, ep, pts, e := g.v.cellPredicates(ownSlot, bad.Cells[ownSlot])
	if e != nil {
		t.Fatal(e)
	}
	ctx := cellContext(g.d, 1, ownSlot, bad.Cells[ownSlot])
	bad.Cells[ownSlot].Proof, e = proof.HashProve(g.v.s, ctx+"/owner-or-cover", p.Prover(g.v.s, map[string]kyber.Scalar{"y": attacker.owner}, pts, map[proof.Predicate]int{p: 1}))
	if e != nil {
		t.Fatal(e)
	}
	if e = verifyProof(g.v.s, ctx+"/owner-or-cover", p.Verifier(g.v.s, pts), bad.Cells[ownSlot].Proof); e != nil {
		t.Fatal("attack must pass owner OR proof", e)
	}
	bad.Cells[ownSlot].EphemeralProof = clone(xs[0].Cells[victimSlot].EphemeralProof)
	bad.Signature = sign(attacker.id, "input", contributionSigned(g.d, bad))
	reject(t, verifyProof(g.v.s, ctx+"/ephemeral", ep.Verifier(g.v.s, pts), bad.Cells[ownSlot].EphemeralProof))
	xs[1] = bad
	for _, s := range g.servers {
		_, e = s.Commit(xs)
		reject(t, e)
		_, e = s.Release(nil)
		reject(t, e)
	}
}
func TestSignedCorruptionMalformedProofReplayAndMissingInputsReject(t *testing.T) {
	g := makeGroup(t)
	xs := g.prepare(t, map[int][]byte{0: payload(1)})
	mutators := map[string]func(*Contribution){
		"wrong point":               func(x *Contribution) { x.Cells[0].C[0] = raw(g.v.s.Point().Base()) },
		"trailing proof":            func(x *Contribution) { x.Cells[0].Proof = append(x.Cells[0].Proof, 0) },
		"noncanonical proof scalar": func(x *Contribution) { p := x.Cells[0].Proof; copy(p[len(p)-32:], bytes.Repeat([]byte{255}, 32)) },
		"missing ephemeral proof":   func(x *Contribution) { x.Cells[0].EphemeralProof = nil },
		"torsion point":             func(x *Contribution) { x.Cells[0].R[0] = make([]byte, 32) },
		"reordered slots":           func(x *Contribution) { x.Cells[0], x.Cells[1] = x.Cells[1], x.Cells[0] },
	}
	for name, mutate := range mutators {
		t.Run(name, func(t *testing.T) {
			bad := clone(xs)
			mutate(&bad[1])
			bad[1].Signature = sign(g.clients[1].id, "input", contributionSigned(g.d, bad[1]))
			_, _, e := g.v.checkedInputs(g.d, bad)
			reject(t, e)
		})
	}
	_, e := g.servers[0].Commit(xs[:7])
	reject(t, e)
	d := g.d
	d.Context = hash("other transcript")
	x := clone(xs[0])
	x.Signature = sign(g.clients[0].id, "input", contributionSigned(d, x))
	reject(t, g.v.verifyContribution(d, x))
	d = g.d
	d.Sequence++
	reject(t, g.clients[0].Begin(d))
	reject(t, g.servers[0].Begin(d))
	vs, ss := g.release(t, xs)
	_, e = g.clients[0].Accept(xs, vs, ss[:2])
	reject(t, e)
	_, e = g.servers[0].Release(vs[:2])
	reject(t, e)
	badShare := clone(ss)
	badShare[0].Cells[0].Points[0] = raw(g.v.s.Point().Base())
	badShare[0].Signature = sign(g.servers[0].id, "share", shareSigned(g.d, badShare[0]))
	_, e = g.v.Reveal(g.d, xs, vs, badShare)
	reject(t, e)
	if _, e = g.clients[0].Accept(xs, vs, ss); e != nil {
		t.Fatal("retry after absent share", e)
	}
}
func TestCoordinatorCannotReleaseTwoInputRoots(t *testing.T) {
	g := makeGroup(t)
	xs := g.prepare(t, map[int][]byte{0: payload(3)})
	v, e := g.servers[0].Commit(xs)
	if e != nil {
		t.Fatal(e)
	}
	other := clone(xs)
	// A malicious admitted owner can create a second entirely valid ciphertext,
	// but an honest coordinator must not release both versions of this round.
	cell, e := g.v.makeCell(g.d, 1, g.clients[1].slot, g.clients[1].owner, payload(4))
	if e != nil {
		t.Fatal(e)
	}
	other[1].Cells[g.clients[1].slot] = cell
	other[1].Signature = sign(g.clients[1].id, "input", contributionSigned(g.d, other[1]))
	_, _, e = g.v.checkedInputs(g.d, other)
	if e != nil {
		t.Fatal("fork should be cryptographically valid", e)
	}
	_, e = g.servers[0].Commit(other)
	reject(t, e)
	v1, e := g.servers[1].Commit(other)
	if e != nil {
		t.Fatal(e)
	}
	v2, e := g.servers[2].Commit(xs)
	if e != nil {
		t.Fatal(e)
	}
	for _, s := range g.servers {
		_, e = s.Release([]Vote{v, v1, v2})
		reject(t, e)
	}
}
func TestMaliciousOwnerMalformedOwnSlotDoesNotEraseOtherComplaint(t *testing.T) {
	g := makeGroup(t)
	xs := g.prepare(t, map[int][]byte{0: payload(9)})
	owner := g.clients[1]
	slot := owner.slot
	cell := Cell{}
	randomness := map[string]kyber.Scalar{}
	for j := range g.v.chunks() {
		r := g.v.s.Scalar().Pick(g.v.s.RandomStream())
		randomness[fmt.Sprint("r", j)] = r
		cell.R = append(cell.R, raw(g.v.s.Point().Mul(r, nil)))
		cell.C = append(cell.C, raw(g.v.s.Point().Add(g.v.s.Point().Base(), g.v.s.Point().Mul(r, g.v.sums[slot]))))
	}
	p, ep, pts, e := g.v.cellPredicates(slot, cell)
	if e != nil {
		t.Fatal(e)
	}
	ctx := cellContext(g.d, 1, slot, cell)
	cell.EphemeralProof, e = proof.HashProve(g.v.s, ctx+"/ephemeral", ep.Prover(g.v.s, randomness, pts, nil))
	if e != nil {
		t.Fatal(e)
	}
	cell.Proof, e = proof.HashProve(g.v.s, ctx+"/owner-or-cover", p.Prover(g.v.s, map[string]kyber.Scalar{"y": owner.owner}, pts, map[proof.Predicate]int{p: 1}))
	if e != nil {
		t.Fatal(e)
	}
	xs[1].Cells[slot] = cell
	xs[1].Signature = sign(owner.id, "input", contributionSigned(g.d, xs[1]))
	vs, ss := g.release(t, xs)
	out, e := g.v.Reveal(g.d, xs, vs, ss)
	if e != nil {
		t.Fatal(e)
	}
	if !out[slot].Invalid || out[g.clients[0].slot].Invalid || !bytes.Equal(out[g.clients[0].slot].Payload, payload(9)) {
		t.Fatal("malformed owner cell affected another slot")
	}
}

func TestIndependentControlKeysProofOfPossessionAndBinding(t *testing.T) {
	g := makeGroup(t)
	hs := clone(g.hs)
	// Even a correctly signed hello with a valid knowledge proof is rejected if
	// it reuses an encryption key from another server/slot.
	hs[1].Keys[0] = clone(hs[0].Keys[0])
	p, pts, e := helloPredicate(g.v.s, hs[1])
	if e != nil {
		t.Fatal(e)
	}
	secrets := map[string]kyber.Scalar{}
	for slot, k := range g.servers[1].keys {
		secrets[fmt.Sprint("b", slot)] = k
	}
	secrets["b0"] = g.servers[0].keys[0]
	hs[1].Proof, e = proof.HashProve(g.v.s, helloContext(hs[1]), p.Prover(g.v.s, secrets, pts, nil))
	if e != nil {
		t.Fatal(e)
	}
	hs[1].Signature = sign(g.servers[1].id, "hello", helloSigned(hs[1]))
	_, e = NewView(g.r, hs)
	reject(t, e)
	reject(t, g.servers[1].Bind(hs))
	hs = clone(g.hs)
	hs[0].Epoch = hash("other epoch")
	hs[0].Signature = sign(g.servers[0].id, "hello", helloSigned(hs[0]))
	_, e = NewView(g.r, hs)
	reject(t, e)
	hs = clone(g.hs)
	hs[0].Proof = append(hs[0].Proof, 0)
	hs[0].Signature = sign(g.servers[0].id, "hello", helloSigned(hs[0]))
	_, e = NewView(g.r, hs)
	reject(t, e)
	_, e = NewClient(g.v, 0, g.clients[0].slot, g.clients[1].id, g.clients[0].id)
	reject(t, e)
}
