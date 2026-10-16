package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"io"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type rpcBudgetTestClock struct {
	mu    sync.Mutex
	value time.Time
}

func (c *rpcBudgetTestClock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.value
}
func (c *rpcBudgetTestClock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.value = c.value.Add(d)
}
func frozenRPCBudget() (*rpcWorkBudget, *rpcBudgetTestClock) {
	c := &rpcBudgetTestClock{value: time.Unix(100, 0)}
	return newRPCWorkBudget(c.now), c
}

func TestRPCWorkBudgetRefillAndClockRegression(t *testing.T) {
	b, clock := frozenRPCBudget()
	for range rpcHandshakeBurst {
		if !b.allowHandshake() {
			t.Fatal("initial handshake burst rejected")
		}
	}
	if b.allowHandshake() {
		t.Fatal("handshake burst overspent")
	}
	clock.advance(500 * time.Millisecond)
	if b.allowHandshake() {
		t.Fatal("fractional credit became a whole handshake")
	}
	clock.advance(500 * time.Millisecond)
	if !b.allowHandshake() || b.allowHandshake() {
		t.Fatal("one-second refill was not exactly one handshake")
	}
	clock.advance(-time.Second)
	if b.allowHandshake() {
		t.Fatal("clock regression minted credit")
	}
	clock.advance(time.Second)
	if b.allowHandshake() {
		t.Fatal("return to prior high-water time minted credit")
	}
	clock.advance(time.Second)
	if !b.allowHandshake() || b.allowHandshake() {
		t.Fatal("forward refill after regression incorrect")
	}
	clock.advance(time.Duration(1<<63 - 1))
	for range rpcHandshakeBurst {
		if !b.allowHandshake() {
			t.Fatal("large elapsed interval failed to cap/refill")
		}
	}
	if b.allowHandshake() {
		t.Fatal("large elapsed interval overflowed burst")
	}
}

func TestRPCWorkBudgetIndependentFrameAndByteBounds(t *testing.T) {
	t.Run("frames", func(t *testing.T) {
		b, clock := frozenRPCBudget()
		for range rpcFrameBurst {
			if !b.allowFrame(1) {
				t.Fatal("frame burst rejected")
			}
		}
		if b.allowFrame(1) {
			t.Fatal("small frames bypassed frame rate")
		}
		clock.advance(time.Second / rpcFramesPerSecond)
		if !b.allowFrame(1) || b.allowFrame(1) {
			t.Fatal("frame refill incorrect")
		}
	})
	t.Run("bytes", func(t *testing.T) {
		b, clock := frozenRPCBudget()
		for range rpcBodyByteBurst / maxRPCBytes {
			if !b.allowFrame(maxRPCBytes) {
				t.Fatal("body burst rejected")
			}
		}
		if b.allowFrame(1) {
			t.Fatal("byte burst overspent")
		}
		clock.advance(time.Microsecond)
		if !b.allowFrame(1) || b.allowFrame(1) {
			t.Fatal("fractional byte refill incorrect")
		}
		clock.advance(100 * time.Hour)
		for range rpcBodyByteBurst / maxRPCBytes {
			if !b.allowFrame(maxRPCBytes) {
				t.Fatal("long refill failed")
			}
		}
		if b.allowFrame(1) {
			t.Fatal("long refill exceeded byte burst")
		}
	})
	t.Run("invalid-and-nil", func(t *testing.T) {
		b, _ := frozenRPCBudget()
		for _, n := range []int{-1, 0, maxRPCBytes + 1, int(^uint(0) >> 1)} {
			if b.allowFrame(n) {
				t.Fatal("invalid length accepted")
			}
		}
		var absent *rpcWorkBudget
		if absent.allowHandshake() || absent.allowFrame(1) {
			t.Fatal("absent budget admitted work")
		}
	})
}

func TestRPCWorkBudgetConcurrentAggregateCannotOverspend(t *testing.T) {
	for _, tc := range []struct {
		name           string
		body, expected int
	}{
		{"handshakes", 0, rpcHandshakeBurst},
		{"frames", 1, rpcFrameBurst},
		{"bytes", maxRPCBytes, rpcBodyByteBurst / maxRPCBytes},
	} {
		t.Run(tc.name, func(t *testing.T) {
			b, _ := frozenRPCBudget()
			var accepted atomic.Int64
			var wg sync.WaitGroup
			start := make(chan struct{})
			for range 128 {
				wg.Add(1)
				go func() {
					defer wg.Done()
					<-start
					allowed := false
					if tc.body == 0 {
						allowed = b.allowHandshake()
					} else {
						allowed = b.allowFrame(tc.body)
					}
					if allowed {
						accepted.Add(1)
					}
				}()
			}
			close(start)
			wg.Wait()
			if accepted.Load() != int64(tc.expected) {
				t.Fatalf("accepted %d, wanted %d", accepted.Load(), tc.expected)
			}
		})
	}
}

type forbiddenRPCBodyReader struct{ t *testing.T }

func (r forbiddenRPCBodyReader) Read([]byte) (int, error) {
	r.t.Fatal("rejected body was read")
	return 0, io.EOF
}
func rpcBudgetHeader(n int) []byte {
	header := []byte{'F', 'T', 1, framedRPCRequest, 0, 0, 0, 0}
	binary.BigEndian.PutUint32(header[4:], uint32(n))
	return header
}

func TestRPCWorkBudgetRejectsBeforeBodyReadAndKeepsFailedCharges(t *testing.T) {
	t.Run("depleted-bytes", func(t *testing.T) {
		b, _ := frozenRPCBudget()
		for range rpcBodyByteBurst / maxRPCBytes {
			if !b.allowFrame(maxRPCBytes) {
				t.Fatal("setup")
			}
		}
		body, e := readBudgetedRPCBody(forbiddenRPCBodyReader{t}, rpcBudgetHeader(1), framedRPCRequest, b)
		if !errors.Is(e, errRPCWorkBudget) || body != nil {
			t.Fatal("depleted byte budget did not reject before allocation/read", e)
		}
	})
	t.Run("depleted-frames", func(t *testing.T) {
		b, _ := frozenRPCBudget()
		for range rpcFrameBurst {
			if !b.allowFrame(1) {
				t.Fatal("setup")
			}
		}
		body, e := readBudgetedRPCBody(forbiddenRPCBodyReader{t}, rpcBudgetHeader(1), framedRPCRequest, b)
		if !errors.Is(e, errRPCWorkBudget) || body != nil {
			t.Fatal("depleted frame budget did not reject before allocation/read", e)
		}
	})
	t.Run("invalid-header", func(t *testing.T) {
		b, _ := frozenRPCBudget()
		body, e := readBudgetedRPCBody(forbiddenRPCBodyReader{t}, rpcBudgetHeader(maxRPCBytes+1), framedRPCRequest, b)
		if e == nil || body != nil {
			t.Fatal("oversized body accepted")
		}
	})
	t.Run("incomplete-disconnected", func(t *testing.T) {
		b, _ := frozenRPCBudget()
		for range rpcBodyByteBurst / maxRPCBytes {
			if _, e := readBudgetedRPCBody(bytes.NewReader(nil), rpcBudgetHeader(maxRPCBytes), framedRPCRequest, b); !errors.Is(e, io.EOF) {
				t.Fatal("incomplete body not rejected", e)
			}
		}
		if b.allowFrame(1) {
			t.Fatal("disconnect refunded declared body bytes")
		}
	})
	t.Run("malformed-cbor", func(t *testing.T) {
		b, _ := frozenRPCBudget()
		for range rpcFrameBurst {
			body, e := readBudgetedRPCBody(bytes.NewReader([]byte{0xff}), rpcBudgetHeader(1), framedRPCRequest, b)
			if e != nil {
				t.Fatal(e)
			}
			var q rpcRequest
			if decodeRPC("cbor-v1", body, &q) == nil {
				t.Fatal("malformed CBOR accepted")
			}
		}
		if b.allowFrame(1) {
			t.Fatal("decode rejection refunded frame credits")
		}
	})
}

func TestFramedRPCBudgetAcrossListenersAndReconnects(t *testing.T) {
	b, _ := frozenRPCBudget()
	var handled atomic.Int64
	handle := func(rpcRequest) (rpcResponse, error) { handled.Add(1); return rpcResponse{}, nil }
	s1, cfg1 := startFramedTestServerWithBudget(t, handle, nil, b)
	s2, cfg2 := startFramedTestServerWithBudget(t, handle, nil, b)
	servers := []*framedRPCServer{s1, s2}
	configs := []*tls.Config{cfg1, cfg2}
	body := framedTestBody(t)
	// These listeners trust different controller certificates. Neither a new
	// connection nor a different authenticated identity creates new credit.
	for i := range rpcHandshakeBurst {
		c := framedTestClient(servers[i%2], configs[i%2], nil)
		_, e := c.exchange(context.Background(), body)
		c.Close()
		if e != nil {
			t.Fatal(e)
		}
	}
	for i, s := range servers {
		var dials atomic.Int64
		c := framedTestClient(s, configs[i], &dials)
		_, e := c.exchange(context.Background(), body)
		c.Close()
		if e == nil || dials.Load() != 1 {
			t.Fatal("shared budget reset or automatic retry occurred", e, dials.Load())
		}
	}
	if handled.Load() != rpcHandshakeBurst {
		t.Fatal("excess work reached handler", handled.Load())
	}
}

func TestFramedRPCBudgetRejectsBeforeTLSAndFailedAuthCannotRefund(t *testing.T) {
	b, _ := frozenRPCBudget()
	var handled, handshakes atomic.Int64
	s, cfg := startFramedTestServerWithBudget(t, func(rpcRequest) (rpcResponse, error) { handled.Add(1); return rpcResponse{}, nil }, nil, b, func(sc *tls.Config) {
		sc.GetConfigForClient = func(*tls.ClientHelloInfo) (*tls.Config, error) { handshakes.Add(1); return nil, nil }
	})
	bad := cfg.Clone()
	bad.Certificates = nil
	for range rpcHandshakeBurst {
		c := framedTestClient(s, bad, nil)
		_, e := c.exchange(context.Background(), framedTestBody(t))
		c.Close()
		if e == nil {
			t.Fatal("unauthenticated request accepted")
		}
	}
	if handshakes.Load() != rpcHandshakeBurst {
		t.Fatal("test did not exercise all failed handshakes", handshakes.Load())
	}
	c := framedTestClient(s, cfg, nil)
	defer c.Close()
	if _, e := c.exchange(context.Background(), framedTestBody(t)); e == nil {
		t.Fatal("failed authentication refunded allowance")
	}
	if handshakes.Load() != rpcHandshakeBurst || handled.Load() != 0 {
		t.Fatal("exhausted receiver entered TLS or dispatched work")
	}
}

func TestFramedRPCBudgetExhaustionClosesBeforeHandler(t *testing.T) {
	b, _ := frozenRPCBudget()
	var handled atomic.Int64
	s, cfg := startFramedTestServerWithBudget(t, func(rpcRequest) (rpcResponse, error) {
		handled.Add(1)
		return rpcResponse{}, errors.New("rejected by handler")
	}, nil, b)
	c := framedTestClient(s, cfg, nil)
	defer c.Close()
	body := framedTestBody(t)
	for range rpcFrameBurst {
		reply, e := c.exchange(context.Background(), body)
		if e != nil {
			t.Fatal(e)
		}
		var response rpcResponse
		if decodeRPC("cbor-v1", reply, &response) != nil || response.Error != "rejected by handler" {
			t.Fatal("test failed to exercise handler rejection")
		}
	}
	if _, e := c.exchange(context.Background(), body); e == nil {
		t.Fatal("frame burst exceeded")
	}
	if handled.Load() != rpcFrameBurst {
		t.Fatal("over-budget frame reached handler", handled.Load())
	}
}

func TestFramedRPCFrameBudgetSharedAcrossListenersAndConnections(t *testing.T) {
	b, _ := frozenRPCBudget()
	var handled atomic.Int64
	handle := func(rpcRequest) (rpcResponse, error) { handled.Add(1); return rpcResponse{}, nil }
	s1, cfg1 := startFramedTestServerWithBudget(t, handle, nil, b)
	s2, cfg2 := startFramedTestServerWithBudget(t, handle, nil, b)
	c1, c2 := framedTestClient(s1, cfg1, nil), framedTestClient(s2, cfg2, nil)
	defer c1.Close()
	defer c2.Close()
	clients := []*framedRPCClient{c1, c2}
	body := framedTestBody(t)
	for i := range rpcFrameBurst {
		if _, e := clients[i%2].exchange(context.Background(), body); e != nil {
			t.Fatal(e)
		}
	}
	for _, c := range clients {
		if _, e := c.exchange(context.Background(), body); e == nil {
			t.Fatal("listener minted extra frame allowance")
		}
	}
	// A new connection still has handshake capacity, but it must inherit the
	// depleted frame allowance left by both prior connections together.
	fresh := framedTestClient(s1, cfg1, nil)
	defer fresh.Close()
	if _, e := fresh.exchange(context.Background(), body); e == nil {
		t.Fatal("reconnection reset frame allowance")
	}
	if handled.Load() != rpcFrameBurst {
		t.Fatal("shared frame cap bypassed", handled.Load())
	}
}
