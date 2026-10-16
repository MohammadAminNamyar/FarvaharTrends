package setup

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"testing"
)

type rig struct {
	clients []*Client
	servers []*Coordinator
	roster  Roster
	hellos  []Hello
	view    *View
}

func makeRig(t *testing.T) *rig {
	t.Helper()
	r := &rig{roster: Roster{Version: 1, Policy: "lab fixed eight clients and all three coordinators; no admission claim"}}
	for i := range Clients {
		p, k, e := ed25519.GenerateKey(rand.Reader)
		if e != nil {
			t.Fatal(e)
		}
		c, e := NewClient(i, k)
		if e != nil {
			t.Fatal(e)
		}
		r.clients = append(r.clients, c)
		r.roster.ClientKeys = append(r.roster.ClientKeys, p)
		r.hellos = append(r.hellos, c.Hello())
	}
	for j := range Coordinators {
		p, k, e := ed25519.GenerateKey(rand.Reader)
		if e != nil {
			t.Fatal(e)
		}
		c, e := NewCoordinator(j, k)
		if e != nil {
			t.Fatal(e)
		}
		r.servers = append(r.servers, c)
		r.roster.CoordinatorKeys = append(r.roster.CoordinatorKeys, p)
		r.hellos = append(r.hellos, c.Hello())
	}
	var e error
	r.view, e = NewView(r.roster, r.hellos)
	if e != nil {
		t.Fatal(e)
	}
	for _, c := range r.clients {
		if e = c.Bind(r.roster, r.hellos); e != nil {
			t.Fatal(e)
		}
	}
	for _, c := range r.servers {
		if e = c.Bind(r.roster, r.hellos); e != nil {
			t.Fatal(e)
		}
	}
	return r
}
func (r *rig) inputs(t *testing.T) Transcript {
	t.Helper()
	x := Transcript{Epoch: r.view.epoch}
	for _, c := range r.clients {
		i, e := c.Input()
		if e != nil {
			t.Fatal(e)
		}
		x.Inputs = append(x.Inputs, i)
	}
	return x
}
func (r *rig) finish(t *testing.T, x Transcript) Release {
	t.Helper()
	for _, s := range r.servers {
		m, e := s.Mix(x)
		if e != nil {
			t.Fatal(e)
		}
		x.Mixes = append(x.Mixes, m)
	}
	out := Release{Transcript: x}
	for _, s := range r.servers {
		v, e := s.Commit(x)
		if e != nil {
			t.Fatal(e)
		}
		out.Votes = append(out.Votes, v)
	}
	for _, s := range r.servers {
		v, e := s.Release(x, out.Votes)
		if e != nil {
			t.Fatal(e)
		}
		out.Shares = append(out.Shares, v)
	}
	return out
}
func reject(t *testing.T, e error) {
	t.Helper()
	if e == nil {
		t.Fatal("invalid input accepted")
	}
}

func TestSetupProducesUsableLocalMaterial(t *testing.T) {
	r := makeRig(t)
	packet := r.finish(t, r.inputs(t))
	expected, e := r.view.Finalize(packet)
	if e != nil {
		t.Fatal(e)
	}
	var cm []ClientMaterial
	var sm []CoordinatorMaterial
	seen := map[int]bool{}
	for _, c := range r.clients {
		if e = c.Accept(packet); e != nil {
			t.Fatal(e)
		}
		m, e := c.Material()
		if e != nil {
			t.Fatal(e)
		}
		cm = append(cm, m)
		if seen[m.OwnSlot] || hash(m.Public) != hash(expected) {
			t.Fatal("duplicate/mismatched local slot")
		}
		seen[m.OwnSlot] = true
		msg := []byte("آزمایش امضای کلید ناشناس")
		sig := ed25519.Sign(m.SlotPrivate, msg)
		if !ed25519.Verify(expected.SlotPublic[m.OwnSlot], msg, sig) {
			t.Fatal("slot key incompatible with standard Ed25519")
		}
	}
	for _, c := range r.servers {
		if e = c.Accept(packet); e != nil {
			t.Fatal(e)
		}
		m, e := c.Material()
		if e != nil {
			t.Fatal(e)
		}
		sm = append(sm, m)
		if hash(m.Public) != hash(expected) {
			t.Fatal("server has different final state")
		}
	}
	seeds := map[[32]byte]bool{}
	for i := range Clients {
		for j := range Coordinators {
			if cm[i].Seeds[j] != sm[j].Seeds[i] || seeds[cm[i].Seeds[j]] || cm[i].Seeds[j] == [32]byte{} {
				t.Fatal("DH seed mismatch, reuse or zero")
			}
			seeds[cm[i].Seeds[j]] = true
		}
	}
}
func TestExactRetriesAreCopiesAndConflictingInputRefused(t *testing.T) {
	r := makeRig(t)
	x := r.inputs(t)
	again, e := r.clients[0].Input()
	if e != nil || hash(again) != hash(x.Inputs[0]) {
		t.Fatal("input retry")
	}
	again.Y[0] ^= 1
	again, e = r.clients[0].Input()
	if e != nil || hash(again) != hash(x.Inputs[0]) {
		t.Fatal("input returned alias")
	}
	m, e := r.servers[0].Mix(x)
	if e != nil {
		t.Fatal(e)
	}
	againMix, e := r.servers[0].Mix(x)
	if e != nil || hash(m) != hash(againMix) {
		t.Fatal("mix retry")
	}
	// A malicious member can sign another valid encryption of its own slot.
	fork := *r.clients[0]
	fork.input = nil
	i, e := fork.Input()
	if e != nil {
		t.Fatal(e)
	}
	other := clone(x)
	other.Inputs[0] = i
	if e = r.view.VerifyInputs(other.Inputs); e != nil {
		t.Fatal("attack fixture invalid", e)
	}
	_, e = r.servers[0].Mix(other)
	reject(t, e)
}
func TestNoReleaseUntilEveryCoordinatorCommitsSameTranscript(t *testing.T) {
	r := makeRig(t)
	x := r.inputs(t)
	_, e := r.servers[0].Release(x, nil)
	reject(t, e)
	for _, s := range r.servers {
		m, e := s.Mix(x)
		if e != nil {
			t.Fatal(e)
		}
		x.Mixes = append(x.Mixes, m)
	}
	var votes []Vote
	for _, s := range r.servers {
		v, e := s.Commit(x)
		if e != nil {
			t.Fatal(e)
		}
		votes = append(votes, v)
	}
	_, e = r.servers[0].Release(x, votes[:2])
	reject(t, e)
	bad := clone(votes)
	bad[1].Root = "different"
	bad[1].Signature = sign(r.servers[1].l.identity, "vote", voteSigned(bad[1]))
	_, e = r.servers[0].Release(x, bad)
	reject(t, e)
	packet := Release{Transcript: x, Votes: votes}
	for _, s := range r.servers {
		v, e := s.Release(x, votes)
		if e != nil {
			t.Fatal(e)
		}
		again, e := s.Release(x, votes)
		if e != nil || hash(again) != hash(v) {
			t.Fatal("decryption retry changed")
		}
		packet.Shares = append(packet.Shares, v)
	}
	missing := clone(packet)
	missing.Shares = missing.Shares[:2]
	_, e = r.view.Finalize(missing)
	reject(t, e)
	if _, e = r.view.Finalize(packet); e != nil {
		t.Fatal("valid recovery after missing share", e)
	}
}
func TestSignedMalformedInputAndShuffleRejected(t *testing.T) {
	r := makeRig(t)
	x := r.inputs(t)
	bad := clone(x)
	p, e := r.view.s.point(bad.Inputs[0].Y, false)
	if e != nil {
		t.Fatal(e)
	}
	bad.Inputs[0].Y = raw(r.view.s.Point().Add(p, r.view.s.Point().Base()))
	bad.Inputs[0].Signature = sign(r.clients[0].l.identity, "input", inputSigned(bad.Inputs[0]))
	_, e = r.servers[0].Mix(bad)
	reject(t, e)
	m, e := r.servers[0].Mix(x)
	if e != nil {
		t.Fatal(e)
	}
	bad = clone(x)
	bad.Mixes = append(bad.Mixes, clone(m))
	bad.Mixes[0].X[0] = append([]byte{}, bad.Mixes[0].X[1]...)
	bad.Mixes[0].Signature = sign(r.servers[0].l.identity, "mix", mixSigned(bad.Mixes[0]))
	_, e = r.servers[1].Mix(bad)
	reject(t, e)
	x.Mixes = append(x.Mixes, m)
	if _, e = r.servers[1].Mix(x); e != nil {
		t.Fatal("bad proof consumed next coordinator", e)
	}
}
func TestSignedBadDecryptionAndContextReplayRejected(t *testing.T) {
	r := makeRig(t)
	packet := r.finish(t, r.inputs(t))
	bad := clone(packet)
	p, e := r.view.s.point(bad.Shares[0].Points[0], true)
	if e != nil {
		t.Fatal(e)
	}
	bad.Shares[0].Points[0] = raw(r.view.s.Point().Add(p, r.view.s.Point().Base()))
	bad.Shares[0].Signature = sign(r.servers[0].l.identity, "share", shareSigned(bad.Shares[0]))
	_, e = r.view.Finalize(bad)
	reject(t, e)
	bad = clone(packet)
	bad.Transcript.Inputs[0].Epoch = "different"
	bad.Transcript.Inputs[0].Signature = sign(r.clients[0].l.identity, "input", inputSigned(bad.Transcript.Inputs[0]))
	_, e = r.view.Finalize(bad)
	reject(t, e)
	// Session freshness includes participant nonces even with the same roster.
	h := clone(r.hellos)
	h[0].Nonce[0] ^= 1
	h[0].Signature = sign(r.clients[0].l.identity, "hello", helloSigned(h[0]))
	fresh, e := NewView(r.roster, h)
	if e != nil {
		t.Fatal(e)
	}
	_, e = fresh.Finalize(packet)
	reject(t, e)
	reject(t, r.clients[1].Bind(r.roster, h))
}
func TestUntrustedHelloRogueKeyAndLowOrderDHRejected(t *testing.T) {
	r := makeRig(t)
	bad := clone(r.hellos)
	bad[0].DH = make([]byte, 32)
	bad[0].Signature = sign(r.clients[0].l.identity, "hello", helloSigned(bad[0]))
	reject(t, r.servers[0].Bind(r.roster, bad))
	bad = clone(r.hellos)
	bad[Clients].DecryptKey = append([]byte{}, bad[Clients+1].DecryptKey...)
	bad[Clients].Signature = sign(r.servers[0].l.identity, "hello", helloSigned(bad[Clients]))
	_, e := NewView(r.roster, bad)
	reject(t, e)
	bad = clone(r.hellos)
	bad[0].Identity = bad[1].Identity
	_, e = NewView(r.roster, bad)
	reject(t, e)
	_, e = NewView(r.roster, r.hellos[:len(r.hellos)-1])
	reject(t, e)
}
func TestMalformedProofEncodingDoesNotPassUpstreamVerifier(t *testing.T) {
	r := makeRig(t)
	x := r.inputs(t)
	for _, mutate := range []func([]byte) []byte{
		func(b []byte) []byte { return append(b, 0) },
		func(b []byte) []byte { return b[:len(b)-1] },
		func(b []byte) []byte {
			for i := len(b) - 32; i < len(b); i++ {
				b[i] = 255
			}
			return b
		},
		func(b []byte) []byte {
			p, _ := hex.DecodeString("ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f")
			copy(b, p)
			return b
		},
	} {
		bad := clone(x)
		bad.Inputs[0].Proof = mutate(bad.Inputs[0].Proof)
		bad.Inputs[0].Signature = sign(r.clients[0].l.identity, "input", inputSigned(bad.Inputs[0]))
		reject(t, r.view.VerifyInputs(bad.Inputs))
	}
	// Neff proofs use the same checked upstream reader, including trailing bytes.
	m, e := r.servers[0].Mix(x)
	if e != nil {
		t.Fatal(e)
	}
	m.Proof = append(m.Proof, 0)
	m.Signature = sign(r.servers[0].l.identity, "mix", mixSigned(m))
	x.Mixes = append(x.Mixes, m)
	_, e = r.servers[1].Mix(x)
	reject(t, e)
}
func TestDuplicateColludingSlotKeysRefusedAtFinalization(t *testing.T) {
	r := makeRig(t)
	r.clients[1].slot = r.clients[0].slot
	packet := r.finish(t, r.inputs(t))
	_, e := r.view.Finalize(packet)
	reject(t, e)
}
func TestMemberOmissionDoesNotBecomeSmallerGroup(t *testing.T) {
	r := makeRig(t)
	x := r.inputs(t)
	x.Inputs = x.Inputs[:Clients-1]
	_, e := r.servers[0].Mix(x)
	reject(t, e)
	if _, e = r.clients[0].Material(); e == nil {
		t.Fatal("material before acceptance")
	}
}
func TestDifferentLocalEpochsHaveDifferentSeeds(t *testing.T) {
	r := makeRig(t)
	old, e := r.clients[0].l.derive(r.view, r.hellos[Clients])
	if e != nil {
		t.Fatal(e)
	}
	h := clone(r.hellos)
	h[1].Nonce[0] ^= 1
	h[1].Signature = sign(r.clients[1].l.identity, "hello", helloSigned(h[1]))
	v, e := NewView(r.roster, h)
	if e != nil {
		t.Fatal(e)
	}
	next, e := r.clients[0].l.derive(v, h[Clients])
	if e != nil || bytes.Equal(old[:], next[:]) {
		t.Fatal("seed epoch binding", e)
	}
}
