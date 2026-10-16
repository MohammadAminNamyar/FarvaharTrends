package main

// Laboratory-only private parent/child pipe. Plaintext never enters the TLS
// peer RPC. This is an integration harness, not a public enqueue endpoint or APK.
import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"time"
)

type localIPCRequest struct {
	ID             uint64
	Enqueue        *localSubmission `json:",omitempty"`
	StatusSequence uint64           `json:",omitempty"`
	Diagnostics    bool             `json:",omitempty"`
}
type localIPCResponse struct {
	ID          uint64
	Receipt     localReceipt
	Error       string                 `json:",omitempty"`
	Diagnostics *localDiagnosticReport `json:",omitempty"`
}
type nodeReady struct {
	Ready         bool
	Address, Role string
	WireCodec     string
	Index, PID    int
}

func boundedPipeScanner(r io.Reader) *bufio.Scanner {
	s := bufio.NewScanner(r)
	s.Buffer(make([]byte, 2048), 16384)
	return s
}

func readNodeReady(r io.Reader) (nodeReady, *bufio.Scanner, error) {
	type observation struct {
		value   nodeReady
		scanner *bufio.Scanner
		err     error
	}
	done := make(chan observation, 1)
	go func() {
		s := boundedPipeScanner(r)
		var value nodeReady
		if !s.Scan() {
			e := s.Err()
			if e == nil {
				e = io.EOF
			}
			done <- observation{err: e}
			return
		}
		e := json.Unmarshal(s.Bytes(), &value)
		done <- observation{value, s, e}
	}()
	select {
	case got := <-done:
		return got.value, got.scanner, got.err
	case <-time.After(10 * time.Second):
		return nodeReady{}, nil, errors.New("role startup timed out")
	}
}
func (n *remoteRole) startPrivateReplies(s *bufio.Scanner) {
	ch := make(chan localIPCResponse, 1)
	n.localReplies = ch
	go func() {
		defer close(ch)
		for s.Scan() {
			var r localIPCResponse
			if json.Unmarshal(s.Bytes(), &r) != nil {
				return
			}
			select {
			case ch <- r:
			default:
				return
			}
		}
	}()
}
func (n *remoteRole) privateCall(q localIPCRequest) (localReceipt, error) {
	r, e := n.privateExchange(q)
	return r.Receipt, e
}

func (n *remoteRole) privateExchange(q localIPCRequest) (localIPCResponse, error) {
	n.localMu.Lock()
	defer n.localMu.Unlock()
	n.localID++
	if n.localID == 0 {
		return localIPCResponse{}, errors.New("private request ID exhausted")
	}
	q.ID = n.localID
	b, e := json.Marshal(q)
	if e != nil {
		return localIPCResponse{}, e
	}
	if len(b) > 16000 {
		return localIPCResponse{}, errors.New("private command too large")
	}
	timer := time.NewTimer(12 * time.Second)
	defer timer.Stop()
	written := make(chan error, 1)
	go func() { _, e := n.keepAlive.Write(append(b, '\n')); written <- e }()
	select {
	case e = <-written:
		if e != nil {
			return localIPCResponse{}, e
		}
	case <-timer.C:
		_ = n.keepAlive.Close()
		return localIPCResponse{}, errors.New("private write timeout; status unknown")
	}
	select {
	case r, ok := <-n.localReplies:
		if !ok || r.ID != q.ID {
			_ = n.keepAlive.Close()
			return localIPCResponse{}, errors.New("private reply unavailable or mismatched")
		}
		if r.Error != "" {
			return localIPCResponse{}, fmt.Errorf("local command rejected: %s", r.Error)
		}
		return r, nil
	case <-timer.C:
		_ = n.keepAlive.Close()
		return localIPCResponse{}, errors.New("private command timeout; reconnect and retry same submission sequence")
	}
}
func servePrivatePipe(n *roleNode) {
	servePrivateStream(n, os.Stdin, os.Stdout)
}
func servePrivateStream(n *roleNode, input io.Reader, output io.Writer) {
	s := boundedPipeScanner(input)
	writer := json.NewEncoder(output)
	for s.Scan() {
		var q localIPCRequest
		d := json.NewDecoder(bytes.NewReader(s.Bytes()))
		d.DisallowUnknownFields()
		if d.Decode(&q) != nil {
			return
		}
		var extra any
		if d.Decode(&extra) != io.EOF {
			return
		}
		choices := 0
		if q.Enqueue != nil {
			choices++
		}
		if q.StatusSequence != 0 {
			choices++
		}
		if q.Diagnostics {
			choices++
		}
		if q.ID == 0 || choices != 1 {
			return
		}
		var receipt localReceipt
		var e error
		var diagnostics *localDiagnosticReport
		if q.Enqueue != nil {
			receipt, e = n.enqueueLocal(*q.Enqueue)
		} else if q.Diagnostics {
			value := n.privateDiagnostics()
			diagnostics = &value
		} else {
			receipt, e = n.localStatus(q.StatusSequence)
		}
		r := localIPCResponse{ID: q.ID, Receipt: receipt, Diagnostics: diagnostics}
		if e != nil {
			r.Error = e.Error()
		}
		if writer.Encode(r) != nil {
			return
		}
	}
}
