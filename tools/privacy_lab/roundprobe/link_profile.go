// Application-level test pacing. This is not a TCP, cellular or Internet
// emulator: rates apply independently to each direction of each role socket,
// and additional latency applies once per RPC. No OS network settings change.
package main

import (
	"context"
	"errors"
	"net"
	"sync"
	"time"
)

type linkProfile struct {
	WireCodec   string `json:"wireCodec,omitempty"`
	Kbps        int    `json:"kilobitsPerSecondEachDirection"`
	RoundTripMs int    `json:"additionalRoundTripMsPerRPC"`
}

func (p linkProfile) valid() bool {
	return validWireCodec(p.WireCodec) && p.Kbps >= 0 && p.Kbps <= 1000000 && p.RoundTripMs >= 0 && p.RoundTripMs <= 2000
}
func (p linkProfile) active() bool { return p.Kbps > 0 || p.RoundTripMs > 0 }

type bytePacer struct {
	mu             sync.Mutex
	next           time.Time
	bytesPerSecond float64
}

func (p *bytePacer) reserve(now time.Time, n int) time.Duration {
	p.mu.Lock()
	defer p.mu.Unlock()
	if n <= 0 || p.bytesPerSecond <= 0 {
		return 0
	}
	start := p.next
	if start.Before(now) {
		start = now
	}
	p.next = start.Add(time.Duration(float64(n) * float64(time.Second) / p.bytesPerSecond))
	return p.next.Sub(now)
}
func (p *bytePacer) wait(n int, done <-chan struct{}) error {
	delay := p.reserve(time.Now(), n)
	if delay <= 0 {
		return nil
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-timer.C:
		return nil
	case <-done:
		return net.ErrClosed
	}
}

type pacedConn struct {
	net.Conn
	upload, download bytePacer
	done             chan struct{}
	closeOnce        sync.Once
}

func paceConnection(c net.Conn, kbps int) net.Conn {
	if kbps == 0 {
		return c
	}
	rate := float64(kbps) * 1000 / 8
	return &pacedConn{Conn: c, upload: bytePacer{bytesPerSecond: rate}, download: bytePacer{bytesPerSecond: rate}, done: make(chan struct{})}
}
func (c *pacedConn) Read(b []byte) (int, error) {
	n, e := c.Conn.Read(b)
	if n > 0 {
		if wait := c.download.wait(n, c.done); wait != nil {
			return n, wait
		}
	}
	return n, e
}
func (c *pacedConn) Write(b []byte) (int, error) {
	if e := c.upload.wait(len(b), c.done); e != nil {
		return 0, e
	}
	return c.Conn.Write(b)
}
func (c *pacedConn) Close() error { c.closeOnce.Do(func() { close(c.done) }); return c.Conn.Close() }
func profileDelay(ctx context.Context, d time.Duration) error {
	if d <= 0 {
		return nil
	}
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-timer.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
func requireProfile(p linkProfile) {
	if !p.valid() {
		panic(errors.New("invalid constrained-link test profile"))
	}
}
