// Research-only Sphinx cost measurement. Not a mixnet or anonymity claim.
package main

import (
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"os"
	"runtime"
	"sort"
	"time"

	"github.com/katzenpost/hpqc/kem/schemes"
	"github.com/katzenpost/hpqc/nike/x25519"
	"github.com/katzenpost/katzenpost/core/sphinx"
	"github.com/katzenpost/katzenpost/core/sphinx/commands"
	"github.com/katzenpost/katzenpost/core/sphinx/geo"
)

type stats struct {
	N   int     `json:"n"`
	P50 float64 `json:"p50Ms"`
	P95 float64 `json:"p95Ms"`
	P99 float64 `json:"p99Ms"`
	Max float64 `json:"maxMs"`
}

func summarize(x []float64) stats {
	if len(x) == 0 {
		panic("no measured observations")
	}
	y := append([]float64{}, x...)
	sort.Float64s(y)
	q := func(p float64) float64 {
		i := int(math.Ceil(p*float64(len(y)))) - 1
		if i < 0 {
			i = 0
		}
		if i >= len(y) {
			i = len(y) - 1
		}
		return y[i]
	}
	return stats{len(y), q(.5), q(.95), q(.99), y[len(y)-1]}
}
func must(err error) {
	if err != nil {
		panic(err)
	}
}
func ms(d time.Duration) float64 { return float64(d) / float64(time.Millisecond) }

func main() {
	mode := flag.String("mode", "crypto", "crypto, batch-lab or pipe-lab (isolated research)")
	n := flag.Int("samples", 2000, "measured packets after 50 warmups")
	size := flag.Int("payload", 4096, "fixed application payload size")
	hops := flag.Int("hops", 3, "mix hops, excludes gateway/service")
	scheme := flag.String("scheme", "x25519", "x25519 or xwing")
	flag.Parse()
	if *n < 1 || *n > 20000 || *size < 32 || *size > 32768 || *hops < 1 || *hops > 5 {
		panic("invalid workload")
	}
	if *mode == "pipe-lab" {
		runPipeLab(*size, *hops)
		return
	}
	if *mode == "batch-lab" {
		runBatchLab(*n, *size, *hops)
		return
	}
	if *mode != "crypto" {
		panic("unknown mode")
	}
	var s *sphinx.Sphinx
	var g *geo.Geometry
	path := make([]*sphinx.PathHop, *hops)
	keys := make([]interface{}, *hops)
	nike := x25519.Scheme(rand.Reader)
	kem := schemes.ByName("Xwing")
	switch *scheme {
	case "x25519":
		g = geo.GeometryFromUserForwardPayloadLength(nike, *size, false, *hops)
		s = sphinx.NewNIKESphinx(nike, g)
	case "xwing":
		g = geo.KEMGeometryFromUserForwardPayloadLength(kem, *size, false, *hops)
		s = sphinx.NewSphinx(g)
	default:
		panic("unknown scheme")
	}
	for i := range path {
		h := new(sphinx.PathHop)
		_, err := rand.Read(h.ID[:])
		must(err)
		if *scheme == "x25519" {
			pub, priv, err := nike.GenerateKeyPair()
			must(err)
			h.NIKEPublicKey = pub
			keys[i] = priv
		} else {
			pub, priv, err := kem.GenerateKeyPair()
			must(err)
			h.KEMPublicKey = pub
			keys[i] = priv
		}
		if i == len(path)-1 {
			r := new(commands.Recipient)
			_, err = rand.Read(r.ID[:])
			must(err)
			h.Commands = []commands.RoutingCommand{r}
		} else {
			h.Commands = []commands.RoutingCommand{&commands.NodeDelay{Delay: 0}}
		}
		path[i] = h
	}
	payload := make([]byte, *size)
	_, err := rand.Read(payload)
	must(err)
	create := make([]float64, 0, *n)
	unwrap := make([]float64, 0, *n)
	total := make([]float64, 0, *n)
	var cpuStart, phaseStart time.Duration
	var wallStart time.Time
	var finalPacket []byte
	for i := -50; i < *n; i++ {
		if i == 0 {
			cpuStart = cpuTime()
			wallStart = time.Now()
		}
		binary.BigEndian.PutUint64(payload[:8], uint64(i+50))
		a := time.Now()
		pkt, err := s.NewPacket(rand.Reader, path, payload)
		must(err)
		b := time.Now()
		if i == *n-1 {
			finalPacket = append([]byte{}, pkt...)
		}
		var body []byte
		for j := range path {
			body, _, _, err = s.Unwrap(keys[j], pkt)
			must(err)
		}
		c := time.Now()
		if !bytes.Equal(body, payload) {
			panic("payload mismatch")
		}
		if i >= 0 {
			create = append(create, ms(b.Sub(a)))
			unwrap = append(unwrap, ms(c.Sub(b)))
			total = append(total, ms(c.Sub(a)))
		}
	}
	phaseStart = cpuTime() - cpuStart
	measuredWall := time.Since(wallStart)
	// Payload tampering must be rejected by the end of the route.
	tampered := append([]byte{}, finalPacket...)
	tampered[len(tampered)-1] ^= 1
	tamperRejected := false
	for j := range path {
		_, _, _, err = s.Unwrap(keys[j], tampered)
		if err != nil {
			tamperRejected = true
			break
		}
	}
	if !tamperRejected {
		panic("tampering not rejected")
	}
	out := map[string]interface{}{
		"schema": 2, "kind": "Sphinx cryptographic microbenchmark, not network delivery or battery",
		"quantiles": "nearest-rank ceil(p*n)-1; empirical, no population guarantee",
		"go":        runtime.Version(), "os": runtime.GOOS, "arch": runtime.GOARCH, "gomaxprocs": runtime.GOMAXPROCS(0),
		"scheme": *scheme, "hops": *hops, "applicationPayloadBytes": *size, "wirePacketBytes": g.PacketLength,
		"upstream":     "katzenpost v0.0.90 d5a6349a34c4a2d4bca587f4be86ce92f2873b12",
		"modification": "hpqc NIKE/KEM registries restricted to X25519/Xwing; cryptographic implementations unchanged",
		"warmups":      50, "createPacket": summarize(create), "unwrapAllHops": summarize(unwrap), "createAndUnwrap": summarize(total),
		"processCpuMsMeasuredPhase": ms(phaseStart), "wallMsMeasuredPhase": ms(measuredWall),
		"tamperRejected": tamperRejected, "replayCacheRequired": true,
		"excludes": []string{"mixing delay", "other clients", "network", "radio", "discovery", "battery", "app signing/storage"},
	}
	data, err := json.MarshalIndent(out, "", "  ")
	must(err)
	fmt.Fprintln(os.Stdout, string(data))
}
