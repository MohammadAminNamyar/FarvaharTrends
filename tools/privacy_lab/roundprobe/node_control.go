package main

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"

	control "farvahartrends.local/privacy-lab/verdictprobe/control"
)

type controlRole struct {
	roster      control.Roster
	view        *control.View
	client      *control.Client
	server      *control.Coordinator
	audit       *faultAudit
	descriptor  control.Descriptor
	openedHash  [32]byte
	outputs     []control.Output
	boundHellos [32]byte
	hellos      []control.Hello
}
type rpcBitReport struct {
	Witness     []byte
	Coordinator int
	Bits        []byte
	Signature   []byte
}

func witnessPayload(w accusation) ([]byte, error) {
	if w.slot < 0 || w.slot >= clients || w.bit < 0 || w.bit >= maxCell*8 || len(w.signature) != 64 {
		return nil, errors.New("invalid witness serialization")
	}
	b := make([]byte, control.PayloadBytes)
	b[0] = 1
	copy(b[1:33], w.context[:])
	b[33] = byte(w.slot)
	binary.BigEndian.PutUint32(b[34:38], uint32(w.bit))
	copy(b[38:102], w.signature)
	return b, nil
}
func payloadWitness(b []byte) (accusation, error) {
	if len(b) != control.PayloadBytes || b[0] != 1 {
		return accusation{}, errors.New("invalid control payload")
	}
	for _, x := range b[102:] {
		if x != 0 {
			return accusation{}, errors.New("noncanonical witness padding")
		}
	}
	w := accusation{slot: int(b[33]), bit: int(binary.BigEndian.Uint32(b[34:38])), signature: append([]byte{}, b[38:102]...)}
	copy(w.context[:], b[1:33])
	return w, nil
}
func (r rpcBitReport) native() (accusation, bitReport, error) {
	w, e := payloadWitness(r.Witness)
	if e != nil {
		return w, bitReport{}, e
	}
	if len(r.Bits) != clients || len(r.Signature) != 64 {
		return w, bitReport{}, errors.New("invalid bit report shape")
	}
	x := bitReport{accusation: w.digest(), server: r.Coordinator, signature: append([]byte{}, r.Signature...)}
	copy(x.bits[:], r.Bits)
	return w, x, nil
}
func (n *roleNode) ensureControl() error {
	if n.control != nil {
		return nil
	}
	r := control.Roster{Epoch: hex.EncodeToString(n.state.epoch[:]), ClientKeys: jsonCopy(n.config.ClientPublic), CoordinatorKeys: jsonCopy(n.config.ServerPublic), SlotKeys: jsonCopy(n.config.SlotPublic)}
	c := &controlRole{roster: r}
	if n.config.Role == "coordinator" {
		var e error
		c.server, e = control.NewCoordinator(r, n.config.Index, n.config.Private)
		if e != nil {
			return e
		}
	}
	n.control = c
	return nil
}
func (n *roleNode) controlCall(q rpcRequest) (rpcResponse, error) {
	if e := n.ensureControl(); e != nil {
		return rpcResponse{}, e
	}
	c := n.control
	if q.Op == "control-hello" {
		if c.server == nil {
			return rpcResponse{}, errors.New("only coordinator has control encryption keys")
		}
		h := c.server.Hello()
		return rpcResponse{ControlHello: &h}, nil
	}
	if q.Op == "control-bind" {
		encoded, e := json.Marshal(q.ControlHellos)
		if e != nil {
			return rpcResponse{}, e
		}
		h := hash(encoded)
		if c.view != nil {
			if c.boundHellos != h {
				return rpcResponse{}, errors.New("control session already bound")
			}
			return rpcResponse{ControlSession: c.view.Session()}, nil
		}
		v, e := control.NewView(c.roster, q.ControlHellos)
		if e != nil {
			return rpcResponse{}, e
		}
		if c.server != nil {
			e = c.server.Bind(q.ControlHellos)
		} else {
			c.client, e = control.NewClient(v, n.config.Index, n.config.Slot, n.config.Private, n.config.SlotPrivate)
		}
		if e != nil {
			return rpcResponse{}, e
		}
		c.view = v
		c.boundHellos = h
		c.hellos = jsonCopy(q.ControlHellos)
		return rpcResponse{ControlSession: v.Session()}, nil
	}
	if c.view == nil {
		return rpcResponse{}, errors.New("control setup incomplete")
	}
	d, e := q.Descriptor.value()
	if e != nil {
		return rpcResponse{}, e
	}
	if q.Op == "control-open" {
		b, e := json.Marshal(struct {
			D rpcDescriptor
			X []rpcInput
			V []rpcVote
			S []rpcShare
		}{q.Descriptor, q.Inputs, q.Votes, q.Shares})
		if e != nil {
			return rpcResponse{}, e
		}
		h := hash(b)
		if c.audit != nil {
			if h != c.openedHash {
				return rpcResponse{}, errors.New("control investigation already bound")
			}
			dd := c.descriptor
			return rpcResponse{ControlDescriptor: &dd}, nil
		}
		xs, e := nativeInputs(q.Inputs)
		if e != nil {
			return rpcResponse{}, e
		}
		vs, e := nativeVotes(q.Votes)
		if e != nil {
			return rpcResponse{}, e
		}
		ss, e := nativeShares(q.Shares)
		if e != nil {
			return rpcResponse{}, e
		}
		root, e := n.state.validate(d, xs)
		if e != nil {
			return rpcResponse{}, e
		}
		if c.client != nil {
			if n.prepared == nil || n.state.clientNext[n.config.Index] != d.sequence+1 || !bytes.Equal(n.prepared.wire(d), xs[n.config.Index].wire(d)) {
				return rpcResponse{}, errors.New("own failed-round input replaced")
			}
		} else if n.pending == nil || n.pending.root != root || n.pending.descriptorHash != hash(d.wire()) || n.state.servers[n.config.Index].next != d.sequence+1 {
			return rpcResponse{}, errors.New("coordinator has not released this failed round")
		}
		a, e := newFaultAudit(n.state, d, xs, vs, ss)
		if e != nil {
			return rpcResponse{}, e
		}
		dd := control.Descriptor{Session: c.view.Session(), Sequence: d.sequence + 1, Context: hex.EncodeToString(a.context[:])}
		if c.client != nil {
			e = c.client.Begin(dd)
		} else {
			e = c.server.Begin(dd)
		}
		if e != nil {
			return rpcResponse{}, e
		}
		c.audit = a
		c.descriptor = dd
		c.openedHash = h
		return rpcResponse{ControlDescriptor: &dd}, nil
	}
	if c.audit == nil || !bytes.Equal(c.audit.d.wire(), d.wire()) {
		return rpcResponse{}, errors.New("control request outside authenticated failed round")
	}
	switch q.Op {
	case "control-prepare":
		if c.client == nil {
			return rpcResponse{}, errors.New("not a control client")
		}
		w, e := c.audit.makeAccusation(n.state, n.config.Index)
		var payload []byte
		if e == nil {
			payload, e = witnessPayload(w)
		} else if errors.Is(e, errNoWitness) {
			e = nil
		}
		if e != nil {
			return rpcResponse{}, e
		}
		x, e := c.client.Prepare(payload)
		return rpcResponse{ControlInput: &x}, e
	case "control-commit":
		if c.server == nil {
			return rpcResponse{}, errors.New("not a control coordinator")
		}
		x, e := c.server.Commit(q.ControlInputs)
		return rpcResponse{ControlVote: &x}, e
	case "control-release":
		if c.server == nil {
			return rpcResponse{}, errors.New("not a control coordinator")
		}
		x, e := c.server.Release(q.ControlVotes)
		return rpcResponse{ControlShare: &x}, e
	case "control-finish":
		var out []control.Output
		var certificate *control.Certificate
		if c.client != nil {
			out, e = c.client.AcceptCertified(q.ControlInputs, q.ControlVotes, q.ControlOutputs, q.ControlCertificates)
		} else {
			out, e = c.server.Accept(q.ControlVotes, q.ControlShares)
			if e == nil {
				var cert control.Certificate
				cert, e = c.server.Certify()
				certificate = &cert
			}
		}
		if e != nil {
			return rpcResponse{}, e
		}
		for _, o := range out {
			if o.Invalid || o.Payload == nil {
				continue
			}
			w, e := payloadWitness(o.Payload)
			if e != nil || w.slot != o.Slot {
				continue
			}
			if e = c.audit.accept(w); e != nil {
				continue
			}
		}
		c.outputs = jsonCopy(out)
		return rpcResponse{ControlOutput: out, ControlCertificate: certificate}, nil
	case "control-report":
		if c.server == nil || c.outputs == nil {
			return rpcResponse{}, errors.New("control output not accepted by coordinator")
		}
		var out []rpcBitReport
		for _, w := range c.audit.accepted {
			if w == nil {
				continue
			}
			r, e := c.audit.report(n.state, n.config.Index, *w)
			if e != nil {
				return rpcResponse{}, e
			}
			p, e := witnessPayload(*w)
			if e != nil {
				return rpcResponse{}, e
			}
			out = append(out, rpcBitReport{p, r.server, append([]byte{}, r.bits[:]...), append([]byte{}, r.signature...)})
		}
		return rpcResponse{WitnessReports: out}, nil
	}
	return rpcResponse{}, errors.New("unsupported control operation")
}
