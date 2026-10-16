package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

// Anchor the controller's test timer once to the certified wall-time boundary,
// then advance with monotonic durations. Roles still enforce their own windows.
// No request arrival or local queue length selects/advances a round boundary.
func runCertifiedOutboxSchedule(ctx context.Context, lab *networkLab, p reservationSchedule, frames chan<- outboxRelease) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	now := time.Now()
	first := now.Add(time.Unix(0, p.StartUnixNano).Sub(now) + 2*scheduleSkew + 50*time.Millisecond)
	ticks := make(chan time.Time)
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer close(ticks)
		for due := first; ; due = due.Add(schedulePeriod) {
			timer := time.NewTimer(time.Until(due))
			select {
			case <-ctx.Done():
				timer.Stop()
				return
			case <-timer.C:
			}
			select {
			case ticks <- due:
			case <-ctx.Done():
				return
			}
		}
	}()
	runOutboxSchedule(ctx, lab, ticks, schedulePeriod, frames)
	cancel()
	<-done
}

func (lab *networkLab) installCommonSchedule(lead time.Duration, rounds uint64) (scheduleCertificate, error) {
	p := reservationSchedule{Epoch: lab.public.epoch, StartUnixNano: time.Now().Add(lead).UnixNano(), PeriodNano: int64(schedulePeriod), SkewNano: int64(scheduleSkew), Rounds: rounds}
	if lab.frozenCompletion {
		p.CompletionSlackNano = int64(frozenCompletionSlack)
	}
	c := scheduleCertificate{Proposal: p}
	votes, e := lab.parallel(allCoordinatorIDs(), func(int) rpcRequest { return rpcRequest{Op: "schedule-vote", Schedule: &p} })
	if e != nil {
		return c, e
	}
	for _, v := range votes {
		c.Signatures = append(c.Signatures, v.Signature)
	}
	if e = c.verify(lab.public); e != nil {
		return c, e
	}
	ids := append(allClientIDs(), allCoordinatorIDs()...)
	_, e = lab.parallel(ids, func(int) rpcRequest { return rpcRequest{Op: "schedule-install", ScheduleCertificate: &c} })
	if e == nil {
		lab.scheduleAdmissionLead = lead
	}
	return c, e
}

func networkScheduleChecks(profile linkProfile) {
	networkScheduleChecksWithFusion(profile, false)
}
func networkScheduleChecksWithFusion(profile linkProfile, fused bool) {
	networkScheduleChecksWithStorage(profile, fused, false)
}
func networkScheduleChecksWithStorage(profile linkProfile, fused, atomicPublication bool) {
	networkScheduleChecksWithCompletion(profile, fused, atomicPublication, false)
}
func networkScheduleChecksWithCompletion(profile linkProfile, fused, atomicPublication, frozenCompletion bool) {
	started := time.Now()
	lab, e := newNetworkLabCompletion(profile, true, -1, true, true, true, atomicPublication, frozenCompletion)
	must(e)
	defer lab.close()
	lab.fuseReservationPrepare = fused
	checks := map[string]bool{}
	report := map[string]any{
		"schema": 1, "scope": "eleven durable separate processes, anonymous slot setup and mutual loopback TLS; controller-mediated traffic, common authenticated local cutoffs",
		"runtimeOS": runtime.GOOS, "runtimeArch": runtime.GOARCH, "runtimeVersion": runtime.Version(),
		"profile": profile, "checks": checks, "securityGatePassed": false, "productionIntegrationAllowed": false,
		"fusedReservationAcceptanceAndBulkPrepare": fused,
		"atomicPublicationCheckpoints":             atomicPublication,
		"frozenCompletion":                         frozenCompletion,
		"assumptions":                              []string{"live role clocks within 100 ms; this is not established by the schedule certificate", "same-host loopback clocks, no physical clock/admission or shutdown claim"},
	}
	defer func() {
		report["elapsedMsIncludingSetupWaitAndFaultChecks"] = ms(time.Since(started))
		must(saveJSON(filepath.Join(lab.directory, "schedule-checks.json"), report))
	}()
	check := func(name string, ok bool) {
		checks[name] = ok
		if !ok {
			panic("schedule check failed: " + name)
		}
	}
	_, e = lab.nodes[0].privateCall(localIPCRequest{Enqueue: &localSubmission{1, []byte("پیش از پذیرش زمان‌بندی")}})
	check("missingScheduleRejectsSubmissionWithoutAcknowledgement", e != nil)
	cert, e := lab.installCommonSchedule(8*time.Second, 30)
	must(e)
	report["schedule"] = cert
	// Private controller diagnostics, never peer telemetry. Anchor once so a
	// wall-clock adjustment cannot distort elapsed phase durations or offsets.
	observedNow := time.Now()
	observedCutoff := observedNow.Add(time.Unix(0, cert.Proposal.StartUnixNano).Sub(observedNow))
	trace := []map[string]any{}
	defer func() { report["controllerTimeline"] = trace }()
	observe := func(label string, round uint64, action func() error) error {
		begin := time.Now()
		err := action()
		end := time.Now()
		cutoff := observedCutoff.Add(time.Duration(round) * schedulePeriod)
		row := map[string]any{
			"operation": label, "round": round,
			"startedAfterCutoffMs":  ms(begin.Sub(cutoff)),
			"finishedAfterCutoffMs": ms(end.Sub(cutoff)),
			"elapsedMs":             ms(end.Sub(begin)),
		}
		if err != nil {
			row["error"] = err.Error()
		}
		trace = append(trace, row)
		return err
	}
	observeRound := func(label string, round uint64, desc descriptor) (result, error) {
		var out result
		err := observe(label, round, func() (err error) {
			out, err = lab.run(desc, nil)
			return err
		})
		trace[len(trace)-1]["phasesMs"] = out.phaseTimings
		trace[len(trace)-1]["tlsPayloadBytesAllRoleLinks"] = out.transportBytes
		return out, err
	}
	report["timelineScope"] = "private controller monotonic observation of this finite test; includes test enqueue/preparation work, not delivered-message latency or peer telemetry"
	d := descriptorRPC(lab.public.reservation(0))
	_, e = lab.nodes[0].call(rpcRequest{Op: "prepare", Descriptor: d})
	check("earlyRemotePrepareRejected", e != nil)
	changed := cert.Proposal
	changed.StartUnixNano += int64(time.Second)
	_, e = lab.nodes[clients].call(rpcRequest{Op: "schedule-vote", Schedule: &changed})
	check("coordinatorCannotEquivocateOnSchedule", e != nil)
	tampered := jsonCopy(cert)
	tampered.Proposal.StartUnixNano++
	_, e = lab.nodes[1].call(rpcRequest{Op: "schedule-install", ScheduleCertificate: &tampered})
	check("alteredScheduleCertificateRejected", e != nil)
	wait := func(round uint64) {
		due := time.Unix(0, cert.Proposal.StartUnixNano+int64(round)*int64(schedulePeriod)).Add(2*scheduleSkew + 50*time.Millisecond)
		if delay := time.Until(due); delay > 0 {
			time.Sleep(delay)
		}
	}
	wait(0)
	target := 5
	early := []int{}
	for i := range clients {
		if i != target {
			early = append(early, i)
		}
	}
	e = observe("early-seven-prepare", 0, func() error {
		_, err := lab.parallel(early, func(int) rpcRequest { return rpcRequest{Op: "prepare", Descriptor: d} })
		return err
	})
	must(e)
	payloads := map[int][]byte{}
	e = observe("sequential-test-enqueue-eight", 0, func() error {
		for i := range clients {
			payloads[i] = []byte(fmt.Sprintf("خبر آزمایشی؛ مرز مشترک انتخاب خبر برای عضو %d باید مستقل از درخواست همتا باشد", i))
			if _, err := lab.nodes[i].privateCall(localIPCRequest{Enqueue: &localSubmission{1, payloads[i]}}); err != nil {
				return err
			}
		}
		return nil
	})
	must(e)
	r, e := observeRound("reservation-zero", 0, lab.public.reservation(0))
	must(e)
	check("delayedTargetCannotPublishPostCutoffNewsAlone", len(r.messages) == 0)
	wait(1)
	r, e = observeRound("reservation-one", 1, lab.public.reservation(1))
	must(e)
	out, e := observeRound("bulk-one", 1, lab.public.bulk(1, r, maxCell))
	must(e)
	check("nextCommonRoundReleasesAllEightQueuedMessages", samePayloadMultiset(out, payloads))
	for i := range clients {
		receipt, e := lab.nodes[i].privateCall(localIPCRequest{StatusSequence: 1})
		must(e)
		check(fmt.Sprintf("client%dHasCertifiedLocalReceipt", i), receipt.Status == "released" && receipt.Digest == hash(payloads[i]))
	}
	nextSequence, received := uint64(2), 8
	if frozenCompletion {
		latePayload := []byte("تکمیل خبر تثبیت‌شده پس از پایان مهلت انتخاب خبر تازه")
		_, e = lab.nodes[0].privateCall(localIPCRequest{Enqueue: &localSubmission{2, latePayload}})
		must(e)
		wait(2)
		desc := descriptorRPC(lab.public.reservation(2))
		_, e = lab.parallel(allClientIDs(), func(int) rpcRequest { return rpcRequest{Op: "prepare", Descriptor: desc} })
		must(e)
		lateDue := time.Unix(0, cert.Proposal.StartUnixNano+int64(3*schedulePeriod)).Add(200 * time.Millisecond)
		if delay := time.Until(lateDue); delay > 0 {
			time.Sleep(delay)
		}
		r, e = observeRound("late-frozen-reservation-two", 2, lab.public.reservation(2))
		must(e)
		out, e = observeRound("late-frozen-bulk-two", 2, lab.public.bulk(2, r, maxCell))
		must(e)
		check("frozenCompletionAfterSelectionDeadlineReleasesOnlyPinnedNews", samePayloadMultiset(out, map[int][]byte{0: latePayload}))
		receipt, err := lab.nodes[0].privateCall(localIPCRequest{StatusSequence: 2})
		must(err)
		check("lateFrozenCompletionHasCertifiedLocalReceipt", receipt.Status == "released" && receipt.Digest == hash(latePayload))
		nextSequence, received = 3, 9
	}
	q := localSubmission{nextSequence, []byte("خبر در صف پس از راه‌اندازی دوباره حفظ می‌شود")}
	queued, e := lab.nodes[0].privateCall(localIPCRequest{Enqueue: &q})
	must(e)
	must(lab.nodes[0].crashRestart())
	again, e := lab.nodes[0].privateCall(localIPCRequest{Enqueue: &q})
	must(e)
	check("restartRetainsExactLocalQueuedReceipt", again == queued)
	_, e = lab.nodes[0].call(rpcRequest{Op: "schedule-install", ScheduleCertificate: &cert})
	must(e)
	nextRound := uint64(2)
	if frozenCompletion {
		nextRound = 3
	}
	_, e = lab.nodes[0].call(rpcRequest{Op: "prepare", Descriptor: descriptorRPC(lab.public.reservation(nextRound))})
	check("certificateReplayCannotRearmRestartedClock", e != nil && strings.Contains(e.Error(), "local schedule clock unavailable"))
	_, e = lab.nodes[0].privateCall(localIPCRequest{Enqueue: &localSubmission{nextSequence + 1, bytes.Repeat([]byte("خبر"), 3)}})
	check("newSubmissionBlockedAfterClockAnchorLoss", e != nil && strings.Contains(e.Error(), "local schedule clock unavailable"))
	report["passed"] = len(checks)
	report["receivedMessages"] = received
	report["limitations"] = []string{"shared clock-bound assumption not measured on physical phones", "new epoch/queue migration after restart is not implemented", "not autonomous uniform network traffic, no response-work timing or intersection defense", "no physical latency, battery or publisher-security acceptance"}
	must(json.NewEncoder(os.Stdout).Encode(map[string]any{"report": filepath.Join(lab.directory, "schedule-checks.json"), "passed": len(checks), "receivedMessages": received, "frozenCompletion": frozenCompletion}))
}
