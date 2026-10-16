package control

import "testing"

func TestControlCheckpointPreservesCiphertextCertificatesAndProofBudgets(t *testing.T) {
	g := makeGroup(t)
	xs := g.prepare(t, map[int][]byte{0: payload(57)})
	for i, c := range g.clients {
		b, e := c.LocalCheckpoint()
		if e != nil {
			t.Fatal(e)
		}
		g.clients[i], e = RestoreClient(b)
		if e != nil {
			t.Fatal(e)
		}
		var p []byte
		if i == 0 {
			p = payload(57)
		}
		again, e := g.clients[i].Prepare(p)
		if e != nil || hash(again) != hash(xs[i]) {
			t.Fatal("ciphertext regenerated", e)
		}
	}
	var votes []Vote
	for i, s := range g.servers {
		bad := clone(xs)
		bad[0].Cells[0].Proof[0] ^= 1
		bad[0].Signature = sign(g.clients[0].id, "input", contributionSigned(g.d, bad[0]))
		_, e := s.Commit(bad)
		reject(t, e)
		b, e := s.LocalCheckpoint()
		if e != nil {
			t.Fatal(e)
		}
		g.servers[i], e = RestoreCoordinator(b)
		if e != nil {
			t.Fatal(e)
		}
		if g.servers[i].inputProofAttempts != 1 {
			t.Fatal("proof budget reset")
		}
		v, e := g.servers[i].Commit(xs)
		if e != nil {
			t.Fatal(e)
		}
		votes = append(votes, v)
		b, e = g.servers[i].LocalCheckpoint()
		if e != nil {
			t.Fatal(e)
		}
		g.servers[i], e = RestoreCoordinator(b)
		if e != nil {
			t.Fatal(e)
		}
		again, e := g.servers[i].Commit(xs)
		if e != nil || hash(again) != hash(v) {
			t.Fatal("vote changed", e)
		}
	}
	var shares []Share
	for i, s := range g.servers {
		x, e := s.Release(votes)
		if e != nil {
			t.Fatal(e)
		}
		shares = append(shares, x)
		b, e := s.LocalCheckpoint()
		if e != nil {
			t.Fatal(e)
		}
		g.servers[i], e = RestoreCoordinator(b)
		if e != nil {
			t.Fatal(e)
		}
		again, e := g.servers[i].Release(votes)
		if e != nil || hash(again) != hash(x) {
			t.Fatal("share changed", e)
		}
	}
	var out []Output
	var certs []Certificate
	for i, s := range g.servers {
		var e error
		out, e = s.Accept(votes, shares)
		if e != nil {
			t.Fatal(e)
		}
		cert, e := s.Certify()
		if e != nil {
			t.Fatal(e)
		}
		certs = append(certs, cert)
		b, e := s.LocalCheckpoint()
		if e != nil {
			t.Fatal(e)
		}
		g.servers[i], e = RestoreCoordinator(b)
		if e != nil {
			t.Fatal(e)
		}
		again, e := g.servers[i].Certify()
		if e != nil || hash(again) != hash(cert) {
			t.Fatal("certificate changed", e)
		}
	}
	for i, c := range g.clients {
		if _, e := c.AcceptCertified(xs, votes, out, certs); e != nil {
			t.Fatal(e)
		}
		b, e := c.LocalCheckpoint()
		if e != nil {
			t.Fatal(e)
		}
		g.clients[i], e = RestoreClient(b)
		if e != nil {
			t.Fatal(e)
		}
		again, e := g.clients[i].AcceptCertified(xs, votes, out, certs)
		if e != nil || hash(again) != hash(out) {
			t.Fatal("accepted output changed", e)
		}
	}
}
