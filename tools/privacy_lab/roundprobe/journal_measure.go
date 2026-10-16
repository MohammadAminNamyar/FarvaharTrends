package main

// Measurements of the actual role adapters and synchronized journal on one
// device. No transport, slot waiting, anonymous setup or battery claim.
import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"time"
)

type roleCost struct {
	Role                            string
	Index                           int
	Calls                           int
	WallMs, CPUms                   float64
	Commits, EncodedCheckpointBytes uint64
}

type journalArm struct {
	lab   *networkLab
	nodes []*roleNode
	rows  []roleCost
	next  uint64
}

func newJournalArm(root string, durable bool) (*journalArm, error) {
	a := &journalArm{lab: &networkLab{public: newFixtureWithLimit(clients)}}
	for id := range clients + coordinators {
		role, index := "client", id
		if id >= clients {
			role, index = "coordinator", id-clients
		}
		c := configFor(a.lab.public, role, index)
		c.Durable = durable
		var n *roleNode
		var e error
		if durable {
			n, e = openDurableRole(c, filepath.Join(root, fmt.Sprintf("%s-%d", role, index)))
		} else {
			n, e = newRoleNode(c)
		}
		if e != nil {
			a.close()
			return nil, e
		}
		a.nodes = append(a.nodes, n)
	}
	a.lab.componentCall = func(id int, q rpcRequest) (rpcResponse, error) {
		n := a.nodes[id]
		row := &a.rows[id]
		var commits, encoded uint64
		if n.journal != nil {
			commits, encoded = n.journal.commits, n.journal.plaintextBytes
		}
		started, cpu := time.Now(), cpuTime()
		r, e := n.handle(q)
		row.CPUms += ms(cpuTime() - cpu)
		row.WallMs += ms(time.Since(started))
		row.Calls++
		if n.journal != nil {
			row.Commits += n.journal.commits - commits
			row.EncodedCheckpointBytes += n.journal.plaintextBytes - encoded
		}
		return r, e
	}
	return a, nil
}

func (a *journalArm) close() {
	for _, n := range a.nodes {
		if n.journal != nil {
			_ = n.journal.close()
		}
	}
}

func (a *journalArm) measure(size, senders int) (map[string]interface{}, error) {
	a.rows = make([]roleCost, len(a.nodes))
	for i, n := range a.nodes {
		a.rows[i].Role = n.config.Role
		a.rows[i].Index = n.config.Index
	}
	requests, payloads := map[int][]byte{}, map[int][]byte{}
	for i := range senders {
		id := (int(a.next) + i) % clients
		requests[id] = []byte{1}
		payloads[id] = payloadFixture(size)
	}
	started, cpu := time.Now(), cpuTime()
	r, e := a.lab.run(a.lab.public.reservation(a.next), requests)
	if e != nil {
		return nil, e
	}
	if senders > 0 {
		var b result
		b, e = a.lab.run(a.lab.public.bulk(a.next, r, maxCell), payloads)
		if e != nil {
			return nil, e
		}
		if !samePayloadMultiset(b, payloads) {
			return nil, fmt.Errorf("durable component changed payloads")
		}
	}
	cpuMs, wallMs := ms(cpuTime()-cpu), ms(time.Since(started))
	a.next++
	return map[string]interface{}{"wallMs": wallMs, "processCPUms": cpuMs, "roles": a.rows, "verifiedMessages": senders}, nil
}

func journalCompare(samples, size int) {
	root, e := os.MkdirTemp("", "farvahar-journal-compare-")
	must(e)
	defer os.RemoveAll(root) // Fresh, exclusively owned temporary directory.
	report := map[string]interface{}{
		"schema": 1, "os": runtime.GOOS, "arch": runtime.GOARCH, "runtime": runtime.Version(),
		"scope":              "actual role adapters, all eleven roles sequential on one device; isolated memory/durable epochs, ABBA order; no network, scheduled wait, anonymous setup, APK or battery",
		"securityGatePassed": false, "productionIntegrationAllowed": false,
		"samplesPerWorkload": samples, "samplesPerMode": samples / 2, "warmupsPerModePerWorkload": 1, "payloadBytes": size,
		"roleCPUCaveat": "same process, runtime/GC overhead can cross call boundaries; role observations within a round are not independent devices",
	}
	workloads := []map[string]interface{}{}
	for _, senders := range []int{0, 1, clients} {
		dir := filepath.Join(root, fmt.Sprintf("publishers-%d", senders))
		must(os.Mkdir(dir, 0700))
		memory, e := newJournalArm(dir, false)
		must(e)
		defer memory.close()
		durable, e := newJournalArm(dir, true)
		must(e)
		defer durable.close()
		arms := []*journalArm{memory, durable}
		rows := []map[string]interface{}{}
		times, cpus := [2][]float64{}, [2][]float64{}
		for i := -2; i < samples; i++ {
			arm := i % 4
			if i < 0 {
				arm = i + 2
			} else if arm == 0 || arm == 3 {
				arm = 0
			} else {
				arm = 1
			}
			row, e := arms[arm].measure(size, senders)
			must(e)
			row["sample"], row["warmup"], row["mode"] = i, i < 0, []string{"memory", "durable"}[arm]
			rows = append(rows, row)
			if i >= 0 {
				times[arm] = append(times[arm], row["wallMs"].(float64))
				cpus[arm] = append(cpus[arm], row["processCPUms"].(float64))
			}
		}
		final := []rpcResponse{}
		for _, n := range durable.nodes {
			r, e := n.handle(rpcRequest{Op: "stats"})
			must(e)
			final = append(final, r)
		}
		workloads = append(workloads, map[string]interface{}{"simultaneousPublishers": senders, "rows": rows, "memoryAllRoleWall": stats(times[0]), "durableAllRoleWall": stats(times[1]), "memoryAllRoleCPU": stats(cpus[0]), "durableAllRoleCPU": stats(cpus[1]), "durableFinalStatsIncludingWarmupsAndInitialization": final})
		memory.close()
		durable.close()
	}
	must(os.RemoveAll(root))
	report["workloads"] = workloads
	report["completed"] = true
	report["temporaryDatabasesRemoved"] = true
	b, e := json.MarshalIndent(report, "", "  ")
	must(e)
	fmt.Println(string(b))
}
