package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"strings"
	"testing"
	"time"
)

func prepareFrozenTestRound(t *testing.T, f *scheduledFixture, round uint64) []rpcInput {
	t.Helper()
	xs := []rpcInput{}
	for _, n := range f.nodes[:clients] {
		r, e := n.handle(rpcRequest{Op: "prepare", Descriptor: descriptorRPC(f.lab.public.reservation(round))})
		if e != nil {
			t.Fatal(e)
		}
		xs = append(xs, *r.Input)
	}
	return xs
}

func TestFrozenCompletionShorterAdmissionStillRejectsLateVoteAndInstall(t *testing.T) {
	for _, tc := range []struct {
		name                    string
		voteDelay, installDelay time.Duration
		voteOK, installOK       bool
	}{
		{"two-second-lead", 0, 0, true, true},
		{"last-vote-boundary", time.Second, time.Second, true, true},
		{"late-vote", time.Second + time.Nanosecond, 0, false, false},
		{"last-install-boundary", 0, 2*time.Second - scheduleSkew, true, true},
		{"late-install", 0, 2*time.Second - scheduleSkew + time.Nanosecond, true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newOutboxFixtureCompletion(t, true, true, true)
			base := time.Date(2026, 10, 15, 0, 0, 0, 0, time.UTC).UnixNano()
			elapsed := tc.voteDelay
			for _, n := range f.nodes {
				n.localNow = func() clockReading { return clockReading{base + int64(elapsed), time.Second + elapsed} }
			}
			p := reservationSchedule{Epoch: f.lab.public.epoch, StartUnixNano: base + int64(2*time.Second), PeriodNano: int64(schedulePeriod), SkewNano: int64(scheduleSkew), Rounds: 10, CompletionSlackNano: int64(frozenCompletionSlack)}
			c := scheduleCertificate{Proposal: p}
			for i := range coordinators {
				r, e := f.nodes[clients+i].handle(rpcRequest{Op: "schedule-vote", Schedule: &p})
				if (e == nil) != tc.voteOK {
					t.Fatalf("vote boundary: %v", e)
				}
				if tc.voteOK {
					c.Signatures = append(c.Signatures, r.Signature)
				}
			}
			if !tc.voteOK {
				return
			}
			elapsed = tc.installDelay
			for _, n := range f.nodes {
				_, e := n.handle(rpcRequest{Op: "schedule-install", ScheduleCertificate: &c})
				if (e == nil) != tc.installOK {
					t.Fatalf("install boundary: %v", e)
				}
				if !tc.installOK && (n.scheduleClock != nil || n.schedule != nil && n.schedule.Certificate != nil) {
					t.Fatal("late admission armed a clock")
				}
			}
		})
	}
}

func TestFrozenCompletionFinishesOnlyPinnedNewsAfterSelectionDeadline(t *testing.T) {
	for _, fused := range []bool{false, true} {
		for _, atomic := range []bool{false, true} {
			t.Run(fmt.Sprintf("fused=%v/atomic=%v", fused, atomic), func(t *testing.T) {
				f := newScheduledFixtureCompletion(t, atomic, true)
				f.lab.localOutboxes, f.lab.fuseReservationPrepare = true, fused
				early, late := map[int][]byte{}, map[int][]byte{}
				for i := range clients {
					early[i] = []byte(fmt.Sprintf("خبر پیش از مرز زمانی؛ عضو %d", i))
					late[i] = []byte(fmt.Sprintf("خبر تازه پس از انتخاب؛ عضو %d", i))
					if _, e := f.nodes[i].enqueueLocal(localSubmission{1, early[i]}); e != nil {
						t.Fatal(e)
					}
				}
				f.at(0)
				prepareFrozenTestRound(t, f, 0)
				f.elapsed += 50 * time.Millisecond
				for i := range clients {
					if _, e := f.nodes[i].enqueueLocal(localSubmission{2, late[i]}); e != nil {
						t.Fatal(e)
					}
				}
				// Identical cached preparations, but commits/fused bulk now arrive
				// after the original round-0 upper bound of start + 1.9 seconds.
				f.elapsed = 6*time.Second + 200*time.Millisecond
				out := f.cycle(t, 0)
				if !samePayloadMultiset(out, early) {
					t.Fatal("late completion changed frozen news")
				}
				for i := range clients {
					r, e := f.nodes[i].localStatus(2)
					if e != nil || r.Status != "queued" {
						t.Fatal("newer news escaped old selection", e)
					}
				}
				f.elapsed = 6*time.Second + 400*time.Millisecond
				if !samePayloadMultiset(f.cycle(t, 1), late) {
					t.Fatal("next original cutoff did not retain queued news")
				}
			})
		}
	}
	// Retained comparison: the original policy stops on these same late commits.
	f := newScheduledFixtureStorage(t, true)
	f.at(0)
	prepareFrozenTestRound(t, f, 0)
	f.elapsed = 6*time.Second + 200*time.Millisecond
	_, e := f.lab.run(f.lab.public.reservation(0), nil)
	requireReject(t, e)
}

func TestFrozenCompletionCannotIsolatePostCutoffSenderOrOmitLateMember(t *testing.T) {
	for target := range clients {
		t.Run(fmt.Sprint(target), func(t *testing.T) {
			f := newScheduledFixtureCompletion(t, true, true)
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
			for i := range clients {
				if _, e := f.nodes[i].enqueueLocal(localSubmission{1, []byte(fmt.Sprintf("خبر پس از مرز مشترک از عضو %d", i))}); e != nil {
					t.Fatal(e)
				}
			}
			if out := f.cycle(t, 0); len(out.messages) != 0 {
				t.Fatal("delayed member exposed a new post-cutoff article")
			}
			// In the next round seven members prepare; delay the last past the
			// selection window. Completion slack must not admit that last prepare.
			f.at(1)
			d = descriptorRPC(f.lab.public.reservation(1))
			xs := []rpcInput{}
			for i := range clients {
				if i != target {
					r, e := f.nodes[i].handle(rpcRequest{Op: "prepare", Descriptor: d})
					if e != nil {
						t.Fatal(e)
					}
					xs = append(xs, *r.Input)
				}
			}
			f.elapsed = 8*time.Second + 150*time.Millisecond
			n := f.nodes[target]
			before := n.journal.commits
			_, e := n.handle(rpcRequest{Op: "prepare", Descriptor: d})
			requireReject(t, e)
			if n.journal.commits != before || n.outbox.SelectionMade {
				t.Fatal("late selection changed durable state")
			}
			for _, op := range []string{"commit", "accept-and-prepare", "prepare-corrupt"} {
				_, e = n.handle(rpcRequest{Op: op, Descriptor: d})
				requireReject(t, e)
			}
			// A coordinator still requires every fixed member, even inside slack.
			_, e = f.nodes[clients].handle(rpcRequest{Op: "commit", Descriptor: d, Inputs: xs})
			requireReject(t, e)
			if f.nodes[clients].pending != nil || f.nodes[clients].state.servers[0].committed {
				t.Fatal("missing member was silently excluded")
			}
		})
	}
}

func TestFrozenBulkDoesNotReplacePinOrAdoptPreviouslyEmptyClient(t *testing.T) {
	for _, fused := range []bool{false, true} {
		t.Run(fmt.Sprint(fused), func(t *testing.T) {
			f := newScheduledFixtureCompletion(t, true, true)
			f.lab.localOutboxes, f.lab.fuseReservationPrepare = true, fused
			early := []byte("خبر اصلی که باید ثابت بماند")
			if _, e := f.nodes[0].enqueueLocal(localSubmission{1, early}); e != nil {
				t.Fatal(e)
			}
			f.at(0)
			prepareFrozenTestRound(t, f, 0)
			if _, e := f.nodes[0].enqueueLocal(localSubmission{1, []byte("جایگزینی غیرمجاز")}); e == nil {
				t.Fatal("pin payload replaced")
			}
			f.elapsed = 6*time.Second + 200*time.Millisecond
			for i := 0; i < 2; i++ {
				seq := uint64(1)
				if i == 0 {
					seq = 2
				}
				if _, e := f.nodes[i].enqueueLocal(localSubmission{seq, []byte("خبر هنگام تکمیل دیرهنگام")}); e != nil {
					t.Fatal(e)
				}
			}
			if out := f.cycle(t, 0); !samePayloadMultiset(out, map[int][]byte{0: early}) {
				t.Fatal("late bulk selected fresh content")
			}
			for i := 0; i < 2; i++ {
				seq := uint64(1)
				if i == 0 {
					seq = 2
				}
				r, e := f.nodes[i].localStatus(seq)
				if e != nil || r.Status != "queued" {
					t.Fatal("fresh queue item released", e)
				}
			}
		})
	}
}

func TestFrozenCompletionAuthenticatesInputsAndRetainsGraceLimit(t *testing.T) {
	for _, name := range []string{"missing", "duplicate", "modified", "descriptor", "grace-expired", "clock-jump", "before-expiry"} {
		t.Run(name, func(t *testing.T) {
			f := newScheduledFixtureCompletion(t, true, true)
			f.at(0)
			xs := prepareFrozenTestRound(t, f, 0)
			q := rpcRequest{Op: "commit", Descriptor: descriptorRPC(f.lab.public.reservation(0)), Inputs: xs}
			f.elapsed = 6*time.Second + 200*time.Millisecond
			switch name {
			case "missing":
				q.Inputs = q.Inputs[:clients-1]
			case "duplicate":
				q.Inputs[1] = q.Inputs[0]
			case "modified":
				q.Inputs[0].Body[0] ^= 1
			case "descriptor":
				q.Descriptor.Previous[0] ^= 1
			case "grace-expired":
				f.elapsed = 8*time.Second - scheduleSkew
			case "before-expiry":
				f.elapsed = 8*time.Second - scheduleSkew - time.Nanosecond
			case "clock-jump":
				f.jump = time.Second
			}
			n := f.nodes[clients]
			_, e := n.handle(q)
			if name == "before-expiry" {
				if e != nil {
					t.Fatal(e)
				}
				return
			}
			requireReject(t, e)
			if n.pending != nil || n.state.servers[0].committed {
				t.Fatal("rejected completion committed an input set")
			}
		})
	}
}

func TestFrozenCompletionPolicyIsSignedBoundedAndRestoredExplicitly(t *testing.T) {
	strict := newScheduledFixtureStorage(t, true)
	f := newScheduledFixtureCompletion(t, true, true)
	if !bytes.HasPrefix(strict.certificate.Proposal.signed(strict.lab.public), []byte("FarvaharTrends/common-reservation-schedule/v1\x00")) || !bytes.HasPrefix(f.certificate.Proposal.signed(f.lab.public), []byte("FarvaharTrends/common-reservation-schedule/v2\x00")) {
		t.Fatal("policy signature domain not explicit")
	}
	b, e := json.Marshal(strict.certificate.Proposal)
	if e != nil || bytes.Contains(b, []byte("CompletionSlackNano")) {
		t.Fatal("legacy default wire form changed")
	}
	for _, nanos := range []int64{-1, 1, int64(frozenCompletionSlack) + 1, math.MaxInt64} {
		p := f.certificate.Proposal
		p.CompletionSlackNano = nanos
		requireReject(t, p.valid(f.lab.public))
	}
	p := f.certificate.Proposal
	p.StartUnixNano = math.MaxInt64 - int64(p.Rounds)*p.PeriodNano - p.SkewNano
	requireReject(t, p.valid(f.lab.public))
	for _, original := range []struct {
		f     *scheduledFixture
		slack int64
	}{{strict, int64(frozenCompletionSlack)}, {f, 0}} {
		c := jsonCopy(original.f.certificate)
		c.Proposal.CompletionSlackNano = original.slack
		requireReject(t, c.verify(original.f.lab.public))
	}
	bad := f.configs[0]
	bad.RequireCommonSchedule = false
	if validScheduleConfig(bad) {
		t.Fatal("completion policy without common selection accepted")
	}
	for _, n := range strict.nodes {
		requireReject(t, n.matchesCompletionPolicy(f.certificate.Proposal))
	}
	for _, n := range f.nodes {
		requireReject(t, n.matchesCompletionPolicy(strict.certificate.Proposal))
	}
	raw, e := f.nodes[0].checkpoint()
	if e != nil {
		t.Fatal(e)
	}
	var saved roleCheckpoint
	if e = json.Unmarshal(raw, &saved); e != nil {
		t.Fatal(e)
	}
	saved.Config.FrozenCompletion = false
	raw, e = json.Marshal(saved)
	if e != nil {
		t.Fatal(e)
	}
	_, e = restoreRole(raw)
	requireReject(t, e)
}

func TestFrozenCompletionRestartRetainsRepliesButCannotRearm(t *testing.T) {
	f := newScheduledFixtureCompletion(t, true, true)
	f.at(0)
	xs := prepareFrozenTestRound(t, f, 0)
	d := descriptorRPC(f.lab.public.reservation(0))
	q := rpcRequest{Op: "commit", Descriptor: d, Inputs: xs}
	f.elapsed = 6*time.Second + 200*time.Millisecond
	first, e := f.nodes[clients].handle(q)
	if e != nil {
		t.Fatal(e)
	}
	for _, id := range []int{0, clients, clients + 1} {
		n := f.nodes[id]
		if e = n.journal.close(); e != nil {
			t.Fatal(e)
		}
		n, e = openDurableRole(f.configs[id], f.dirs[id])
		if e != nil {
			t.Fatal(e)
		}
		f.nodes[id] = n
	}
	again, e := f.nodes[clients].handle(q)
	if e != nil || !bytes.Equal(encodeSetup(first), encodeSetup(again)) {
		t.Fatal("late committed reply changed after restart", e)
	}
	_, e = f.nodes[clients+1].handle(q)
	if e == nil || !strings.Contains(e.Error(), "clock unavailable") {
		t.Fatal("restart created a new late commitment", e)
	}
	_, e = f.nodes[clients+1].handle(rpcRequest{Op: "schedule-install", ScheduleCertificate: &f.certificate})
	if e != nil {
		t.Fatal(e)
	}
	_, e = f.nodes[clients+1].handle(q)
	requireReject(t, e)
	_, e = f.nodes[0].handle(rpcRequest{Op: "accept-and-prepare", Descriptor: d})
	requireReject(t, e)
	_, e = f.nodes[0].enqueueLocal(localSubmission{1, []byte("خبر پس از راه‌اندازی دوباره")})
	requireReject(t, e)
}
