package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"testing"

	groupSetup "farvahartrends.local/privacy-lab/setupprobe/setup"
)

func TestRoleLocalSetupAndLateRetryDoNotResetRounds(t *testing.T) {
	var nodes []*roleNode
	var hellos []groupSetup.Hello
	roster := groupSetup.Roster{Version: 1, Policy: "isolated node test; fixed roster"}
	call := func(n *roleNode, q rpcRequest) rpcResponse {
		t.Helper()
		r, e := n.handle(q)
		if e != nil {
			t.Fatal(q.Op, e)
		}
		return r
	}
	for i := range clients + coordinators {
		role, index := "client", i
		if i >= clients {
			role, index = "coordinator", i-clients
		}
		c := nodeConfig{AnonymousSetup: true, Role: role, Index: index, SlotLimit: clients, Slot: -1}
		n, e := newRoleNode(c)
		if e != nil {
			t.Fatal(e)
		}
		nodes = append(nodes, n)
		if _, e = n.handle(rpcRequest{Op: "prepare"}); e == nil {
			t.Fatal("publication before setup")
		}
		h := call(n, rpcRequest{Op: "setup-hello"}).SetupHello
		hellos = append(hellos, *h)
		if i < clients {
			roster.ClientKeys = append(roster.ClientKeys, h.Identity)
		} else {
			roster.CoordinatorKeys = append(roster.CoordinatorKeys, h.Identity)
		}
		// The disk/startup configuration contains no protocol private material.
		b, e := json.Marshal(c)
		if e != nil {
			t.Fatal(e)
		}
		if bytes.Contains(b, []byte(base64.StdEncoding.EncodeToString(n.config.Private))) {
			t.Fatal("generated identity exported into startup config")
		}
	}
	for _, n := range nodes {
		call(n, rpcRequest{Op: "setup-bind", SetupRoster: &roster, SetupHellos: hellos})
	}
	view, e := groupSetup.NewView(roster, hellos)
	if e != nil {
		t.Fatal(e)
	}
	transcript := groupSetup.Transcript{Epoch: view.Epoch()}
	for _, n := range nodes[:clients] {
		r := call(n, rpcRequest{Op: "setup-input"})
		transcript.Inputs = append(transcript.Inputs, *r.SetupInput)
	}
	for _, n := range nodes[clients:] {
		r := call(n, rpcRequest{Op: "setup-mix", SetupTranscript: &transcript})
		transcript.Mixes = append(transcript.Mixes, *r.SetupMix)
	}
	packet := groupSetup.Release{Transcript: transcript}
	for _, n := range nodes[clients:] {
		r := call(n, rpcRequest{Op: "setup-commit", SetupTranscript: &transcript})
		packet.Votes = append(packet.Votes, *r.SetupVote)
	}
	for _, n := range nodes[clients:] {
		r := call(n, rpcRequest{Op: "setup-release", SetupTranscript: &transcript, SetupVotes: packet.Votes})
		packet.Shares = append(packet.Shares, *r.SetupShare)
	}
	q := rpcRequest{Op: "setup-finalize", SetupRelease: &packet}
	var public []byte
	for _, n := range nodes {
		oldClient, oldCoordinator := n.setup.client, n.setup.coordinator
		r := call(n, q)
		if n.setup.client != nil || n.setup.coordinator != nil {
			t.Fatal("completed setup retained private setup objects")
		}
		compact, e := n.checkpoint()
		if e != nil {
			t.Fatal(e)
		}
		var old roleCheckpoint
		if e = json.Unmarshal(compact, &old); e != nil {
			t.Fatal(e)
		}
		if oldClient != nil {
			old.Setup.Client, e = oldClient.LocalCheckpoint()
		} else {
			old.Setup.Coordinator, e = oldCoordinator.LocalCheckpoint()
		}
		if e != nil {
			t.Fatal(e)
		}
		legacy, e := json.Marshal(old)
		if e != nil {
			t.Fatal(e)
		}
		if len(compact) >= len(legacy) {
			t.Fatal("retiring setup did not reduce checkpoint")
		}
		for _, snapshot := range [][]byte{compact, legacy} {
			restored, e := restoreRole(snapshot)
			if e != nil {
				t.Fatal(e)
			}
			if restored.setup.client != nil || restored.setup.coordinator != nil {
				t.Fatal("restore revived retired setup objects")
			}
			restored.cache = nil
			if !bytes.Equal(encodeSetup(call(restored, q)), encodeSetup(r)) {
				t.Fatal("compact restore changed final setup receipt")
			}
			bad := old
			final := *old.Setup.Final
			final.Epoch = "wrong"
			setupCopy := *old.Setup
			setupCopy.Final = &final
			bad.Setup = &setupCopy
			encoded, _ := json.Marshal(bad)
			if _, e = restoreRole(encoded); e == nil {
				t.Fatal("mismatched final setup accepted")
			}
		}
		t.Logf("%s-%d checkpoint: legacy %d bytes, compact %d bytes", n.config.Role, n.config.Index, len(legacy), len(compact))
		b, e := json.Marshal(r)
		if e != nil {
			t.Fatal(e)
		}
		if bytes.Contains(b, []byte(base64.StdEncoding.EncodeToString(n.config.Private))) {
			t.Fatal("setup response exported identity")
		}
		if len(n.config.SlotPrivate) > 0 && bytes.Contains(b, []byte(base64.StdEncoding.EncodeToString(n.config.SlotPrivate))) {
			t.Fatal("setup response exported slot private key")
		}
		for _, seed := range n.config.Seeds {
			if bytes.Contains(b, []byte(base64.StdEncoding.EncodeToString(seed.Value))) {
				t.Fatal("setup response exported shared seed")
			}
		}
		b, e = json.Marshal(r.SetupFinal)
		if e != nil {
			t.Fatal(e)
		}
		if public == nil {
			public = b
		} else if !bytes.Equal(public, b) {
			t.Fatal("different public setup results")
		}
	}
	for c := range clients {
		f := nodes[c].state
		for s := range coordinators {
			if f.seeds[c][s] != nodes[clients+s].state.seeds[c][s] {
				t.Fatal("incorrect local material adapter")
			}
		}
		for other := range clients {
			if other != c && (f.ownerSlot[other] != -1 || len(f.clientKeys[other].private) != 0) {
				t.Fatal("foreign client secrets/mapping")
			}
		}
	}
	for _, n := range nodes[clients:] {
		for c := range clients {
			if n.state.ownerSlot[c] != -1 || len(n.state.slotKeys[c].private) != 0 {
				t.Fatal("coordinator received publisher secrets")
			}
		}
	}
	n := nodes[0]
	call(n, rpcRequest{Op: "prepare", Descriptor: descriptorRPC(n.state.reservation(0)), Payload: []byte{1}})
	n.cache = nil // model bounded response-cache eviction, not protocol-state loss
	call(n, q)
	if n.state.clientNext[0] != 1 {
		t.Fatal("late setup retry reset a consumed mask")
	}
	bad := q
	changed := jsonCopy(packet)
	changed.Shares = changed.Shares[:2]
	bad.SetupRelease = &changed
	if _, e = n.handle(bad); e == nil {
		t.Fatal("different final release accepted after setup")
	}
	if n.state.clientNext[0] != 1 {
		t.Fatal("rejected setup modified round state")
	}
}
