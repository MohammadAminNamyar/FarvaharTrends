package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	bolt "go.etcd.io/bbolt"
)

func TestJournalLockWorker(t *testing.T) {
	dir := os.Getenv("FT_JOURNAL_LOCK_TEST")
	if dir == "" {
		return
	}
	b, e := os.ReadFile(filepath.Join(dir, "config.json"))
	if e != nil {
		t.Fatal(e)
	}
	var c nodeConfig
	if e = json.Unmarshal(b, &c); e != nil {
		t.Fatal(e)
	}
	n, e := openDurableRole(c, filepath.Join(dir, "state"))
	if e != nil {
		os.Exit(94)
	}
	if e = n.journal.close(); e != nil {
		t.Fatal(e)
	}
}

func TestJournalRejectsIndependentProcessAndReopensAfterClose(t *testing.T) {
	dir := t.TempDir()
	c := configFor(newFixture(), "client", 0)
	if e := saveJSON(filepath.Join(dir, "config.json"), c); e != nil {
		t.Fatal(e)
	}
	n, e := openDurableRole(c, filepath.Join(dir, "state"))
	if e != nil {
		t.Fatal(e)
	}
	defer n.journal.close()
	for _, whileOpen := range []bool{true, false} {
		if !whileOpen {
			if e = n.journal.close(); e != nil {
				t.Fatal(e)
			}
		}
		cmd := exec.Command(os.Args[0], "-test.run=^TestJournalLockWorker$")
		cmd.Env = append(os.Environ(), "FT_JOURNAL_LOCK_TEST="+dir)
		output, runErr := cmd.CombinedOutput()
		wantExit := 0
		if whileOpen {
			wantExit = 94
		}
		if cmd.ProcessState == nil || cmd.ProcessState.ExitCode() != wantExit {
			t.Fatalf("second process whileOpen=%t: %v %s", whileOpen, runErr, output)
		}
	}
}

// A real child process exits without running defers or closing the database.
func TestJournalCrashWorker(t *testing.T) {
	dir := os.Getenv("FT_JOURNAL_CRASH_TEST")
	if dir == "" {
		return
	}
	b, e := os.ReadFile(filepath.Join(dir, "config.json"))
	if e != nil {
		t.Fatal(e)
	}
	var c nodeConfig
	if e = json.Unmarshal(b, &c); e != nil {
		t.Fatal(e)
	}
	b, e = os.ReadFile(filepath.Join(dir, "request.json"))
	if e != nil {
		t.Fatal(e)
	}
	var q rpcRequest
	if e = json.Unmarshal(b, &q); e != nil {
		t.Fatal(e)
	}
	stateDir := os.Getenv("FT_JOURNAL_CRASH_STATE")
	if stateDir == "" {
		stateDir = filepath.Join(dir, "state")
	}
	n, e := openDurableRole(c, stateDir)
	if e != nil {
		t.Fatal(e)
	}
	crash := func() { os.Exit(93) }
	switch os.Getenv("FT_JOURNAL_CRASH_STAGE") {
	case "begin":
		n.journal.afterBegin = crash
	case "execute":
		n.journal.afterExecute = crash
	case "commit":
		n.journal.afterCommit = func() {
			if e := saveJSON(filepath.Join(dir, "committed-response.json"), n.cache[len(n.cache)-1].response); e != nil {
				panic(e)
			}
			crash()
		}
	default:
		t.Fatal("unknown crash stage")
	}
	_, _ = n.handle(q)
	t.Fatal("worker did not crash")
}

func TestJournalRecoversAcrossActualProcessExitAtEveryCommitBoundary(t *testing.T) {
	for _, stage := range []string{"begin", "execute", "commit"} {
		t.Run(stage, func(t *testing.T) {
			dir := t.TempDir()
			f := newFixtureWithLimit(clients)
			c := configFor(f, "client", 0)
			c.Durable = true
			q := rpcRequest{Op: "prepare", Descriptor: descriptorRPC(f.reservation(0)), Payload: []byte{1}}
			if e := saveJSON(filepath.Join(dir, "config.json"), c); e != nil {
				t.Fatal(e)
			}
			if e := saveJSON(filepath.Join(dir, "request.json"), q); e != nil {
				t.Fatal(e)
			}
			cmd := exec.Command(os.Args[0], "-test.run=^TestJournalCrashWorker$")
			cmd.Env = append(os.Environ(), "FT_JOURNAL_CRASH_TEST="+dir, "FT_JOURNAL_CRASH_STAGE="+stage)
			output, e := cmd.CombinedOutput()
			if e == nil || cmd.ProcessState == nil || cmd.ProcessState.ExitCode() != 93 {
				t.Fatalf("crash worker: %v %s", e, output)
			}
			n, e := openDurableRole(c, filepath.Join(dir, "state"))
			if e != nil {
				t.Fatal(e)
			}
			defer n.journal.close()
			r, e := n.handle(q)
			if e != nil || r.Input == nil {
				t.Fatal("recovered response", e)
			}
			if n.state.clientNext[0] != 1 {
				t.Fatal("round advanced more than once")
			}
			if stage == "commit" {
				b, e := os.ReadFile(filepath.Join(dir, "committed-response.json"))
				if e != nil {
					t.Fatal(e)
				}
				var original rpcResponse
				if e = json.Unmarshal(b, &original); e != nil {
					t.Fatal(e)
				}
				if !bytes.Equal(encodeSetup(original), encodeSetup(r)) {
					t.Fatal("emitted ciphertext regenerated after restart")
				}
			}
			q.Payload = []byte{0}
			_, e = n.handle(q)
			requireReject(t, e)
			if pending, e := n.journal.load("pending"); e != nil || pending != nil {
				t.Fatal("pending operation not committed", e)
			}
		})
	}
}

func TestJournalWriteFailureFencesEvenCachedResponses(t *testing.T) {
	f := newFixture()
	c := configFor(f, "client", 0)
	n, e := openDurableRole(c, filepath.Join(t.TempDir(), "state"))
	if e != nil {
		t.Fatal(e)
	}
	n.journal.afterExecute = func() { _ = n.journal.db.Close() }
	defer n.journal.close()
	q := rpcRequest{Op: "prepare", Descriptor: descriptorRPC(f.reservation(0)), Payload: []byte{1}}
	r, e := n.handle(q)
	requireReject(t, e)
	if r.Input != nil || !n.journal.poisoned || len(n.cache) == 0 {
		t.Fatal("bad failure fence")
	}
	r, e = n.handle(q)
	requireReject(t, e)
	if r.Input != nil {
		t.Fatal("uncommitted cached response escaped")
	}
}

func TestJournalRejectsParallelOpenWrongKeyChangedConfigMissingAndTamperedState(t *testing.T) {
	f := newFixture()
	c := configFor(f, "client", 0)
	for _, mode := range []string{"parallel", "wrong-key", "changed-config", "missing-state", "tamper", "interrupted-budget"} {
		t.Run(mode, func(t *testing.T) {
			dir := filepath.Join(t.TempDir(), "state")
			n, e := openDurableRole(c, dir)
			if e != nil {
				t.Fatal(e)
			}
			if mode == "parallel" {
				second, openErr := openDurableRole(c, dir)
				if second != nil {
					_ = second.journal.close()
				}
				e = openErr
				defer n.journal.close()
				requireReject(t, e)
				return
			}
			if mode == "tamper" {
				e = n.journal.db.Update(func(tx *bolt.Tx) error {
					bucket := tx.Bucket(journalBucket)
					b := bytes.Clone(bucket.Get([]byte("state")))
					b[len(b)-1] ^= 1
					return bucket.Put([]byte("state"), b)
				})
				if e != nil {
					t.Fatal(e)
				}
			}
			if mode == "interrupted-budget" {
				if e = n.journal.savePending(pendingOperation{Request: rpcRequest{Op: "prepare", Descriptor: descriptorRPC(f.reservation(0))}, Attempts: maxInterruptedAttempts}); e != nil {
					t.Fatal(e)
				}
			}
			_ = n.journal.close()
			cc := c
			switch mode {
			case "wrong-key":
				if e = os.WriteFile(filepath.Join(dir, "lab-storage.key"), bytes.Repeat([]byte{22}, 32), 0600); e != nil {
					t.Fatal(e)
				}
			case "changed-config":
				cc.SlotLimit = 1
			case "missing-state":
				if e = os.Remove(filepath.Join(dir, "role.db")); e != nil {
					t.Fatal(e)
				}
			}
			_, e = openDurableRole(cc, dir)
			requireReject(t, e)
		})
	}
}

func TestJournalKeepsPrivateMaterialOutOfDatabasePlaintextAndBoundsDisk(t *testing.T) {
	f := newFixture()
	c := configFor(f, "client", 0)
	dir := filepath.Join(t.TempDir(), "state")
	n, e := openDurableRole(c, dir)
	if e != nil {
		t.Fatal(e)
	}
	if n.journal.db.NoSync || n.journal.db.NoGrowSync {
		t.Fatal("unsafe database synchronization")
	}
	for range 30 {
		_, e := n.handle(rpcRequest{Op: "invalid", Descriptor: descriptorRPC(f.reservation(0))})
		requireReject(t, e)
	}
	_, e = n.journal.seal("state", make([]byte, maxCheckpointBytes+1))
	requireReject(t, e)
	_ = n.journal.close()
	b, e := os.ReadFile(filepath.Join(dir, "role.db"))
	if e != nil {
		t.Fatal(e)
	}
	encoded, _ := json.Marshal(c.Private)
	if bytes.Contains(b, c.Private) || bytes.Contains(b, encoded) || len(b) > maxJournalBytes {
		t.Fatal("private plaintext or unbounded journal")
	}
}

func TestAdapterCheckpointRestoresBothPrivateSetupRoles(t *testing.T) {
	for _, role := range []string{"client", "coordinator"} {
		t.Run(role, func(t *testing.T) {
			c := nodeConfig{AnonymousSetup: true, Role: role, Index: 0, Slot: -1, SlotLimit: clients}
			n, e := newRoleNode(c)
			if e != nil {
				t.Fatal(e)
			}
			first, e := n.handle(rpcRequest{Op: "setup-hello"})
			if e != nil {
				t.Fatal(e)
			}
			b, e := n.checkpoint()
			if e != nil {
				t.Fatal(e)
			}
			restored, e := restoreRole(b)
			if e != nil {
				t.Fatal(e)
			}
			restored.cache = nil // Exercise restored role, not just the response cache.
			again, e := restored.handle(rpcRequest{Op: "setup-hello"})
			if e != nil || !bytes.Equal(encodeSetup(first), encodeSetup(again)) {
				t.Fatal("private role restored incorrectly", e)
			}
		})
	}
}
