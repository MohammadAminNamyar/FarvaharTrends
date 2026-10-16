package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func compactRequestForTest(t *testing.T, q rpcRequest) rpcRequest {
	t.Helper()
	b, e := encodeRPC("cbor-v1", q)
	if e != nil {
		t.Fatal(e)
	}
	var decoded rpcRequest
	if e = decodeRPC("cbor-v1", b, &decoded); e != nil {
		t.Fatal(e)
	}
	a, _ := json.Marshal(q)
	z, _ := json.Marshal(decoded)
	if !bytes.Equal(a, z) {
		t.Fatal("compact transport changed canonical request/cache digest", string(a), string(z))
	}
	return decoded
}

func TestCompactRPCPreservesNilEmptyAndBinaryValues(t *testing.T) {
	for _, q := range []rpcRequest{
		{Op: "stats"},
		{Op: "prepare", Payload: []byte{}, Inputs: []rpcInput{}, Votes: []rpcVote{}, Shares: []rpcShare{}, Root: []byte{}, Output: []byte{}, Signatures: [][]byte{}, Descriptor: rpcDescriptor{Epoch: []byte{}, Previous: []byte{}, Slots: []int{}}},
		{Op: "commit", Inputs: []rpcInput{{Client: 0, Body: []byte{0, 255, 0, 127}, Signature: []byte{}, KeyHashes: [][]byte{nil, {}, {3, 4}}}}, Descriptor: descriptorRPC(newFixture().reservation(0))},
		{Op: "accept", Output: []byte("خبر فارسی؛ آزمایش حفظ دقیق بایت‌ها"), Signatures: [][]byte{{1, 2}, {3, 4}, {5, 6}}},
	} {
		compactRequestForTest(t, q)
	}
}

func TestCompactRPCRejectsAmbiguityAndResourceAbuse(t *testing.T) {
	valid, e := encodeRPC("cbor-v1", rpcRequest{Op: "stats"})
	if e != nil {
		t.Fatal(e)
	}
	unknown, _ := rpcCBOR.Marshal(map[uint64]any{1: "stats", 99: true})
	largeArray, _ := rpcCBOR.Marshal(map[uint64]any{1: "commit", 4: make([]any, 129)})
	var nested any = "x"
	for range 17 {
		nested = []any{nested}
	}
	deep, _ := rpcCBOR.Marshal(map[uint64]any{1: "prepare", 3: nested})
	cases := map[string][]byte{
		"duplicate": append(append([]byte{0xa2}, valid[1:]...), valid[1:]...),
		"unknown":   unknown, "large-array": largeArray, "deep": deep,
		"trailing":       append(bytes.Clone(valid), 0xa0),
		"tag":            append([]byte{0xc0}, valid...),
		"indefinite":     append(append([]byte{0xbf}, valid[1:]...), 0xff),
		"nonminimal-key": append([]byte{0xa1, 0x18, 0x01}, valid[2:]...),
		"truncated":      valid[:len(valid)-1], "null": {0xf6}, "wrong-type": {0x81, 0xa0},
		"invalid-utf8":   {0xa1, 1, 0x61, 0xff},
		"hostile-length": {0xa1, 3, 0x5b, 255, 255, 255, 255, 255, 255, 255, 255},
		"oversized":      bytes.Repeat([]byte{0}, maxRPCBytes+1),
		"json-as-cbor":   []byte(`{"Op":"stats"}`),
	}
	for name, b := range cases {
		t.Run(name, func(t *testing.T) {
			var q rpcRequest
			if decodeRPC("cbor-v1", b, &q) == nil {
				t.Fatal("invalid compact request accepted")
			}
		})
	}
	for _, value := range []float64{math.NaN(), math.Inf(1), math.Inf(-1)} {
		b, _ := rpcCBOR.Marshal(map[uint64]any{10: value})
		var r rpcResponse
		if decodeRPC("cbor-v1", b, &r) == nil {
			t.Fatal("nonfinite telemetry accepted")
		}
	}
	if _, e := encodeRPC("other", rpcRequest{}); e == nil {
		t.Fatal("unknown encoder silently selected a codec")
	}
	var q rpcRequest
	if decodeRPC("other", valid, &q) == nil || decodeRPC("json", valid, &q) == nil {
		t.Fatal("unexpected codec fallback")
	}
}

func TestCompactRPCPreservesCertifiedRoundAndRecoveredExactReplies(t *testing.T) {
	for _, publishers := range []int{0, 1, clients} {
		t.Run(fmt.Sprint(publishers), func(t *testing.T) {
			f := newScheduledFixtureStorage(t, true)
			f.lab.localOutboxes, f.lab.fuseReservationPrepare = true, true
			payloads := map[int][]byte{}
			for i := 0; i < publishers; i++ {
				payloads[i] = []byte(fmt.Sprintf("خبر فارسی برای آزمون کدگذاری فشرده؛ عضو %d", i))
				if _, e := f.nodes[i].enqueueLocal(localSubmission{1, payloads[i]}); e != nil {
					t.Fatal(e)
				}
			}
			var lastRequest rpcRequest
			var lastResponse rpcResponse
			jsonBytes, cborBytes := 0, 0
			f.lab.componentCall = func(id int, q rpcRequest) (rpcResponse, error) {
				decoded := compactRequestForTest(t, q)
				j, _ := encodeRPC("json", q)
				c, _ := encodeRPC("cbor-v1", q)
				jsonBytes += len(j)
				cborBytes += len(c)
				r, e := f.nodes[id].handle(decoded)
				if e != nil {
					return r, e
				}
				commits := f.nodes[id].journal.commits
				again, e := f.nodes[id].handle(q)
				if e != nil || !bytes.Equal(encodeSetup(r), encodeSetup(again)) || f.nodes[id].journal.commits != commits {
					t.Fatal("cross-codec retry repeated work or changed reply", e)
				}
				b, e := encodeRPC("cbor-v1", r)
				if e != nil {
					t.Fatal(e)
				}
				var received rpcResponse
				if e = decodeRPC("cbor-v1", b, &received); e != nil || !bytes.Equal(encodeSetup(r), encodeSetup(received)) {
					t.Fatal("compact response changed signed/cached bytes", e)
				}
				j, _ = encodeRPC("json", r)
				jsonBytes += len(j)
				cborBytes += len(b)
				if id == 0 {
					lastRequest, lastResponse = q, r
				}
				return received, nil
			}
			f.at(0)
			out := f.cycle(t, 0)
			if !samePayloadMultiset(out, payloads) {
				t.Fatal("compact cycle changed public news")
			}
			if cborBytes >= jsonBytes {
				t.Fatal("compact representation did not reduce encoded bytes")
			}
			t.Logf("publishers=%d JSON body bytes=%d CBOR body bytes=%d (not TLS or radio)", publishers, jsonBytes, cborBytes)
			n := f.nodes[0]
			if e := n.journal.close(); e != nil {
				t.Fatal(e)
			}
			restored, e := openDurableRole(n.config, f.dirs[0])
			if e != nil {
				t.Fatal(e)
			}
			defer restored.journal.close()
			commits := restored.journal.commits
			again, e := restored.handle(compactRequestForTest(t, lastRequest))
			if e != nil || !bytes.Equal(encodeSetup(again), encodeSetup(lastResponse)) || restored.journal.commits != commits {
				t.Fatal("compact historical retry changed after restart", e)
			}
			if _, e = restored.enqueueLocal(localSubmission{2, []byte("ساعت قبلی معتبر نیست")}); e == nil {
				t.Fatal("codec bypassed restart fence")
			}
		})
	}
}

func TestCompactRPCRejectsResponseDowngradeWithoutRetry(t *testing.T) {
	requests := 0
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{}`))
	}))
	defer server.Close()
	n := remoteRole{name: "test", address: strings.TrimPrefix(server.URL, "https://"), client: server.Client(), profile: linkProfile{WireCodec: "cbor-v1"}}
	if _, e := n.call(rpcRequest{Op: "stats"}); e == nil || requests != 1 {
		t.Fatal("wrong content type accepted or retried", e, requests)
	}
}

func FuzzCompactRPCRejectsMalformedWithoutPanic(f *testing.F) {
	valid, _ := encodeRPC("cbor-v1", rpcRequest{Op: "stats"})
	f.Add(valid)
	f.Add([]byte{0xa0})
	f.Add([]byte{0xbf, 0xff})
	f.Add([]byte{0xa1, 3, 0x5b, 255, 255, 255, 255, 255, 255, 255, 255})
	f.Fuzz(func(t *testing.T, b []byte) {
		if len(b) > maxRPCBytes+1 {
			return
		}
		var q rpcRequest
		if decodeRPC("cbor-v1", b, &q) == nil {
			encoded, e := encodeRPC("cbor-v1", q)
			if e != nil || !bytes.Equal(encoded, b) {
				t.Fatal("accepted noncanonical RPC")
			}
		}
	})
}
