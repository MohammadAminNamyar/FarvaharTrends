package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"time"

	control "farvahartrends.local/privacy-lab/verdictprobe/control"
)

func networkControlChecks(profile linkProfile) {
	networkControlChecksWithDurability(profile, false)
}
func networkControlChecksWithDurability(profile linkProfile, durable bool) {
	lab, e := newNetworkLabConfigured(profile, true, 1, durable)
	must(e)
	defer lab.close()
	lab.crashReplay = durable
	report := map[string]any{"schema": 1, "scope": "one deliberately corrupted round; eleven role-local processes over loopback mutual TLS; local complaint creation, all-slot verifiable transport; controller supplied roster; no anonymity or production recovery claim", "profile": profile, "securityGatePassed": false, "productionIntegrationAllowed": false, "directory": lab.directory}
	report["durableWithProcessCrashReplay"] = durable
	checks := map[string]bool{}
	report["checks"] = checks
	defer func() {
		report["replayedIdenticalResponsesAfterCrash"] = lab.replayedAfterCrash
		r := recover()
		if r != nil {
			report["fatal"] = fmt.Sprint(r)
		}
		passed := 0
		for _, ok := range checks {
			if ok {
				passed++
			}
		}
		report["passed"] = passed
		must(saveJSON(filepath.Join(lab.directory, "control-checks.json"), report))
		must(json.NewEncoder(os.Stdout).Encode(map[string]any{"report": filepath.Join(lab.directory, "control-checks.json"), "passed": passed, "fatal": report["fatal"], "timing": report["timing"]}))
		if r != nil {
			panic(r)
		}
	}()
	check := func(name string, ok bool) {
		checks[name] = ok
		if !ok {
			panic("control check failed: " + name)
		}
	}
	started, before := time.Now(), lab.bytes()
	r, e := lab.parallel(allCoordinatorIDs(), func(int) rpcRequest { return rpcRequest{Op: "control-hello"} })
	must(e)
	var hellos []control.Hello
	for _, x := range r {
		if x.ControlHello == nil {
			panic("missing control hello")
		}
		hellos = append(hellos, *x.ControlHello)
	}
	r, e = lab.parallel(allRoleIDs(), func(int) rpcRequest { return rpcRequest{Op: "control-bind", ControlHellos: hellos} })
	must(e)
	for _, x := range r {
		check("allRolesAgreeControlSession", x.ControlSession == r[0].ControlSession && x.ControlSession != "")
	}
	setupMs, setupBytes := ms(time.Since(started)), lab.bytes()-before
	d := lab.public.reservation(0)
	wd := descriptorRPC(d)
	_, e = lab.nodes[0].call(rpcRequest{Op: "prepare-corrupt", Descriptor: wd})
	check("faultInjectionDisabledForHonestRoles", e != nil)
	r, e = lab.parallel(allClientIDs(), func(i int) rpcRequest {
		op := "prepare"
		if i == 1 {
			op = "prepare-corrupt"
		}
		var p []byte
		if i == 0 {
			p = []byte{1}
		}
		return rpcRequest{Op: op, Descriptor: wd, Payload: p}
	})
	must(e)
	var inputs []rpcInput
	for _, x := range r {
		if x.Input == nil {
			panic("missing bulk input")
		}
		inputs = append(inputs, *x.Input)
	}
	r, e = lab.parallel(allCoordinatorIDs(), func(int) rpcRequest { return rpcRequest{Op: "commit", Descriptor: wd, Inputs: inputs} })
	must(e)
	var votes []rpcVote
	for _, x := range r {
		votes = append(votes, *x.Vote)
	}
	r, e = lab.parallel(allCoordinatorIDs(), func(int) rpcRequest { return rpcRequest{Op: "release", Descriptor: wd, Votes: votes} })
	must(e)
	var shares []rpcShare
	for _, x := range r {
		shares = append(shares, *x.Share)
	}
	_, e = lab.nodes[clients].call(rpcRequest{Op: "finish", Descriptor: wd, Root: votes[0].Root, Shares: shares})
	check("corruptedNewsNotReleased", e != nil)
	started, before = time.Now(), lab.bytes()
	r, e = lab.parallel(allRoleIDs(), func(int) rpcRequest {
		return rpcRequest{Op: "control-open", Descriptor: wd, Inputs: inputs, Votes: votes, Shares: shares}
	})
	must(e)
	for _, x := range r {
		check("allRolesBindSameFaultContext", x.ControlDescriptor != nil && reflect.DeepEqual(x.ControlDescriptor, r[0].ControlDescriptor))
	}
	openMs := ms(time.Since(started))
	phase := time.Now()
	r, e = lab.parallel(allClientIDs(), func(int) rpcRequest { return rpcRequest{Op: "control-prepare", Descriptor: wd} })
	must(e)
	var ci []control.Contribution
	for _, x := range r {
		if x.ControlInput == nil {
			panic("missing encrypted complaint contribution")
		}
		ci = append(ci, *x.ControlInput)
	}
	createMs := ms(time.Since(phase))
	encoded, _ := json.Marshal(ci[0])
	for _, x := range ci {
		b, _ := json.Marshal(x)
		check("allClientsSendSameEncodedSize", len(b) == len(encoded))
	}
	bad := jsonCopy(ci)
	bad[1].Cells[0].C[0][0] ^= 1
	_, e = lab.nodes[clients].call(rpcRequest{Op: "control-commit", Descriptor: wd, ControlInputs: bad})
	check("modifiedComplaintContributionRejected", e != nil)
	_, e = lab.nodes[clients].call(rpcRequest{Op: "control-commit", Descriptor: wd, ControlInputs: ci[:clients-1]})
	check("missingControlContributorDoesNotRelease", e != nil)
	phase = time.Now()
	r, e = lab.parallel(allCoordinatorIDs(), func(int) rpcRequest { return rpcRequest{Op: "control-commit", Descriptor: wd, ControlInputs: ci} })
	must(e)
	var cv []control.Vote
	for _, x := range r {
		cv = append(cv, *x.ControlVote)
	}
	commitMs := ms(time.Since(phase))
	_, e = lab.nodes[clients].call(rpcRequest{Op: "control-release", Descriptor: wd, ControlVotes: cv[:2]})
	check("missingControlVoteDoesNotRelease", e != nil)
	phase = time.Now()
	r, e = lab.parallel(allCoordinatorIDs(), func(int) rpcRequest { return rpcRequest{Op: "control-release", Descriptor: wd, ControlVotes: cv} })
	must(e)
	var cs []control.Share
	for _, x := range r {
		cs = append(cs, *x.ControlShare)
	}
	releaseMs := ms(time.Since(phase))
	_, e = lab.nodes[0].call(rpcRequest{Op: "control-finish", Descriptor: wd, ControlInputs: ci, ControlVotes: cv, ControlShares: cs[:2]})
	check("incompleteControlOutputNotAccepted", e != nil)
	phase = time.Now()
	r, e = lab.parallel(allCoordinatorIDs(), func(int) rpcRequest {
		return rpcRequest{Op: "control-finish", Descriptor: wd, ControlInputs: ci, ControlVotes: cv, ControlShares: cs}
	})
	must(e)
	finishMs := ms(time.Since(phase))
	outputs := r[0].ControlOutput
	var certs []control.Certificate
	for _, x := range r {
		check("allRolesAgreeRecoveredControlOutput", reflect.DeepEqual(x.ControlOutput, outputs))
		if x.ControlCertificate == nil {
			panic("missing verified output certificate")
		}
		certs = append(certs, *x.ControlCertificate)
	}
	_, e = lab.nodes[0].call(rpcRequest{Op: "control-finish", Descriptor: wd, ControlInputs: ci, ControlVotes: cv, ControlOutputs: outputs, ControlCertificates: certs[:2]})
	check("missingUnanimousCertificateRejected", e != nil)
	badOutputs := jsonCopy(outputs)
	badOutputs[0].Invalid = !badOutputs[0].Invalid
	_, e = lab.nodes[0].call(rpcRequest{Op: "control-finish", Descriptor: wd, ControlInputs: ci, ControlVotes: cv, ControlOutputs: badOutputs, ControlCertificates: certs})
	check("modifiedCertifiedOutputRejected", e != nil)
	phase = time.Now()
	r, e = lab.parallel(allClientIDs(), func(int) rpcRequest {
		return rpcRequest{Op: "control-finish", Descriptor: wd, ControlInputs: ci, ControlVotes: cv, ControlOutputs: outputs, ControlCertificates: certs}
	})
	must(e)
	clientFinishMs := ms(time.Since(phase))
	for _, x := range r {
		check("allRolesAgreeRecoveredControlOutput", reflect.DeepEqual(x.ControlOutput, outputs))
	}
	xs, e := nativeInputs(inputs)
	must(e)
	vs, e := nativeVotes(votes)
	must(e)
	ss, e := nativeShares(shares)
	must(e)
	audit, e := newFaultAudit(lab.public, d, xs, vs, ss)
	must(e)
	count := 0
	for _, o := range outputs {
		if o.Payload == nil {
			continue
		}
		check("noMalformedRecoveredComplaint", !o.Invalid)
		w, e := payloadWitness(o.Payload)
		must(e)
		check("complaintAuthorizedForItsSlot", w.slot == o.Slot)
		must(audit.accept(w))
		count++
	}
	check("sevenHonestParticipantsRecoverComplaints", count == clients-1)
	r, e = lab.parallel(allCoordinatorIDs(), func(int) rpcRequest { return rpcRequest{Op: "control-report", Descriptor: wd} })
	must(e)
	bySlot := map[int][]bitReport{}
	for _, x := range r {
		for _, wr := range x.WitnessReports {
			w, b, e := wr.native()
			must(e)
			must(audit.verifyReport(w, b))
			bySlot[w.slot] = append(bySlot[w.slot], b)
		}
	}
	for slot, reports := range bySlot {
		finding, e := audit.investigate(*audit.accepted[slot], reports)
		must(e)
		check("clientOneIsCandidateAcrossEveryWitness", reflect.DeepEqual(finding.ClientCandidates, []int{1}) && len(finding.CoordinatorContradictions) == 0)
	}
	check("allComplaintsHaveThreeReports", len(bySlot) == count)
	_, e = lab.nodes[0].call(rpcRequest{Op: "prepare", Descriptor: descriptorRPC(lab.public.reservation(1)), Payload: []byte{1}})
	check("noAutomaticUnsafeRoundAdvance", e != nil)
	// Exact late retries must not restart setup or regenerate an owner ciphertext.
	_, e = lab.nodes[0].call(rpcRequest{Op: "control-bind", ControlHellos: hellos})
	must(e)
	again, e := lab.nodes[0].call(rpcRequest{Op: "control-prepare", Descriptor: wd})
	must(e)
	check("lateSetupRetryPreservesControlContribution", reflect.DeepEqual(again.ControlInput, &ci[0]))
	report["timing"] = map[string]any{"controlSetupMs": setupMs, "controlSetupTLSBytes": setupBytes, "investigationTotalMsIncludingInjectedFailures": ms(time.Since(started)), "investigationTLSBytesIncludingInjectedFailures": lab.bytes() - before, "faultOpenMs": openMs, "clientContributionMs": createMs, "coordinatorCommitMs": commitMs, "coordinatorReleaseMs": releaseMs, "coordinatorAcceptMs": finishMs, "clientCertificateAcceptMs": clientFinishMs}
	report["complaintsRecovered"] = count
	report["validBulkOutputCertificates"] = 0
	report["removedParticipants"] = 0
	report["scopeExcludes"] = []string{"autonomous uniform traffic schedule", "physical network/radio", "battery", "Sybil and intersection defense", "durable recovery", "expulsion and safe resumed publication"}
	if durable {
		report["scopeExcludes"] = []string{"autonomous uniform traffic schedule", "physical network/radio", "battery", "Sybil and intersection defense", "power loss and malicious filesystem rollback", "expulsion and safe resumed publication"}
	}
	must(saveJSON(filepath.Join(lab.directory, "control-public-transcript.json"), map[string]any{"hellos": hellos, "failedDescriptor": wd, "inputs": inputs, "votes": votes, "shares": shares, "controlInputs": ci, "controlVotes": cv, "controlShares": cs, "controlOutputs": outputs, "controlCertificates": certs}))
}
