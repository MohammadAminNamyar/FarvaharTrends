package control

import (
	"errors"
	"testing"
)

func TestCertifiedClientRejectsForgeryMissingSignerReplayAndOwnInputReplacement(t *testing.T) {
	g := makeGroup(t)
	xs := g.prepare(t, map[int][]byte{0: payload(42)})
	_, e := g.servers[0].Certify()
	reject(t, e)
	vs, ss := g.release(t, xs)
	_, e = g.servers[0].Certify()
	reject(t, e)
	var certs []Certificate
	var out []Output
	for _, s := range g.servers {
		out, e = s.Accept(vs, ss)
		if e != nil {
			t.Fatal(e)
		}
		cert, e := s.Certify()
		if e != nil {
			t.Fatal(e)
		}
		certs = append(certs, cert)
	}
	c := g.clients[0]
	_, e = c.AcceptCertified(xs, vs, out, certs[:2])
	reject(t, e)
	_, e = c.AcceptCertified(xs, vs[:2], out, certs)
	reject(t, e)
	mutations := map[string]func([]Certificate){
		"forged signature": func(cs []Certificate) { cs[2].Signature[0] ^= 1 },
		"duplicate signer": func(cs []Certificate) { cs[2] = cs[1] },
		"wrong root":       func(cs []Certificate) { cs[1].Root = hash("other inputs") },
	}
	for name, mutate := range mutations {
		t.Run(name, func(t *testing.T) {
			cs := clone(certs)
			mutate(cs)
			_, e := c.AcceptCertified(xs, vs, out, cs)
			reject(t, e)
		})
	}
	bad := clone(out)
	bad[c.slot].Payload[0] ^= 1
	_, e = c.AcceptCertified(xs, vs, bad, certs)
	reject(t, e)
	badInputs := clone(xs)
	badInputs[0] = xs[1]
	_, e = c.AcceptCertified(badInputs, vs, out, certs)
	reject(t, e)
	other := g.d
	other.Sequence++
	reject(t, g.v.VerifyCertificates(other, vs[0].Root, out, certs))
	other = g.d
	other.Context = hash("different failed transcript")
	reject(t, g.v.VerifyCertificates(other, vs[0].Root, out, certs))
	// All three signatures are required even when two admitted coordinators
	// sign a consistent fabricated payload with their actual identity keys.
	forged := clone(certs)
	for i := 0; i < 2; i++ {
		forged[i].Signature = sign(g.servers[i].id, "output", certificateSigned(g.d, forged[i], bad))
	}
	_, e = c.AcceptCertified(xs, vs, bad, forged)
	reject(t, e)
	for _, client := range g.clients {
		x, e := client.AcceptCertified(xs, vs, out, certs)
		if e != nil || hash(x) != hash(out) {
			t.Fatal("certificate acceptance", e)
		}
		x[0].Invalid = !x[0].Invalid
		again, e := client.AcceptCertified(xs, vs, out, certs)
		if e != nil || hash(again) != hash(out) {
			t.Fatal("cached output mutated", e)
		}
		_, e = client.AcceptCertified(xs, vs, bad, certs)
		reject(t, e)
	}
	other = g.d
	other.Sequence++
	g.begin(t, other)
	_, e = g.servers[0].Certify()
	reject(t, e)
}

func TestControlExpensiveProofAttemptsBoundedWithoutResetOrSilentFallback(t *testing.T) {
	g := makeGroup(t)
	xs := g.prepare(t, nil)
	s := g.servers[0]
	// Missing and unauthenticated inputs are rejected before the costly budget.
	for i := 0; i < 8; i++ {
		_, e := s.Commit(xs[:7])
		reject(t, e)
		bad := clone(xs)
		bad[7].Signature[0] ^= 1
		_, e = s.Commit(bad)
		reject(t, e)
	}
	if s.inputProofAttempts != 0 {
		t.Fatal("cheap rejections spent proof budget")
	}
	bad := clone(xs)
	bad[0].Cells[0].Proof[0] ^= 1
	bad[0].Signature = sign(g.clients[0].id, "input", contributionSigned(g.d, bad[0]))
	for range maxProofAttempts {
		_, e := s.Commit(bad)
		reject(t, e)
	}
	_, e := s.Commit(xs)
	if !errors.Is(e, errProofBudget) {
		t.Fatal("signed proof spam not bounded", e)
	}
	if e = s.Begin(g.d); e != nil {
		t.Fatal(e)
	}
	if e = s.Bind(g.hs); e != nil {
		t.Fatal(e)
	}
	_, e = s.Commit(xs)
	if !errors.Is(e, errProofBudget) {
		t.Fatal("retry reset proof budget")
	}
	d := g.d
	d.Sequence++
	reject(t, s.Begin(d))
	_, e = s.Release(nil)
	reject(t, e)
	_, e = s.Certify()
	reject(t, e)
}

func TestControlShareProofBudgetAndTransientRetry(t *testing.T) {
	g := makeGroup(t)
	xs := g.prepare(t, nil)
	vs, ss := g.release(t, xs)
	bad := clone(ss)
	bad[0].Cells[0].Proof[0] ^= 1
	bad[0].Signature = sign(g.servers[0].id, "share", shareSigned(g.d, bad[0]))
	for i, s := range g.servers[:2] {
		for j := 0; j < 5; j++ {
			_, e := s.Accept(vs, ss[:2])
			reject(t, e)
		}
		if s.shareProofAttempts != 0 {
			t.Fatal("missing share spent budget")
		}
		attempts := maxProofAttempts
		if i == 0 {
			attempts--
		}
		for range attempts {
			_, e := s.Accept(vs, bad)
			reject(t, e)
		}
		_, e := s.Accept(vs, ss)
		if i == 0 {
			if e != nil {
				t.Fatal("correct transient retry", e)
			}
			if _, e = s.Certify(); e != nil {
				t.Fatal(e)
			}
		} else {
			if !errors.Is(e, errProofBudget) {
				t.Fatal("share proof spam not bounded", e)
			}
			_, e = s.Certify()
			reject(t, e)
		}
	}
}
