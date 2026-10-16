package main

import (
	"bytes"
	"fmt"
	"testing"
)

// Retained negative control: the old RPC-selected cutoff can isolate a sender
// without forging any contribution, membership list or release certificate.
func TestLegacySchedulerCutoffCanIsolateLateClient(t *testing.T) {
	f := newOutboxFixture(t)
	target := 5
	d := descriptorRPC(f.lab.public.reservation(0))
	for i := range clients {
		if i == target {
			continue
		}
		if _, e := f.nodes[i].handle(rpcRequest{Op: "prepare", Descriptor: d}); e != nil {
			t.Fatal(e)
		}
	}
	payloads := map[int][]byte{}
	for i := range clients {
		payloads[i] = []byte(fmt.Sprintf("خبر آزمایشی فارسی از عضو %d", i))
		if _, e := f.nodes[i].enqueueLocal(localSubmission{1, payloads[i]}); e != nil {
			t.Fatal(e)
		}
	}
	// Every member now has news. Only the target's request has not arrived yet.
	out := f.cycle(t, 0)
	if len(out.messages) != 1 {
		t.Fatal("negative control did not isolate one output")
	}
	for _, p := range out.messages {
		if !bytes.Equal(p, payloads[target]) {
			t.Fatal("wrong isolated target")
		}
	}
	for i := range clients {
		r, e := f.nodes[i].localStatus(1)
		if e != nil || (r.Status == "released") != (i == target) {
			t.Fatal("wrong release status", i, e)
		}
	}
	t.Log("Reproduced: scheduler delayed only client 5; its news was the sole certified output while seven other clients retained queued news.")
}
