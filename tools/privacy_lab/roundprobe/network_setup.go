package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"errors"
	"path/filepath"
	"time"

	groupSetup "farvahartrends.local/privacy-lab/setupprobe/setup"
)

func allRoleIDs() []int {
	out := []int{}
	for i := range clients + coordinators {
		out = append(out, i)
	}
	return out
}
func (lab *networkLab) establishSetup() (err error) {
	started, before := time.Now(), lab.bytes()
	defer func() {
		lab.setupMetrics = map[string]interface{}{"elapsedMs": ms(time.Since(started)), "allRoleTLSPayloadBytes": lab.bytes() - before, "accepted": err == nil, "scope": "hello to all roles accepting; includes first TLS connections, excludes child launch; public control topology; roster trust supplied by laboratory", "securityGatePassed": false}
		if err != nil {
			lab.setupMetrics["error"] = err.Error()
		}
		_ = saveJSON(filepath.Join(lab.directory, "anonymous-setup-result.json"), lab.setupMetrics)
	}()
	r, e := lab.parallel(allRoleIDs(), func(int) rpcRequest { return rpcRequest{Op: "setup-hello"} })
	if e != nil {
		return e
	}
	roster := groupSetup.Roster{Version: 1, Policy: "fixed eight clients / all three coordinators / eight bulk slots; laboratory roster, not Sybil admission"}
	var hellos []groupSetup.Hello
	for i, v := range r {
		if v.SetupHello == nil {
			return errors.New("missing setup hello")
		}
		h := *v.SetupHello
		hellos = append(hellos, h)
		if i < clients {
			roster.ClientKeys = append(roster.ClientKeys, h.Identity)
		} else {
			roster.CoordinatorKeys = append(roster.CoordinatorKeys, h.Identity)
		}
	}
	view, e := groupSetup.NewView(roster, hellos)
	if e != nil {
		return e
	}
	if _, e = lab.parallel(allRoleIDs(), func(int) rpcRequest { return rpcRequest{Op: "setup-bind", SetupRoster: &roster, SetupHellos: hellos} }); e != nil {
		return e
	}
	r, e = lab.parallel(allClientIDs(), func(int) rpcRequest { return rpcRequest{Op: "setup-input"} })
	if e != nil {
		return e
	}
	t := groupSetup.Transcript{Epoch: view.Epoch()}
	for _, v := range r {
		if v.SetupInput == nil {
			return errors.New("missing encrypted slot")
		}
		t.Inputs = append(t.Inputs, *v.SetupInput)
	}
	for j := range coordinators {
		v, e := lab.nodes[clients+j].call(rpcRequest{Op: "setup-mix", SetupTranscript: &t})
		if e != nil {
			return e
		}
		if v.SetupMix == nil {
			return errors.New("missing shuffle")
		}
		t.Mixes = append(t.Mixes, *v.SetupMix)
	}
	r, e = lab.parallel(allCoordinatorIDs(), func(int) rpcRequest { return rpcRequest{Op: "setup-commit", SetupTranscript: &t} })
	if e != nil {
		return e
	}
	packet := groupSetup.Release{Transcript: t}
	for _, v := range r {
		if v.SetupVote == nil {
			return errors.New("missing setup commit")
		}
		packet.Votes = append(packet.Votes, *v.SetupVote)
	}
	r, e = lab.parallel(allCoordinatorIDs(), func(int) rpcRequest {
		return rpcRequest{Op: "setup-release", SetupTranscript: &t, SetupVotes: packet.Votes}
	})
	if e != nil {
		return e
	}
	for _, v := range r {
		if v.SetupShare == nil {
			return errors.New("missing setup share")
		}
		packet.Shares = append(packet.Shares, *v.SetupShare)
	}
	final, e := view.Finalize(packet)
	if e != nil {
		return e
	}
	r, e = lab.parallel(allRoleIDs(), func(int) rpcRequest { return rpcRequest{Op: "setup-finalize", SetupRelease: &packet} })
	if e != nil {
		return e
	}
	for _, v := range r {
		if v.SetupFinal == nil || !bytes.Equal(encodeSetup(*v.SetupFinal), encodeSetup(final)) {
			return errors.New("role final setup differs")
		}
	}
	f := new(fixture)
	epoch, e := hex.DecodeString(final.Epoch)
	if e != nil || len(epoch) != 32 {
		return errors.New("invalid final setup epoch")
	}
	copy(f.epoch[:], epoch)
	f.slotLimit = clients
	for i := range clients {
		f.clientKeys[i].pub = ed25519.PublicKey(roster.ClientKeys[i])
		f.slotKeys[i].pub = ed25519.PublicKey(final.SlotPublic[i])
		f.ownerSlot[i] = -1
	}
	for j := range coordinators {
		f.serverKeys[j].pub = ed25519.PublicKey(roster.CoordinatorKeys[j])
	}
	f.expected = f.reservation(0)
	lab.public = f
	// This transcript is public. No role identity private key, slot private key,
	// owner mapping or shared seed ever travels in setup RPC responses.
	return saveJSON(filepath.Join(lab.directory, "anonymous-setup-public.json"), map[string]interface{}{"roster": roster, "hellos": hellos, "release": packet, "final": final})
}
func encodeSetup(v interface{}) []byte { b, e := json.Marshal(v); must(e); return b }
func deliveredPayload(output result, expected []byte) ([]byte, bool) {
	for _, p := range output.messages {
		if bytes.Equal(p, expected) {
			return p, true
		}
	}
	return nil, false
}
func samePayloadMultiset(output result, expected map[int][]byte) bool {
	if len(output.messages) != len(expected) {
		return false
	}
	counts := map[string]int{}
	for _, p := range expected {
		counts[string(p)]++
	}
	for _, p := range output.messages {
		if counts[string(p)] == 0 {
			return false
		}
		counts[string(p)]--
	}
	return true
}
