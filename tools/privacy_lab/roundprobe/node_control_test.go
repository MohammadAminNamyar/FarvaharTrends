package main

import (
	"bytes"
	"encoding/hex"
	"reflect"
	"testing"

	control "farvahartrends.local/privacy-lab/verdictprobe/control"
)

func TestControlRebindAfterRPCCacheEvictionDoesNotResetCiphertext(t *testing.T) {
	f := newFixtureWithLimit(clients)
	n, e := newRoleNode(configFor(f, "client", 0))
	if e != nil {
		t.Fatal(e)
	}
	if e = n.ensureControl(); e != nil {
		t.Fatal(e)
	}
	var hs []control.Hello
	for i := range coordinators {
		s, e := control.NewCoordinator(n.control.roster, i, f.serverKeys[i].private)
		if e != nil {
			t.Fatal(e)
		}
		hs = append(hs, s.Hello())
	}
	bind := rpcRequest{Op: "control-bind", ControlHellos: hs}
	r, e := n.handle(bind)
	if e != nil {
		t.Fatal(e)
	}
	context := hash([]byte("local control fixture"))
	d := control.Descriptor{Session: r.ControlSession, Sequence: 1, Context: hex.EncodeToString(context[:])}
	if e = n.control.client.Begin(d); e != nil {
		t.Fatal(e)
	}
	p := bytes.Repeat([]byte{71}, control.PayloadBytes)
	first, e := n.control.client.Prepare(p)
	if e != nil {
		t.Fatal(e)
	}
	n.cache = nil
	if _, e = n.handle(bind); e != nil {
		t.Fatal(e)
	}
	again, e := n.control.client.Prepare(p)
	if e != nil || !reflect.DeepEqual(first, again) {
		t.Fatal("rebind regenerated ciphertext", e)
	}
	_, e = n.control.client.Prepare(bytes.Repeat([]byte{72}, control.PayloadBytes))
	requireReject(t, e)
	_, e = n.handle(rpcRequest{Op: "control-prepare", Descriptor: descriptorRPC(f.reservation(0))})
	requireReject(t, e)
	_, e = n.handle(rpcRequest{Op: "control-report", Descriptor: descriptorRPC(f.reservation(0))})
	requireReject(t, e)
}

func TestWitnessPayloadHasCanonicalFixedSizeAndBitBounds(t *testing.T) {
	_, a, w := jammedAudit(t, false)
	b, e := witnessPayload(w)
	if e != nil || len(b) != control.PayloadBytes {
		t.Fatal(e)
	}
	decoded, e := payloadWitness(b)
	if e != nil || decoded.digest() != w.digest() {
		t.Fatal("witness round trip", e)
	}
	_, e = a.verify(decoded)
	if e != nil {
		t.Fatal(e)
	}
	bad := append([]byte{}, b...)
	bad[len(bad)-1] = 1
	_, e = payloadWitness(bad)
	requireReject(t, e)
	_, e = payloadWitness(b[:len(b)-1])
	requireReject(t, e)
	w.bit = maxCell * 8
	_, e = witnessPayload(w)
	requireReject(t, e)
}
