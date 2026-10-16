package main

import (
	"math"
	"testing"
)

func TestIdleResourceIntervalsRetainObservationUncertainty(t *testing.T) {
	b := idleBoundary{Role: "client-0", RequestStartMs: 100, RequestEndMs: 110, ProcessCPUms: 20, ControllerReadBytes: 40, ControllerWrittenBytes: 60}
	a := idleBoundary{Role: "client-0", RequestStartMs: 1100, RequestEndMs: 1110, ProcessCPUms: 220, ControllerReadBytes: 140, ControllerWrittenBytes: 260}
	r, e := idleCost(b, a)
	if e != nil || r.WindowLowerMs != 990 || r.WindowUpperMs != 1010 || r.CPUms != 200 || r.TLSBytesBothDirections != 300 {
		t.Fatal("incorrect private observation accounting", r, e)
	}
	if r.OneCorePercentLower >= 20 || r.OneCorePercentUpper <= 20 || r.StationaryIdleMiBPerDayLower >= r.StationaryIdleMiBPerDayUpper {
		t.Fatal("uncertainty was collapsed to a point", r)
	}
	bad := []idleBoundary{a, a, a, a, a, a, a, a, a, a}
	bad[0].Role = "client-1"
	bad[1].RequestEndMs = 1090
	bad[2].RequestStartMs = 105
	bad[3].ProcessCPUms = 19
	bad[4].ControllerReadBytes = 39
	bad[5].ControllerWrittenBytes = 59
	bad[6].ProcessCPUms = math.NaN()
	bad[7].RequestEndMs = math.Inf(1)
	bad[8].RequestStartMs = -1
	bad[9].ControllerReadBytes, bad[9].ControllerWrittenBytes = ^uint64(0), ^uint64(0)
	for i, x := range bad {
		if _, e := idleCost(b, x); e == nil {
			t.Fatalf("invalid idle observation %d accepted", i)
		}
	}
	if _, e := idleCost(idleBoundary{}, a); e == nil {
		t.Fatal("missing start observation accepted")
	}
}
