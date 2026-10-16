package setup

// These encodings contain PRIVATE role material. They are for authenticated,
// encrypted local storage only, never a peer message or a public backup.
import (
	"bytes"
	"crypto/ecdh"
	"crypto/ed25519"
	"encoding/json"
	"errors"

	"go.dedis.ch/kyber/v4/sign/eddsa"
)

type localCheckpoint struct {
	Version      int
	Role         string
	Index        int
	Identity, DH []byte
	Hello        Hello
	Roster       *Roster
	Hellos       []Hello
}
type clientCheckpoint struct {
	Local   localCheckpoint
	Slot    []byte
	Input   *Input
	Final   *Final
	OwnSlot int
}
type coordinatorCheckpoint struct {
	Local      localCheckpoint
	Decrypt    []byte
	MixedInput string
	Mix        *Mix
	Vote       *Vote
	Share      *Share
	Final      *Final
}

func checkpointLocal(l *local) localCheckpoint {
	x := localCheckpoint{Version: 1, Role: l.role, Index: l.index, Identity: l.identity, DH: l.dh.Bytes(), Hello: l.hello}
	if l.view != nil {
		r := l.view.roster
		x.Roster = &r
		x.Hellos = l.view.hellos
	}
	return x
}
func restoreLocal(x localCheckpoint, role string) (*local, error) {
	limit := Clients
	if role == "coordinator" {
		limit = Coordinators
	}
	if x.Version != 1 || x.Role != role || x.Index < 0 || x.Index >= limit || len(x.Identity) != 64 || !bytes.Equal(ed25519.NewKeyFromSeed(x.Identity[:32]), x.Identity) {
		return nil, errors.New("invalid private setup checkpoint")
	}
	dh, e := ecdh.X25519().NewPrivateKey(x.DH)
	if e != nil {
		return nil, e
	}
	l := &local{role: role, index: x.Index, identity: ed25519.PrivateKey(x.Identity), dh: dh, hello: x.Hello}
	if l.hello.Role != role || l.hello.Index != x.Index || !bytes.Equal(l.hello.Identity, x.Identity[32:]) || !bytes.Equal(l.hello.DH, dh.PublicKey().Bytes()) || !signed(l.hello.Identity, "hello", helloSigned(l.hello), l.hello.Signature) {
		return nil, errors.New("setup checkpoint key binding")
	}
	if x.Roster != nil {
		if e = l.bind(*x.Roster, x.Hellos); e != nil {
			return nil, e
		}
	} else if len(x.Hellos) != 0 {
		return nil, errors.New("unbound setup checkpoint")
	}
	return l, nil
}
func (c *Client) LocalCheckpoint() ([]byte, error) {
	key, e := c.slot.MarshalBinary()
	if e != nil {
		return nil, e
	}
	return json.Marshal(clientCheckpoint{checkpointLocal(c.l), key, c.input, c.final, c.ownSlot})
}
func RestoreClient(data []byte) (*Client, error) {
	if len(data) > 2<<20 {
		return nil, errors.New("setup checkpoint too large")
	}
	var x clientCheckpoint
	if e := json.Unmarshal(data, &x); e != nil {
		return nil, e
	}
	l, e := restoreLocal(x.Local, "client")
	if e != nil {
		return nil, e
	}
	key := &eddsa.EdDSA{}
	if e = key.UnmarshalBinary(x.Slot); e != nil {
		return nil, e
	}
	if x.OwnSlot < -1 || x.OwnSlot >= Clients || x.Final != nil && (x.OwnSlot < 0 || len(x.Final.SlotPublic) != Clients || !bytes.Equal(raw(key.Public), x.Final.SlotPublic[x.OwnSlot])) {
		return nil, errors.New("setup checkpoint slot binding")
	}
	return &Client{l: l, slot: key, input: x.Input, final: x.Final, ownSlot: x.OwnSlot}, nil
}
func (c *Coordinator) LocalCheckpoint() ([]byte, error) {
	k, e := c.decrypt.MarshalBinary()
	if e != nil {
		return nil, e
	}
	return json.Marshal(coordinatorCheckpoint{checkpointLocal(c.l), k, c.mixedInput, c.mix, c.vote, c.share, c.final})
}
func RestoreCoordinator(data []byte) (*Coordinator, error) {
	if len(data) > 2<<20 {
		return nil, errors.New("setup checkpoint too large")
	}
	var x coordinatorCheckpoint
	if e := json.Unmarshal(data, &x); e != nil {
		return nil, e
	}
	l, e := restoreLocal(x.Local, "coordinator")
	if e != nil {
		return nil, e
	}
	s := newSuite()
	k := s.Scalar()
	if e = k.UnmarshalBinary(x.Decrypt); e != nil {
		return nil, e
	}
	canonical, e := k.MarshalBinary()
	if e != nil || !bytes.Equal(canonical, x.Decrypt) || !bytes.Equal(raw(s.Point().Mul(k, nil)), l.hello.DecryptKey) {
		return nil, errors.New("setup checkpoint decrypt binding")
	}
	return &Coordinator{l: l, decrypt: k, mixedInput: x.MixedInput, mix: x.Mix, vote: x.Vote, share: x.Share, final: x.Final}, nil
}
