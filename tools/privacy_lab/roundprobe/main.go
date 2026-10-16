package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"os"
	"runtime"
	"sort"
	"time"
)

func ms(t time.Duration) float64 { return float64(t) / float64(time.Millisecond) }
func stats(a []float64) map[string]float64 {
	if len(a) == 0 {
		panic("empty samples")
	}
	b := append([]float64{}, a...)
	sort.Float64s(b)
	q := func(p float64) float64 { return b[int(math.Ceil(p*float64(len(b))))-1] }
	return map[string]float64{"p50Ms": q(.5), "p95Ms": q(.95), "p99Ms": q(.99), "maxMs": q(1)}
}
func measure(samples, size, senders int) map[string]interface{} {
	f := newFixtureWithLimit(clients)
	rows := []map[string]interface{}{}
	durations := []float64{}
	var wallStart time.Time
	var cpuStart time.Duration
	up, down, coord := 0, 0, 0
	for i := -20; i < samples; i++ {
		if i == 0 {
			wallStart = time.Now()
			cpuStart = cpuTime()
		}
		round := uint64(i + 20)
		requests := map[int][]byte{}
		payloads := map[int][]byte{}
		for sender := range senders {
			client := (i + 20 + sender) % clients
			requests[client] = []byte{1}
			payloads[client] = payloadFixture(size)
		}
		started := time.Now()
		r, e := f.runMany(f.reservation(round), requests)
		must(e)
		reserveEnd := time.Now()
		rUp, rDown, rCoord := r.clientUp, r.clientDown, r.interCoordinator
		if senders > 0 {
			b, e := f.runMany(f.bulk(round, r, maxCell), payloads)
			must(e)
			if len(b.messages) != senders {
				panic("publication count mismatch")
			}
			for sender, payload := range payloads {
				if !bytes.Equal(b.messages[f.ownerSlot[sender]], payload) {
					panic("wrong payload")
				}
			}
			rUp += b.clientUp
			rDown += b.clientDown
			rCoord += b.interCoordinator
		}
		finished := time.Now()
		elapsed := ms(finished.Sub(started))
		if i >= 0 {
			durations = append(durations, elapsed)
			rows = append(rows, map[string]interface{}{"sample": i, "totalMs": elapsed, "reservationMs": ms(reserveEnd.Sub(started)), "bulkMs": ms(finished.Sub(reserveEnd)), "clientUpEncodedBytes": rUp, "clientDownEncodedBytes": rDown, "interCoordinatorEncodedBytes": rCoord})
			up += rUp
			down += rDown
			coord += rCoord
		}
	}
	cpu := cpuTime() - cpuStart
	wall := time.Since(wallStart)
	return map[string]interface{}{"samples": samples, "warmups": 20, "simultaneousPublishers": senders, "rows": rows, "allRolesSequential": stats(durations), "processCpuMs": ms(cpu), "phaseWallMs": ms(wall), "clientUpEncodedBytes": up, "clientDownEncodedBytes": down, "interCoordinatorEncodedBytes": coord, "meanAllRoleCpuMsPerRound": ms(cpu) / float64(samples)}
}
func main() {
	mode := flag.String("mode", "component", "component, pipe-lab, node or network")
	config := flag.String("config", "", "role config for node mode")
	listen := flag.String("listen", "127.0.0.1:0", "loopback listener")
	publishers := flag.Int("publishers", 1, "simultaneous network publishers: 0, 1 or 8")
	kbps := flag.Int("kbps", 0, "test pacing per role socket/direction; zero disables")
	rtt := flag.Int("rtt-ms", 0, "additional test latency per RPC")
	wire := flag.String("wire", "json", "laboratory RPC wire format: json, cbor-v1 or cbor-framed-v1")
	samples := flag.Int("samples", 300, "round pairs per active/idle workload")
	size := flag.Int("payload", 4288, "actual bulletin bundle bytes")
	cohort := flag.Int("cohort", 8, "fixed laboratory cohort")
	hops := flag.Int("hops", 3, "fixed coordinator count, not hop count")
	flag.Parse()
	profile := linkProfile{Kbps: *kbps, RoundTripMs: *rtt, WireCodec: *wire}
	requireProfile(profile)
	if *mode == "network-schedule-idle" || *mode == "network-frozen-idle" {
		must(networkIdleMeasureWithCompletion(profile, *samples, *mode == "network-frozen-idle"))
		return
	}
	if *mode == "network-schedule-pipe" || *mode == "network-schedule-fused-pipe" || *mode == "network-schedule-atomic-pipe" || *mode == "network-frozen-pipe" {
		frozen := *mode == "network-frozen-pipe"
		lab, e := newNetworkLabCompletion(profile, true, -1, true, true, true, *mode == "network-schedule-atomic-pipe" || frozen, frozen)
		must(e)
		defer lab.close()
		lab.fuseReservationPrepare = *mode != "network-schedule-pipe"
		lead := 4 * time.Second
		if frozen {
			// Admission still requires all signatures and live role clocks before
			// the cutoff. Startup is measured; missed admission fails closed.
			lead = 2 * time.Second
		}
		certificate, e := lab.installCommonSchedule(lead, scheduleMaxRounds)
		must(e)
		must(pipeOutboxLabWithSchedule(lab, &certificate))
		return
	}
	if *mode == "network-schedule-checks" {
		networkScheduleChecks(profile)
		return
	}
	if *mode == "network-schedule-fused-checks" {
		networkScheduleChecksWithFusion(profile, true)
		return
	}
	if *mode == "network-schedule-atomic-checks" {
		networkScheduleChecksWithStorage(profile, true, true)
		return
	}
	if *mode == "network-frozen-checks" {
		networkScheduleChecksWithCompletion(profile, true, true, true)
		return
	}
	if *mode == "network-outbox-pipe" {
		lab, e := newNetworkLabConfiguredOutbox(profile, true, -1, true, true)
		must(e)
		defer lab.close()
		must(pipeOutboxLab(lab))
		return
	}
	if *mode == "network-outbox-checks" {
		networkOutboxChecks(profile)
		return
	}
	if *mode == "journal-compare" {
		if *samples < 4 || *samples > 40 || *samples%4 != 0 || *size < 32 || *size > maxCell-cellNonceSize-66 {
			panic("journal comparison requires 4..40 samples in complete ABBA blocks and a supported payload")
		}
		journalCompare(*samples, *size)
		return
	}
	if *mode == "network-control-checks" {
		networkControlChecks(profile)
		return
	}
	if *mode == "network-durability-checks" {
		networkDurabilityChecks(profile)
		return
	}
	if *mode == "network-control-durable-checks" {
		networkControlChecksWithDurability(profile, true)
		return
	}
	if *mode == "network-pipe" || *mode == "network-setup-pipe" || *mode == "network-durable-pipe" {
		lab, e := newNetworkLabConfigured(profile, *mode != "network-pipe", -1, *mode == "network-durable-pipe")
		must(e)
		defer lab.close()
		pipeWithBackend(lab.public, lab.run, lab)
		return
	}
	if *mode == "network-checks" || *mode == "network-setup-checks" {
		networkChecksWithSetup(*mode == "network-setup-checks")
		return
	}
	if *mode == "node" {
		must(serveRole(*config, *listen, *wire))
		return
	}
	if *mode == "network" || *mode == "network-setup" {
		if *samples < 1 || *samples > 300 || *size < 32 || *size > maxCell-cellNonceSize-66 || (*publishers != 0 && *publishers != 1 && *publishers != clients) {
			panic("invalid network workload")
		}
		networkMeasureWithSetup(*samples, *size, *publishers, profile, *mode == "network-setup")
		return
	}
	if *mode == "pipe-lab" {
		pipeLab()
		return
	}
	if *mode != "component" {
		unsupportedMode(*mode)
	}
	if *samples < 1 || *samples > 20000 || *size < 32 || *size > maxCell-cellNonceSize-66 || *cohort != clients || *hops != coordinators {
		panic("unsupported component workload")
	}
	result := map[string]interface{}{"schema": 1, "component": "fixed-cohort reservation and DC-net bulk round experiment", "os": runtime.GOOS, "arch": runtime.GOARCH, "runtime": runtime.Version(), "cohort": clients, "coordinators": coordinators, "payloadBytes": *size, "reservationCellBytes": reservationCell, "bulkCellBytes": maxCell, "scope": "all roles sequentially in one process with centrally assigned slots and shared seeds; encoded bytes, no socket or scheduled waiting", "productionIntegrationAllowed": false, "securityGatePassed": false, "missing": []string{"distributed anonymous slot setup", "authenticated DH and durable state", "Sybil resistance", "proactive jam proof or safe blame", "long-term intersection defense", "network and radio", "traffic-correlation evaluation", "battery", "full application pipeline"}}
	result["schema"] = 2
	result["maxBulkSlots"] = clients
	result["idle"] = measure(*samples, *size, 0)
	result["onePublication"] = measure(*samples, *size, 1)
	result["eightPublications"] = measure(*samples, *size, clients)
	raw, e := json.MarshalIndent(result, "", "  ")
	must(e)
	fmt.Fprintln(os.Stdout, string(raw))
}
