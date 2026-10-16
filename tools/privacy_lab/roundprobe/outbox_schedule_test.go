package main

import (
	"context"
	"encoding/json"
	"testing"
	"time"
)

func TestOutboxScheduleUsesClockWithoutSubmissionAndRetainsQueueOnMiss(t *testing.T) {
	f := newOutboxFixture(t)
	f.lab.localOutboxes = true
	ctx, cancel := context.WithCancel(context.Background())
	ticks := make(chan time.Time, 1)
	frames := make(chan outboxRelease, 1)
	done := make(chan struct{})
	go func() { defer close(done); runOutboxSchedule(ctx, f.lab, ticks, time.Minute, frames) }()
	defer func() { cancel(); <-done }()
	next := func() outboxRelease {
		t.Helper()
		select {
		case r := <-frames:
			return r
		case <-time.After(10 * time.Second):
			for id, n := range f.nodes {
				// Failure-only local observations; keep the watchdog unchanged.
				t.Logf("role %d private operation timings: %+v", id, n.privateDiagnostics().Operations)
			}
			t.Fatal("scheduled cycle stalled")
			return outboxRelease{}
		}
	}
	ticks <- time.Now()
	idle := next()
	if idle.err != nil || idle.round != 0 || idle.idleRounds != 1 || len(idle.bulk.messages) != 0 {
		t.Fatal("idle clock did not run cover reservation", idle.err)
	}
	q := localSubmission{1, []byte("ارسال باید منتظر ساعت مستقل از خبر بماند")}
	if _, e := f.nodes[0].enqueueLocal(q); e != nil {
		t.Fatal(e)
	}
	select {
	case <-frames:
		t.Fatal("enqueue advanced the schedule")
	default:
	}
	ticks <- time.Now()
	active := next()
	if active.err != nil || active.round != 1 || !samePayloadMultiset(active.bulk, map[int][]byte{0: q.Payload}) {
		t.Fatal("clock did not release private queued news", active.err)
	}
	if _, e := f.nodes[0].enqueueLocal(localSubmission{2, []byte("قطع مسیر نباید خبر را مستقیم منتشر کند")}); e != nil {
		t.Fatal(e)
	}
	ticks <- time.Now().Add(-2 * time.Minute)
	missed := next()
	if missed.err == nil {
		t.Fatal("missed clock accepted")
	}
	if missed.round != 2 || missed.started.IsZero() || missed.finished.Before(missed.started) {
		t.Fatal("deadline failure lost its round/timing diagnostics")
	}
	<-done
	r, e := f.nodes[0].localStatus(2)
	if e != nil || r.Status != "queued" {
		t.Fatal("deadline failure lost queue", e)
	}
}

func TestOutboxRestoreRejectsInconsistentPhaseAndReceipt(t *testing.T) {
	f := newOutboxFixture(t)
	n := f.nodes[0]
	if _, e := n.enqueueLocal(localSubmission{1, []byte("خبر در صف محلی")}); e != nil {
		t.Fatal(e)
	}
	check := func(change func(*roleCheckpoint)) {
		t.Helper()
		b, e := n.checkpoint()
		if e != nil {
			t.Fatal(e)
		}
		if _, e = restoreRole(b); e != nil {
			t.Fatal("valid checkpoint rejected", e)
		}
		var x roleCheckpoint
		if e = json.Unmarshal(b, &x); e != nil {
			t.Fatal(e)
		}
		change(&x)
		bad, e := json.Marshal(x)
		if e != nil {
			t.Fatal(e)
		}
		_, e = restoreRole(bad)
		requireReject(t, e)
	}
	check(func(x *roleCheckpoint) { x.Outbox.SelectionMade = true; x.Outbox.Pinned = 1 })
	r, e := f.lab.run(f.lab.public.reservation(0), nil)
	if e != nil {
		t.Fatal(e)
	}
	check(func(x *roleCheckpoint) { x.Outbox.SelectionRound++ })
	check(func(x *roleCheckpoint) { x.Outbox.SelectionMade = false; x.Outbox.Pinned = 0 })
	// Move only this client into prepared bulk state, then check that the saved
	// ciphertext and consumed-phase counter must refer to that same round.
	if _, e = n.handle(rpcRequest{Op: "prepare", Descriptor: descriptorRPC(f.lab.public.bulk(0, r, maxCell))}); e != nil {
		t.Fatal(e)
	}
	check(func(x *roleCheckpoint) { x.Prepared = nil })
	check(func(x *roleCheckpoint) { x.Prepared.Signature[0] ^= 1 })
	if _, e = f.lab.run(f.lab.public.bulk(0, r, maxCell), nil); e != nil {
		t.Fatal(e)
	}
	check(func(x *roleCheckpoint) { x.Outbox.Released[0].Epoch[0] ^= 1 })
	check(func(x *roleCheckpoint) { x.Outbox.Released[0].PhaseSequence = 3 })
}
