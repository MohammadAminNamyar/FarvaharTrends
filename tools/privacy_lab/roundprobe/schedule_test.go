package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"testing"
	"time"
)

type scheduledFixture struct {
	*outboxFixture
	base        clockReading
	elapsed     time.Duration
	jump        time.Duration
	certificate scheduleCertificate
}

func newScheduledFixture(t *testing.T) *scheduledFixture {
	return newScheduledFixtureStorage(t, false)
}
func newScheduledFixtureStorage(t *testing.T, atomicPublication bool) *scheduledFixture {
	return newScheduledFixtureCompletion(t, atomicPublication, false)
}
func newScheduledFixtureCompletion(t *testing.T, atomicPublication, frozen bool) *scheduledFixture {
	t.Helper()
	f := &scheduledFixture{outboxFixture: newOutboxFixtureCompletion(t, true, atomicPublication, frozen), base: clockReading{time.Date(2026, 10, 15, 0, 0, 0, 0, time.UTC).UnixNano(), time.Second}}
	for _, n := range f.nodes {
		n.localNow = func() clockReading {
			return clockReading{f.base.wall + int64(f.elapsed+f.jump), f.base.mono + f.elapsed}
		}
	}
	p := reservationSchedule{Epoch: f.lab.public.epoch, StartUnixNano: f.base.wall + int64(4*time.Second), PeriodNano: int64(schedulePeriod), SkewNano: int64(scheduleSkew), Rounds: 10}
	if frozen {
		p.CompletionSlackNano = int64(frozenCompletionSlack)
	}
	f.certificate.Proposal = p
	for i := range coordinators {
		r, e := f.nodes[clients+i].handle(rpcRequest{Op: "schedule-vote", Schedule: &p})
		if e != nil {
			t.Fatal(e)
		}
		f.certificate.Signatures = append(f.certificate.Signatures, r.Signature)
	}
	for _, n := range f.nodes {
		if _, e := n.handle(rpcRequest{Op: "schedule-install", ScheduleCertificate: &f.certificate}); e != nil {
			t.Fatal(e)
		}
	}
	return f
}
func (f *scheduledFixture) at(round uint64) {
	f.elapsed = 4*time.Second + time.Duration(round)*schedulePeriod + 150*time.Millisecond
}

func TestCommonScheduleStopsStaggeredCutoffIsolation(t *testing.T) {
	for target := range clients {
		t.Run(fmt.Sprint(target), func(t *testing.T) {
			f := newScheduledFixture(t)
			f.at(0)
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
				payloads[i] = []byte(fmt.Sprintf("خبر فارسی پس از مرز مشترک؛ عضو %d", i))
				if _, e := f.nodes[i].enqueueLocal(localSubmission{1, payloads[i]}); e != nil {
					t.Fatal(e)
				}
			}
			out := f.cycle(t, 0)
			if len(out.messages) != 0 {
				t.Fatal("late prepare selected an identifiable post-cutoff publisher")
			}
			for i := range clients {
				if f.nodes[i].outbox.Pending[0].Eligibility.Round != 1 {
					t.Fatal("RPC arrival changed eligibility")
				}
			}
			f.at(1)
			out = f.cycle(t, 1)
			if !samePayloadMultiset(out, payloads) {
				t.Fatal("next common round omitted queued news")
			}
		})
	}
}

func TestScheduleSignaturesEquivocationAndRestartFence(t *testing.T) {
	f := newScheduledFixture(t)
	other := f.certificate.Proposal
	other.StartUnixNano += int64(time.Second)
	for i := range coordinators {
		_, e := f.nodes[clients+i].handle(rpcRequest{Op: "schedule-vote", Schedule: &other})
		requireReject(t, e)
	}
	for _, change := range []func(*scheduleCertificate){
		func(c *scheduleCertificate) { c.Proposal.StartUnixNano++ },
		func(c *scheduleCertificate) { c.Proposal.Epoch[0] ^= 1 },
		func(c *scheduleCertificate) { c.Proposal.SkewNano++ },
		func(c *scheduleCertificate) { c.Signatures = c.Signatures[:2] },
		func(c *scheduleCertificate) { c.Signatures[1] = c.Signatures[0] },
	} {
		c := jsonCopy(f.certificate)
		change(&c)
		_, e := f.nodes[0].handle(rpcRequest{Op: "schedule-install", ScheduleCertificate: &c})
		requireReject(t, e)
	}
	n := f.nodes[0]
	q := localSubmission{1, []byte("خبر پس از راه‌اندازی دوباره نباید بی‌اجازه منتشر شود")}
	if _, e := n.enqueueLocal(q); e != nil {
		t.Fatal(e)
	}
	f.at(0)
	d := descriptorRPC(f.lab.public.reservation(0))
	first, e := n.handle(rpcRequest{Op: "prepare", Descriptor: d})
	if e != nil {
		t.Fatal(e)
	}
	if e = n.journal.close(); e != nil {
		t.Fatal(e)
	}
	n, e = openDurableRole(f.configs[0], f.dirs[0])
	if e != nil {
		t.Fatal(e)
	}
	f.nodes[0] = n
	// Cached replies are exact, but neither certificate replay nor local retry
	// creates a new monotonic anchor after a process restart.
	again, e := n.handle(rpcRequest{Op: "prepare", Descriptor: d})
	if e != nil || !bytes.Equal(encodeSetup(first), encodeSetup(again)) {
		t.Fatal("lost exact cached contribution", e)
	}
	_, e = n.handle(rpcRequest{Op: "schedule-install", ScheduleCertificate: &f.certificate})
	if e != nil {
		t.Fatal(e)
	}
	if n.scheduleClock != nil {
		t.Fatal("certificate replay re-armed restarted clock")
	}
	r, e := n.enqueueLocal(q)
	if e != nil || r.Status != "queued" {
		t.Fatal("lost idempotent local receipt", e)
	}
	_, e = n.enqueueLocal(localSubmission{2, []byte("خبر تازه")})
	requireReject(t, e)
	if n.outbox.Next != 2 {
		t.Fatal("clock rejection consumed sequence")
	}
}

func TestScheduleLocalWindowsClockDiscontinuityAndFrozenPendingEnqueue(t *testing.T) {
	t.Run("windows", func(t *testing.T) {
		f := newScheduledFixture(t)
		n := f.nodes[0]
		if _, e := n.enqueueLocal(localSubmission{1, []byte("خبر پیش از مرز زمانی")}); e != nil {
			t.Fatal(e)
		}
		q := rpcRequest{Op: "prepare", Descriptor: descriptorRPC(f.lab.public.reservation(0))}
		commits := n.journal.commits
		_, e := n.handle(q)
		requireReject(t, e)
		if n.journal.commits != commits {
			t.Fatal("early RPC forced journal writes")
		}
		if n.outbox.SelectionMade || n.state.clientNext[0] != 0 {
			t.Fatal("early request consumed selection")
		}
		f.elapsed = 4*time.Second + scheduleSkew - time.Nanosecond
		_, e = n.handle(q)
		requireReject(t, e)
		f.at(0)
		if _, e = n.handle(q); e != nil {
			t.Fatal(e)
		}
	})
	t.Run("late", func(t *testing.T) {
		f := newScheduledFixture(t)
		f.at(1)
		_, e := f.nodes[0].handle(rpcRequest{Op: "prepare", Descriptor: descriptorRPC(f.lab.public.reservation(0))})
		requireReject(t, e)
		if f.nodes[0].outbox.SelectionMade {
			t.Fatal("late request selected news")
		}
	})
	t.Run("clock jump stays fenced", func(t *testing.T) {
		f := newScheduledFixture(t)
		f.at(0)
		f.jump = time.Second
		_, e := f.nodes[0].localEligibility()
		requireReject(t, e)
		f.jump = 0
		_, e = f.nodes[0].localEligibility()
		requireReject(t, e)
	})
	t.Run("pending enqueue retains its cutoff after restart", func(t *testing.T) {
		f := newScheduledFixture(t)
		n := f.nodes[0]
		q := localSubmission{1, []byte("زمان پذیرش صف باید پس از قطع فرایند هم حفظ شود")}
		eligibility, e := n.localEligibility()
		if e != nil {
			t.Fatal(e)
		}
		if e = n.journal.savePending(pendingOperation{Local: &q, Eligibility: eligibility, Attempts: 1}); e != nil {
			t.Fatal(e)
		}
		if e = n.journal.close(); e != nil {
			t.Fatal(e)
		}
		n, e = openDurableRole(f.configs[0], f.dirs[0])
		if e != nil {
			t.Fatal(e)
		}
		f.nodes[0] = n
		if len(n.outbox.Pending) != 1 || *n.outbox.Pending[0].Eligibility != *eligibility || n.scheduleClock != nil {
			t.Fatal("pending enqueue was re-timed on restart")
		}
		if _, e = n.localStatus(1); e != nil {
			t.Fatal(e)
		}
	})
}

func TestScheduleRestoreRejectsChangedCertificateOrEligibility(t *testing.T) {
	f := newScheduledFixture(t)
	n := f.nodes[0]
	if _, e := n.enqueueLocal(localSubmission{1, []byte("آزمایش وضعیت ذخیره‌شده")}); e != nil {
		t.Fatal(e)
	}
	for _, change := range []func(*roleCheckpoint){
		func(c *roleCheckpoint) { c.Schedule.Certificate.Proposal.StartUnixNano++ },
		func(c *roleCheckpoint) { c.Outbox.Pending[0].Eligibility = nil },
		func(c *roleCheckpoint) { c.Outbox.Pending[0].Eligibility.Round = scheduleMaxRounds },
		func(c *roleCheckpoint) { c.Outbox.Pending[0].Eligibility.ScheduleHash[0] ^= 1 },
		func(c *roleCheckpoint) { c.Schedule = nil },
	} {
		raw, e := n.checkpoint()
		if e != nil {
			t.Fatal(e)
		}
		var c roleCheckpoint
		if e = json.Unmarshal(raw, &c); e != nil {
			t.Fatal(e)
		}
		change(&c)
		raw, e = json.Marshal(c)
		if e != nil {
			t.Fatal(e)
		}
		_, e = restoreRole(raw)
		requireReject(t, e)
	}
}

func TestScheduleFirstCoverAlsoRequiresCertificateOnRestore(t *testing.T) {
	f := newScheduledFixture(t)
	f.at(0)
	n := f.nodes[0]
	if _, e := n.handle(rpcRequest{Op: "prepare", Descriptor: descriptorRPC(f.lab.public.reservation(0))}); e != nil {
		t.Fatal(e)
	}
	raw, e := n.checkpoint()
	if e != nil {
		t.Fatal(e)
	}
	var c roleCheckpoint
	if e = json.Unmarshal(raw, &c); e != nil {
		t.Fatal(e)
	}
	c.Schedule = nil
	raw, e = json.Marshal(c)
	if e != nil {
		t.Fatal(e)
	}
	_, e = restoreRole(raw)
	requireReject(t, e)
}
