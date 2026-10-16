package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"testing"
)

func TestCompletedPreparedCopyRetiresWithoutLosingRetryOrRecovery(t *testing.T) {
	f := newScheduledFixtureStorage(t, true)
	f.lab.localOutboxes, f.lab.fuseReservationPrepare = true, true
	payloads := map[int][]byte{}
	for i := range clients {
		payloads[i] = []byte(fmt.Sprintf("آزمایش بازیابی و پاسخ تکراری پس از پایان دور؛ نویسندهٔ %d", i))
		if _, e := f.nodes[i].enqueueLocal(localSubmission{1, payloads[i]}); e != nil {
			t.Fatal(e)
		}
	}
	call := f.lab.componentCall
	var retryRequest rpcRequest
	var retryResponse rpcResponse
	checkedRejections := 0
	f.lab.componentCall = func(id int, q rpcRequest) (rpcResponse, error) {
		if id == 0 && (q.Op == "accept-and-prepare" || q.Op == "accept") {
			if f.nodes[0].prepared == nil {
				t.Fatal("live contribution missing before acceptance")
			}
			prepared := inputRPC(*f.nodes[0].prepared)
			before, _ := json.Marshal(prepared)
			bad := jsonCopy(q)
			bad.Signatures[0][0] ^= 1
			if _, e := call(id, bad); e == nil {
				t.Fatal("altered certificate accepted")
			}
			if f.nodes[0].prepared == nil {
				t.Fatal("rejected certificate erased active contribution")
			}
			after, _ := json.Marshal(inputRPC(*f.nodes[0].prepared))
			if !bytes.Equal(before, after) {
				t.Fatal("rejected certificate changed active contribution")
			}
			checkedRejections++
		}
		r, e := call(id, q)
		if id == 0 && q.Op == "accept-and-prepare" && e == nil {
			if r.Input == nil || f.nodes[0].prepared == nil {
				t.Fatal("fused preparation lost its new active contribution")
			}
			retryRequest, retryResponse = jsonCopy(q), jsonCopy(r)
		}
		return r, e
	}
	f.at(0)
	if out := f.cycle(t, 0); !samePayloadMultiset(out, payloads) || checkedRejections != 2 {
		t.Fatal("round did not release all authenticated payloads")
	}
	for _, n := range f.nodes[:clients] {
		if n.prepared != nil {
			t.Fatal("completed contribution still retained outside reply cache")
		}
	}
	n := f.nodes[0]
	if e := n.journal.close(); e != nil {
		t.Fatal(e)
	}
	restored, e := openDurableRole(n.config, f.dirs[0])
	if e != nil {
		t.Fatal(e)
	}
	defer restored.journal.close()
	if restored.prepared != nil {
		t.Fatal("restoration recreated a completed contribution")
	}
	commits := restored.journal.commits
	again, e := restored.handle(retryRequest)
	want, _ := json.Marshal(retryResponse)
	got, _ := json.Marshal(again)
	if e != nil || !bytes.Equal(want, got) || restored.journal.commits != commits {
		t.Fatal("historical exact retry changed after durable recovery", e)
	}
	status, e := restored.localStatus(1)
	if e != nil || status.Status != "released" {
		t.Fatal("certified local receipt lost", e)
	}
	if _, e := restored.enqueueLocal(localSubmission{2, []byte("نباید با ساعت قدیمی منتشر شود")}); e == nil {
		t.Fatal("retirement bypassed restart clock fence")
	}
}
