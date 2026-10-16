package setup

import "testing"

func TestPrivateSetupCheckpointPreservesRandomizedInputsAndSharedMaterial(t *testing.T) {
	r := makeRig(t)
	x := r.inputs(t)
	for i, c := range r.clients {
		b, e := c.LocalCheckpoint()
		if e != nil {
			t.Fatal(e)
		}
		r.clients[i], e = RestoreClient(b)
		if e != nil {
			t.Fatal(e)
		}
		again, e := r.clients[i].Input()
		if e != nil || hash(again) != hash(x.Inputs[i]) {
			t.Fatal("input changed across restore", e)
		}
	}
	for i, s := range r.servers {
		m, e := s.Mix(x)
		if e != nil {
			t.Fatal(e)
		}
		b, e := s.LocalCheckpoint()
		if e != nil {
			t.Fatal(e)
		}
		r.servers[i], e = RestoreCoordinator(b)
		if e != nil {
			t.Fatal(e)
		}
		again, e := r.servers[i].Mix(x)
		if e != nil || hash(again) != hash(m) {
			t.Fatal("shuffle changed across restore", e)
		}
		x.Mixes = append(x.Mixes, m)
	}
	packet := Release{Transcript: x}
	for _, s := range r.servers {
		v, e := s.Commit(x)
		if e != nil {
			t.Fatal(e)
		}
		packet.Votes = append(packet.Votes, v)
	}
	for _, s := range r.servers {
		v, e := s.Release(x, packet.Votes)
		if e != nil {
			t.Fatal(e)
		}
		packet.Shares = append(packet.Shares, v)
	}
	for i, c := range r.clients {
		if e := c.Accept(packet); e != nil {
			t.Fatal(e)
		}
		before, e := c.Material()
		if e != nil {
			t.Fatal(e)
		}
		b, e := c.LocalCheckpoint()
		if e != nil {
			t.Fatal(e)
		}
		r.clients[i], e = RestoreClient(b)
		if e != nil {
			t.Fatal(e)
		}
		after, e := r.clients[i].Material()
		if e != nil || hash(before) != hash(after) {
			t.Fatal("client material changed", e)
		}
	}
	for i, s := range r.servers {
		if e := s.Accept(packet); e != nil {
			t.Fatal(e)
		}
		before, e := s.Material()
		if e != nil {
			t.Fatal(e)
		}
		b, e := s.LocalCheckpoint()
		if e != nil {
			t.Fatal(e)
		}
		r.servers[i], e = RestoreCoordinator(b)
		if e != nil {
			t.Fatal(e)
		}
		after, e := r.servers[i].Material()
		if e != nil || hash(before) != hash(after) {
			t.Fatal("coordinator material changed", e)
		}
	}
}
