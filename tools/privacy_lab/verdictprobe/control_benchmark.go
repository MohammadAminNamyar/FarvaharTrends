package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"os"
	"runtime"
	"time"

	control "farvahartrends.local/privacy-lab/verdictprobe/control"
)

func measureControl(samples int, compare bool) {
	start, ct := time.Now(), cpuTime()
	r := control.Roster{Epoch: digest("local component fixture; no anonymous setup")}
	var identities, slotKeys []ed25519.PrivateKey
	for i := range clients + servers {
		p, k, e := ed25519.GenerateKey(rand.Reader)
		must(e)
		identities = append(identities, k)
		if i < clients {
			r.ClientKeys = append(r.ClientKeys, p)
		} else {
			r.CoordinatorKeys = append(r.CoordinatorKeys, p)
		}
	}
	for range clients {
		p, k, e := ed25519.GenerateKey(rand.Reader)
		must(e)
		r.SlotKeys = append(r.SlotKeys, p)
		slotKeys = append(slotKeys, k)
	}
	var cs []*control.Client
	var ss []*control.Coordinator
	var hellos []control.Hello
	for i := range servers {
		s, e := control.NewCoordinator(r, i, identities[clients+i])
		must(e)
		ss = append(ss, s)
		hellos = append(hellos, s.Hello())
	}
	for _, s := range ss {
		must(s.Bind(hellos))
	}
	view, e := control.NewView(r, hellos)
	must(e)
	for i := range clients {
		v, e := control.NewView(r, hellos)
		must(e)
		slot := (i + 3) % clients
		c, e := control.NewClient(v, i, slot, identities[i], slotKeys[slot])
		must(e)
		cs = append(cs, c)
	}
	setupWall, setupCPU := ms(time.Since(start)), ms(cpuTime()-ct)
	var rows []map[string]any
	var walls, cpus []float64
	warmups := 1
	if compare {
		warmups = 2
	}
	modeWalls, modeCPUs := map[string][]float64{}, map[string][]float64{}
	for sample := -warmups; sample < samples; sample++ {
		acceptance := "certified"
		if compare && (sample == -2 || sample >= 0 && (sample%4 == 0 || sample%4 == 3)) {
			acceptance = "full"
		}
		d := control.Descriptor{Session: view.Session(), Sequence: uint64(sample + warmups + 1), Context: digest(fmt.Sprint("component simulated failed round ", sample))}
		for _, c := range cs {
			must(c.Begin(d))
		}
		for _, s := range ss {
			must(s.Begin(d))
		}
		message := make([]byte, control.PayloadBytes)
		_, e = rand.Read(message)
		must(e)
		start, ct = time.Now(), cpuTime()
		var xs []control.Contribution
		var votes []control.Vote
		var shares []control.Share
		var certificates []control.Certificate
		var certifiedOutput []control.Output
		var clientCreate, serverCommit, serverRelease, serverAccept, clientAccept []float64
		var clientCreateCPU, serverCommitCPU, serverReleaseCPU, serverAcceptCPU, clientAcceptCPU []float64
		owner := (sample + warmups) % clients
		for i, c := range cs {
			t, roleCPU := time.Now(), cpuTime()
			var p []byte
			if i == owner {
				p = message
			}
			x, e := c.Prepare(p)
			must(e)
			xs = append(xs, x)
			clientCreate = append(clientCreate, ms(time.Since(t)))
			clientCreateCPU = append(clientCreateCPU, ms(cpuTime()-roleCPU))
		}
		for _, s := range ss {
			t, roleCPU := time.Now(), cpuTime()
			x, e := s.Commit(xs)
			must(e)
			votes = append(votes, x)
			serverCommit = append(serverCommit, ms(time.Since(t)))
			serverCommitCPU = append(serverCommitCPU, ms(cpuTime()-roleCPU))
		}
		for _, s := range ss {
			t, roleCPU := time.Now(), cpuTime()
			x, e := s.Release(votes)
			must(e)
			shares = append(shares, x)
			serverRelease = append(serverRelease, ms(time.Since(t)))
			serverReleaseCPU = append(serverReleaseCPU, ms(cpuTime()-roleCPU))
		}
		for _, s := range ss {
			t, roleCPU := time.Now(), cpuTime()
			out, e := s.Accept(votes, shares)
			must(e)
			if certifiedOutput != nil && !bytes.Equal(encoded(certifiedOutput), encoded(out)) {
				panic("coordinator output mismatch")
			}
			certifiedOutput = out
			certificate, e := s.Certify()
			must(e)
			certificates = append(certificates, certificate)
			serverAccept = append(serverAccept, ms(time.Since(t)))
			serverAcceptCPU = append(serverAcceptCPU, ms(cpuTime()-roleCPU))
		}
		for _, c := range cs {
			t, roleCPU := time.Now(), cpuTime()
			var out []control.Output
			var e error
			if acceptance == "full" {
				out, e = c.Accept(xs, votes, shares)
			} else {
				out, e = c.AcceptCertified(xs, votes, certifiedOutput, certificates)
			}
			must(e)
			for slot, x := range out {
				want := []byte(nil)
				if slot == (owner+3)%clients {
					want = message
				}
				if x.Invalid || !bytes.Equal(x.Payload, want) {
					panic("wrong control payload")
				}
			}
			clientAccept = append(clientAccept, ms(time.Since(t)))
			clientAcceptCPU = append(clientAcceptCPU, ms(cpuTime()-roleCPU))
		}
		wall, used := ms(time.Since(start)), ms(cpuTime()-ct)
		rows = append(rows, map[string]any{"sample": sample, "warmup": sample < 0, "received": true, "allRolesSequentialMs": wall, "processCPUms": used, "clientCreateMs": clientCreate, "serverCommitMs": serverCommit, "serverReleaseMs": serverRelease, "serverAcceptMs": serverAccept, "clientAcceptMs": clientAccept, "clientCreateCPUms": clientCreateCPU, "serverCommitCPUms": serverCommitCPU, "serverReleaseCPUms": serverReleaseCPU, "serverAcceptCPUms": serverAcceptCPU, "clientAcceptCPUms": clientAcceptCPU, "encodedInputBytes": len(encoded(xs)), "encodedVoteBytes": len(encoded(votes)), "encodedShareBytes": len(encoded(shares)), "encodedCertificateBytes": len(encoded(certificates)), "encodedOutputBytes": len(encoded(certifiedOutput))})
		rows[len(rows)-1]["acceptance"] = acceptance
		if sample >= 0 {
			walls = append(walls, wall)
			cpus = append(cpus, used)
			modeWalls[acceptance] = append(modeWalls[acceptance], wall)
			modeCPUs[acceptance] = append(modeCPUs[acceptance], used)
		}
	}
	result := map[string]any{"schema": 2, "candidate": "all-slot verifiable control with per-slot keys, mandatory ephemeral proofs, unanimous output certificates", "acceptance": "each coordinator verifies every proof; clients authenticate inputs, own inclusion, all votes and three output certificates", "os": runtime.GOOS, "arch": runtime.GOARCH, "runtime": runtime.Version(), "requestedSamples": samples, "warmups": 1, "payloadBytesPerSlot": control.PayloadBytes, "slots": clients, "scope": "eight clients and three coordinators including all-role acceptance, sequentially on one device; central fixture roster/slot assignment; no network or fault-audit semantics", "setupWallMs": setupWall, "setupCPUms": setupCPU, "wallSummary": stats(walls), "cpuSummary": stats(cpus), "rows": rows, "securityGatePassed": false, "productionIntegrationAllowed": false, "excludes": []string{"anonymous setup", "normal publication", "fault generation and bit reports", "network coordination", "radio and battery", "admission and intersection defenses", "durable state and resumed publication"}}
	if compare {
		delete(result, "wallSummary")
		delete(result, "cpuSummary")
		result["warmups"] = warmups
		result["acceptance"] = "ABBA comparison: A every client verifies all proofs; B clients require unanimous coordinator certificates; same live roster, one binary, sequential sessions"
		byMode := map[string]any{}
		for _, mode := range []string{"full", "certified"} {
			byMode[mode] = map[string]any{"samples": len(modeWalls[mode]), "wallSummary": stats(modeWalls[mode]), "cpuSummary": stats(modeCPUs[mode])}
		}
		result["byAcceptance"] = byMode
	}
	must(json.NewEncoder(os.Stdout).Encode(result))
}
