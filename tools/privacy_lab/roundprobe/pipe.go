// Laboratory bridge: continuously scheduled IN-MEMORY component rounds.
// No private network transport, distributed setup or anonymity claim.
package main

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"time"
)

type request struct {
	ID      uint64 `json:"id"`
	Payload string `json:"payload"`
	body    []byte
	arrived time.Time
	cpu     time.Duration
}

func pipeLab() {
	f := newFixtureWithLimit(clients)
	pipeWithBackend(f, f.runMany, nil)
}
func pipeWithBackend(f *fixture, run func(descriptor, map[int][]byte) (result, error), lab *networkLab) {
	encoder := json.NewEncoder(os.Stdout)
	ready := map[string]interface{}{"ready": true, "candidate": "FPP-1 component", "wireVersion": 2, "securityGatePassed": false, "reason": "central fixture; no Sybil admission, safe jam recovery or anonymous setup", "slotIntervalMs": 2000, "maxApplicationBytes": maxCell - cellNonceSize - 66, "scope": "continuous simulated rounds in one process; not on-wire cover traffic", "processCpuScope": "all in-memory roles in one process"}
	if lab != nil {
		ready["candidate"] = "FPP-1 role RPC"
		ready["scope"] = "continuous rounds over 11 role processes and loopback mutual TLS; centrally provisioned and controller-mediated, no phone radio"
		ready["processCpuScope"] = "controller only; child role totals recorded in lifecycle.json"
		ready["labRunDirectory"] = lab.directory
		ready["durableRoleCheckpoints"] = lab.durable
		ready["linkProfile"] = lab.profile
		ready["pacingScope"] = "application-level per-role socket pacing and per-RPC latency; not a carrier measurement"
		if lab.anonymousSetup {
			ready["candidate"] = "FPP-1 role-local verifiable setup"
			ready["scope"] = "continuous rounds over 11 independent roles with verifiable key setup and loopback mutual TLS; controller-mediated laboratory transport"
			ready["reason"] = "no Sybil admission, safe jam recovery, intersection defense or production transport"
			ready["anonymousSetup"] = lab.setupMetrics
		}
	}
	must(encoder.Encode(ready))
	requests := make(chan request, 64)
	readDone := make(chan error, 1)
	go func() {
		scanner := bufio.NewScanner(os.Stdin)
		scanner.Buffer(make([]byte, 16384), 16384)
		var last uint64
		for scanner.Scan() {
			var r request
			if e := json.Unmarshal(scanner.Bytes(), &r); e != nil {
				readDone <- e
				return
			}
			if r.ID <= last {
				readDone <- errors.New("nonmonotonic request id")
				return
			}
			last = r.ID
			var e error
			r.body, e = base64.StdEncoding.DecodeString(r.Payload)
			if e != nil || len(r.body) > maxCell-cellNonceSize-66 || len(r.body) == 0 {
				readDone <- errors.New("invalid or oversized payload; no fallback")
				return
			}
			r.Payload = ""
			r.arrived = time.Now()
			r.cpu = cpuTime()
			requests <- r
		}
		readDone <- scanner.Err()
	}()
	timer := time.NewTicker(2 * time.Second)
	defer timer.Stop()
	pending := []request{}
	var round uint64
	idleRounds := 0
	for {
		select {
		case r := <-requests:
			if len(pending) >= 64 {
				panic("bounded queue full; no fallback")
			}
			pending = append(pending, r)
		case e := <-readDone:
			must(e)
			if len(pending) > 0 || len(requests) > 0 {
				panic("input closed with unprocessed requests")
			}
			return
		case due := <-timer.C:
			started := time.Now()
			if started.Sub(due) > 2*time.Second {
				panic("missed round deadline; no fallback")
			}
			selected := map[int]request{}
			reservations := map[int][]byte{}
			for _, r := range pending {
				c := int(r.ID % clients)
				if _, exists := selected[c]; !exists {
					selected[c] = r
					reservations[c] = []byte{1}
				}
			}
			reservation, e := run(f.reservation(round), reservations)
			must(e)
			if len(selected) == 0 {
				idleRounds++
				round++
				continue
			}
			payloads := map[int][]byte{}
			for c, r := range selected {
				payloads[c] = r.body
			}
			output, e := run(f.bulk(round, reservation, maxCell), payloads)
			must(e)
			finished := time.Now()
			finishedCPU := cpuTime()
			published := map[uint64]bool{}
			for _, r := range selected {
				body, exists := deliveredPayload(output, r.body)
				if !exists {
					panic("reserved payload missing; no fallback")
				}
				reply := map[string]interface{}{"id": r.ID, "payload": base64.StdEncoding.EncodeToString(body), "processCpuMs": ms(finishedCPU - r.cpu), "releaseMs": ms(finished.Sub(r.arrived)), "queuedMs": ms(started.Sub(r.arrived)), "roundWorkMs": ms(finished.Sub(started)), "idleRoundsSinceStart": idleRounds}
				if lab == nil {
					reply["encodedClientBytesForRound"] = reservation.clientUp + reservation.clientDown + output.clientUp + output.clientDown
					reply["encodedInterCoordinatorBytesForRound"] = reservation.interCoordinator + output.interCoordinator
					reply["bytesScope"] = "encoded model only; no private sockets"
				} else {
					reply["tlsPayloadBytesAllRoleLinks"] = reservation.transportBytes + output.transportBytes
					reply["reservationPhases"] = reservation.phaseTimings
					reply["bulkPhases"] = output.phaseTimings
					reply["bytesScope"] = "actual TLS socket payloads including laboratory control requests; excludes IP/TCP headers"
				}
				must(encoder.Encode(reply))
				published[r.ID] = true
			}
			kept := pending[:0]
			for _, r := range pending {
				if !published[r.ID] {
					kept = append(kept, r)
				}
			}
			// Clear discarded slice entries to avoid retaining payloads beyond delivery.
			for i := len(kept); i < len(pending); i++ {
				pending[i] = request{}
			}
			pending = kept
			round++
		}
	}
}

func unsupportedMode(mode string) { panic(fmt.Sprintf("unsupported laboratory mode %q", mode)) }
