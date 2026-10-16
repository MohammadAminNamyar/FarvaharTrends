package main

// Laboratory receiver work limits. These allowances belong to the receiver,
// never to a peer identity. A caller with several listeners must share one
// rpcWorkBudget among them. The default server constructor owns one role's
// budget; eleven role processes therefore do not constitute a phone-wide cap.
//
// A new process starts with a full burst. Persistent restart accounting is not
// implemented. These bounds concern admitted application work, not kernel,
// radio, socket-accept or attacker-induced denial-of-service costs.
import (
	"errors"
	"io"
	"sync"
	"time"
)

const (
	rpcHandshakeBurst            = 4
	rpcHandshakesPerSecond       = 1
	rpcFrameBurst                = 32
	rpcFramesPerSecond           = 16
	rpcBodyByteBurst             = 4 * 1024 * 1024
	rpcBodyBytesPerSecond        = 1024 * 1024
	rpcBudgetScale         int64 = int64(time.Second)
)

var errRPCWorkBudget = errors.New("receiver RPC work budget exhausted")

// Integer credits retain fractional refill without floating-point drift. Each
// whole token costs one second's worth of credits; dt * rate refills credits.
type rpcWorkBucket struct {
	credits, capacity, rate int64
}

func newRPCWorkBucket(capacity, rate int64) rpcWorkBucket {
	return rpcWorkBucket{credits: capacity * rpcBudgetScale, capacity: capacity * rpcBudgetScale, rate: rate}
}

func (b *rpcWorkBucket) refill(elapsed time.Duration) {
	if elapsed <= 0 {
		return
	}
	remaining := b.capacity - b.credits
	// Clamp before multiplication, including after a very long suspension.
	if int64(elapsed) >= (remaining+b.rate-1)/b.rate {
		b.credits = b.capacity
		return
	}
	b.credits += int64(elapsed) * b.rate
}

type rpcWorkBudget struct {
	mu                        sync.Mutex
	now                       func() time.Time
	last                      time.Time
	handshakes, frames, bytes rpcWorkBucket
}

func newRPCWorkBudget(now func() time.Time) *rpcWorkBudget {
	if now == nil {
		now = time.Now
	}
	return &rpcWorkBudget{
		now: now, last: now(),
		handshakes: newRPCWorkBucket(rpcHandshakeBurst, rpcHandshakesPerSecond),
		frames:     newRPCWorkBucket(rpcFrameBurst, rpcFramesPerSecond),
		bytes:      newRPCWorkBucket(rpcBodyByteBurst, rpcBodyBytesPerSecond),
	}
}

func (b *rpcWorkBudget) refillLocked() {
	now := b.now()
	elapsed := now.Sub(b.last)
	if elapsed <= 0 {
		// Keep the prior high-water time: moving backward and then returning
		// to that same instant must not mint another refill.
		return
	}
	b.last = now
	b.handshakes.refill(elapsed)
	b.frames.refill(elapsed)
	b.bytes.refill(elapsed)
}

func (b *rpcWorkBudget) allowHandshake() bool {
	if b == nil {
		return false
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	b.refillLocked()
	if b.handshakes.credits < rpcBudgetScale {
		return false
	}
	b.handshakes.credits -= rpcBudgetScale
	return true
}

func (b *rpcWorkBudget) allowFrame(declaredBytes int) bool {
	if b == nil || declaredBytes <= 0 || declaredBytes > maxRPCBytes {
		return false
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	b.refillLocked()
	cost := int64(declaredBytes) * rpcBudgetScale
	if b.frames.credits < rpcBudgetScale || b.bytes.credits < cost {
		return false
	}
	// One atomic admission. Neither a decode failure nor a disconnect nor an
	// unsuccessful handler can refund these already-admitted resources.
	b.frames.credits -= rpcBudgetScale
	b.bytes.credits -= cost
	return true
}

// Validate and charge before allocating or reading the declared body. Header
// bytes are small and fixed; a rejected header/body closes the connection.
func readBudgetedRPCBody(r io.Reader, header []byte, kind byte, budget *rpcWorkBudget) ([]byte, error) {
	n, e := rpcFrameLength(header, kind)
	if e != nil {
		return nil, e
	}
	if !budget.allowFrame(n) {
		return nil, errRPCWorkBudget
	}
	body := make([]byte, n)
	_, e = io.ReadFull(r, body)
	return body, e
}
