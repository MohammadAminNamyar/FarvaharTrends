package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestAtomicPublicationRequiresDurableOrdinaryConfig(t *testing.T) {
	for _, fault := range []bool{false, true} {
		c := configFor(newFixture(), "client", 0)
		c.AtomicPublication, c.Durable, c.AllowFaultInjection = true, fault, fault
		if _, e := newRoleNode(c); e == nil {
			t.Fatal("unsafe publication storage configuration accepted")
		}
		b, _ := json.Marshal(roleCheckpoint{Version: 1, Config: c})
		if _, e := restoreRole(b); e == nil {
			t.Fatal("unsafe saved publication configuration accepted")
		}
	}
}

func TestAtomicPublicationUsesOneCommitAndPreservesWholeRound(t *testing.T) {
	f := newScheduledFixtureStorage(t, true)
	f.lab.localOutboxes, f.lab.fuseReservationPrepare = true, true
	payloads := map[int][]byte{}
	for i := range clients {
		payloads[i] = []byte("خبر فارسی آزمایشی؛ هر پاسخ باید پس از ثبت پایدار منتشر شود")
		before := f.nodes[i].journal.commits
		if _, e := f.nodes[i].enqueueLocal(localSubmission{1, payloads[i]}); e != nil {
			t.Fatal(e)
		}
		if f.nodes[i].journal.commits-before != 2 {
			t.Fatal("local enqueue lost its intent/eligibility recovery record")
		}
	}
	calls := map[string]int{}
	f.lab.componentCall = func(id int, q rpcRequest) (rpcResponse, error) {
		n := f.nodes[id]
		before := n.journal.commits
		r, e := n.handle(q)
		if e != nil {
			return r, e
		}
		calls[q.Op]++
		if n.journal.commits-before != 1 || n.journal.db.NoSync || n.journal.db.NoGrowSync {
			t.Fatal("publication did not use exactly one synchronized transaction", q.Op)
		}
		if pending, e := n.journal.load("pending"); e != nil || pending != nil {
			t.Fatal("publication left a stale intent", e)
		}
		again, e := n.handle(q)
		if e != nil || !bytes.Equal(encodeSetup(r), encodeSetup(again)) || n.journal.commits-before != 1 {
			t.Fatal("exact retry changed response or repeated storage work", q.Op, e)
		}
		return r, nil
	}
	f.at(0)
	if out := f.cycle(t, 0); !samePayloadMultiset(out, payloads) {
		t.Fatal("atomic round lost or changed news")
	}
	for _, op := range []string{"prepare", "accept-and-prepare", "accept", "commit", "release", "finish"} {
		if calls[op] == 0 {
			t.Fatal("unexercised publication operation", op)
		}
	}
	for i := range clients {
		r, e := f.nodes[i].localStatus(1)
		if e != nil || r.Status != "released" {
			t.Fatal("missing certified private receipt", e)
		}
	}
	f.at(1)
	if out := f.cycle(t, 1); len(out.messages) != 0 {
		t.Fatal("idle round repeated a publication")
	}
}

func TestAtomicPublicationKeepsIntentForSetupScheduleAndControl(t *testing.T) {
	f := newScheduledFixtureStorage(t, true)
	n := f.nodes[0]
	for _, op := range []string{"setup-hello", "control-unknown", "unknown", "prepare-corrupt"} {
		begins, before := 0, n.journal.commits
		n.journal.afterBegin = func() { begins++ }
		_, _ = n.handle(rpcRequest{Op: op})
		if begins != 1 || n.journal.commits-before != 2 {
			t.Fatal("non-publication operation bypassed recovery intent", op)
		}
	}
	n.journal.afterBegin = nil
	// The installation itself must also retain the original write-ahead path.
	n.cache = nil
	before := n.journal.commits
	if _, e := n.handle(rpcRequest{Op: "schedule-install", ScheduleCertificate: &f.certificate}); e != nil || n.journal.commits-before != 2 {
		t.Fatal("schedule admission lost its recovery intent", e)
	}
}

func TestAtomicPublicationRetainsCutoffCertificateAndCommitFailureFences(t *testing.T) {
	for _, scenario := range []string{"late", "bad-certificate", "write-failure", "committed-restart"} {
		t.Run(scenario, func(t *testing.T) {
			f, q := heldReservationStorage(t, true)
			n := f.nodes[0]
			before := n.journal.commits
			switch scenario {
			case "late":
				f.elapsed += 2 * time.Second
			case "bad-certificate":
				q.Signatures[0][0] ^= 1
			case "write-failure":
				n.journal.afterExecute = func() { _ = n.journal.db.Close() }
			}
			r, e := n.handle(q)
			if scenario != "committed-restart" {
				if e == nil || r.Input != nil {
					t.Fatal("unsafe contribution escaped", e)
				}
				if scenario == "late" && n.journal.commits != before {
					t.Fatal("late request forced disk work")
				}
			} else if e != nil || r.Input == nil {
				t.Fatal("valid preparation failed", e)
			}
			if scenario == "write-failure" {
				if again, e := n.handle(q); e == nil || again.Input != nil || !n.journal.poisoned {
					t.Fatal("uncommitted cache escaped storage-failure fence")
				}
			}
			if scenario == "write-failure" || scenario == "committed-restart" {
				if e = n.journal.close(); e != nil {
					t.Fatal(e)
				}
				n, e = openDurableRole(f.configs[0], f.dirs[0])
				if e != nil {
					t.Fatal(e)
				}
				f.nodes[0] = n
				again, e := n.handle(q)
				if scenario == "committed-restart" {
					if e != nil || !bytes.Equal(encodeSetup(r), encodeSetup(again)) {
						t.Fatal("committed contribution changed after restart", e)
					}
				} else if e == nil || again.Input != nil {
					t.Fatal("restart released uncommitted scheduled contribution")
				}
				if n.scheduleClock != nil || len(n.outbox.Pending) != 1 || len(n.outbox.Released) != 0 {
					t.Fatal("restart re-armed clock or lost queued news")
				}
				if _, e = n.enqueueLocal(localSubmission{2, []byte("خبر پس از راه‌اندازی دوباره")}); e == nil {
					t.Fatal("fresh publication admitted after clock-anchor loss")
				}
			}
		})
	}
}

// Abrupt child exits exercise the same transaction boundary for every bulk
// operation, including removal of a queued publication after certified accept.
// This is process-crash evidence, not a simulated physical power-loss test.
func TestAtomicPublicationCrashesBeforeAndAfterCommitForEveryBulkOperation(t *testing.T) {
	for _, op := range []string{"prepare", "commit", "release", "finish", "accept"} {
		for _, stage := range []string{"execute", "commit"} {
			t.Run(op+"/"+stage, func(t *testing.T) {
				f := newOutboxFixtureStorage(t, false, true)
				payload := []byte("خبر فارسی برای آزمون توقف واقعی فرایند هنگام ثبت")
				if _, e := f.nodes[0].enqueueLocal(localSubmission{1, payload}); e != nil {
					t.Fatal(e)
				}
				target := 0
				if op == "commit" || op == "release" || op == "finish" {
					target = clients
				}
				injected := false
				call := f.lab.componentCall
				f.lab.componentCall = func(id int, q rpcRequest) (rpcResponse, error) {
					if injected || id != target || q.Op != op || q.Descriptor.Phase != 1 {
						return call(id, q)
					}
					injected = true
					n := f.nodes[id]
					prior, e := n.checkpoint()
					if e != nil {
						t.Fatal(e)
					}
					root := t.TempDir()
					if e = saveJSON(filepath.Join(root, "config.json"), f.configs[id]); e != nil {
						t.Fatal(e)
					}
					if e = saveJSON(filepath.Join(root, "request.json"), q); e != nil {
						t.Fatal(e)
					}
					if e = n.journal.close(); e != nil {
						t.Fatal(e)
					}
					cmd := exec.Command(os.Args[0], "-test.run=^TestJournalCrashWorker$")
					cmd.Env = append(os.Environ(), "FT_JOURNAL_CRASH_TEST="+root, "FT_JOURNAL_CRASH_STAGE="+stage, "FT_JOURNAL_CRASH_STATE="+f.dirs[id])
					output, e := cmd.CombinedOutput()
					if e == nil || cmd.ProcessState == nil || cmd.ProcessState.ExitCode() != 93 {
						t.Fatalf("atomic crash worker: %v %s", e, output)
					}
					n, e = openDurableRole(f.configs[id], f.dirs[id])
					if e != nil {
						t.Fatal(e)
					}
					f.nodes[id] = n
					if pending, e := n.journal.load("pending"); e != nil || pending != nil {
						t.Fatal("atomic operation left a replayable intent", e)
					}
					if stage == "execute" {
						restored, e := n.checkpoint()
						if e != nil || !bytes.Equal(prior, restored) {
							t.Fatal("pre-commit crash changed acknowledged state", e)
						}
					}
					r, e := n.handle(q)
					if e != nil {
						t.Fatal(e)
					}
					if stage == "commit" {
						b, e := os.ReadFile(filepath.Join(root, "committed-response.json"))
						var saved rpcResponse
						if e != nil || json.Unmarshal(b, &saved) != nil || !bytes.Equal(encodeSetup(saved), encodeSetup(r)) {
							t.Fatal("committed reply regenerated after process exit", e)
						}
					}
					before := n.journal.commits
					again, e := n.handle(q)
					if e != nil || !bytes.Equal(encodeSetup(again), encodeSetup(r)) || n.journal.commits != before {
						t.Fatal("recovered retry repeated or changed the transition", e)
					}
					return r, nil
				}
				out := f.cycle(t, 0)
				if !injected || !samePayloadMultiset(out, map[int][]byte{0: payload}) {
					t.Fatal("recovered round lost or duplicated publication")
				}
				if r, e := f.nodes[0].localStatus(1); e != nil || r.Status != "released" {
					t.Fatal("recovered round lost certified receipt", e)
				}
			})
		}
	}
}
