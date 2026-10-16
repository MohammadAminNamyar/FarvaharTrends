package main

import (
	"bytes"
	"strings"
	"testing"
	"time"
)

func TestNearestRankQuantiles(t *testing.T) {
	// p95 of 20 values is the 19th, not the 20th observation.
	values := make([]float64, 20)
	for i := range values {
		values[i] = float64(20 - i)
	}
	s := summarize(values)
	if s.N != 20 || s.P50 != 10 || s.P95 != 19 || s.P99 != 20 || s.Max != 20 {
		t.Fatalf("unexpected quantiles: %+v", s)
	}
	if values[0] != 20 {
		t.Fatal("summarize modified the raw observations")
	}
}

func TestEmptySamplesCannotProducePassingLatency(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("empty observations must not report zero latency")
		}
	}()
	summarize(nil)
}

func TestOriginalCandidateFailsActiveIsolation(t *testing.T) {
	r := newBatchRoute(3, 4096)
	finding := r.isolateAttack()
	if finding["targetInputLinkedToPublication"] != true || finding["securityGatePassed"] != false {
		t.Fatalf("known design failure was hidden: %+v", finding)
	}
}

func TestRealPayloadTraversesThreeSockets(t *testing.T) {
	r := newBatchRoute(3, 4096)
	c, arrivals, stop, metrics, failures := r.network(0)
	defer stop()
	payload := []byte("خبر آزمایشی با متن فارسی — exact bytes after all hops")
	for i := 0; i < cohort; i++ {
		packet := r.packet(1, false, 0)
		if i == 0 {
			packet = r.payloadPacket(1, payload)
		}
		if e := writeAll(c, packet); e != nil {
			t.Fatal(e)
		}
	}
	select {
	case got := <-arrivals:
		body, e := unpackArrival(got)
		if e != nil || !bytes.Equal(body, payload) {
			t.Fatalf("release mismatch: %v", e)
		}
		expected := uint64(cohort * 3 * r.s.Geometry().PacketLength)
		if metrics.read.Load() != expected || metrics.written.Load() != expected {
			t.Fatalf("read=%d written=%d expected=%d", metrics.read.Load(), metrics.written.Load(), expected)
		}
	case e := <-failures:
		t.Fatal(e)
	case <-time.After(3 * time.Second):
		t.Fatal("no release")
	}
}

func TestReplayAndCorruptionNeverRelease(t *testing.T) {
	for _, attack := range []string{"replay", "corruption", "partial-frame-disconnect"} {
		t.Run(attack, func(t *testing.T) {
			r := newBatchRoute(3, 4096)
			c, arrivals, stop, _, failures := r.network(0)
			defer stop()
			packet := r.payloadPacket(1, []byte("lab only"))
			if attack == "partial-frame-disconnect" {
				if e := writeAll(c, packet[:100]); e != nil {
					t.Fatal(e)
				}
				c.Close()
			} else {
				if attack == "corruption" {
					packet[len(packet)-1] ^= 1
				}
				for i := 0; i < cohort; i++ {
					p := r.packet(2, false, 0)
					if i == 0 || (attack == "replay" && i == 1) {
						p = packet
					}
					if e := writeAll(c, p); e != nil {
						break
					}
				}
			}
			select {
			case e := <-failures:
				if attack == "replay" && !strings.Contains(e.Error(), "replay") {
					t.Fatal(e)
				}
			case <-arrivals:
				t.Fatal("failed batch released an application action")
			case <-time.After(3 * time.Second):
				t.Fatal("failure was not observed")
			}
			select {
			case <-arrivals:
				t.Fatal("action escaped after error")
			default:
			}
		})
	}
}
