package main

import (
	"bytes"
	"crypto/ed25519"
	"path/filepath"
	"testing"
)

func TestRoleProjectionContainsOnlyItsOwnSecrets(t *testing.T) {
	f := newFixtureWithLimit(clients)
	for c := range clients {
		node, e := newRoleNode(configFor(f, "client", c))
		if e != nil {
			t.Fatal(e)
		}
		for i := range clients {
			if i != c && (len(node.state.clientKeys[i].private) != 0 || node.state.ownerSlot[i] != -1) {
				t.Fatal("foreign client secret or mapping")
			}
			for s := range coordinators {
				if node.state.seedAvailable[i][s] != (i == c) {
					t.Fatal("foreign seed")
				}
			}
		}
		for i, k := range node.state.slotKeys {
			if (len(k.private) > 0) != (i == f.ownerSlot[c]) {
				t.Fatal("foreign slot secret")
			}
		}
		for _, k := range node.state.serverKeys {
			if len(k.private) != 0 {
				t.Fatal("coordinator signing secret leaked")
			}
		}
	}
	for s := range coordinators {
		node, e := newRoleNode(configFor(f, "coordinator", s))
		if e != nil {
			t.Fatal(e)
		}
		for c := range clients {
			if len(node.state.clientKeys[c].private) != 0 || len(node.state.slotKeys[c].private) != 0 || node.state.ownerSlot[c] != -1 {
				t.Fatal("publisher secret or mapping leaked")
			}
			for j := range coordinators {
				if node.state.seedAvailable[c][j] != (j == s) {
					t.Fatal("foreign seed")
				}
			}
		}
	}
}
func TestForeignSeedCannotBeInjectedIntoRoleConfig(t *testing.T) {
	f := newFixture()
	c := configFor(f, "client", 0)
	c.Seeds[0].Client = 1
	_, e := newRoleNode(c)
	requireReject(t, e)
	c = configFor(f, "coordinator", 0)
	c.Seeds[0].Server = 1
	_, e = newRoleNode(c)
	requireReject(t, e)
}
func TestOnlyOwnedRoleOperationsAreAllowedAndRetriesAreIdempotent(t *testing.T) {
	f := newFixture()
	node, e := newRoleNode(configFor(f, "client", 0))
	if e != nil {
		t.Fatal(e)
	}
	d := descriptorRPC(f.reservation(0))
	q := rpcRequest{Op: "prepare", Descriptor: d, Payload: []byte{1}}
	first, e := node.handle(q)
	if e != nil {
		t.Fatal(e)
	}
	again, e := node.handle(q)
	if e != nil || !bytes.Equal(first.Input.Body, again.Input.Body) || !bytes.Equal(first.Input.Signature, again.Input.Signature) {
		t.Fatal("exact retry changed ciphertext", e)
	}
	q.Payload = []byte{2}
	_, e = node.handle(q)
	requireReject(t, e)
	_, e = node.handle(rpcRequest{Op: "commit", Descriptor: d})
	requireReject(t, e)
	coordinator, e := newRoleNode(configFor(f, "coordinator", 0))
	if e != nil {
		t.Fatal(e)
	}
	_, e = coordinator.handle(rpcRequest{Op: "prepare", Descriptor: d})
	requireReject(t, e)
}
func TestIndependentRolesAgreeAndRejectIncompleteOutput(t *testing.T) {
	f := newFixtureWithLimit(clients)
	cc := []*roleNode{}
	ss := []*roleNode{}
	for c := range clients {
		n, e := newRoleNode(configFor(f, "client", c))
		if e != nil {
			t.Fatal(e)
		}
		cc = append(cc, n)
	}
	for s := range coordinators {
		n, e := newRoleNode(configFor(f, "coordinator", s))
		if e != nil {
			t.Fatal(e)
		}
		ss = append(ss, n)
	}
	for round := range 6 {
		d := descriptorRPC(f.reservation(uint64(round)))
		xs := []rpcInput{}
		for _, c := range cc {
			r, e := c.handle(rpcRequest{Op: "prepare", Descriptor: d})
			if e != nil {
				t.Fatal(e)
			}
			xs = append(xs, *r.Input)
		}
		votes := []rpcVote{}
		for _, s := range ss {
			r, e := s.handle(rpcRequest{Op: "commit", Descriptor: d, Inputs: xs})
			if e != nil {
				t.Fatal(e)
			}
			votes = append(votes, *r.Vote)
		}
		shares := []rpcShare{}
		for _, s := range ss {
			r, e := s.handle(rpcRequest{Op: "release", Descriptor: d, Votes: votes})
			if e != nil {
				t.Fatal(e)
			}
			shares = append(shares, *r.Share)
		}
		var first rpcResponse
		signatures := [][]byte{}
		// Caller buffers may change after commit. A role must retain the exact
		// previously authenticated input set rather than aliasing caller memory.
		xs[0].Body[0] ^= 1
		for i, s := range ss {
			q := rpcRequest{Op: "finish", Descriptor: d, Root: votes[0].Root, Shares: shares}
			bad := q
			bad.Inputs = xs
			_, e := s.handle(bad)
			requireReject(t, e)
			bad = q
			bad.Root = append([]byte{}, q.Root...)
			bad.Root[0] ^= 1
			_, e = s.handle(bad)
			requireReject(t, e)
			r, e := s.handle(q)
			if e != nil {
				t.Fatal(e)
			}
			if i == 0 {
				first = r
			} else if !bytes.Equal(first.Output, r.Output) || !bytes.Equal(first.Root, r.Root) {
				t.Fatal("independent states diverged")
			}
			if s.pending != nil {
				t.Fatal("completed input batch retained")
			}
			signatures = append(signatures, r.Signature)
			retry, e := s.handle(q)
			if e != nil || !bytes.Equal(retry.Signature, r.Signature) {
				t.Fatal("lost reply cannot be recovered")
			}
		}
		for _, c := range cc {
			bad := rpcRequest{Op: "accept", Descriptor: d, Root: first.Root, Output: first.Output, Signatures: signatures[:2]}
			_, e := c.handle(bad)
			requireReject(t, e)
			bad.Signatures = signatures
			r, e := c.handle(bad)
			if e != nil {
				t.Fatal(e)
			}
			_ = r
			if len(c.cache) > 8 {
				t.Fatal("unbounded reply cache")
			}
		}
		native, _ := d.value()
		if !ed25519.Verify(f.serverKeys[0].pub, outputSigned(native, first.Root, first.Output), signatures[0]) {
			t.Fatal("bad certificate")
		}
		f.advance(native, result{raw: first.Output, messages: map[int][]byte{}})
	}
}

func TestRoleConfigurationCannotBeRestartedWithSameMasks(t *testing.T) {
	path := filepath.Join(t.TempDir(), "role-config.json")
	if e := claimRoleConfiguration(path); e != nil {
		t.Fatal(e)
	}
	requireReject(t, claimRoleConfiguration(path))
}
