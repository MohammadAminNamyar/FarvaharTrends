package main

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"os"
	"runtime"
	"sort"
	"time"
)

func stats(values []float64) map[string]float64 {
	x := append([]float64{}, values...)
	sort.Float64s(x)
	q := func(p float64) float64 { return x[max(0, int(math.Ceil(p*float64(len(x))))-1)] }
	return map[string]float64{"p50Ms": q(.5), "p95Ms": q(.95), "p99Ms": q(.99), "maxMs": q(1)}
}
func main() {
	mode := flag.String("mode", "component", "component, control, or control-compare")
	samples := flag.Int("samples", 30, "measured slot rounds after 3 warmups")
	size := flag.Int("payload", 32, "payload bytes in one anonymous slot")
	cohort := flag.Int("cohort", 8, "fixed eight-client laboratory roster")
	hops := flag.Int("hops", 3, "fixed three-server laboratory roster")
	flag.Parse()
	if *samples < 1 || *samples > 300 || *size < 1 || *size > 8192 || *cohort != clients || *hops != servers {
		panic("invalid workload")
	}
	if *mode == "control" || *mode == "control-compare" {
		if *size != 128 {
			panic("control payload is fixed at 128 bytes per slot")
		}
		if *mode == "control-compare" && *samples%4 != 0 {
			panic("comparison needs complete ABBA blocks")
		}
		measureControl(*samples, *mode == "control-compare")
		return
	}
	if *mode != "component" {
		panic("unknown experiment mode")
	}
	started := time.Now()
	cpu := cpuTime()
	f := newFixture()
	setupWall, setupCPU := ms(time.Since(started)), ms(cpuTime()-cpu)
	var rows []map[string]any
	var timings, cpus []float64
	for sample := -3; sample < *samples; sample++ {
		d := descriptor{f.epoch, uint64(sample + 4), (sample + 3) % clients, *size}
		message := make([]byte, *size)
		_, e := rand.Read(message)
		must(e)
		start, ct := time.Now(), cpuTime()
		var input []contribution
		var output []share
		var clientTimes, serverTimes []float64
		for i := range clients {
			t := time.Now()
			var m []byte
			if i == d.Slot {
				m = message
			}
			c, e := f.create(d, i, m)
			must(e)
			input = append(input, c)
			clientTimes = append(clientTimes, ms(time.Since(t)))
		}
		for i := range servers {
			t := time.Now()
			v, e := f.release(d, i, input)
			must(e)
			output = append(output, v)
			serverTimes = append(serverTimes, ms(time.Since(t)))
		}
		revealStart := time.Now()
		got, e := f.reveal(d, input, output)
		must(e)
		if !bytes.Equal(got, message) {
			panic("actual payload mismatch")
		}
		revealMs := ms(time.Since(revealStart))
		elapsed, used := ms(time.Since(start)), ms(cpuTime()-ct)
		row := map[string]any{"sample": sample, "warmup": sample < 0, "allRolesSequentialMs": elapsed, "processCPUms": used, "clientCreateMs": clientTimes, "serverVerifyAndReleaseMs": serverTimes, "oneRecipientVerifyAndRevealMs": revealMs, "encodedInputBytes": len(encoded(input)), "encodedShareBytes": len(encoded(output)), "received": true}
		rows = append(rows, row)
		if sample >= 0 {
			timings = append(timings, elapsed)
			cpus = append(cpus, used)
		}
	}
	result := map[string]any{"schema": 1, "os": runtime.GOOS, "arch": runtime.GOARCH, "runtime": runtime.Version(), "candidate": "Verdict section 5.2 ElGamal primitive via Kyber v4.0.2", "scope": "one anonymous slot: all eight clients, three verifying servers and one verifying recipient sequentially in one process; centrally provisioned fixture", "payloadBytes": *size, "pointPayloadBytes": f.s.Point().EmbedLen(), "requestedSamples": *samples, "warmups": 3, "setupWallMs": setupWall, "setupCPUms": setupCPU, "rows": rows, "wallSummary": stats(timings), "cpuSummary": stats(cpus), "securityGatePassed": false, "productionIntegrationAllowed": false, "excludes": []string{"anonymous setup", "network and consensus", "slot scheduling", "all-slot workload", "phone radio/battery", "Sybil/churn/intersection defense", "safe exclusion and recovery", "application signing/outbox/public delivery"}}
	if e := json.NewEncoder(os.Stdout).Encode(result); e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(1)
	}
}
