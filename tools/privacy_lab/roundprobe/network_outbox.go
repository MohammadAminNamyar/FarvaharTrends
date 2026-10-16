package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

func networkOutboxChecks(profile linkProfile) {
	lab, e := newNetworkLabConfiguredOutbox(profile, true, -1, true, true)
	must(e)
	defer lab.close()
	checks := map[string]bool{}
	report := map[string]any{"schema": 1, "scope": "private local pipe enqueue; eleven durable roles with role-local setup over loopback TLS; controller still supplies membership and phase timing", "profile": profile, "securityGatePassed": false, "productionIntegrationAllowed": false, "checks": checks}
	defer func() {
		report["replayedIdenticalResponsesAfterCrash"] = lab.replayedAfterCrash
		must(saveJSON(filepath.Join(lab.directory, "outbox-checks.json"), report))
	}()
	check := func(name string, condition bool) {
		checks[name] = condition
		if !condition {
			panic("outbox check failed: " + name)
		}
	}
	started := time.Now()
	first := []byte("خبر فارسی نخست؛ انتشار باید تنها از صف خصوصی همین دستگاه انجام شود")
	other := bytes.Repeat([]byte("آزمایش متن بلند فارسی و مسئولیت‌پذیری در اطلاع‌رسانی؛ "), 20)
	late := []byte("خبر تازه پس از رزرو رسیده است؛ باید در نوبت بعد منتشر شود")
	a, e := lab.nodes[0].privateCall(localIPCRequest{Enqueue: &localSubmission{1, first}})
	must(e)
	b, e := lab.nodes[5].privateCall(localIPCRequest{Enqueue: &localSubmission{1, other}})
	must(e)
	check("privateEnqueueAcknowledgedAfterCommit", a.Status == "queued" && b.Status == "queued" && a.Digest == hash(first) && b.Digest == hash(other))
	_, e = lab.nodes[0].call(rpcRequest{Op: "prepare", Descriptor: descriptorRPC(lab.public.reservation(0)), Payload: []byte{1}})
	check("peerPayloadInjectionRejected", e != nil)
	_, e = lab.run(lab.public.reservation(0), map[int][]byte{0: {1}})
	check("controllerCannotInjectPublicationIntoRound", e != nil)
	_, e = lab.nodes[0].call(rpcRequest{Op: "enqueue"})
	check("peerEnqueueNotExposed", e != nil)
	s, e := lab.nodes[0].call(rpcRequest{Op: "stats"})
	must(e)
	check("peerStatsHideLocalQueueAndWriteActivity", s.CPUms == 0 && s.JournalCommits == 0 && s.JournalPlaintextBytes == 0 && s.JournalFileBytes == 0 && s.JournalCommitTiming == nil)
	must(lab.nodes[0].crashRestart())
	saved, e := lab.nodes[0].privateCall(localIPCRequest{StatusSequence: 1})
	must(e)
	check("queuedSubmissionSurvivesProcessRestart", saved == a)
	lab.crashReplay = true
	r, e := lab.run(lab.public.reservation(0), nil)
	must(e)
	c, e := lab.nodes[0].privateCall(localIPCRequest{Enqueue: &localSubmission{2, late}})
	must(e)
	check("lateArrivalQueuedLocally", c.Status == "queued")
	out, e := lab.run(lab.public.bulk(0, r, maxCell), nil)
	must(e)
	check("onlyPinnedMessagesReleased", samePayloadMultiset(out, map[int][]byte{0: first, 1: other}))
	status, e := lab.nodes[0].privateCall(localIPCRequest{StatusSequence: 1})
	must(e)
	check("certifiedOutputHasPrivateReleaseReceipt", status.Status == "released" && status.Digest == hash(first) && status.PhaseSequence == 1)
	saved, e = lab.nodes[0].privateCall(localIPCRequest{StatusSequence: 2})
	must(e)
	check("lateArrivalNotPublishedInEarlierReservation", saved == c)
	duplicate, e := lab.nodes[0].privateCall(localIPCRequest{Enqueue: &localSubmission{1, first}})
	must(e)
	check("lostEnqueueAckCannotDuplicatePublication", duplicate == status)
	_, e = lab.nodes[0].privateCall(localIPCRequest{Enqueue: &localSubmission{1, late}})
	check("sequencePayloadReplacementRejected", e != nil)
	r, e = lab.run(lab.public.reservation(1), nil)
	must(e)
	out, e = lab.run(lab.public.bulk(1, r, maxCell), nil)
	must(e)
	check("nextRoundReleasesLateArrival", samePayloadMultiset(out, map[int][]byte{0: late}))
	status, e = lab.nodes[0].privateCall(localIPCRequest{StatusSequence: 2})
	must(e)
	check("lateArrivalReceiptMatchesItsRound", status.Status == "released" && status.PhaseSequence == 3 && status.Digest == hash(late))
	r, e = lab.run(lab.public.reservation(2), nil)
	must(e)
	check("noDuplicateNewsAfterQueueDrains", len(r.messages) == 0)
	report["receivedMessages"] = 3
	report["separatePreReservationRestart"] = 1
	report["passed"] = len(checks)
	report["elapsedMsIncludingRestartsAndNegativeChecks"] = ms(time.Since(started))
	report["limits"] = []string{"no autonomous schedule or anonymity claim", "opaque bytes; application signatures/action policy and image fragmentation not integrated", "no physical network or battery acceptance", "laboratory local key file, not Android Keystore"}
	must(json.NewEncoder(os.Stdout).Encode(map[string]any{"report": filepath.Join(lab.directory, "outbox-checks.json"), "passed": len(checks), "receivedMessages": 3, "crashReplays": lab.replayedAfterCrash}))
}
