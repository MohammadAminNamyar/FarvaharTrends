package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"sync/atomic"
	"testing"
	"time"
)

type shortFrameWriter struct {
	bytes.Buffer
	zero bool
}

func (w *shortFrameWriter) Write(b []byte) (int, error) {
	if w.zero {
		return 0, nil
	}
	if len(b) > 3 {
		b = b[:3]
	}
	return w.Buffer.Write(b)
}

type fragmentedFrameReader struct{ r io.Reader }

func (r fragmentedFrameReader) Read(b []byte) (int, error) {
	if len(b) > 1 {
		b = b[:1]
	}
	return r.r.Read(b)
}
func TestFramedRPCRejectsBadFramesAndHandlesFragmentation(t *testing.T) {
	payload := []byte("خبر فارسی؛ حفظ پیام در خواندن و نوشتن بخش‌بخش")
	w := &shortFrameWriter{}
	for range 2 {
		if e := writeRPCFrame(w, framedRPCRequest, payload); e != nil {
			t.Fatal(e)
		}
	}
	r := fragmentedFrameReader{bytes.NewReader(w.Bytes())}
	for range 2 {
		b, e := readRPCFrame(r, framedRPCRequest)
		if e != nil || !bytes.Equal(b, payload) {
			t.Fatal("fragmented/coalesced stream corrupted", e)
		}
	}
	if e := writeRPCFrame(&shortFrameWriter{zero: true}, 0, payload); !errors.Is(e, io.ErrShortWrite) {
		t.Fatal("zero write not rejected", e)
	}
	var valid bytes.Buffer
	if e := writeRPCFrame(&valid, 0, payload); e != nil {
		t.Fatal(e)
	}
	base := valid.Bytes()
	cases := map[string][]byte{"empty": nil, "truncated-header": base[:7], "truncated-body": base[:len(base)-1]}
	for _, change := range []struct {
		name  string
		at    int
		value byte
	}{{"magic", 0, 'X'}, {"version", 2, 2}, {"direction", 3, 1}, {"flags", 3, 128}} {
		b := bytes.Clone(base)
		b[change.at] = change.value
		cases[change.name] = b
	}
	for name, n := range map[string]uint32{"zero": 0, "over-limit": maxRPCBytes + 1, "overflow": 0xffffffff} {
		b := bytes.Clone(base[:8])
		binary.BigEndian.PutUint32(b[4:], n)
		cases[name] = b
	}
	for name, b := range cases {
		t.Run(name, func(t *testing.T) {
			if _, e := readRPCFrame(bytes.NewReader(b), 0); e == nil {
				t.Fatal("bad frame accepted")
			}
		})
	}
	if writeRPCFrame(io.Discard, 0, nil) == nil || writeRPCFrame(io.Discard, 0, make([]byte, maxRPCBytes+1)) == nil || writeRPCFrame(io.Discard, 2, payload) == nil {
		t.Fatal("invalid outbound frame accepted")
	}
}

func framedTLSForTest(t *testing.T) (*tls.Config, *tls.Config) {
	t.Helper()
	sp, sk := laboratoryCertificate("framed-server")
	cp, ck := laboratoryCertificate("framed-controller")
	sc, e := tls.X509KeyPair(sp, sk)
	if e != nil {
		t.Fatal(e)
	}
	cc, e := tls.X509KeyPair(cp, ck)
	if e != nil {
		t.Fatal(e)
	}
	spool, cpool := x509.NewCertPool(), x509.NewCertPool()
	if !spool.AppendCertsFromPEM(sp) || !cpool.AppendCertsFromPEM(cp) {
		t.Fatal("bad test pins")
	}
	return &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{sc}, ClientAuth: tls.RequireAndVerifyClientCert, ClientCAs: cpool}, &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{cc}, RootCAs: spool, ServerName: "localhost", NextProtos: []string{framedRPCALPN}}
}
func startFramedTestServer(t *testing.T, handle func(rpcRequest) (rpcResponse, error), timeouts *framedRPCTimeouts) (*framedRPCServer, *tls.Config) {
	t.Helper()
	return startFramedTestServerWithBudget(t, handle, timeouts, newRPCWorkBudget(nil))
}
func startFramedTestServerWithBudget(t *testing.T, handle func(rpcRequest) (rpcResponse, error), timeouts *framedRPCTimeouts, budget *rpcWorkBudget, configure ...func(*tls.Config)) (*framedRPCServer, *tls.Config) {
	t.Helper()
	sc, cc := framedTLSForTest(t)
	for _, f := range configure {
		f(sc)
	}
	l, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	counts := new(wireCounter)
	s := newFramedRPCServerWithBudget(&countedListener{l, counts}, sc, counts, handle, budget)
	if timeouts != nil {
		s.timeouts = *timeouts
	}
	done := make(chan error, 1)
	go func() { done <- s.Serve() }()
	t.Cleanup(func() {
		s.Close()
		select {
		case e := <-done:
			if e != nil {
				t.Error(e)
			}
		case <-time.After(3 * time.Second):
			t.Error("framed server leaked a connection/goroutine")
		}
	})
	return s, cc
}
func framedTestClient(s *framedRPCServer, cfg *tls.Config, dials *atomic.Int64) *framedRPCClient {
	d := &net.Dialer{Timeout: time.Second}
	return newFramedRPCClient(s.listener.Addr().String(), cfg, func(ctx context.Context, network, address string) (net.Conn, error) {
		if dials != nil {
			dials.Add(1)
		}
		return d.DialContext(ctx, network, address)
	})
}
func framedTestBody(t *testing.T) []byte {
	t.Helper()
	b, e := encodeRPC("cbor-v1", rpcRequest{Op: "stats"})
	if e != nil {
		t.Fatal(e)
	}
	return b
}
func awaitFramedTest(t *testing.T, f func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !f() {
		if time.Now().After(deadline) {
			t.Fatal("bounded condition timed out")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestFramedRPCAuthenticatedReuseAndRejections(t *testing.T) {
	var handled, dials atomic.Int64
	s, cfg := startFramedTestServer(t, func(q rpcRequest) (rpcResponse, error) {
		handled.Add(1)
		if q.Op == "empty-error" {
			return rpcResponse{}, errors.New("")
		}
		if q.Op != "stats" {
			return rpcResponse{}, errors.New("operation rejected")
		}
		return rpcResponse{Output: []byte("آزمایش رمزگذاری و ارتباط پایدار")}, nil
	}, nil)
	c := framedTestClient(s, cfg, &dials)
	defer c.Close()
	n := remoteRole{name: "test", profile: linkProfile{WireCodec: "cbor-framed-v1"}, framed: c}
	for range 3 {
		r, e := n.call(rpcRequest{Op: "stats"})
		if e != nil || string(r.Output) != "آزمایش رمزگذاری و ارتباط پایدار" {
			t.Fatal(e)
		}
	}
	if dials.Load() != 1 || handled.Load() != 3 {
		t.Fatal("connection not reused")
	}
	if _, e := n.call(rpcRequest{Op: "invalid"}); e == nil {
		t.Fatal("role rejection ignored")
	}
	if _, e := n.call(rpcRequest{Op: "empty-error"}); e == nil {
		t.Fatal("empty-message rejection was treated as success")
	}
	if _, e := n.call(rpcRequest{Op: "stats"}); e != nil || dials.Load() != 1 {
		t.Fatal("role rejection poisoned a healthy connection", e)
	}
}

func TestFramedRPCCertificateAndALPNFailuresNeverDispatch(t *testing.T) {
	var handled atomic.Int64
	body := framedTestBody(t)
	for _, name := range []string{"untrusted-server", "missing-client", "foreign-client", "wrong-alpn", "missing-alpn"} {
		t.Run(name, func(t *testing.T) {
			// Each case must reach TLS validation; an earlier case exhausting
			// a shared handshake budget would otherwise mask its assertion.
			s, cfg := startFramedTestServer(t, func(rpcRequest) (rpcResponse, error) { handled.Add(1); return rpcResponse{}, nil }, nil)
			cc := cfg.Clone()
			switch name {
			case "untrusted-server":
				cc.RootCAs = x509.NewCertPool()
			case "missing-client":
				cc.Certificates = nil
			case "foreign-client":
				p, k := laboratoryCertificate("foreign")
				cert, e := tls.X509KeyPair(p, k)
				if e != nil {
					t.Fatal(e)
				}
				cc.Certificates = []tls.Certificate{cert}
			}
			var dials atomic.Int64
			c := framedTestClient(s, cc, &dials)
			defer c.Close()
			if name == "wrong-alpn" {
				c.config.NextProtos = []string{"http/1.1"}
			}
			if name == "missing-alpn" {
				c.config.NextProtos = nil
			}
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			if _, e := c.exchange(ctx, body); e == nil {
				t.Fatal("authentication/protocol failure accepted")
			}
			if dials.Load() != 1 {
				t.Fatal("unexpected retry/fallback")
			}
		})
	}
	if handled.Load() != 0 {
		t.Fatal("unauthenticated request dispatched")
	}
}

func TestFramedRPCMalformedInputAndSlowReadsNeverDispatch(t *testing.T) {
	var handled atomic.Int64
	policy := defaultFramedRPCTimeouts
	policy.header = 50 * time.Millisecond
	policy.body = 50 * time.Millisecond
	policy.idle = 100 * time.Millisecond
	for _, name := range []string{"bad-version", "wrong-direction", "over-limit", "bad-cbor", "slow-header", "slow-body", "idle"} {
		t.Run(name, func(t *testing.T) {
			s, cfg := startFramedTestServer(t, func(rpcRequest) (rpcResponse, error) { handled.Add(1); return rpcResponse{}, nil }, &policy)
			c, e := tls.Dial("tcp", s.listener.Addr().String(), cfg)
			if e != nil {
				t.Fatal(e)
			}
			defer c.NetConn().Close()
			_ = c.SetDeadline(time.Now().Add(time.Second))
			var b bytes.Buffer
			must(writeRPCFrame(&b, 0, framedTestBody(t)))
			packet := bytes.Clone(b.Bytes())
			switch name {
			case "bad-version":
				packet[2] = 2
			case "wrong-direction":
				packet[3] = 1
			case "over-limit":
				binary.BigEndian.PutUint32(packet[4:8], maxRPCBytes+1)
			case "bad-cbor":
				packet[len(packet)-1] = 0xff
			case "slow-header":
				packet = packet[:1]
			case "slow-body":
				packet = packet[:8]
			case "idle":
				packet = nil
			}
			if len(packet) > 0 {
				_, _ = c.Write(packet)
			}
			var one [1]byte
			_, e = c.Read(one[:])
			if e == nil {
				t.Fatal("invalid request got a reply")
			}
			if ne, ok := e.(net.Error); ok && ne.Timeout() {
				t.Fatal("server failed to bound incomplete/idle frame")
			}
		})
	}
	if handled.Load() != 0 {
		t.Fatal("bad input reached handler")
	}
}

func TestFramedRPCNoAutomaticRetryAfterLostResponse(t *testing.T) {
	var calls, dials atomic.Int64
	var s *framedRPCServer
	var cfg *tls.Config
	s, cfg = startFramedTestServer(t, func(rpcRequest) (rpcResponse, error) { calls.Add(1); s.Close(); return rpcResponse{}, nil }, nil)
	c := framedTestClient(s, cfg, &dials)
	defer c.Close()
	if _, e := c.exchange(context.Background(), framedTestBody(t)); e == nil {
		t.Fatal("lost response accepted")
	}
	if calls.Load() != 1 || dials.Load() != 1 {
		t.Fatal("ambiguous operation was retransmitted")
	}
}

func TestFramedRPCBusyAndCloseCancelOutstandingWork(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	s, cfg := startFramedTestServer(t, func(rpcRequest) (rpcResponse, error) { close(entered); <-release; return rpcResponse{}, nil }, nil)
	defer close(release)
	c := framedTestClient(s, cfg, nil)
	defer c.Close()
	other := framedTestClient(s, cfg, nil)
	defer other.Close()
	body := framedTestBody(t)
	done := make(chan error, 1)
	go func() { _, e := c.exchange(context.Background(), body); done <- e }()
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("request did not start")
	}
	b, e := other.exchange(context.Background(), body)
	if e != nil {
		t.Fatal(e)
	}
	var r rpcResponse
	if decodeRPC("cbor-v1", b, &r) != nil || r.Error != "busy" {
		t.Fatal("parallel handler not bounded")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if _, e := c.exchange(ctx, body); e == nil {
		t.Fatal("queued exchange ignored deadline")
	}
	c.Close()
	select {
	case e := <-done:
		if e == nil {
			t.Fatal("interrupted reply accepted")
		}
	case <-time.After(time.Second):
		t.Fatal("close failed to cancel active exchange")
	}
	if _, e := c.exchange(context.Background(), body); !errors.Is(e, net.ErrClosed) {
		t.Fatal("closed client reopened", e)
	}
}

func TestFramedRPCBoundsConnectionsAndInterruptsPacing(t *testing.T) {
	s, _ := startFramedTestServer(t, func(rpcRequest) (rpcResponse, error) { return rpcResponse{}, nil }, nil)
	var sockets []net.Conn
	defer func() {
		for _, c := range sockets {
			_ = c.Close()
		}
	}()
	for range framedRPCMaxConnections {
		c, e := net.Dial("tcp", s.listener.Addr().String())
		if e != nil {
			t.Fatal(e)
		}
		sockets = append(sockets, c)
	}
	awaitFramedTest(t, func() bool { s.mu.Lock(); defer s.mu.Unlock(); return len(s.conns) == framedRPCMaxConnections })
	extra, e := net.Dial("tcp", s.listener.Addr().String())
	if e != nil {
		t.Fatal(e)
	}
	defer extra.Close()
	_ = extra.SetReadDeadline(time.Now().Add(time.Second))
	var one [1]byte
	if _, e = extra.Read(one[:]); e == nil {
		t.Fatal("excess connection accepted")
	} else if ne, ok := e.(net.Error); ok && ne.Timeout() {
		t.Fatal("excess connection not closed")
	}
	for _, c := range sockets {
		_ = c.Close()
	}
	awaitFramedTest(t, func() bool { s.mu.Lock(); defer s.mu.Unlock(); return len(s.conns) == 0 })
	// This assertion measures cancellation during pacing, independently of
	// the preceding four handshakes consuming the first receiver's budget.
	paceServer, cfg := startFramedTestServer(t, func(rpcRequest) (rpcResponse, error) { return rpcResponse{}, nil }, nil)
	d := &net.Dialer{Timeout: time.Second}
	c := newFramedRPCClient(paceServer.listener.Addr().String(), cfg, func(ctx context.Context, network, address string) (net.Conn, error) {
		raw, e := d.DialContext(ctx, network, address)
		if e != nil {
			return nil, e
		}
		return paceConnection(raw, 1), nil
	})
	defer c.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	done := make(chan error, 1)
	go func() { _, e := c.exchange(ctx, framedTestBody(t)); done <- e }()
	select {
	case e := <-done:
		if e == nil {
			t.Fatal("expired pacing completed")
		}
	case <-time.After(time.Second):
		t.Fatal("test pacing ignored cancellation")
	}
}
