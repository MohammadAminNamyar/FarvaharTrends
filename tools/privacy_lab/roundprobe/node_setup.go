package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"

	groupSetup "farvahartrends.local/privacy-lab/setupprobe/setup"
)

type setupRole struct {
	client      *groupSetup.Client
	coordinator *groupSetup.Coordinator
	roster      *groupSetup.Roster
	final       *groupSetup.Final
	releaseHash [32]byte
}

func jsonCopy[T any](x T) T {
	b, e := json.Marshal(x)
	must(e)
	var y T
	must(json.Unmarshal(b, &y))
	return y
}
func newSetupRoleNode(c nodeConfig) (*roleNode, error) {
	if len(c.Private) != 0 || len(c.SlotPrivate) != 0 || len(c.Seeds) != 0 || len(c.Epoch) != 0 || len(c.ClientPublic) != 0 || len(c.ServerPublic) != 0 || len(c.SlotPublic) != 0 || c.SlotLimit != clients {
		return nil, errors.New("anonymous setup must start without provisioned protocol secrets")
	}
	_, id, e := ed25519.GenerateKey(rand.Reader)
	if e != nil {
		return nil, e
	}
	n := &roleNode{config: c, setup: &setupRole{}}
	n.config.Private = id
	if c.Role == "client" {
		n.setup.client, e = groupSetup.NewClient(c.Index, id)
	} else if c.Role == "coordinator" {
		n.setup.coordinator, e = groupSetup.NewCoordinator(c.Index, id)
	} else {
		e = errors.New("invalid setup role")
	}
	if e != nil {
		return nil, e
	}
	return n, nil
}
func (n *roleNode) setupCall(q rpcRequest) (rpcResponse, error) {
	if n.setup == nil {
		return rpcResponse{}, errors.New("node uses legacy fixture")
	}
	s := n.setup
	if s.final != nil {
		if q.Op == "setup-finalize" && q.SetupRelease != nil {
			b, e := json.Marshal(q.SetupRelease)
			if e == nil && hash(b) == s.releaseHash {
				f := jsonCopy(*s.final)
				return rpcResponse{SetupFinal: &f}, nil
			}
		}
		return rpcResponse{}, errors.New("setup complete; cannot reset publication state")
	}
	switch q.Op {
	case "setup-hello":
		var h groupSetup.Hello
		if s.client != nil {
			h = s.client.Hello()
		} else {
			h = s.coordinator.Hello()
		}
		return rpcResponse{SetupHello: &h}, nil
	case "setup-bind":
		if q.SetupRoster == nil {
			return rpcResponse{}, errors.New("missing roster")
		}
		var e error
		if s.client != nil {
			e = s.client.Bind(*q.SetupRoster, q.SetupHellos)
		} else {
			e = s.coordinator.Bind(*q.SetupRoster, q.SetupHellos)
		}
		if e != nil {
			return rpcResponse{}, e
		}
		r := jsonCopy(*q.SetupRoster)
		s.roster = &r
		return rpcResponse{}, nil
	case "setup-input":
		if s.client == nil {
			return rpcResponse{}, errors.New("only clients submit slot keys")
		}
		x, e := s.client.Input()
		return rpcResponse{SetupInput: &x}, e
	case "setup-mix":
		if s.coordinator == nil || q.SetupTranscript == nil {
			return rpcResponse{}, errors.New("missing coordinator/transcript")
		}
		m, e := s.coordinator.Mix(*q.SetupTranscript)
		return rpcResponse{SetupMix: &m}, e
	case "setup-commit":
		if s.coordinator == nil || q.SetupTranscript == nil {
			return rpcResponse{}, errors.New("missing coordinator/transcript")
		}
		v, e := s.coordinator.Commit(*q.SetupTranscript)
		return rpcResponse{SetupVote: &v}, e
	case "setup-release":
		if s.coordinator == nil || q.SetupTranscript == nil {
			return rpcResponse{}, errors.New("missing coordinator/transcript")
		}
		v, e := s.coordinator.Release(*q.SetupTranscript, q.SetupVotes)
		return rpcResponse{SetupShare: &v}, e
	case "setup-finalize":
		if q.SetupRelease == nil || s.roster == nil {
			return rpcResponse{}, errors.New("missing setup release/roster")
		}
		c := n.config
		c.ClientPublic = jsonCopy(s.roster.ClientKeys)
		c.ServerPublic = jsonCopy(s.roster.CoordinatorKeys)
		c.Seeds = nil
		c.Slot = -1
		var f groupSetup.Final
		if s.client != nil {
			if e := s.client.Accept(*q.SetupRelease); e != nil {
				return rpcResponse{}, e
			}
			m, e := s.client.Material()
			if e != nil {
				return rpcResponse{}, e
			}
			f = m.Public
			c.Slot = m.OwnSlot
			c.SlotPrivate = m.SlotPrivate
			for j := range coordinators {
				c.Seeds = append(c.Seeds, sharedSeed{c.Index, j, append([]byte{}, m.Seeds[j][:]...)})
			}
		} else {
			if e := s.coordinator.Accept(*q.SetupRelease); e != nil {
				return rpcResponse{}, e
			}
			m, e := s.coordinator.Material()
			if e != nil {
				return rpcResponse{}, e
			}
			f = m.Public
			for i := range clients {
				c.Seeds = append(c.Seeds, sharedSeed{i, c.Index, append([]byte{}, m.Seeds[i][:]...)})
			}
		}
		var e error
		c.Epoch, e = hex.DecodeString(f.Epoch)
		if e != nil {
			return rpcResponse{}, e
		}
		c.SlotPublic = jsonCopy(f.SlotPublic)
		state, e := c.fixture()
		if e != nil {
			return rpcResponse{}, e
		}
		b, e := json.Marshal(q.SetupRelease)
		if e != nil {
			return rpcResponse{}, e
		}
		n.config = c
		n.state = state
		s.final = &f
		s.releaseHash = hash(b)
		// Only the final public receipt and its request hash are used after setup.
		// Retire the setup-only objects so every later journal commit need not
		// re-encode their private keys, proofs and transcripts. Bulk secrets are
		// already copied into c/state. This is not a claim of secure memory erase.
		s.client, s.coordinator = nil, nil
		copy := jsonCopy(f)
		return rpcResponse{SetupFinal: &copy}, nil
	}
	return rpcResponse{}, errors.New("unknown setup request")
}
