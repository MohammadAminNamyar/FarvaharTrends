package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

func networkChecks() {
	networkChecksWithSetup(false)
}
func networkChecksWithSetup(anonymous bool) {
	lab, e := newNetworkLabOptions(linkProfile{}, anonymous)
	must(e)
	defer lab.close()
	checks := map[string]bool{}
	started := time.Now()
	check := func(name string, ok bool) {
		checks[name] = ok
		if !ok {
			panic("network check failed: " + name)
		}
	}
	target := lab.nodes[0]
	noAuthTLS := target.transport.TLSClientConfig.Clone()
	noAuthTLS.Certificates = nil
	tr := &http.Transport{TLSClientConfig: noAuthTLS, Proxy: nil}
	unauthed := &http.Client{Transport: tr, Timeout: 3 * time.Second}
	response, e := unauthed.Post("https://"+target.address+"/round", "application/json", bytes.NewReader([]byte(`{"Op":"stats"}`)))
	if response != nil {
		response.Body.Close()
	}
	tr.CloseIdleConnections()
	check("mutualTLSRejectsUnauthenticatedClient", e != nil)
	for name, raw := range map[string][]byte{
		"truncatedJsonRejected": []byte(`{"Op":"prepare","Descriptor":`),
		"oversizedJsonRejected": append(append([]byte(`{"Op":"prepare","Payload":"`), bytes.Repeat([]byte("A"), maxRPCBytes)...), []byte(`"}`)...),
	} {
		req, e := http.NewRequest("POST", "https://"+target.address+"/round", bytes.NewReader(raw))
		must(e)
		response, e := target.client.Do(req)
		must(e)
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
		response.Body.Close()
		check(name, response.StatusCode == http.StatusBadRequest)
	}
	d := lab.public.reservation(0)
	wd := descriptorRPC(d)
	wrong := wd
	wrong.Sequence = 2
	_, e = target.call(rpcRequest{Op: "prepare", Descriptor: wrong})
	check("unexpectedRoundRejected", e != nil)
	inputs := []rpcInput{}
	for i, n := range lab.nodes[:clients] {
		payload := []byte(nil)
		if i == 0 {
			payload = []byte{1}
		}
		r, e := n.call(rpcRequest{Op: "prepare", Descriptor: wd, Payload: payload})
		must(e)
		inputs = append(inputs, *r.Input)
	}
	for _, n := range lab.nodes[clients:] {
		_, e = n.call(rpcRequest{Op: "commit", Descriptor: wd, Inputs: inputs[:clients-1]})
		check(n.name+"MissingInputRejected", e != nil)
	}
	corrupted := append([]rpcInput{}, inputs...)
	corrupted[1].Body = append([]byte{}, corrupted[1].Body...)
	corrupted[1].Body[0] ^= 1
	_, e = lab.nodes[clients].call(rpcRequest{Op: "commit", Descriptor: wd, Inputs: corrupted})
	check("changedInputSignatureRejected", e != nil)
	votes := []rpcVote{}
	for _, n := range lab.nodes[clients:] {
		q := rpcRequest{Op: "commit", Descriptor: wd, Inputs: inputs}
		r, e := n.call(q)
		must(e)
		retry, e := n.call(q)
		must(e)
		check(n.name+"LostCommitReplyRetryStable", bytes.Equal(r.Vote.Signature, retry.Vote.Signature))
		votes = append(votes, *r.Vote)
	}
	badVotes := append([]rpcVote{}, votes...)
	badVotes[1].Root = append([]byte{}, badVotes[1].Root...)
	badVotes[1].Root[0] ^= 1
	_, e = lab.nodes[clients].call(rpcRequest{Op: "release", Descriptor: wd, Votes: badVotes})
	check("ConflictingCommitmentRejected", e != nil)
	shares := []rpcShare{}
	for _, n := range lab.nodes[clients:] {
		r, e := n.call(rpcRequest{Op: "release", Descriptor: wd, Votes: votes})
		must(e)
		shares = append(shares, *r.Share)
	}
	_, e = lab.nodes[clients].call(rpcRequest{Op: "finish", Descriptor: wd, Root: votes[0].Root, Shares: shares[:2]})
	check("missingMaskShareRejected", e != nil)
	var root, raw []byte
	signatures := [][]byte{}
	for i, n := range lab.nodes[clients:] {
		r, e := n.call(rpcRequest{Op: "finish", Descriptor: wd, Root: votes[0].Root, Shares: shares})
		must(e)
		if i == 0 {
			root = r.Root
			raw = r.Output
		} else {
			check(n.name+"OutputAgrees", bytes.Equal(root, r.Root) && bytes.Equal(raw, r.Output))
		}
		signatures = append(signatures, r.Signature)
	}
	for _, n := range lab.nodes[:clients] {
		_, e = n.call(rpcRequest{Op: "accept", Descriptor: wd, Root: root, Output: raw, Signatures: signatures[:2]})
		check(n.name+"IncompleteCertificateRejected", e != nil)
		_, e = n.call(rpcRequest{Op: "accept", Descriptor: wd, Root: root, Output: raw, Signatures: signatures})
		must(e)
	}
	messages, e := lab.public.decode(d, raw)
	must(e)
	_, found := deliveredPayload(result{messages: messages}, []byte{1})
	check("sameEpochRoundRecoversAfterMissingPackets", len(messages) == 1 && found)
	lab.public.advance(d, result{raw: raw, messages: messages})
	_, e = target.call(rpcRequest{Op: "prepare", Descriptor: wd, Payload: []byte{2}})
	check("oldRoundCannotGenerateAnotherCiphertext", e != nil)
	bulk := lab.public.expected
	foreign := descriptorRPC(bulk)
	foreign.Epoch = append([]byte{}, foreign.Epoch...)
	foreign.Epoch[0] ^= 1
	_, e = target.call(rpcRequest{Op: "prepare", Descriptor: foreign})
	check("foreignEpochRejected", e != nil)
	// Stop exactly one owned coordinator, then attempt the pending bulk phase.
	// All remaining roles must refuse to produce a complete output certificate.
	lost := lab.nodes[clients+2]
	must(lost.keepAlive.Close())
	lost.keepAlive = nil
	stopped := false
	until := time.Now().Add(2 * time.Second)
	for time.Now().Before(until) {
		_, e = lost.call(rpcRequest{Op: "stats"})
		if e != nil {
			stopped = true
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	check("closedControllerLifelineStopsRoleListener", stopped)
	result, e := lab.run(bulk, map[int][]byte{0: []byte("خبر آزمایشی بدون انتشار پس از قطع هماهنگ‌کننده")})
	check("coordinatorLossFailsWithoutPublicRelease", e != nil && len(result.messages) == 0 && lab.public.expected.sequence == bulk.sequence)
	stats, e := lab.nodes[0].call(rpcRequest{Op: "stats"})
	must(e)
	check("replyCacheBounded", stats.CacheEntries <= 8)
	report := map[string]interface{}{"schema": 1, "scope": "actual mutually authenticated local TLS sockets and separate role processes; no mobile radio or anonymity claim", "checks": checks, "elapsedMs": ms(time.Since(started)), "directory": lab.directory, "productionIntegrationAllowed": false}
	report["roleLocalAnonymousSetup"] = anonymous
	must(saveJSON(filepath.Join(lab.directory, "network-checks.json"), report))
	must(json.NewEncoder(os.Stdout).Encode(map[string]interface{}{"report": filepath.Join(lab.directory, "network-checks.json"), "passed": len(checks)}))
}
