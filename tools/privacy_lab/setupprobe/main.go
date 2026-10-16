package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"flag"
	"math"
	"os"
	"runtime"
	"sort"
	"time"

	"farvahartrends.local/privacy-lab/setupprobe/setup"
)

func must(e error) {
	if e != nil {
		panic(e)
	}
}
func ms(d time.Duration) float64 { return float64(d) / float64(time.Millisecond) }
func stats(v []float64) map[string]float64 {
	x := append([]float64{}, v...)
	sort.Float64s(x)
	q := func(p float64) float64 { return x[max(0, int(math.Ceil(p*float64(len(x))))-1)] }
	return map[string]float64{"p50Ms": q(.5), "p95Ms": q(.95), "p99Ms": q(.99), "maxMs": q(1)}
}
func run() map[string]any {
	start, cpu := time.Now(), cpuTime()
	phase := time.Now()
	r := setup.Roster{Version: 1, Policy: "fixed eight clients / all three coordinators / lab only"}
	var clients []*setup.Client
	var servers []*setup.Coordinator
	var hellos []setup.Hello
	for i := range setup.Clients {
		p, k, e := ed25519.GenerateKey(rand.Reader)
		must(e)
		c, e := setup.NewClient(i, k)
		must(e)
		clients = append(clients, c)
		r.ClientKeys = append(r.ClientKeys, p)
		hellos = append(hellos, c.Hello())
	}
	for j := range setup.Coordinators {
		p, k, e := ed25519.GenerateKey(rand.Reader)
		must(e)
		c, e := setup.NewCoordinator(j, k)
		must(e)
		servers = append(servers, c)
		r.CoordinatorKeys = append(r.CoordinatorKeys, p)
		hellos = append(hellos, c.Hello())
	}
	created := ms(time.Since(phase))
	phase = time.Now()
	for _, c := range clients {
		must(c.Bind(r, hellos))
	}
	for _, c := range servers {
		must(c.Bind(r, hellos))
	}
	bound := ms(time.Since(phase))
	phase = time.Now()
	var inputs []setup.Input
	for _, c := range clients {
		i, e := c.Input()
		must(e)
		inputs = append(inputs, i)
	}
	inputMs := ms(time.Since(phase))
	phase = time.Now()
	t := setup.Transcript{Epoch: inputs[0].Epoch, Inputs: inputs}
	for _, c := range servers {
		m, e := c.Mix(t)
		must(e)
		t.Mixes = append(t.Mixes, m)
	}
	mixed := ms(time.Since(phase))
	phase = time.Now()
	packet := setup.Release{Transcript: t}
	for _, c := range servers {
		v, e := c.Commit(t)
		must(e)
		packet.Votes = append(packet.Votes, v)
	}
	committed := ms(time.Since(phase))
	phase = time.Now()
	for _, c := range servers {
		v, e := c.Release(t, packet.Votes)
		must(e)
		packet.Shares = append(packet.Shares, v)
	}
	released := ms(time.Since(phase))
	phase = time.Now()
	var cm []setup.ClientMaterial
	var sm []setup.CoordinatorMaterial
	for _, c := range clients {
		must(c.Accept(packet))
		m, e := c.Material()
		must(e)
		cm = append(cm, m)
	}
	for _, c := range servers {
		must(c.Accept(packet))
		m, e := c.Material()
		must(e)
		sm = append(sm, m)
	}
	for i := range setup.Clients {
		for j := range setup.Coordinators {
			if cm[i].Seeds[j] != sm[j].Seeds[i] {
				panic("actual DH material mismatch")
			}
		}
	}
	accepted := ms(time.Since(phase))
	elapsed, used := ms(time.Since(start)), ms(cpuTime()-cpu)
	wire, e := json.Marshal(packet)
	must(e)
	return map[string]any{"allRolesSequentialMs": elapsed, "processCPUms": used, "generateMs": created, "bindMs": bound, "inputMs": inputMs, "mixMs": mixed, "commitMs": committed, "releaseMs": released, "acceptAllRolesMs": accepted, "encodedReleaseBytes": len(wire), "accepted": true}
}
func main() {
	samples := flag.Int("samples", 10, "measured complete setups after one warmup")
	payload := flag.Int("payload", 32, "fixed public slot-key bytes")
	cohort := flag.Int("cohort", 8, "fixed clients")
	hops := flag.Int("hops", 3, "fixed coordinators")
	flag.Parse()
	if *samples < 1 || *samples > 50 || *payload != 32 || *cohort != 8 || *hops != 3 {
		panic("invalid setup workload")
	}
	var rows []map[string]any
	var wall, cpu []float64
	for i := -1; i < *samples; i++ {
		r := run()
		r["sample"] = i
		r["warmup"] = i < 0
		rows = append(rows, r)
		if i >= 0 {
			wall = append(wall, r["allRolesSequentialMs"].(float64))
			cpu = append(cpu, r["processCPUms"].(float64))
		}
	}
	must(json.NewEncoder(os.Stdout).Encode(map[string]any{"schema": 1, "os": runtime.GOOS, "arch": runtime.GOARCH, "runtime": runtime.Version(), "scope": "all eleven local role objects sequentially; independently generated role secrets, verifiable slot shuffle and all-coordinator decryption; no network/admission or crash journal", "requestedSamples": *samples, "warmups": 1, "rows": rows, "wallSummary": stats(wall), "cpuSummary": stats(cpu), "securityGatePassed": false, "productionIntegrationAllowed": false}))
}
