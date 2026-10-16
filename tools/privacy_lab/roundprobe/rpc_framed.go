package main

// Optional laboratory transport. TLS supplies authentication and encryption;
// this framing changes neither signed protocol bytes nor durable retry rules.
import (
	"context"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"sync"
	"time"
)

const framedRPCALPN = "farvahar-lab-cbor/1"
const framedRPCRequest byte = 0
const framedRPCResponse byte = 1
const framedRPCHeaderSize = 8
const framedRPCMaxConnections = 4

func rpcFrameLength(header []byte, kind byte) (int, error) {
	if kind > framedRPCResponse || len(header) != framedRPCHeaderSize || header[0] != 'F' || header[1] != 'T' || header[2] != 1 || header[3] != kind {
		return 0, errors.New("invalid RPC frame version or direction")
	}
	n := binary.BigEndian.Uint32(header[4:])
	if n == 0 || n > maxRPCBytes {
		return 0, errors.New("RPC frame exceeds byte limit")
	}
	return int(n), nil
}
func readRPCFrame(r io.Reader, kind byte) ([]byte, error) {
	var header [framedRPCHeaderSize]byte
	if _, e := io.ReadFull(r, header[:]); e != nil {
		return nil, e
	}
	n, e := rpcFrameLength(header[:], kind)
	if e != nil {
		return nil, e
	}
	body := make([]byte, n)
	_, e = io.ReadFull(r, body)
	return body, e
}
func writeRPCFrame(w io.Writer, kind byte, body []byte) error {
	if len(body) == 0 || len(body) > maxRPCBytes || kind > framedRPCResponse {
		return errors.New("invalid RPC frame")
	}
	// A single normal write avoids a separate TLS record for the tiny header.
	packet := make([]byte, framedRPCHeaderSize+len(body))
	copy(packet, []byte{'F', 'T', 1, kind})
	binary.BigEndian.PutUint32(packet[4:8], uint32(len(body)))
	copy(packet[8:], body)
	for len(packet) > 0 {
		n, e := w.Write(packet)
		if n < 0 || n > len(packet) {
			return io.ErrShortWrite
		}
		packet = packet[n:]
		if e != nil {
			return e
		}
		if n == 0 {
			return io.ErrShortWrite
		}
	}
	return nil
}

type framedRPCClient struct {
	mu      sync.Mutex
	gate    chan struct{}
	address string
	config  *tls.Config
	dial    func(context.Context, string, string) (net.Conn, error)
	conn    *tls.Conn
	cancel  context.CancelFunc
	closed  bool
}

func newFramedRPCClient(address string, config *tls.Config, dial func(context.Context, string, string) (net.Conn, error)) *framedRPCClient {
	cfg := config.Clone()
	cfg.NextProtos = []string{framedRPCALPN}
	return &framedRPCClient{gate: make(chan struct{}, 1), address: address, config: cfg, dial: dial}
}
func (c *framedRPCClient) Close() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.closed = true
	if c.cancel != nil {
		c.cancel()
	}
	if c.conn != nil {
		// Abort the underlying counted/paced socket directly. TLS close-notify
		// must not keep a cancelled operation waiting on test pacing or writes.
		_ = c.conn.NetConn().Close()
		c.conn = nil
	}
}
func (c *framedRPCClient) exchange(ctx context.Context, body []byte) (reply []byte, err error) {
	if len(body) == 0 || len(body) > maxRPCBytes {
		return nil, errors.New("invalid RPC body")
	}
	ctx, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	select {
	case c.gate <- struct{}{}:
		defer func() { <-c.gate }()
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil, net.ErrClosed
	}
	c.cancel = cancel
	conn := c.conn
	c.mu.Unlock()
	defer func() {
		c.mu.Lock()
		defer c.mu.Unlock()
		c.cancel = nil
		if err != nil && conn != nil {
			_ = conn.NetConn().Close()
			if c.conn == conn {
				c.conn = nil
			}
		}
	}()
	fresh := conn == nil
	if fresh {
		raw, e := c.dial(ctx, "tcp", c.address)
		if e != nil {
			return nil, e
		}
		conn = tls.Client(raw, c.config)
	}
	// Also interrupt application-level test pacing, whose timers are outside
	// socket deadlines. No failed/ambiguous exchange is retried automatically.
	stopClose := context.AfterFunc(ctx, func() { _ = conn.NetConn().Close() })
	defer stopClose()
	deadline, _ := ctx.Deadline()
	if e := conn.SetDeadline(deadline); e != nil {
		return nil, e
	}
	if fresh {
		if e := conn.HandshakeContext(ctx); e != nil {
			return nil, e
		}
		if conn.ConnectionState().NegotiatedProtocol != framedRPCALPN {
			return nil, errors.New("unexpected RPC ALPN; no fallback")
		}
		c.mu.Lock()
		if c.closed {
			c.mu.Unlock()
			return nil, net.ErrClosed
		}
		c.conn = conn
		c.mu.Unlock()
	}
	if e := writeRPCFrame(conn, framedRPCRequest, body); e != nil {
		return nil, e
	}
	return readRPCFrame(conn, framedRPCResponse)
}

type framedRPCTimeouts struct{ handshake, idle, header, body, write time.Duration }

var defaultFramedRPCTimeouts = framedRPCTimeouts{3 * time.Second, 30 * time.Second, 2 * time.Second, 5 * time.Second, 10 * time.Second}

type framedRPCServer struct {
	mu       sync.Mutex
	wg       sync.WaitGroup
	listener net.Listener
	config   *tls.Config
	conns    map[*tls.Conn]struct{}
	closed   bool
	busy     chan struct{}
	timeouts framedRPCTimeouts
	handle   func(rpcRequest) (rpcResponse, error)
	counts   *wireCounter
	budget   *rpcWorkBudget
}

func newFramedRPCServer(listener net.Listener, config *tls.Config, counts *wireCounter, handle func(rpcRequest) (rpcResponse, error)) *framedRPCServer {
	return newFramedRPCServerWithBudget(listener, config, counts, handle, newRPCWorkBudget(nil))
}

// Share budget when one receiving role exposes multiple listeners. A nil
// budget fails closed instead of accidentally granting a fresh allowance.
func newFramedRPCServerWithBudget(listener net.Listener, config *tls.Config, counts *wireCounter, handle func(rpcRequest) (rpcResponse, error), budget *rpcWorkBudget) *framedRPCServer {
	cfg := config.Clone()
	cfg.NextProtos = []string{framedRPCALPN}
	return &framedRPCServer{listener: listener, config: cfg, conns: make(map[*tls.Conn]struct{}), busy: make(chan struct{}, 1), timeouts: defaultFramedRPCTimeouts, handle: handle, counts: counts, budget: budget}
}
func (s *framedRPCServer) Close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return
	}
	s.closed = true
	_ = s.listener.Close()
	for conn := range s.conns {
		_ = conn.NetConn().Close()
	}
}
func (s *framedRPCServer) Serve() error {
	defer func() { s.Close(); s.wg.Wait() }()
	for {
		raw, e := s.listener.Accept()
		if e != nil {
			s.mu.Lock()
			closed := s.closed
			s.mu.Unlock()
			if closed {
				return nil
			}
			return e
		}
		s.mu.Lock()
		if s.closed || len(s.conns) >= framedRPCMaxConnections || !s.budget.allowHandshake() {
			s.mu.Unlock()
			_ = raw.Close()
			continue
		}
		// Charge before constructing TLS state or starting authentication.
		conn := tls.Server(raw, s.config)
		s.conns[conn] = struct{}{}
		s.wg.Add(1)
		s.mu.Unlock()
		go func() {
			defer s.wg.Done()
			defer func() { _ = conn.NetConn().Close(); s.mu.Lock(); delete(s.conns, conn); s.mu.Unlock() }()
			s.serveConn(conn)
		}()
	}
}
func (s *framedRPCServer) serveConn(conn *tls.Conn) {
	if conn.SetDeadline(time.Now().Add(s.timeouts.handshake)) != nil || conn.Handshake() != nil || conn.ConnectionState().NegotiatedProtocol != framedRPCALPN {
		return
	}
	if conn.SetDeadline(time.Time{}) != nil {
		return
	}
	for {
		var header [framedRPCHeaderSize]byte
		if conn.SetReadDeadline(time.Now().Add(s.timeouts.idle)) != nil {
			return
		}
		if _, e := io.ReadFull(conn, header[:1]); e != nil {
			return
		}
		if conn.SetReadDeadline(time.Now().Add(s.timeouts.header)) != nil {
			return
		}
		if _, e := io.ReadFull(conn, header[1:]); e != nil {
			return
		}
		if conn.SetReadDeadline(time.Now().Add(s.timeouts.body)) != nil {
			return
		}
		body, e := readBudgetedRPCBody(conn, header[:], framedRPCRequest, s.budget)
		if e != nil {
			return
		}
		var q rpcRequest
		if decodeRPC("cbor-v1", body, &q) != nil {
			return
		}
		var response rpcResponse
		select {
		case s.busy <- struct{}{}:
			response, e = s.handle(q)
			<-s.busy
			if e != nil {
				response = rpcResponse{Error: e.Error()}
				if response.Error == "" {
					response.Error = "RPC rejected"
				}
			}
		default:
			response = rpcResponse{Error: "busy"}
		}
		response.ReadBytes, response.WrittenBytes = s.counts.read.Load(), s.counts.written.Load()
		encoded, e := encodeRPC("cbor-v1", response)
		if e != nil {
			return
		}
		if conn.SetWriteDeadline(time.Now().Add(s.timeouts.write)) != nil || writeRPCFrame(conn, framedRPCResponse, encoded) != nil {
			return
		}
	}
}
