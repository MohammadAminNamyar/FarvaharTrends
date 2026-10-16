// Laboratory adapter carrying actual application envelopes through Sphinx.
// FPP-0 is known to fail active isolation. This adapter is not production IPC.
package main

import (
	"bufio"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"os"
	"time"
)

type pipeRequest struct {
	ID         uint64 `json:"id"`
	Payload    string `json:"payload"`
	SlotWaitMs int    `json:"slotWaitMs"`
}

func (r *batchRoute) payloadPacket(id uint64, body []byte) []byte {
	if len(body) > r.size-13 {
		panic("application envelope exceeds fixed cell capacity")
	}
	p := make([]byte, r.size)
	_, e := rand.Read(p)
	must(e)
	p[0] = 2
	binary.BigEndian.PutUint64(p[1:9], id)
	binary.BigEndian.PutUint32(p[9:13], uint32(len(body)))
	copy(p[13:], body)
	pkt, e := r.s.NewPacket(rand.Reader, r.path, p)
	must(e)
	return pkt
}

func unpackArrival(item arrival) ([]byte, error) {
	if len(item.body) < 13 || item.body[0] != 2 {
		return nil, fmt.Errorf("invalid application cell")
	}
	n := int(binary.BigEndian.Uint32(item.body[9:13]))
	if n > len(item.body)-13 {
		return nil, fmt.Errorf("invalid application length")
	}
	return item.body[13 : 13+n], nil
}

func runPipeLab(size, hops int) {
	r := newBatchRoute(hops, size)
	c, arrivals, stop, counts, failures := r.network(500 * time.Millisecond)
	defer stop()
	encode := json.NewEncoder(os.Stdout)
	must(encode.Encode(map[string]interface{}{
		"ready": true, "candidate": "FPP-0", "packetBytes": r.s.Geometry().PacketLength,
		"maxApplicationBytes": size - 13, "securityGatePassed": false,
		"reason": "known active isolation; simulated cohort, sample-driven covers",
	}))
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 65536), 65536)
	for scanner.Scan() {
		var req pipeRequest
		if e := json.Unmarshal(scanner.Bytes(), &req); e != nil {
			panic(e)
		}
		if req.ID == 0 || req.SlotWaitMs < 0 || req.SlotWaitMs >= 2000 {
			panic("invalid lab request")
		}
		body, e := base64.StdEncoding.DecodeString(req.Payload)
		must(e)
		if len(body) > size-13 {
			panic("oversized lab request; never direct-fallback")
		}
		cpu := cpuTime()
		started := time.Now()
		written, read := counts.written.Load(), counts.read.Load()
		time.Sleep(time.Duration(req.SlotWaitMs) * time.Millisecond)
		for j := 0; j < cohort; j++ {
			var pkt []byte
			if j == 0 {
				pkt = r.payloadPacket(req.ID, body)
			} else {
				pkt = r.packet(req.ID, false, 0)
			}
			must(writeAll(c, pkt))
		}
		timer := time.NewTimer(8 * time.Second)
		select {
		case item := <-arrivals:
			timer.Stop()
			if item.id != req.ID {
				panic("wrong publication released")
			}
			received, e := unpackArrival(item)
			must(e)
			// The reply is the actual decrypted payload at the release end.
			must(encode.Encode(map[string]interface{}{
				"id": req.ID, "payload": base64.StdEncoding.EncodeToString(received),
				"processCpuMs": ms(cpuTime() - cpu), "releaseMs": ms(item.at.Sub(started)),
				"tcpPayloadBytesWrittenAllHops": counts.written.Load() - written,
				"tcpPayloadBytesReadAllHops":    counts.read.Load() - read,
			}))
		case <-timer.C:
			panic("protected path timed out; no direct-fallback")
		case err := <-failures:
			timer.Stop()
			panic(fmt.Sprintf("protected path failed; no direct-fallback: %v", err))
		}
	}
	must(scanner.Err())
}
