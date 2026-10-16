package main

// Isolated idle-resource characterization. All roles share one machine; this
// measures protocol processes and TLS streams, not radio energy or anonymity.
import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"time"
)

type idleBoundary struct {
	Role                                        string
	RequestStartMs, RequestEndMs, ProcessCPUms  float64
	ControllerReadBytes, ControllerWrittenBytes uint64
	DatabaseFileBytes                           int64
}

type idleRoleCost struct {
	Role                                                       string
	Before, After                                              idleBoundary
	CPUms, WindowLowerMs, WindowUpperMs                        float64
	OneCorePercentLower, OneCorePercentUpper                   float64
	TLSBytesBothDirections                                     uint64
	StationaryIdleMiBPerDayLower, StationaryIdleMiBPerDayUpper float64
}

func idleCost(before, after idleBoundary) (idleRoleCost, error) {
	r := idleRoleCost{Role: before.Role, Before: before, After: after}
	for _, b := range []idleBoundary{before, after} {
		for _, v := range []float64{b.RequestStartMs, b.RequestEndMs, b.ProcessCPUms} {
			if math.IsNaN(v) || math.IsInf(v, 0) || v < 0 {
				return r, errors.New("invalid idle counter observation")
			}
		}
		if b.RequestEndMs < b.RequestStartMs {
			return r, errors.New("reversed idle observation")
		}
	}
	if before.Role == "" || before.Role != after.Role || after.ProcessCPUms < before.ProcessCPUms || after.ControllerReadBytes < before.ControllerReadBytes || after.ControllerWrittenBytes < before.ControllerWrittenBytes {
		return r, errors.New("idle role/counters changed")
	}
	r.WindowLowerMs = after.RequestStartMs - before.RequestEndMs
	r.WindowUpperMs = after.RequestEndMs - before.RequestStartMs
	if r.WindowLowerMs <= 0 {
		return r, errors.New("idle counter windows overlap")
	}
	r.CPUms = after.ProcessCPUms - before.ProcessCPUms
	r.OneCorePercentLower = 100 * r.CPUms / r.WindowUpperMs
	r.OneCorePercentUpper = 100 * r.CPUms / r.WindowLowerMs
	readDelta, writtenDelta := after.ControllerReadBytes-before.ControllerReadBytes, after.ControllerWrittenBytes-before.ControllerWrittenBytes
	if ^uint64(0)-readDelta < writtenDelta {
		return r, errors.New("idle byte count overflow")
	}
	r.TLSBytesBothDirections = readDelta + writtenDelta
	// Conditional arithmetic projection, not a measured day or a mobile budget.
	r.StationaryIdleMiBPerDayLower = float64(r.TLSBytesBothDirections) * 86400000 / r.WindowUpperMs / (1 << 20)
	r.StationaryIdleMiBPerDayUpper = float64(r.TLSBytesBothDirections) * 86400000 / r.WindowLowerMs / (1 << 20)
	return r, nil
}

func (lab *networkLab) idleBoundary(origin time.Time) ([]idleBoundary, error) {
	rows := make([]idleBoundary, len(lab.nodes))
	errs := make([]error, len(lab.nodes))
	var wg sync.WaitGroup
	for i, n := range lab.nodes {
		wg.Add(1)
		go func(i int, n *remoteRole) {
			defer wg.Done()
			begin := time.Now()
			local, e := n.privateExchange(localIPCRequest{Diagnostics: true})
			read, written := n.counter.read.Load(), n.counter.written.Load()
			end := time.Now()
			if e != nil {
				errs[i] = e
				return
			}
			if local.Diagnostics == nil {
				errs[i] = errors.New("missing private idle counters")
				return
			}
			rows[i] = idleBoundary{Role: n.name, RequestStartMs: ms(begin.Sub(origin)), RequestEndMs: ms(end.Sub(origin)), ProcessCPUms: local.Diagnostics.Stats.CPUms, ControllerReadBytes: read, ControllerWrittenBytes: written, DatabaseFileBytes: local.Diagnostics.Stats.JournalFileBytes}
		}(i, n)
	}
	wg.Wait()
	for _, e := range errs {
		if e != nil {
			return rows, e
		}
	}
	return rows, nil
}

func networkIdleMeasure(profile linkProfile, samples int) (err error) {
	return networkIdleMeasureWithCompletion(profile, samples, false)
}
func networkIdleMeasureWithCompletion(profile linkProfile, samples int, frozenCompletion bool) (err error) {
	if samples < 1 || samples > 300 {
		return errors.New("idle samples must be 1..300")
	}
	lab, err := newNetworkLabCompletion(profile, true, -1, true, true, true, true, frozenCompletion)
	if err != nil {
		return err
	}
	defer lab.close()
	lab.fuseReservationPrepare = true
	origin := time.Now()
	const warmups = 5
	rows := []map[string]any{}
	completed, attempted := 0, 0
	report := map[string]any{
		"schema": 1, "startedUtc": origin.UTC(), "requestedMeasuredRounds": samples, "requestedWarmups": warmups,
		"runtimeOS": runtime.GOOS, "runtimeArch": runtime.GOARCH, "profile": profile,
		"scope":                        "eleven native roles on one emulator; idle common schedule, private pipe CPU observations and controller-side TLS counters; no public path, radio, battery, physical-phone or anonymity acceptance",
		"measurement":                  "CPU windows bounded by private diagnostic request/response times; counter reads included inside those bounds; CPU includes boundary diagnostic work; setup and five warmup rounds excluded from measured deltas",
		"trafficExcludes":              []string{"private pipes", "IP/TCP headers and retransmissions", "discovery", "public news traffic", "radio signalling"},
		"dailyProjection":              "conditional on this idle schedule and topology continuing unchanged for 24 hours; not observed daily consumption or a publisher bandwidth gate",
		"productionIntegrationAllowed": false,
		"frozenCompletion":             frozenCompletion,
	}
	defer func() {
		report["rounds"], report["completedMeasuredRounds"] = rows, completed
		report["attemptedMeasuredRounds"] = attempted
		report["failedMeasuredRounds"] = attempted - completed
		report["unattemptedMeasuredRounds"] = samples - attempted
		if err != nil {
			report["failure"] = err.Error()
		}
		path := filepath.Join(lab.directory, "idle-resources.json")
		if e := saveJSON(path, report); e != nil {
			err = errors.Join(err, e)
		}
		if e := json.NewEncoder(os.Stdout).Encode(map[string]any{"report": path, "completedMeasuredRounds": completed, "requestedMeasuredRounds": samples, "failure": report["failure"]}); e != nil {
			err = errors.Join(err, e)
		}
	}()
	cert, err := lab.installCommonSchedule(4*time.Second, uint64(samples+warmups+2))
	if err != nil {
		return err
	}
	report["schedule"] = cert
	now := time.Now()
	first := now.Add(time.Unix(0, cert.Proposal.StartUnixNano).Sub(now) + 2*scheduleSkew + 50*time.Millisecond)
	var before []idleBoundary
	for round := 0; round < samples+warmups; round++ {
		if round == warmups {
			before, err = lab.idleBoundary(origin)
			if err != nil {
				return err
			}
			report["before"] = before
		}
		due := first.Add(time.Duration(round) * schedulePeriod)
		if wait := time.Until(due); wait > 0 {
			time.Sleep(wait)
		}
		started := time.Now()
		if round >= warmups {
			attempted++
		}
		entry := map[string]any{"round": round, "warmup": round < warmups, "startedLateMs": ms(started.Sub(due))}
		if started.Sub(due) > schedulePeriod {
			err = errors.New("missed idle schedule deadline; no rescheduling")
		} else {
			f := outboxCycle(lab, uint64(round))
			err = f.err
			entry["tlsBytesAllRoleLinks"], entry["phasesMs"] = f.reservation.transportBytes, f.reservation.phaseTimings
			if err == nil && (len(f.reservation.messages) != 0 || len(f.bulk.messages) != 0) {
				err = errors.New("idle workload unexpectedly published")
			}
		}
		entry["elapsedMs"] = ms(time.Since(started))
		if err != nil {
			entry["error"] = err.Error()
		}
		rows = append(rows, entry)
		if err != nil {
			return err
		}
		if round >= warmups {
			completed++
		}
	}
	after, err := lab.idleBoundary(origin)
	if err != nil {
		return err
	}
	report["after"] = after
	costs := make([]idleRoleCost, len(before))
	for i := range before {
		costs[i], err = idleCost(before[i], after[i])
		if err != nil {
			return fmt.Errorf("role %d: %w", i, err)
		}
	}
	report["roleCosts"] = costs
	return nil
}
