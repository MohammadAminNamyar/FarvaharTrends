package main

import (
	"context"
	"net"
	"testing"
	"time"
)

func TestPacingScheduleAccountsForBytesAndIdleTime(t *testing.T) {
	p := bytePacer{bytesPerSecond: 1000}
	now := time.Unix(100, 0)
	if got := p.reserve(now, 100); got != 100*time.Millisecond {
		t.Fatal(got)
	}
	if got := p.reserve(now, 200); got != 300*time.Millisecond {
		t.Fatal(got)
	}
	if got := p.reserve(now.Add(time.Second), 50); got != 50*time.Millisecond {
		t.Fatal(got)
	}
	if got := p.reserve(now.Add(time.Second), 0); got != 0 {
		t.Fatal(got)
	}
}
func TestCancelledPacingDoesNotWaitForFullTransfer(t *testing.T) {
	p := bytePacer{bytesPerSecond: 1}
	done := make(chan struct{})
	close(done)
	start := time.Now()
	if e := p.wait(1000, done); e != net.ErrClosed {
		t.Fatal(e)
	}
	if time.Since(start) > time.Second {
		t.Fatal("cancellation did not interrupt pacing")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if e := profileDelay(ctx, time.Hour); e != context.Canceled {
		t.Fatal(e)
	}
}
