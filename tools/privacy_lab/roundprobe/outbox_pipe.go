package main

// Measurement adapter only. The timer sees certified reservation/output data,
// never local requests or their owner. Roles still receive controller-driven
// RPCs; this is not a decentralized schedule or an anonymity result.
import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"time"
)

type outboxRelease struct {
	round             uint64
	started, finished time.Time
	reservation, bulk result
	idleRounds        uint64
	err               error
}
type outboxObservation struct {
	request
	committed     time.Time
	localSequence uint64
	client        int
}
type observedRelease struct {
	frame outboxRelease
	body  []byte
}

func outboxCycle(lab *networkLab, round uint64) outboxRelease {
	f := outboxRelease{round: round, started: time.Now()}
	if !lab.localOutboxes {
		f.err = errors.New("role-local outboxes required")
		return f
	}
	f.reservation, f.err = lab.run(lab.public.reservation(round), nil)
	if f.err == nil && len(f.reservation.messages) != 0 {
		f.bulk, f.err = lab.run(lab.public.bulk(round, f.reservation, maxCell), nil)
	}
	f.finished = time.Now()
	return f
}

// The caller provides clock ticks, independently of the enqueue pipe. A missed
// deadline or round error stops the experiment without broadcasting queued news.
func runOutboxSchedule(ctx context.Context, lab *networkLab, ticks <-chan time.Time, interval time.Duration, frames chan<- outboxRelease) {
	var round, idle uint64
	for {
		select {
		case <-ctx.Done():
			return
		case due, ok := <-ticks:
			if !ok {
				return
			}
			var f outboxRelease
			if time.Since(due) > interval {
				f.round, f.started, f.finished = round, time.Now(), time.Now()
				f.err = errors.New("missed outbox round deadline; queued news retained, no fallback")
			} else {
				f = outboxCycle(lab, round)
			}
			if f.err == nil && len(f.reservation.messages) == 0 {
				idle++
			}
			f.idleRounds = idle
			select {
			case frames <- f:
			case <-ctx.Done():
				return
			}
			if f.err != nil {
				return
			}
			round++
		}
	}
}

func readOutboxSubmissions(ctx context.Context, lab *networkLab, reader io.Reader, observations chan<- outboxObservation) error {
	scanner := boundedPipeScanner(reader)
	var last uint64
	var sequences [clients]uint64
	for scanner.Scan() {
		var r request
		if e := json.Unmarshal(scanner.Bytes(), &r); e != nil {
			return e
		}
		if r.ID <= last {
			return errors.New("nonmonotonic laboratory request id")
		}
		last = r.ID
		var e error
		r.body, e = base64.StdEncoding.DecodeString(r.Payload)
		if e != nil || len(r.body) == 0 || len(r.body) > maxCell-cellNonceSize-66 {
			return errors.New("invalid local payload; no fallback")
		}
		r.Payload = ""
		r.arrived, r.cpu = time.Now(), cpuTime()
		c := int(r.ID % clients)
		sequence := sequences[c] + 1
		receipt, e := lab.nodes[c].privateCall(localIPCRequest{Enqueue: &localSubmission{sequence, r.body}})
		if e != nil {
			return e
		}
		if receipt.Sequence != sequence || receipt.Status != "queued" || receipt.Digest != hash(r.body) {
			return errors.New("local enqueue receipt mismatch")
		}
		sequences[c] = sequence
		select {
		case observations <- outboxObservation{r, time.Now(), sequence, c}:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return scanner.Err()
}

func pipeOutboxLab(lab *networkLab) error {
	return pipeOutboxLabWithSchedule(lab, nil)
}
func pipeOutboxLabWithSchedule(lab *networkLab, common *scheduleCertificate) error {
	encoder := json.NewEncoder(os.Stdout)
	if e := encoder.Encode(map[string]any{
		"ready": true, "candidate": "FPP-1 role-local durable outbox", "wireVersion": 2,
		"runtimeOS": runtime.GOOS, "runtimeArch": runtime.GOARCH, "runtimeVersion": runtime.Version(),
		"securityGatePassed": false, "productionIntegrationAllowed": false,
		"slotIntervalMs": 2000, "maxApplicationBytes": maxCell - cellNonceSize - 66,
		"durableRoleCheckpoints": true, "roleLocalOutboxes": true,
		"commonSchedule": common, "clockErrorBoundEstablished": false,
		"fusedReservationAcceptanceAndBulkPrepare": lab.fuseReservationPrepare,
		"atomicPublicationCheckpoints":             lab.atomicPublication,
		"frozenCompletion":                         lab.frozenCompletion,
		"scheduleAdmissionLeadMs":                  ms(lab.scheduleAdmissionLead),
		"labRunDirectory":                          lab.directory, "anonymousSetup": lab.setupMetrics, "linkProfile": lab.profile,
		"scope":           "independent timer, private local enqueue and eleven loopback TLS roles; scheduler remains a laboratory controller",
		"processCpuScope": "controller only; client CPU is intentionally absent from peer-facing stats",
		"reason":          "no decentralized schedule, admission/intersection defense, safe jam resumption or production integration",
	}); e != nil {
		return e
	}
	ctx, cancel := context.WithCancel(context.Background())
	timer := time.NewTicker(2 * time.Second)
	frames := make(chan outboxRelease, 32)
	observations := make(chan outboxObservation, 64)
	readDone := make(chan error, 1)
	scheduleDone := make(chan struct{})
	go func() {
		defer close(scheduleDone)
		if common != nil {
			runCertifiedOutboxSchedule(ctx, lab, common.Proposal, frames)
		} else {
			runOutboxSchedule(ctx, lab, timer.C, 2*time.Second, frames)
		}
	}()
	go func() { readDone <- readOutboxSubmissions(ctx, lab, os.Stdin, observations) }()
	defer func() {
		cancel()
		timer.Stop()
		_ = os.Stdin.Close()
		<-scheduleDone
	}()
	// Correlation here is a test observer, not an input to the schedule. Release
	// and private enqueue acknowledgement may arrive in either order.
	pending := map[[32]byte]outboxObservation{}
	released := map[[32]byte]observedRelease{}
	match := func() error {
		for digest, r := range pending {
			got, ok := released[digest]
			if !ok {
				continue
			}
			f := got.frame
			if e := encoder.Encode(map[string]any{
				"id": r.ID, "payload": base64.StdEncoding.EncodeToString(got.body),
				"localEnqueueAckMs":             ms(r.committed.Sub(r.arrived)),
				"releaseMs":                     ms(f.finished.Sub(r.arrived)),
				"reservationRoundStartOffsetMs": ms(f.started.Sub(r.arrived)),
				"roundWorkMs":                   ms(f.finished.Sub(f.started)), "idleRoundsSinceStart": f.idleRounds,
				"round": f.round, "localSequence": r.localSequence,
				"tlsPayloadBytesAllRoleLinks": f.reservation.transportBytes + f.bulk.transportBytes,
				"reservationPhases":           f.reservation.phaseTimings, "bulkPhases": f.bulk.phaseTimings,
				"bytesScope": "actual TLS socket payloads including controller RPCs; excludes private pipes and IP/TCP headers",
			}); e != nil {
				return e
			}
			delete(pending, digest)
			delete(released, digest)
		}
		return nil
	}
	for {
		select {
		case r := <-observations:
			digest := hash(r.body)
			if _, exists := pending[digest]; exists {
				return errors.New("duplicate laboratory payload")
			}
			pending[digest] = r
		case f := <-frames:
			if f.err != nil {
				// Local laboratory diagnostics only. Never expose queue/clock work
				// in a peer response, or discard failed warmups from the evidence.
				failure := map[string]any{
					"scope": "controller-observed failed laboratory round; not peer telemetry",
					"round": f.round, "error": f.err.Error(),
					"startedUtc": f.started.UTC(), "finishedUtc": f.finished.UTC(),
					"roundWorkMs":        ms(f.finished.Sub(f.started)),
					"reservationPhases":  f.reservation.phaseTimings,
					"bulkPhases":         f.bulk.phaseTimings,
					"securityGatePassed": false, "productionIntegrationAllowed": false,
				}
				if common != nil {
					cutoff := time.Unix(0, common.Proposal.StartUnixNano+int64(f.round)*common.Proposal.PeriodNano)
					failure["startedAfterCutoffMs"] = ms(f.started.Sub(cutoff))
					failure["finishedAfterCutoffMs"] = ms(f.finished.Sub(cutoff))
				}
				if e := saveJSON(filepath.Join(lab.directory, "outbox-failure.json"), failure); e != nil {
					return errors.Join(f.err, e)
				}
				return f.err
			}
			for _, b := range f.bulk.messages {
				digest := hash(b)
				if _, exists := released[digest]; exists {
					return errors.New("duplicate unmatched laboratory release")
				}
				released[digest] = observedRelease{f, b}
			}
		case e := <-readDone:
			if e != nil {
				return e
			}
			if len(pending) != 0 || len(released) != 0 || len(observations) != 0 {
				return errors.New("input closed with pending measurements; queued news retained")
			}
			return nil
		}
		if e := match(); e != nil {
			return e
		}
		if len(pending) > 64 || len(released) > 64 {
			return errors.New("bounded measurement correlation queue full")
		}
	}
}
