package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

func networkDurabilityChecks(profile linkProfile) {
	lab, e := newNetworkLabConfigured(profile, true, -1, true)
	must(e)
	defer lab.close()
	lab.crashReplay = true
	report := map[string]any{"schema": 1, "scope": "actual process termination and same-cohort restoration; controller-managed loopback TLS; not power-loss or malicious disk rollback", "profile": profile, "productionIntegrationAllowed": false, "securityGatePassed": false}
	defer func() {
		report["replayedIdenticalResponsesAfterCrash"] = lab.replayedAfterCrash
		must(saveJSON(filepath.Join(lab.directory, "durability-checks.json"), report))
	}()
	started := time.Now()
	for round := range 3 {
		requests := map[int][]byte{0: {1}, 5: {1}}
		r, e := lab.run(lab.public.reservation(uint64(round)), requests)
		must(e)
		messages := map[int][]byte{0: []byte(fmt.Sprintf("آزمایش بازیابی پس از بسته شدن برنامه؛ پیام فارسی بلند شمارهٔ %d", round)), 5: []byte("پیام نویسندهٔ دوم پس از بازیابی همان گروه")}
		b, e := lab.run(lab.public.bulk(uint64(round), r, maxCell), messages)
		must(e)
		if !samePayloadMultiset(b, messages) {
			panic("durable publication mismatch")
		}
	}
	report["receivedMessages"] = 6
	report["elapsedMsIncludingProcessRestarts"] = ms(time.Since(started))
	report["sameCohort"] = true
	report["passed"] = true
	must(json.NewEncoder(os.Stdout).Encode(map[string]any{"report": filepath.Join(lab.directory, "durability-checks.json"), "receivedMessages": 6, "replayedAfterCrash": lab.replayedAfterCrash}))
}
