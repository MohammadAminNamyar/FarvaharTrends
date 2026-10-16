package main

import (
	"bytes"
	"errors"
	"fmt"
	"testing"
	"time"
)

func TestFusedRoundUsesOneDurableTransitionAndNoExtraPrepareRPC(t *testing.T) {
	f := newScheduledFixture(t)
	f.lab.localOutboxes, f.lab.fuseReservationPrepare = true, true
	payloads := map[int][]byte{}
	before := make([]uint64, clients)
	for i := range clients {
		payloads[i] = []byte(fmt.Sprintf("خبر فارسی بلند از عضو %d؛ انتقال فقط از مجموعه امضاشده و ثابت", i))
		if _, e := f.nodes[i].enqueueLocal(localSubmission{1, payloads[i]}); e != nil {
			t.Fatal(e)
		}
		before[i] = f.nodes[i].journal.commits
	}
	prepareRPCs, fusedRPCs := 0, 0
	call := f.lab.componentCall
	f.lab.componentCall = func(id int, q rpcRequest) (rpcResponse, error) {
		if q.Op == "prepare" {
			prepareRPCs++
		}
		if q.Op == "accept-and-prepare" {
			fusedRPCs++
		}
		return call(id, q)
	}
	f.at(0)
	out := f.cycle(t, 0)
	if !samePayloadMultiset(out, payloads) || prepareRPCs != clients || fusedRPCs != clients {
		t.Fatal("wrong outputs or an extra bulk preparation round trip", prepareRPCs, fusedRPCs)
	}
	for i := range clients {
		if f.nodes[i].journal.commits-before[i] != 6 {
			t.Fatal("three operations must each synchronize pending and committed state")
		}
		r, e := f.nodes[i].localStatus(1)
		if e != nil || r.Status != "released" {
			t.Fatal("missing certified receipt", e)
		}
	}
	if len(f.lab.fusedInputs) != 0 {
		t.Fatal("completed bulk kept stale contributions")
	}
	f.at(1)
	idle := f.cycle(t, 1)
	if len(idle.messages) != 0 || len(f.lab.fusedInputs) != 0 {
		t.Fatal("idle cycle fabricated a bulk publication")
	}
}

func TestFusedAlteredBulkContributionCannotReleaseQueuedNews(t *testing.T) {
	f := newScheduledFixture(t)
	f.lab.localOutboxes, f.lab.fuseReservationPrepare = true, true
	if _, e := f.nodes[0].enqueueLocal(localSubmission{1, []byte("خبر صف باید پس از دستکاری محفوظ بماند")}); e != nil {
		t.Fatal(e)
	}
	f.at(0)
	r, e := f.lab.run(f.lab.public.reservation(0), nil)
	if e != nil {
		t.Fatal(e)
	}
	f.lab.fusedInputs[2].Body[0] ^= 1
	out, e := f.lab.run(f.lab.public.bulk(0, r, maxCell), nil)
	if e == nil || len(out.messages) != 0 {
		t.Fatal("altered prefetched input escaped coordinator verification")
	}
	status, e := f.nodes[0].localStatus(1)
	if e != nil || status.Status != "queued" {
		t.Fatal("altered bulk marked the private publication released", e)
	}
}

func TestFusedActiveRoundDoesNotPullInLateNews(t *testing.T) {
	for _, lateClient := range []int{0, 1} {
		t.Run(fmt.Sprint(lateClient), func(t *testing.T) {
			f := newScheduledFixture(t)
			f.lab.localOutboxes, f.lab.fuseReservationPrepare = true, true
			early := []byte("خبر پیش از مرز مشترک باید همین دور منتشر شود")
			late := []byte("خبر هنگام پذیرش رزرو باید تا دور بعد در صف بماند")
			if _, e := f.nodes[0].enqueueLocal(localSubmission{1, early}); e != nil {
				t.Fatal(e)
			}
			sequence := uint64(1)
			if lateClient == 0 {
				sequence = 2
			}
			injected := false
			call := f.lab.componentCall
			f.lab.componentCall = func(id int, q rpcRequest) (rpcResponse, error) {
				if q.Op == "accept-and-prepare" && !injected {
					injected = true
					if _, e := f.nodes[lateClient].enqueueLocal(localSubmission{sequence, late}); e != nil {
						t.Fatal(e)
					}
				}
				return call(id, q)
			}
			f.at(0)
			if out := f.cycle(t, 0); !injected || !samePayloadMultiset(out, map[int][]byte{0: early}) {
				t.Fatal("active bulk included news arriving after the certified cutoff")
			}
			status, e := f.nodes[lateClient].localStatus(sequence)
			if e != nil || status.Status != "queued" {
				t.Fatal("late news was acknowledged as released", e)
			}
			f.at(1)
			if out := f.cycle(t, 1); !samePayloadMultiset(out, map[int][]byte{lateClient: late}) {
				t.Fatal("next eligible round lost late news or repeated the earlier publication")
			}
		})
	}
}

// Obtain a real three-coordinator certificate while withholding only client 0's
// acceptance. Its reservation is already prepared and pinned. No certificate or
// slot set is fabricated by this helper.
func heldReservation(t *testing.T) (*scheduledFixture, rpcRequest) {
	return heldReservationStorage(t, false)
}
func heldReservationStorage(t *testing.T, atomicPublication bool) (*scheduledFixture, rpcRequest) {
	t.Helper()
	f := newScheduledFixtureStorage(t, atomicPublication)
	if _, e := f.nodes[0].enqueueLocal(localSubmission{1, []byte("خبر باید تا تأیید پایدار محفوظ بماند")}); e != nil {
		t.Fatal(e)
	}
	f.at(0)
	var held rpcRequest
	call := f.lab.componentCall
	f.lab.componentCall = func(id int, q rpcRequest) (rpcResponse, error) {
		if id == 0 && q.Op == "accept" {
			held = jsonCopy(q)
			return rpcResponse{}, errors.New("test withholding client acceptance")
		}
		return call(id, q)
	}
	if _, e := f.lab.run(f.lab.public.reservation(0), nil); e == nil || held.Op != "accept" {
		t.Fatal("did not retain certified reservation")
	}
	held.Op = "accept-and-prepare"
	return f, held
}

func TestFusedRejectsAlteredCertificatesAndUnscheduledInput(t *testing.T) {
	for name, alter := range map[string]func(*rpcRequest){
		"output":         func(q *rpcRequest) { q.Output[0] ^= 1 },
		"signature":      func(q *rpcRequest) { q.Signatures[0][0] ^= 1 },
		"missing signer": func(q *rpcRequest) { q.Signatures = q.Signatures[:2] },
		"root":           func(q *rpcRequest) { q.Root[0] ^= 1 },
		"plaintext":      func(q *rpcRequest) { q.Payload = []byte("injected") },
		"wrong epoch":    func(q *rpcRequest) { q.Descriptor.Epoch[0] ^= 1 },
	} {
		t.Run(name, func(t *testing.T) {
			f, valid := heldReservation(t)
			n := f.nodes[0]
			bad := jsonCopy(valid)
			alter(&bad)
			if r, e := n.handle(bad); e == nil || r.Input != nil {
				t.Fatal("invalid certificate returned a contribution")
			}
			if n.state.clientNext[0] != 1 || n.state.expected.phase != 0 || len(n.outbox.Pending) != 1 {
				t.Fatal("invalid certificate advanced publication")
			}
			if r, e := n.handle(valid); e != nil || r.Input == nil {
				t.Fatal("valid pinned certificate rejected", e)
			}
		})
	}
}

func TestFusedPreservesWindowAndRestartFences(t *testing.T) {
	t.Run("late request never starts disk work", func(t *testing.T) {
		f, q := heldReservation(t)
		n := f.nodes[0]
		before := n.journal.commits
		f.elapsed += 2 * time.Second
		if r, e := n.handle(q); e == nil || r.Input != nil {
			t.Fatal("late fused preparation accepted")
		}
		if n.journal.commits != before || n.state.clientNext[0] != 1 {
			t.Fatal("late request mutated durable phase")
		}
	})
	t.Run("crosses window during journal write", func(t *testing.T) {
		f, q := heldReservation(t)
		n := f.nodes[0]
		n.journal.afterBegin = func() { f.elapsed += 2 * time.Second }
		if r, e := n.handle(q); e == nil || r.Input != nil {
			t.Fatal("missed post-write window accepted")
		}
		if n.state.clientNext[0] != 1 || n.state.expected.phase != 0 {
			t.Fatal("late disk completion advanced selection")
		}
	})
	t.Run("exact cached reply survives restart, no fresh publication", func(t *testing.T) {
		f, q := heldReservation(t)
		n := f.nodes[0]
		first, e := n.handle(q)
		if e != nil || first.Input == nil {
			t.Fatal("fused preparation failed", e)
		}
		if e = n.journal.close(); e != nil {
			t.Fatal(e)
		}
		n, e = openDurableRole(f.configs[0], f.dirs[0])
		if e != nil {
			t.Fatal(e)
		}
		f.nodes[0] = n
		again, e := n.handle(q)
		if e != nil || !bytes.Equal(encodeSetup(first), encodeSetup(again)) {
			t.Fatal("lost exact committed contribution", e)
		}
		if _, e = n.enqueueLocal(localSubmission{2, []byte("خبر جدید")}); e == nil {
			t.Fatal("restart re-armed schedule")
		}
		if n.scheduleClock != nil || len(n.outbox.Pending) != 1 {
			t.Fatal("restart lost queued news or reset its clock")
		}
	})
}

func TestFusedCommitFailureReleasesNoContribution(t *testing.T) {
	f, q := heldReservation(t)
	n := f.nodes[0]
	n.journal.afterExecute = func() { _ = n.journal.db.Close() }
	r, e := n.handle(q)
	if e == nil || r.Input != nil || !n.journal.poisoned {
		t.Fatal("failed durable commit released a contribution")
	}
	if r, e = n.handle(q); e == nil || r.Input != nil {
		t.Fatal("cached result escaped failed commit fence")
	}
	if e = n.journal.close(); e != nil {
		t.Fatal(e)
	}
	n, e = openDurableRole(f.configs[0], f.dirs[0])
	if e != nil {
		t.Fatal(e)
	}
	f.nodes[0] = n
	if r, e = n.handle(q); e == nil || r.Input != nil {
		t.Fatal("recovered uncommitted operation bypassed clock fence")
	}
	if len(n.outbox.Pending) != 1 || len(n.outbox.Released) != 0 {
		t.Fatal("recovery lost private queued news")
	}
}

func TestFusedKeepsCommonCutoffForEveryDelayedClient(t *testing.T) {
	for target := range clients {
		t.Run(fmt.Sprint(target), func(t *testing.T) {
			f := newScheduledFixture(t)
			f.lab.localOutboxes, f.lab.fuseReservationPrepare = true, true
			f.at(0)
			d := descriptorRPC(f.lab.public.reservation(0))
			for i := range clients {
				if i != target {
					if _, e := f.nodes[i].handle(rpcRequest{Op: "prepare", Descriptor: d}); e != nil {
						t.Fatal(e)
					}
				}
			}
			payloads := map[int][]byte{}
			for i := range clients {
				payloads[i] = []byte(fmt.Sprintf("خبر پس از مرز مشترک از عضو %d", i))
				if _, e := f.nodes[i].enqueueLocal(localSubmission{1, payloads[i]}); e != nil {
					t.Fatal(e)
				}
			}
			if r := f.cycle(t, 0); len(r.messages) != 0 {
				t.Fatal("delayed request isolated a post-cutoff sender")
			}
			f.at(1)
			if r := f.cycle(t, 1); !samePayloadMultiset(r, payloads) {
				t.Fatal("next round lost eligible messages")
			}
		})
	}
}
