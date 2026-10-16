// An intentionally isolated candidate, NOT production anonymity software.
// Uses real Sphinx transformations and loopback TCP, but not a complete
// Katzenpost network. Its active-adversary failure is tested explicitly.
package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/katzenpost/hpqc/nike/x25519"
	"github.com/katzenpost/katzenpost/core/sphinx"
	"github.com/katzenpost/katzenpost/core/sphinx/commands"
	"github.com/katzenpost/katzenpost/core/sphinx/geo"
)

const cohort = 8

type batchRoute struct {
	s    *sphinx.Sphinx
	path []*sphinx.PathHop
	keys []interface{}
	size int
}

func newBatchRoute(hops, size int) *batchRoute {
	n := x25519.Scheme(rand.Reader)
	g := geo.GeometryFromUserForwardPayloadLength(n, size, false, hops)
	r := &batchRoute{s: sphinx.NewNIKESphinx(n, g), size: size}
	for i := 0; i < hops; i++ {
		h := new(sphinx.PathHop)
		_, e := rand.Read(h.ID[:])
		must(e)
		pub, priv, e := n.GenerateKeyPair()
		must(e)
		h.NIKEPublicKey = pub
		if i == hops-1 {
			h.Commands = []commands.RoutingCommand{new(commands.Recipient)}
		} else {
			h.Commands = []commands.RoutingCommand{&commands.NodeDelay{Delay: 0}}
		}
		r.path = append(r.path, h)
		r.keys = append(r.keys, priv)
	}
	return r
}
func (r *batchRoute) packet(id uint64, real bool, firstHop int) []byte {
	p := make([]byte, r.size)
	_, e := rand.Read(p)
	must(e)
	p[0] = 0
	if real {
		p[0] = 1
	}
	binary.BigEndian.PutUint64(p[1:9], id)
	pkt, e := r.s.NewPacket(rand.Reader, r.path[firstHop:], p)
	must(e)
	return pkt
}
func shuffle(p [][]byte) {
	for i := len(p) - 1; i > 0; i-- {
		v, e := rand.Int(rand.Reader, big.NewInt(int64(i+1)))
		must(e)
		j := int(v.Int64())
		p[i], p[j] = p[j], p[i]
	}
}
func (r *batchRoute) unwrapBatch(p [][]byte, hop int) ([][]byte, []arrival, error) {
	var ids []arrival
	for _, pkt := range p {
		body, _, _, e := r.s.Unwrap(r.keys[hop], pkt)
		if e != nil {
			return nil, nil, e
		}
		if hop == len(r.keys)-1 && len(body) > 8 && (body[0] == 1 || body[0] == 2) {
			ids = append(ids, arrival{id: binary.BigEndian.Uint64(body[1:9]), body: append([]byte{}, body...)})
		}
	}
	shuffle(p)
	return p, ids, nil
}

// Reproduction: a malicious first mix replaces all other honest users' cells
// with its own fresh covers. Cell count and replay detection still pass.
// The target's publication identifies which input it retained. This is a
// release-blocking failure, not an attack on Katzenpost's complete protocol.
func (r *batchRoute) isolateAttack() map[string]interface{} {
	if len(r.keys) < 2 {
		return map[string]interface{}{"applicable": false}
	}
	cells := make([][]byte, cohort)
	// Two honest users publish; the remaining six send indistinguishable covers.
	for i := range cells {
		cells[i] = r.packet(uint64(i+1), i < 2, 0)
	}
	// Attacker knows incoming link 0. It can unwrap its legitimate first hop.
	_, _, _, e := r.s.Unwrap(r.keys[0], cells[0])
	must(e)
	for i := 1; i < cohort; i++ {
		cells[i] = r.packet(uint64(100+i), false, 1)
	}
	var released []arrival
	for h := 1; h < len(r.keys); h++ {
		cells, released, e = r.unwrapBatch(cells, h)
		must(e)
	}
	var published []uint64
	for _, item := range released {
		published = append(published, item.id)
	}
	success := len(published) == 1 && published[0] == 1
	return map[string]interface{}{
		"attack":                     "malicious entry replaces n-1 inputs with fresh cover packets",
		"originalHonestPublications": 2, "batchCountStillValid": len(cells) == cohort,
		"observedPublications": published, "targetInputLinkedToPublication": success,
		"securityGatePassed": false,
	}
}

type arrival struct {
	id   uint64
	at   time.Time
	body []byte
}

type wireMetrics struct{ read, written atomic.Uint64 }
type countedConn struct {
	net.Conn
	metrics *wireMetrics
}

func (c *countedConn) Write(p []byte) (int, error) {
	n, e := c.Conn.Write(p)
	c.metrics.written.Add(uint64(n))
	return n, e
}

func (r *batchRoute) network(hold time.Duration) (net.Conn, chan arrival, func(), *wireMetrics, chan error) {
	count := len(r.keys)
	metrics := new(wireMetrics)
	listeners := make([]net.Listener, count)
	conns := make([]net.Conn, 0, count*2)
	events := make(chan arrival, 64)
	failures := make(chan error, count)
	var workers sync.WaitGroup
	fail := func(h int, err error) {
		select {
		case failures <- fmt.Errorf("mix %d: %w", h, err):
		default:
		}
	}
	for i := range listeners {
		l, e := net.Listen("tcp4", "127.0.0.1:0")
		must(e)
		listeners[i] = l
	}
	inbound := make([]net.Conn, count)
	outgoing := make([]net.Conn, count)
	for i, l := range listeners {
		c, e := net.Dial("tcp4", l.Addr().String())
		must(e)
		a, e := l.Accept()
		must(e)
		outgoing[i] = &countedConn{c, metrics}
		inbound[i] = a
		conns = append(conns, c, a)
	}
	for i := range listeners {
		workers.Add(1)
		go func(h int) {
			defer workers.Done()
			defer inbound[h].Close()
			replay := map[[32]byte]bool{}
			for {
				p := make([][]byte, cohort)
				for j := range p {
					p[j] = make([]byte, r.s.Geometry().PacketLength)
					n, e := io.ReadFull(inbound[h], p[j])
					metrics.read.Add(uint64(n))
					if e != nil {
						fail(h, e)
						return
					}
					tag := sha256.Sum256(p[j])
					if replay[tag] || len(replay) > 100000 {
						fail(h, fmt.Errorf("replay or replay-cache capacity"))
						return
					}
					replay[tag] = true
				}
				var ids []arrival
				var e error
				p, ids, e = r.unwrapBatch(p, h)
				if e != nil {
					fail(h, e)
					return
				}
				if hold > 0 {
					time.Sleep(hold)
				}
				if h == count-1 {
					for _, item := range ids {
						item.at = time.Now()
						events <- item
					}
				} else {
					for _, pkt := range p {
						if e = writeAll(outgoing[h+1], pkt); e != nil {
							fail(h, e)
							return
						}
					}
				}
			}
		}(i)
	}
	stop := func() {
		for _, c := range conns {
			c.Close()
		}
		for _, l := range listeners {
			l.Close()
		}
		workers.Wait()
	}
	return outgoing[0], events, stop, metrics, failures
}
func writeAll(w io.Writer, p []byte) error {
	for len(p) > 0 {
		n, e := w.Write(p)
		if e != nil {
			return e
		}
		if n == 0 {
			return io.ErrShortWrite
		}
		p = p[n:]
	}
	return nil
}
func runBatchLab(samples, size, hops int) {
	if samples > 100 {
		panic("batch lab accepts at most 100 samples")
	}
	r := newBatchRoute(hops, size)
	results := map[string]interface{}{
		"schema": 1, "candidate": "FPP-0 fixed cohort submission + public release",
		"classification": "experimental component timing, not app propagation or anonymity proof",
		"transport":      "loopback TCP, same-process independent goroutines",
		"cohort":         cohort, "hops": hops, "wirePacketBytes": r.s.Geometry().PacketLength,
		"excludes":     []string{"mobile radio", "NAT", "discovery", "signature validation/storage", "public gossip", "battery"},
		"activeAttack": r.isolateAttack(),
	}
	for _, protected := range []bool{false, true} {
		hold := time.Duration(0)
		if protected {
			hold = 500 * time.Millisecond
		}
		c, arrivals, stop, metrics, failuresChannel := r.network(hold)
		rows := []map[string]interface{}{}
		times := []float64{}
		cpuStart := cpuTime()
		wallStart := time.Now()
		failures := 0
		for sample := 0; sample < samples; sample++ {
			// Stratified publication phases cover the full two-second client slot.
			// We actually wait this interval; it is not added to results afterwards.
			wait := time.Duration((sample*137)%2000) * time.Millisecond
			if !protected {
				wait = 0
			}
			started := time.Now()
			if wait > 0 {
				time.Sleep(wait)
			}
			for j := 0; j < cohort; j++ {
				pkt := r.packet(uint64(sample+1), j == 0, 0)
				must(writeAll(c, pkt))
			}
			timer := time.NewTimer(8 * time.Second)
			select {
			case got := <-arrivals:
				timer.Stop()
				if got.id != uint64(sample+1) {
					panic("arrival identifier mismatch")
				}
				elapsed := ms(got.at.Sub(started))
				times = append(times, elapsed)
				rows = append(rows, map[string]interface{}{"index": sample, "slotWaitMs": ms(wait), "elapsedMs": elapsed, "received": true})
			case <-timer.C:
				failures++
				rows = append(rows, map[string]interface{}{"index": sample, "received": false, "timeoutMs": 8000})
			case err := <-failuresChannel:
				timer.Stop()
				failures++
				rows = append(rows, map[string]interface{}{"index": sample, "received": false, "error": err.Error()})
			}
			if failures > 0 {
				break
			}
		}
		cpu := cpuTime() - cpuStart
		wall := time.Since(wallStart)
		stop()
		label := "unpaced_control"
		if protected {
			label = "paced_candidate"
		}
		summary := map[string]interface{}{"samples": samples, "failures": failures, "rows": rows, "processCpuMs": ms(cpu), "wallMs": ms(wall)}
		summary["tcpPayloadBytesWrittenAllHops"] = metrics.written.Load()
		summary["tcpPayloadBytesReadAllHops"] = metrics.read.Load()
		if len(times) > 0 {
			summary["latency"] = summarize(times)
		}
		results[label] = summary
	}
	results["productionIntegrationAllowed"] = false
	results["reason"] = "Active isolation attack succeeds; battery and real-network costs are unmeasured."
	data, e := json.MarshalIndent(results, "", "  ")
	must(e)
	fmt.Fprintln(os.Stdout, string(data))
}
