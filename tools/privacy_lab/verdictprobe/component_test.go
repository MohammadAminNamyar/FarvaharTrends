package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/hex"
	"testing"

	"go.dedis.ch/kyber/v4"
	"go.dedis.ch/kyber/v4/proof"
)

func trial(t *testing.T, size int) (*fixture, descriptor, []byte, []contribution, []share) {
	t.Helper()
	f := newFixture()
	d := descriptor{f.epoch, 1, 3, size}
	m := bytes.Repeat([]byte{73}, size)
	var inputs []contribution
	for i := range clients {
		var payload []byte
		if i == d.Slot {
			payload = m
		}
		c, e := f.create(d, i, payload)
		if e != nil {
			t.Fatal(e)
		}
		inputs = append(inputs, c)
	}
	var shares []share
	for i := range servers {
		v, e := f.release(d, i, inputs)
		if e != nil {
			t.Fatal(e)
		}
		shares = append(shares, v)
	}
	return f, d, m, inputs, shares
}
func TestActualPayloadAndEqualShapes(t *testing.T) {
	for _, size := range []int{1, 29, 32, 96} {
		f, d, m, c, v := trial(t, size)
		got, e := f.reveal(d, c, v)
		if e != nil || !bytes.Equal(got, m) {
			t.Fatalf("payload %d: %v", size, e)
		}
		for _, x := range c {
			if len(x.Proof) != len(c[0].Proof) || len(encoded(x)) != len(encoded(c[0])) {
				t.Fatal("owner/cover encoding size differs")
			}
		}
	}
}
func TestSignedCorruptionDoesNotRelease(t *testing.T) {
	f, d, _, c, _ := trial(t, 32)
	x := c[0]
	x.C = append([][]byte{}, x.C...)
	p, e := f.point(x.C[0], false)
	if e != nil {
		t.Fatal(e)
	}
	x.C[0] = raw(f.s.Point().Add(p, f.s.Point().Base()))
	x.Signature = ed25519.Sign(f.identities[0], clientSigned(d, x))
	c[0] = x
	for i := range servers {
		if _, e := f.release(d, i, c); e == nil {
			t.Fatal("signed jamming released a server share")
		}
	}
}
func TestNonownerCannotProveMalformedCover(t *testing.T) {
	f := newFixture()
	d := descriptor{f.epoch, 1, 1, 1}
	r := f.s.Scalar().Pick(f.s.RandomStream())
	c := contribution{Index: 0, R: [][]byte{raw(f.s.Point().Mul(r, nil))}, C: [][]byte{raw(f.s.Point().Add(f.s.Point().Base(), f.s.Point().Mul(r, f.serverSum)))}}
	p, pts, e := f.clientPredicate(d, c)
	if e != nil {
		t.Fatal(e)
	}
	c.Proof, e = proof.HashProve(f.s, clientContext(d, c), p.Prover(f.s, map[string]kyber.Scalar{"r0": r}, pts, map[proof.Predicate]int{p: 0}))
	if e != nil {
		t.Fatal(e)
	}
	c.Signature = ed25519.Sign(f.identities[0], clientSigned(d, c))
	if f.verifyClient(d, c) == nil {
		t.Fatal("nonowner proved a nonzero cover")
	}
}
func TestContextsAndBoundedProofs(t *testing.T) {
	f, d, _, c, v := trial(t, 32)
	changed := []descriptor{d, d, d, d}
	changed[0].Sequence++
	changed[1].Slot++
	changed[2].Epoch = "different"
	changed[3].Size++
	for _, x := range changed {
		if _, e := f.reveal(x, c, v); e == nil {
			t.Fatal("changed context accepted")
		}
	}
	// A malicious member can sign again. Require the proof itself, not just
	// the outer signature, to bind its contribution to the original context.
	for _, next := range []descriptor{changed[0], changed[1], changed[3]} {
		x := c[0]
		x.Signature = ed25519.Sign(f.identities[0], clientSigned(next, x))
		if f.verifyClient(next, x) == nil {
			t.Fatal("re-signed contribution reused a proof in another context")
		}
	}
	x := c[0]
	x.Proof = append(append([]byte{}, x.Proof...), 0)
	x.Signature = ed25519.Sign(f.identities[0], clientSigned(d, x))
	if f.verifyClient(d, x) == nil {
		t.Fatal("proof trailing data")
	}
	x.Proof = x.Proof[:len(x.Proof)-2]
	x.Signature = ed25519.Sign(f.identities[0], clientSigned(d, x))
	if f.verifyClient(d, x) == nil {
		t.Fatal("truncated proof")
	}
}
func TestIncompleteOrDifferentRosterDoesNotRelease(t *testing.T) {
	f, d, _, c, v := trial(t, 32)
	if _, e := f.release(d, 0, c[:7]); e == nil {
		t.Fatal("missing client")
	}
	if _, e := f.reveal(d, c, v[:2]); e == nil {
		t.Fatal("missing server")
	}
	c[0] = c[1]
	if _, e := f.release(d, 0, c); e == nil {
		t.Fatal("duplicate client")
	}
}
func TestSignedServerTamperAndInputRoot(t *testing.T) {
	f, d, _, c, v := trial(t, 32)
	x := v[0]
	x.S = append([][]byte{}, x.S...)
	p, e := f.point(x.S[0], false)
	if e != nil {
		t.Fatal(e)
	}
	x.S[0] = raw(f.s.Point().Add(p, f.s.Point().Base()))
	x.Signature = ed25519.Sign(f.identities[clients], serverSigned(d, x))
	bad := append([]share{}, v...)
	bad[0] = x
	if _, e := f.reveal(d, c, bad); e == nil {
		t.Fatal("signed server corruption")
	}
	x = v[0]
	x.Root = "different"
	x.Signature = ed25519.Sign(f.identities[clients], serverSigned(d, x))
	bad[0] = x
	if _, e := f.reveal(d, c, bad); e == nil {
		t.Fatal("different signed input root")
	}
}
func TestPrimeSubgroupAndCanonicalProof(t *testing.T) {
	f := newFixture()
	b, e := hex.DecodeString("ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f")
	if e != nil {
		t.Fatal(e)
	}
	torsion := f.s.Point()
	if e = torsion.UnmarshalBinary(b); e != nil {
		t.Fatal(e)
	}
	mixed := f.s.Point().Add(f.s.Point().Base(), torsion)
	for _, p := range []kyber.Point{torsion, mixed} {
		if _, e = f.point(raw(p), false); e == nil {
			t.Fatal("torsion accepted")
		}
	}
	if _, e = f.point(raw(f.s.Point().Null()), true); e == nil {
		t.Fatal("zero public key")
	}
	if _, e = f.point(raw(f.s.Point().Null()), false); e != nil {
		t.Fatal("zero ciphertext rejected", e)
	}
	bad := append([]byte{}, f.setupProofs[0]...)
	copy(bad[:32], raw(mixed))
	if f.validProof(bad, 1, 1) == nil {
		t.Fatal("mixed torsion commitment")
	}
	bad = append([]byte{}, f.setupProofs[0]...)
	for i := 32; i < len(bad); i++ {
		bad[i] = 255
	}
	if f.validProof(bad, 1, 1) == nil {
		t.Fatal("noncanonical scalar")
	}
}
func TestSetupProofBoundToKeyAndEpoch(t *testing.T) {
	f := newFixture()
	p := proof.Rep("B", "b", "G")
	pts := map[string]kyber.Point{"B": f.serverKeys[0].public, "G": f.s.Point().Base()}
	if proof.HashVerify(f.s, domain+"/setup/wrong/0", p.Verifier(f.s, pts), f.setupProofs[0]) == nil {
		t.Fatal("setup epoch replay")
	}
	pts["B"] = f.serverKeys[1].public
	if proof.HashVerify(f.s, domain+"/setup/"+f.epoch+"/0", p.Verifier(f.s, pts), f.setupProofs[0]) == nil {
		t.Fatal("rogue setup key")
	}
}
