package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sync"
	"time"
)

type remoteRole struct {
	localMu      sync.Mutex
	localID      uint64
	localReplies <-chan localIPCResponse
	restarts     []map[string]any
	profile      linkProfile
	name         string
	address      string
	command      *exec.Cmd
	client       *http.Client
	transport    *http.Transport
	framed       *framedRPCClient
	counter      *wireCounter
	log          *os.File
	keepAlive    io.WriteCloser
}

func (n *remoteRole) call(q rpcRequest) (rpcResponse, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	if e := profileDelay(ctx, time.Duration(n.profile.RoundTripMs)*time.Millisecond/2); e != nil {
		return rpcResponse{}, e
	}
	raw, e := encodeRPC(n.profile.WireCodec, q)
	if e != nil {
		return rpcResponse{}, e
	}
	if len(raw) > maxRPCBytes {
		return rpcResponse{}, errors.New("request exceeds network limit")
	}
	if n.profile.WireCodec == "cbor-framed-v1" {
		if n.framed == nil {
			return rpcResponse{}, errors.New("missing framed RPC transport")
		}
		data, e := n.framed.exchange(ctx, raw)
		if e != nil {
			return rpcResponse{}, fmt.Errorf("%s framed RPC: %w", n.name, e)
		}
		var out rpcResponse
		if e = decodeRPC("cbor-framed-v1", data, &out); e != nil {
			n.framed.Close()
			return out, fmt.Errorf("%s invalid compact RPC response; connection fenced", n.name)
		}
		if out.Error != "" {
			return out, fmt.Errorf("%s rejected: %s", n.name, out.Error)
		}
		if e = profileDelay(ctx, time.Duration(n.profile.RoundTripMs)*time.Millisecond/2); e != nil {
			return out, e
		}
		return out, nil
	}
	req, e := http.NewRequestWithContext(ctx, "POST", "https://"+n.address+"/round", bytes.NewReader(raw))
	if e != nil {
		return rpcResponse{}, e
	}
	req.Header.Set("Content-Type", rpcContentType(n.profile.WireCodec))
	response, e := n.client.Do(req)
	if e != nil {
		return rpcResponse{}, fmt.Errorf("%s RPC: %w", n.name, e)
	}
	defer response.Body.Close()
	data, e := io.ReadAll(io.LimitReader(response.Body, maxRPCBytes+1))
	if e != nil {
		return rpcResponse{}, e
	}
	if len(data) > maxRPCBytes {
		return rpcResponse{}, errors.New("oversized role response")
	}
	var out rpcResponse
	if n.profile.WireCodec == "cbor-v1" && response.Header.Get("Content-Type") != compactRPCContentType {
		return out, fmt.Errorf("%s %s HTTP %d: unexpected RPC codec; no fallback", n.name, q.Op, response.StatusCode)
	}
	if e = decodeRPC(n.profile.WireCodec, data, &out); e != nil {
		// HTTP request bounds/deadlines can return a plain-text error. Keep the
		// role, operation and status so a failed link profile is diagnosable;
		// never include response bodies, which could contain test payloads.
		return out, fmt.Errorf("%s %s HTTP %d: invalid RPC response (%d bytes)", n.name, q.Op, response.StatusCode, len(data))
	}
	if response.StatusCode != http.StatusOK || out.Error != "" {
		return out, fmt.Errorf("%s rejected: %s", n.name, out.Error)
	}
	if e = profileDelay(ctx, time.Duration(n.profile.RoundTripMs)*time.Millisecond/2); e != nil {
		return rpcResponse{}, e
	}
	return out, nil
}

type networkLab struct {
	atomicPublication      bool
	frozenCompletion       bool
	scheduleAdmissionLead  time.Duration
	localOutboxes          bool
	fuseReservationPrepare bool
	fusedInputs            []rpcInput
	fusedDescriptorHash    [32]byte
	// Only the journal component benchmark uses a sequential local adapter.
	// Normal network experiments always use the actual role sockets below.
	componentCall      func(int, rpcRequest) (rpcResponse, error)
	durable            bool
	crashReplay        bool
	replayedAfterCrash int
	anonymousSetup     bool
	setupMetrics       map[string]interface{}
	profile            linkProfile
	directory          string
	public             *fixture
	nodes              []*remoteRole
	closed             bool
	initialStats       []rpcResponse
}

func saveJSON(path string, v interface{}) error {
	raw, e := json.MarshalIndent(v, "", "  ")
	if e != nil {
		return e
	}
	return os.WriteFile(path, append(raw, '\n'), 0600)
}
func snapshotLabSources(dir string) error {
	target := filepath.Join(dir, "source")
	if e := os.MkdirAll(target, 0700); e != nil {
		return e
	}
	hashes := map[string]string{}
	for _, module := range []string{"roundprobe", "setupprobe", "verdictprobe"} {
		root := filepath.Join("tools/privacy_lab", module)
		if e := filepath.WalkDir(root, func(path string, item fs.DirEntry, e error) error {
			if e != nil {
				return e
			}
			if item.IsDir() {
				return nil
			}
			name := item.Name()
			if filepath.Ext(name) != ".go" && name != "go.mod" && name != "go.sum" {
				return nil
			}
			rel, e := filepath.Rel(root, path)
			if e != nil {
				return e
			}
			key := filepath.ToSlash(filepath.Join(module, rel))
			b, e := os.ReadFile(path)
			if e != nil {
				return e
			}
			h := sha256.Sum256(b)
			hashes[key] = hex.EncodeToString(h[:])
			dest := filepath.Join(target, key)
			if e = os.MkdirAll(filepath.Dir(dest), 0700); e != nil {
				return e
			}
			return os.WriteFile(dest, b, 0600)
		}); e != nil {
			return e
		}
	}
	executable, e := os.Executable()
	if e != nil {
		return e
	}
	raw, e := os.ReadFile(executable)
	if e != nil {
		return e
	}
	h := sha256.Sum256(raw)
	hashes["worker-binary"] = hex.EncodeToString(h[:])
	if e = os.WriteFile(filepath.Join(dir, "worker-binary"), raw, 0700); e != nil {
		return e
	}
	return saveJSON(filepath.Join(dir, "source-hashes.json"), hashes)
}
func newNetworkLab() (*networkLab, error) {
	return newNetworkLabWithProfile(linkProfile{})
}
func newNetworkLabWithProfile(profile linkProfile) (*networkLab, error) {
	return newNetworkLabOptions(profile, false)
}
func newNetworkLabOptions(profile linkProfile, anonymous bool) (*networkLab, error) {
	return newNetworkLabExperiment(profile, anonymous, -1)
}
func newNetworkLabExperiment(profile linkProfile, anonymous bool, corruptClient int) (*networkLab, error) {
	return newNetworkLabConfigured(profile, anonymous, corruptClient, false)
}
func newNetworkLabConfigured(profile linkProfile, anonymous bool, corruptClient int, durable bool) (*networkLab, error) {
	return newNetworkLabConfiguredOutbox(profile, anonymous, corruptClient, durable, false)
}
func newNetworkLabConfiguredOutbox(profile linkProfile, anonymous bool, corruptClient int, durable, outbox bool) (*networkLab, error) {
	return newNetworkLabCommonSchedule(profile, anonymous, corruptClient, durable, outbox, false)
}
func newNetworkLabCommonSchedule(profile linkProfile, anonymous bool, corruptClient int, durable, outbox, scheduled bool) (*networkLab, error) {
	return newNetworkLabPublicationStorage(profile, anonymous, corruptClient, durable, outbox, scheduled, false)
}
func newNetworkLabPublicationStorage(profile linkProfile, anonymous bool, corruptClient int, durable, outbox, scheduled, atomicPublication bool) (*networkLab, error) {
	return newNetworkLabCompletion(profile, anonymous, corruptClient, durable, outbox, scheduled, atomicPublication, false)
}
func newNetworkLabCompletion(profile linkProfile, anonymous bool, corruptClient int, durable, outbox, scheduled, atomicPublication, frozenCompletion bool) (*networkLab, error) {
	requireProfile(profile)
	root := ".local-only/privacy-lab"
	if e := os.MkdirAll(root, 0700); e != nil {
		return nil, e
	}
	dir, e := os.MkdirTemp(root, "roles-")
	if e != nil {
		return nil, e
	}
	dir, e = filepath.Abs(dir)
	if e != nil {
		return nil, e
	}
	lab := &networkLab{directory: dir, profile: profile, anonymousSetup: anonymous, durable: durable, localOutboxes: outbox, atomicPublication: atomicPublication, frozenCompletion: frozenCompletion}
	if !anonymous {
		lab.public = newFixtureWithLimit(clients)
	}
	if e = snapshotLabSources(dir); e != nil {
		return nil, e
	}
	controlCert, controlKey := laboratoryCertificate("isolated-lab-controller")
	control, e := tls.X509KeyPair(controlCert, controlKey)
	if e != nil {
		return nil, e
	}
	exe, e := os.Executable()
	if e != nil {
		return nil, e
	}
	failed := true
	defer func() {
		if failed {
			lab.close()
		}
	}()
	for id := 0; id < clients+coordinators; id++ {
		role, index := "client", id
		if id >= clients {
			role = "coordinator"
			index = id - clients
		}
		c := nodeConfig{AnonymousSetup: true, Role: role, Index: index, SlotLimit: clients, Slot: -1}
		if !anonymous {
			c = configFor(lab.public, role, index)
		}
		c.AllowFaultInjection = role == "client" && index == corruptClient
		c.Durable = durable
		c.AtomicPublication = atomicPublication
		c.RequireCommonSchedule = scheduled
		c.FrozenCompletion = frozenCompletion
		c.RoleLocalOutbox = outbox && role == "client"
		c.Certificate, c.CertificateKey = laboratoryCertificate(fmt.Sprintf("lab-%s-%d", role, index))
		c.ControlCertificate = controlCert
		cfgPath := filepath.Join(dir, fmt.Sprintf("%s-%d-config.json", role, index))
		if e = saveJSON(cfgPath, c); e != nil {
			return nil, e
		}
		n := &remoteRole{name: fmt.Sprintf("%s-%d", role, index), counter: new(wireCounter), profile: profile}
		lab.nodes = append(lab.nodes, n)
		n.log, e = os.Create(filepath.Join(dir, n.name+"-stderr.txt"))
		if e != nil {
			return nil, e
		}
		n.command = exec.Command(exe, "-mode", "node", "-config", cfgPath, "-listen", "127.0.0.1:0", "-wire", profile.WireCodec)
		n.command.Stderr = n.log
		n.keepAlive, e = n.command.StdinPipe()
		if e != nil {
			return nil, e
		}
		stdout, e := n.command.StdoutPipe()
		if e != nil {
			return nil, e
		}
		if e = n.command.Start(); e != nil {
			return nil, e
		}
		ready, scanner, e := readNodeReady(stdout)
		if e != nil || !ready.Ready || ready.Role != role || ready.Index != index || ready.WireCodec != profile.WireCodec {
			return nil, fmt.Errorf("role startup failed: %s %v", n.name, e)
		}
		n.address = ready.Address
		n.startPrivateReplies(scanner)
		host, _, e := net.SplitHostPort(n.address)
		if e != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() {
			return nil, errors.New("unexpected non-loopback lab address")
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(c.Certificate) {
			return nil, errors.New("bad pinned role certificate")
		}
		dialer := &net.Dialer{Timeout: 3 * time.Second}
		tlsConfig := &tls.Config{MinVersion: tls.VersionTLS13, RootCAs: pool, Certificates: []tls.Certificate{control}, ServerName: "localhost"}
		dial := func(ctx context.Context, network, address string) (net.Conn, error) {
			conn, e := dialer.DialContext(ctx, network, address)
			if e != nil {
				return nil, e
			}
			return paceConnection(&countedConn{conn, n.counter}, profile.Kbps), nil
		}
		if profile.WireCodec == "cbor-framed-v1" {
			n.framed = newFramedRPCClient(n.address, tlsConfig, dial)
		} else {
			n.transport = &http.Transport{Proxy: nil, DisableCompression: true, MaxConnsPerHost: 1, MaxIdleConnsPerHost: 1, IdleConnTimeout: 30 * time.Second, TLSClientConfig: tlsConfig, DialContext: dial}
			n.client = &http.Client{Transport: n.transport, Timeout: 10 * time.Second}
		}
	}
	// The orchestrator keeps public descriptors/slot mapping for checking test
	// payloads, but drops the private role material after provisioning children.
	if anonymous {
		if e = lab.establishSetup(); e != nil {
			return nil, e
		}
	} else {
		for c := range clients {
			lab.public.clientKeys[c].private = nil
			lab.public.slotKeys[c].private = nil
			for s := range coordinators {
				lab.public.seeds[c][s] = [32]byte{}
				lab.public.seedAvailable[c][s] = false
			}
		}
		for s := range coordinators {
			lab.public.serverKeys[s].private = nil
		}
	}
	lab.initialStats, e = lab.stats()
	if e != nil {
		return nil, e
	}
	failed = false
	return lab, nil
}
func (lab *networkLab) stats() ([]rpcResponse, error) {
	out := []rpcResponse{}
	for _, n := range lab.nodes {
		r, e := n.call(rpcRequest{Op: "stats"})
		if e != nil {
			return nil, e
		}
		out = append(out, r)
	}
	return out, nil
}
func (lab *networkLab) bytes() uint64 {
	var n uint64
	for _, node := range lab.nodes {
		n += node.counter.read.Load() + node.counter.written.Load()
	}
	return n
}
func (lab *networkLab) close() {
	if lab.closed {
		return
	}
	lab.closed = true
	records := make([]map[string]interface{}, len(lab.nodes))
	type finalStat struct {
		index    int
		response rpcResponse
		err      error
		local    *localDiagnosticReport
		localErr error
	}
	stats := make(chan finalStat, len(lab.nodes))
	pending := 0
	for i, n := range lab.nodes {
		records[i] = map[string]interface{}{"name": n.name, "wireReadBytes": n.counter.read.Load(), "wireWrittenBytes": n.counter.written.Load()}
		if lab.localOutboxes && i < clients {
			records[i]["peerCpuAndStorageCountersRedacted"] = true
		}
		if n.client != nil || n.framed != nil {
			pending++
			go func(i int, n *remoteRole) {
				r, e := n.call(rpcRequest{Op: "stats"})
				local, localErr := n.privateExchange(localIPCRequest{Diagnostics: true})
				stats <- finalStat{i, r, e, local.Diagnostics, localErr}
			}(i, n)
		}
	}
	deadline := time.NewTimer(2 * time.Second)
	for pending > 0 {
		select {
		case item := <-stats:
			pending--
			row := records[item.index]
			if item.localErr != nil {
				row["privateDiagnosticsError"] = item.localErr.Error()
			} else if item.local != nil {
				row["privateDiagnostics"] = item.local
			}
			if item.err != nil {
				row["finalStatsError"] = item.err.Error()
			} else {
				row["finalStats"] = item.response
				if !(lab.localOutboxes && item.index < clients) && item.index < len(lab.initialStats) && len(lab.nodes[item.index].restarts) == 0 {
					row["cpuDeltaMsIncludingControl"] = item.response.CPUms - lab.initialStats[item.index].CPUms
				}
			}
		case <-deadline.C:
			for _, row := range records {
				if row["finalStats"] == nil && row["finalStatsError"] == nil {
					row["finalStatsError"] = "bounded final-stat collection expired"
				}
			}
			pending = 0
		}
	}
	deadline.Stop()
	for i, n := range lab.nodes {
		row := records[i]
		row["restarts"] = n.restarts
		if n.transport != nil {
			n.transport.CloseIdleConnections()
		}
		if n.framed != nil {
			n.framed.Close()
		}
		if n.keepAlive != nil {
			_ = n.keepAlive.Close()
		}
		if n.command != nil && n.command.Process != nil {
			e := n.command.Process.Kill()
			row["ownedProcessStopRequested"] = e == nil
			wait := n.command.Wait()
			row["reaped"] = n.command.ProcessState != nil
			if wait != nil {
				row["stopResult"] = wait.Error()
			}
		}
		if n.log != nil {
			_ = n.log.Close()
		}
	}
	_ = saveJSON(filepath.Join(lab.directory, "lifecycle.json"), map[string]interface{}{"nodes": records, "scope": "owned temporary local processes; intentional stop after measurement", "productionIntegrationAllowed": false})
}
func (lab *networkLab) parallel(ids []int, makeRequest func(int) rpcRequest) ([]rpcResponse, error) {
	out := make([]rpcResponse, len(ids))
	errs := make([]error, len(ids))
	requests := make([]rpcRequest, len(ids))
	var wg sync.WaitGroup
	for at, id := range ids {
		requests[at] = makeRequest(at)
		if lab.componentCall != nil {
			out[at], errs[at] = lab.componentCall(id, requests[at])
			continue
		}
		wg.Add(1)
		go func(at, id int) { defer wg.Done(); out[at], errs[at] = lab.nodes[id].call(requests[at]) }(at, id)
	}
	wg.Wait()
	for _, e := range errs {
		if e != nil {
			return nil, e
		}
	}
	if lab.crashReplay {
		for at, id := range ids {
			if (id != 0 && id != clients) || requests[at].Op == "stats" {
				continue
			}
			n := lab.nodes[id]
			if e := n.crashRestart(); e != nil {
				return nil, e
			}
			again, e := n.call(requests[at])
			if e != nil {
				return nil, e
			}
			a, b := out[at], again
			a.ReadBytes, a.WrittenBytes, b.ReadBytes, b.WrittenBytes = 0, 0, 0, 0
			if !bytes.Equal(encodeSetup(a), encodeSetup(b)) {
				return nil, errors.New("committed response changed after process crash")
			}
			lab.replayedAfterCrash++
		}
	}
	return out, nil
}
func allClientIDs() []int {
	out := []int{}
	for i := range clients {
		out = append(out, i)
	}
	return out
}
func allCoordinatorIDs() []int {
	out := []int{}
	for i := range coordinators {
		out = append(out, clients+i)
	}
	return out
}
func (lab *networkLab) run(d descriptor, payloads map[int][]byte) (out result, err error) {
	if lab.localOutboxes && len(payloads) != 0 {
		return out, errors.New("outbox experiment forbids injected peer payloads")
	}
	out.phaseTimings = map[string]float64{}
	phaseStarted := time.Now()
	markPhase := func(name string) {
		out.phaseTimings[name] = ms(time.Since(phaseStarted))
		phaseStarted = time.Now()
	}
	if !lab.public.allowed(d) {
		return out, errors.New("unexpected controller round")
	}
	for id, p := range payloads {
		if id < 0 || id >= clients || len(p) > cellCapacity(d) {
			return out, errors.New("invalid controller payload")
		}
	}
	before := lab.bytes()
	defer func() { out.transportBytes = lab.bytes() - before }()
	wireD := descriptorRPC(d)
	xs := []rpcInput{}
	var r []rpcResponse
	var e error
	if lab.fuseReservationPrepare && d.phase == 1 {
		if !lab.localOutboxes || len(payloads) != 0 || len(lab.fusedInputs) != clients || lab.fusedDescriptorHash != hash(d.wire()) {
			return out, errors.New("missing or mismatched fused contributions")
		}
		xs = copyRPCInputs(lab.fusedInputs)
		markPhase("reuseFusedInputsMs")
	} else {
		r, e = lab.parallel(allClientIDs(), func(i int) rpcRequest { return rpcRequest{Op: "prepare", Descriptor: wireD, Payload: payloads[i]} })
		markPhase("clientPrepareMs")
		if e != nil {
			return out, e
		}
		for _, v := range r {
			if v.Input == nil {
				return out, errors.New("missing client input")
			}
			xs = append(xs, *v.Input)
		}
	}
	r, e = lab.parallel(allCoordinatorIDs(), func(i int) rpcRequest { return rpcRequest{Op: "commit", Descriptor: wireD, Inputs: xs} })
	markPhase("coordinatorCommitMs")
	if e != nil {
		return out, e
	}
	votes := []rpcVote{}
	for _, v := range r {
		if v.Vote == nil {
			return out, errors.New("missing vote")
		}
		votes = append(votes, *v.Vote)
	}
	r, e = lab.parallel(allCoordinatorIDs(), func(i int) rpcRequest { return rpcRequest{Op: "release", Descriptor: wireD, Votes: votes} })
	markPhase("coordinatorReleaseMs")
	if e != nil {
		return out, e
	}
	shares := []rpcShare{}
	for _, v := range r {
		if v.Share == nil {
			return out, errors.New("missing share")
		}
		shares = append(shares, *v.Share)
	}
	r, e = lab.parallel(allCoordinatorIDs(), func(i int) rpcRequest {
		return rpcRequest{Op: "finish", Descriptor: wireD, Root: votes[0].Root, Shares: shares}
	})
	markPhase("coordinatorFinishMs")
	if e != nil {
		return out, e
	}
	root, raw := r[0].Root, r[0].Output
	if len(root) != 32 || len(raw) != d.size() {
		return out, errors.New("invalid public result")
	}
	signatures := [][]byte{}
	for i, v := range r {
		if !bytes.Equal(v.Root, root) || !bytes.Equal(v.Output, raw) || !ed25519.Verify(lab.public.serverKeys[i].pub, outputSigned(d, root, raw), v.Signature) {
			return out, errors.New("inconsistent output certificate")
		}
		signatures = append(signatures, v.Signature)
	}
	acceptOp := "accept"
	if lab.fuseReservationPrepare && d.phase == 0 {
		if !lab.localOutboxes || len(lab.fusedInputs) != 0 {
			return out, errors.New("invalid fused reservation state")
		}
		acceptOp = "accept-and-prepare"
	}
	r, e = lab.parallel(allClientIDs(), func(i int) rpcRequest {
		return rpcRequest{Op: acceptOp, Descriptor: wireD, Root: root, Output: raw, Signatures: signatures}
	})
	if acceptOp == "accept-and-prepare" {
		markPhase("clientAcceptAndPrepareMs")
	} else {
		markPhase("clientAcceptMs")
	}
	if e != nil {
		return out, e
	}
	out.raw = raw
	out.messages, e = lab.public.decode(d, raw)
	if e != nil {
		return out, e
	}
	out.transportBytes = lab.bytes() - before
	lab.public.advance(d, out)
	if acceptOp == "accept-and-prepare" {
		for _, v := range r {
			if len(out.messages) == 0 {
				if v.Input != nil {
					return out, errors.New("idle reservation returned a bulk contribution")
				}
			} else {
				if v.Input == nil {
					return out, errors.New("fused reservation omitted a bulk contribution")
				}
				lab.fusedInputs = append(lab.fusedInputs, *v.Input)
			}
		}
		lab.fusedDescriptorHash = hash(lab.public.expected.wire())
	} else if lab.fuseReservationPrepare && d.phase == 1 {
		lab.fusedInputs = nil
		lab.fusedDescriptorHash = [32]byte{}
	}
	markPhase("controllerDecodeMs")
	return out, nil
}
func networkMeasure(samples, size, senders int, profile linkProfile) {
	networkMeasureWithSetup(samples, size, senders, profile, false)
}
func networkMeasureWithSetup(samples, size, senders int, profile linkProfile, anonymous bool) {
	lab, e := newNetworkLabOptions(profile, anonymous)
	must(e)
	defer lab.close()
	report := map[string]interface{}{"schema": 1, "scope": "11 separate processes and mutually authenticated loopback TLS; controller-mediated RPC, no scheduled wait, no mobile radio, centralized setup", "os": runtime.GOOS, "arch": runtime.GOARCH, "runtime": runtime.Version(), "requestedSamples": samples, "warmups": 5, "simultaneousPublishers": senders, "payloadBytes": size, "securityGatePassed": false, "productionIntegrationAllowed": false, "directory": lab.directory}
	report["linkProfile"] = profile
	if anonymous {
		report["scope"] = "11 independent role processes and loopback mutual TLS; role-local anonymous setup; controller RPC topology; no scheduled wait, admission guarantee or mobile radio"
		report["anonymousSetup"] = lab.setupMetrics
	}
	report["pacingScope"] = "application read/write pacing per role and direction; added latency per RPC; not a real network or TCP emulator"
	rows := []map[string]interface{}{}
	times := []float64{}
	var fatal error
	for sample := -5; sample < samples; sample++ {
		round := uint64(sample + 5)
		requests := map[int][]byte{}
		messages := map[int][]byte{}
		for c := range senders {
			id := (sample + 5 + c) % clients
			requests[id] = []byte{1}
			messages[id] = payloadFixture(size)
		}
		start := time.Now()
		cpuStart := cpuTime()
		r, e := lab.run(lab.public.reservation(round), requests)
		var b result
		if e == nil && senders > 0 {
			b, e = lab.run(lab.public.bulk(round, r, maxCell), messages)
		}
		elapsed := ms(time.Since(start))
		cpu := ms(cpuTime() - cpuStart)
		row := map[string]interface{}{"sample": sample, "warmup": sample < 0, "controllerRoundMs": elapsed, "controllerCPUms": cpu, "allLinksTLSPayloadBytes": r.transportBytes + b.transportBytes, "received": e == nil}
		if e == nil && senders > 0 {
			if len(b.messages) != senders {
				e = errors.New("wrong delivered count")
			}
			if !samePayloadMultiset(b, messages) {
				e = errors.New("payload multiset mismatch")
			}
		}
		if e != nil {
			row["received"] = false
			row["error"] = e.Error()
			fatal = e
		}
		rows = append(rows, row)
		if fatal != nil {
			break
		}
		if sample >= 0 {
			times = append(times, elapsed)
		}
	}
	report["rows"] = rows
	report["successfulMeasured"] = len(times)
	attempted := 0
	for _, row := range rows {
		if row["warmup"] == false {
			attempted++
		}
	}
	report["attemptedMeasured"] = attempted
	report["failedMeasured"] = attempted - len(times)
	failedWarmups := 0
	for _, row := range rows {
		if row["warmup"] == true && row["received"] == false {
			failedWarmups++
		}
	}
	report["failedWarmups"] = failedWarmups
	report["unattemptedMeasured"] = samples - attempted
	if len(times) > 0 {
		report["controllerRoundTiming"] = stats(times)
	}
	if fatal != nil {
		report["fatal"] = fatal.Error()
	}
	must(saveJSON(filepath.Join(lab.directory, "result.json"), report))
	must(json.NewEncoder(os.Stdout).Encode(map[string]interface{}{"result": filepath.Join(lab.directory, "result.json"), "summary": report["controllerRoundTiming"], "successfulMeasured": len(times), "fatal": report["fatal"]}))
	if fatal != nil {
		panic(fatal) // run deferred owned-process cleanup before failure exit
	}
}
