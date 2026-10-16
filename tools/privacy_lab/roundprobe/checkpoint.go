package main

// Private role snapshot. Only the encrypted local journal may persist this.
// Restoring authenticated local state is distinct from accepting peer input.
import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"

	groupSetup "farvahartrends.local/privacy-lab/setupprobe/setup"
	control "farvahartrends.local/privacy-lab/verdictprobe/control"
)

type serverCheckpoint struct {
	Next           uint64
	Committed      bool
	Root, MaskHash [32]byte
	KeyHashes      [clients][coordinators][32]byte
}
type batchCheckpoint struct {
	DescriptorHash, Root [32]byte
	Inputs               []rpcInput
	Votes                []rpcVote
}
type cacheCheckpoint struct {
	Digest   [32]byte
	Response rpcResponse
}
type setupCheckpoint struct {
	Client, Coordinator json.RawMessage `json:",omitempty"`
	Roster              *groupSetup.Roster
	Final               *groupSetup.Final
	ReleaseHash         [32]byte
}
type auditCheckpoint struct {
	Descriptor rpcDescriptor
	Inputs     []rpcInput
	Votes      []rpcVote
	Shares     []rpcShare
	Accepted   [][]byte
	Reports    []rpcBitReport
}
type controlCheckpoint struct {
	Roster                  control.Roster
	Hellos                  []control.Hello
	Client, Server          json.RawMessage `json:",omitempty"`
	Audit                   *auditCheckpoint
	Descriptor              control.Descriptor
	OpenedHash, BoundHellos [32]byte
	Outputs                 []control.Output
}
type roleCheckpoint struct {
	Schedule   *scheduleState `json:",omitempty"`
	Outbox     *localOutbox   `json:",omitempty"`
	Version    int
	Config     nodeConfig
	HasBulk    bool
	ClientNext [clients]uint64
	Servers    [coordinators]serverCheckpoint
	Expected   rpcDescriptor
	Cache      []cacheCheckpoint
	Pending    *batchCheckpoint
	Prepared   *rpcInput
	Setup      *setupCheckpoint
	Control    *controlCheckpoint
}

func privateStatePresent(b json.RawMessage) bool {
	return len(bytes.TrimSpace(b)) != 0 && !bytes.Equal(bytes.TrimSpace(b), []byte("null"))
}

func inputRPC(x input) rpcInput {
	r := rpcInput{Client: x.client, Body: x.body, Signature: x.signature}
	for _, h := range x.keyHashes {
		r.KeyHashes = append(r.KeyHashes, h[:])
	}
	return r
}
func inputsRPC(xs []input) []rpcInput {
	var r []rpcInput
	for _, x := range xs {
		r = append(r, inputRPC(x))
	}
	return r
}
func votesRPC(vs []vote) []rpcVote {
	var out []rpcVote
	for _, v := range vs {
		x := rpcVote{Coordinator: v.coordinator, Root: v.root[:], MaskHash: v.maskHash[:], Signature: v.signature}
		for _, h := range v.keyHashes {
			x.KeyHashes = append(x.KeyHashes, h[:])
		}
		out = append(out, x)
	}
	return out
}
func sharesRPC(ss []share) []rpcShare {
	var r []rpcShare
	for _, s := range ss {
		r = append(r, rpcShare{s.coordinator, s.root[:], s.body, s.signature})
	}
	return r
}
func inputFromCheckpoint(x rpcInput) (input, error) {
	if x.Client < 0 || x.Client >= clients || len(x.Body) > clients*maxCell || len(x.Signature) != 64 || len(x.KeyHashes) != coordinators {
		return input{}, errors.New("invalid saved input")
	}
	r := input{client: x.Client, body: x.Body, signature: x.Signature}
	for i, b := range x.KeyHashes {
		if len(b) != 32 {
			return r, errors.New("invalid saved input commitment")
		}
		copy(r.keyHashes[i][:], b)
	}
	return r, nil
}
func (n *roleNode) checkpoint() ([]byte, error) {
	x := roleCheckpoint{Version: 1, Config: n.config, HasBulk: n.state != nil, Outbox: n.outbox, Schedule: n.schedule}
	if n.state != nil {
		x.ClientNext = n.state.clientNext
		x.Expected = descriptorRPC(n.state.expected)
		for i, s := range n.state.servers {
			x.Servers[i] = serverCheckpoint{s.next, s.committed, s.root, s.maskHash, s.keyHashes}
		}
	}
	for _, c := range n.cache {
		x.Cache = append(x.Cache, cacheCheckpoint{c.digest, c.response})
	}
	if n.prepared != nil {
		p := inputRPC(*n.prepared)
		x.Prepared = &p
	}
	if n.pending != nil {
		x.Pending = &batchCheckpoint{n.pending.descriptorHash, n.pending.root, inputsRPC(n.pending.inputs), votesRPC(n.pending.votes)}
	}
	if n.setup != nil {
		s := n.setup
		a := &setupCheckpoint{Roster: s.roster, Final: s.final, ReleaseHash: s.releaseHash}
		var e error
		if s.client != nil {
			a.Client, e = s.client.LocalCheckpoint()
		} else if s.coordinator != nil {
			a.Coordinator, e = s.coordinator.LocalCheckpoint()
		}
		if e != nil {
			return nil, e
		}
		x.Setup = a
	}
	if n.control != nil {
		c := n.control
		z := &controlCheckpoint{Roster: c.roster, Hellos: c.hellos, Descriptor: c.descriptor, OpenedHash: c.openedHash, BoundHellos: c.boundHellos, Outputs: c.outputs}
		var e error
		if c.client != nil {
			z.Client, e = c.client.LocalCheckpoint()
		} else if c.server != nil {
			z.Server, e = c.server.LocalCheckpoint()
		}
		if e != nil {
			return nil, e
		}
		if c.audit != nil {
			a := c.audit
			saved := &auditCheckpoint{Descriptor: descriptorRPC(a.d), Inputs: inputsRPC(a.inputs), Votes: votesRPC(a.votes), Shares: sharesRPC(a.shares)}
			for _, w := range a.accepted {
				if w != nil {
					b, e := witnessPayload(*w)
					if e != nil {
						return nil, e
					}
					saved.Accepted = append(saved.Accepted, b)
				}
			}
			for slot, row := range a.reports {
				for _, r := range row {
					if r != nil {
						b, e := witnessPayload(*a.accepted[slot])
						if e != nil {
							return nil, e
						}
						saved.Reports = append(saved.Reports, rpcBitReport{b, r.server, r.bits[:], r.signature})
					}
				}
			}
			z.Audit = saved
		}
		x.Control = z
	}
	return json.Marshal(x)
}
func restoreRole(data []byte) (*roleNode, error) {
	if len(data) > maxCheckpointBytes {
		return nil, errors.New("checkpoint exceeds limit")
	}
	var x roleCheckpoint
	if e := json.Unmarshal(data, &x); e != nil {
		return nil, e
	}
	if x.Version != 1 || len(x.Cache) > 8 {
		return nil, errors.New("unsupported role checkpoint")
	}
	if !validPublicationStorageConfig(x.Config) {
		return nil, errors.New("invalid saved publication storage configuration")
	}
	n := &roleNode{config: x.Config, restored: true}
	if x.Config.RoleLocalOutbox {
		if x.Config.Role != "client" || !x.Config.Durable || x.Config.AllowFaultInjection || x.Outbox == nil {
			return nil, errors.New("invalid saved outbox role")
		}
		if e := x.Outbox.validate(); e != nil {
			return nil, e
		}
		n.outbox = x.Outbox
	} else if x.Outbox != nil {
		return nil, errors.New("unexpected local outbox")
	}
	var e error
	if x.HasBulk {
		n.state, e = x.Config.fixture()
		if e != nil {
			return nil, e
		}
		d, e := x.Expected.value()
		if e != nil || d.epoch != n.state.epoch {
			return nil, errors.New("invalid saved bulk descriptor")
		}
		n.state.expected = d
		n.state.clientNext = x.ClientNext
		for i, s := range x.Servers {
			n.state.servers[i] = serverState{s.Next, s.Committed, s.Root, s.MaskHash, s.KeyHashes}
		}
	}
	for _, c := range x.Cache {
		n.cache = append(n.cache, cachedResponse{c.Digest, c.Response})
	}
	if x.Prepared != nil {
		p, e := inputFromCheckpoint(*x.Prepared)
		if e != nil {
			return nil, e
		}
		n.prepared = &p
	}
	if x.Pending != nil {
		p := x.Pending
		xs, e := nativeInputs(p.Inputs)
		if e != nil {
			return nil, e
		}
		var vs []vote
		if len(p.Votes) != 0 {
			vs, e = nativeVotes(p.Votes)
			if e != nil {
				return nil, e
			}
		}
		n.pending = &acceptedBatch{p.DescriptorHash, p.Root, xs, vs}
	}
	if x.Setup != nil {
		a := x.Setup
		s := &setupRole{roster: a.Roster, final: a.Final, releaseHash: a.ReleaseHash}
		if a.Final != nil {
			// Accept old authenticated local checkpoints too, but retire their
			// no-longer-used private setup payloads on the next commit.
			if n.state == nil || a.Final.Epoch != hex.EncodeToString(n.state.epoch[:]) || len(a.Final.Root) != 64 || a.ReleaseHash == [32]byte{} || len(a.Final.SlotPublic) != clients {
				return nil, errors.New("invalid completed setup receipt")
			}
			for i, p := range a.Final.SlotPublic {
				if !bytes.Equal(p, n.config.SlotPublic[i]) {
					return nil, errors.New("completed setup slot mismatch")
				}
			}
		} else if privateStatePresent(a.Client) && privateStatePresent(a.Coordinator) {
			return nil, errors.New("ambiguous saved setup role")
		} else if privateStatePresent(a.Client) {
			s.client, e = groupSetup.RestoreClient(a.Client)
		} else if privateStatePresent(a.Coordinator) {
			s.coordinator, e = groupSetup.RestoreCoordinator(a.Coordinator)
		} else {
			return nil, errors.New("missing saved setup role")
		}
		if e != nil {
			return nil, e
		}
		n.setup = s
	}
	if x.Control != nil {
		z := x.Control
		c := &controlRole{roster: z.Roster, hellos: z.Hellos, descriptor: z.Descriptor, openedHash: z.OpenedHash, boundHellos: z.BoundHellos, outputs: z.Outputs}
		if len(z.Hellos) != 0 {
			c.view, e = control.NewView(c.roster, z.Hellos)
			if e != nil {
				return nil, e
			}
		}
		if privateStatePresent(z.Client) && privateStatePresent(z.Server) {
			return nil, errors.New("ambiguous saved control role")
		}
		if privateStatePresent(z.Client) {
			c.client, e = control.RestoreClient(z.Client)
		} else if privateStatePresent(z.Server) {
			c.server, e = control.RestoreCoordinator(z.Server)
		}
		if e != nil {
			return nil, e
		}
		if z.Audit != nil {
			if n.state == nil {
				return nil, errors.New("saved audit without bulk state")
			}
			a := z.Audit
			d, e := a.Descriptor.value()
			if e != nil {
				return nil, e
			}
			xs, e := nativeInputs(a.Inputs)
			if e != nil {
				return nil, e
			}
			vs, e := nativeVotes(a.Votes)
			if e != nil {
				return nil, e
			}
			ss, e := nativeShares(a.Shares)
			if e != nil {
				return nil, e
			}
			c.audit, e = newFaultAudit(n.state, d, xs, vs, ss)
			if e != nil {
				return nil, e
			}
			if len(a.Accepted) > clients || len(a.Reports) > clients*coordinators {
				return nil, errors.New("saved disclosure budget size")
			}
			for _, b := range a.Accepted {
				w, e := payloadWitness(b)
				if e != nil {
					return nil, e
				}
				if e = c.audit.accept(w); e != nil {
					return nil, e
				}
			}
			for _, b := range a.Reports {
				w, r, e := b.native()
				if e != nil {
					return nil, e
				}
				if e = c.audit.verifyReport(w, r); e != nil {
					return nil, e
				}
				if c.audit.reports[w.slot][r.server] != nil {
					return nil, errors.New("duplicate saved report")
				}
				c.audit.reports[w.slot][r.server] = &r
			}
		}
		n.control = c
	}
	if e := n.restoreSchedule(x.Schedule); e != nil {
		return nil, e
	}
	if e := n.validateOutboxPhase(); e != nil {
		return nil, e
	}
	return n, nil
}
