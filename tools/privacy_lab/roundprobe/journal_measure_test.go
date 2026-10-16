package main

import "testing"

// Calibrate the resource apparatus against actual role state transitions: a
// durable sample must perform the expected synchronous commits, not accidentally
// measure the memory path, an RPC cache hit or a request that never publishes.
func TestJournalMeasurementUsesFreshRoundsAndRealCommits(t *testing.T) {
	for _, durable := range []bool{false, true} {
		a, e := newJournalArm(t.TempDir(), durable)
		if e != nil {
			t.Fatal(e)
		}
		defer a.close()
		for _, senders := range []int{0, 1, clients} {
			r, e := a.measure(64, senders)
			if e != nil {
				t.Fatal(e)
			}
			if r["verifiedMessages"] != senders {
				t.Fatal("payload verification missing")
			}
			phases := 1
			if senders > 0 {
				phases = 2
			}
			for _, row := range r["roles"].([]roleCost) {
				calls := 2 * phases
				if row.Role == "coordinator" {
					calls = 3 * phases
				}
				if row.Calls != calls {
					t.Fatal("wrong number of actual adapter calls")
				}
				wantCommits := uint64(0)
				if durable {
					wantCommits = uint64(2 * calls)
				}
				if row.Commits != wantCommits {
					t.Fatal("journal not measured for every request")
				}
				if durable && row.EncodedCheckpointBytes == 0 {
					t.Fatal("missing checkpoint bytes")
				}
			}
		}
	}
}
