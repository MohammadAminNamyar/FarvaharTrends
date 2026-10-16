package main

import (
	"bytes"
	"encoding/json"
	"testing"
)

func TestLocalDiagnosticsStayPrivateBoundedAndReadOnly(t *testing.T) {
	f := newScheduledFixture(t)
	n := f.nodes[0]
	secret := []byte("PRIVATE-DIAGNOSTIC-MESSAGE-نباید-وارد-گزارش-شود")
	if _, e := n.enqueueLocal(localSubmission{1, secret}); e != nil {
		t.Fatal(e)
	}
	f.at(0)
	q := rpcRequest{Op: "prepare", Descriptor: descriptorRPC(f.lab.public.reservation(0))}
	dbBefore := n.journal.db.Stats()
	if _, e := n.handle(q); e != nil {
		t.Fatal(e)
	}
	first := n.privateDiagnostics()
	if first.Stats.JournalCommits == 0 || len(first.Operations) == 0 {
		t.Fatal("missing local observations")
	}
	last := first.Operations[len(first.Operations)-1]
	if last.Operation != "prepare" || last.JournalCommits != 2 || last.Rejected || last.TotalMs < last.LockWaitMs || last.ProcessCPUms < 0 {
		t.Fatal("incorrect operation timing or durable-write accounting", last)
	}
	dbAfter := n.journal.db.Stats()
	delta := dbAfter.TxStats.Sub(&dbBefore.TxStats)
	if last.CheckpointPlaintextBytes == 0 || last.DatabaseAllocatedBytes <= 0 ||
		last.DatabaseAllocatedBytes != delta.GetPageAlloc() || last.DatabaseAllocatedPages != delta.GetPageCount() ||
		last.DatabaseWriteMs < 0 || last.DatabaseSpillMs < 0 || last.DatabaseRebalanceMs < 0 ||
		last.DatabaseWriteMs > last.PendingWriteMs+last.StateWriteMs+0.01 {
		t.Fatal("private database costs do not match actual transaction accounting", last)
	}
	before := n.journal.commits
	peer, e := n.handle(rpcRequest{Op: "stats"})
	if e != nil || peer.CPUms != 0 || peer.JournalCommits != 0 || peer.JournalPendingTiming != nil {
		t.Fatal("private observations leaked through peer stats", e)
	}
	peerJSON, e := json.Marshal(peer)
	if e != nil || bytes.Contains(peerJSON, []byte("ProcessCPUms")) || bytes.Contains(peerJSON, []byte("Database")) || bytes.Contains(peerJSON, []byte("CheckpointPlaintextBytes")) {
		t.Fatal("private operation CPU leaked through peer stats", e)
	}
	input, _ := json.Marshal(localIPCRequest{ID: 1, Diagnostics: true})
	var output bytes.Buffer
	servePrivateStream(n, bytes.NewReader(append(input, '\n')), &output)
	var response localIPCResponse
	if e := json.Unmarshal(output.Bytes(), &response); e != nil || response.ID != 1 || response.Diagnostics == nil || !bytes.Contains(output.Bytes(), []byte("ProcessCPUms")) || !bytes.Contains(output.Bytes(), []byte("DatabaseWriteMs")) {
		t.Fatal("private diagnostics pipe failed", e)
	}
	if bytes.Contains(output.Bytes(), secret) || n.journal.commits != before || len(n.localOperations) != len(first.Operations) {
		t.Fatal("diagnostic read exposed payload or changed persistent state/operation history")
	}
	// Fill the bounded ring with requests rejected before storage work. An
	// attacker cannot retain arbitrary operation names or grow local history.
	f.at(1)
	q.Descriptor = descriptorRPC(f.lab.public.reservation(1))
	for range localOperationLimit + 4 {
		_, _ = n.handle(q)
	}
	if len(n.localOperations) != localOperationLimit || n.journal.commits != before {
		t.Fatal("unbounded observations or early/stale rejection forced disk work")
	}
	if first.Operations[len(first.Operations)-1] != last {
		t.Fatal("snapshot aliases mutable history")
	}
	if r, e := n.handle(rpcRequest{Op: "diagnostics"}); e == nil || r.JournalCommits != 0 {
		t.Fatal("private diagnostics accepted over peer RPC")
	}
	if n.localOperations[len(n.localOperations)-1].Operation != "other" {
		t.Fatal("arbitrary request name retained")
	}
	saved, e := n.checkpoint()
	if e != nil || bytes.Contains(saved, []byte("LockWaitMs")) || bytes.Contains(saved, []byte("ProcessCPUms")) || bytes.Contains(saved, []byte("localOperations")) || bytes.Contains(saved, []byte("Database")) || bytes.Contains(saved, []byte("CheckpointPlaintextBytes")) {
		t.Fatal("volatile measurements entered durable protocol state", e)
	}
}

func TestPrivateDiagnosticsRejectAmbiguousOrUnknownCommands(t *testing.T) {
	f := newScheduledFixture(t)
	n := f.nodes[0]
	for _, command := range []string{
		`{"ID":0,"Diagnostics":true}`,
		`{"ID":1}`,
		`{"ID":1,"Diagnostics":true,"StatusSequence":1}`,
		`{"ID":1,"Diagnostics":true,"Enqueue":{"Sequence":1,"Payload":"YQ=="}}`,
		`{"ID":1,"Diagnostics":true,"Unknown":true}`,
		`{"ID":1,"Diagnostics":true} {}`,
	} {
		var output bytes.Buffer
		before := n.journal.commits
		servePrivateStream(n, bytes.NewBufferString(command+"\n"), &output)
		if output.Len() != 0 || n.journal.commits != before {
			t.Fatal("invalid local command accepted", command)
		}
	}
}
