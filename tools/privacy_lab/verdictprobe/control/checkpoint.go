package control

// Private checkpoint APIs are only for authenticated encrypted local storage.
// They do not authenticate a remote snapshot or prevent filesystem rollback.
import (
	"bytes"
	"crypto/ed25519"
	"encoding/json"
	"errors"

	"go.dedis.ch/kyber/v4"
)

type clientCheckpoint struct {
	Version, Index, Slot      int
	Roster                    Roster
	Hellos                    []Hello
	Identity, Owner           []byte
	Descriptor                *Descriptor
	Input                     *Contribution
	PayloadHash, AcceptedHash string
	Output                    []Output
}
type coordinatorCheckpoint struct {
	Version, Index               int
	Roster                       Roster
	Identity                     []byte
	Keys                         [][]byte
	Hello                        Hello
	Hellos                       []Hello
	Descriptor                   *Descriptor
	Inputs                       []Contribution
	SumR                         [][][]byte
	Vote                         *Vote
	Share                        *Share
	AcceptedHash                 string
	Output                       []Output
	InputAttempts, ShareAttempts int
}

func scalarFromBytes(s *suite, data []byte) (kyber.Scalar, error) {
	k := s.Scalar()
	if e := k.UnmarshalBinary(data); e != nil {
		return nil, e
	}
	b, e := k.MarshalBinary()
	if e != nil || !bytes.Equal(b, data) || k.Equal(s.Scalar().Zero()) {
		return nil, errors.New("invalid checkpoint scalar")
	}
	return k, nil
}
func (c *Client) LocalCheckpoint() ([]byte, error) {
	k, e := c.owner.MarshalBinary()
	if e != nil {
		return nil, e
	}
	return json.Marshal(clientCheckpoint{1, c.index, c.slot, c.v.roster, c.v.hellos, c.id, k, c.d, c.input, c.payloadHash, c.acceptedHash, c.output})
}
func RestoreClient(data []byte) (*Client, error) {
	if len(data) > 2<<20 {
		return nil, errors.New("control checkpoint too large")
	}
	var x clientCheckpoint
	if e := json.Unmarshal(data, &x); e != nil {
		return nil, e
	}
	if x.Version != 1 || x.Index < 0 || x.Index >= Clients || x.Slot < 0 || x.Slot >= Clients {
		return nil, errors.New("invalid control checkpoint")
	}
	v, e := NewView(x.Roster, x.Hellos)
	if e != nil {
		return nil, e
	}
	if !sameKey(ed25519.PrivateKey(x.Identity), v.roster.ClientKeys[x.Index]) {
		return nil, errors.New("checkpoint identity mismatch")
	}
	k, e := scalarFromBytes(v.s, x.Owner)
	if e != nil {
		return nil, e
	}
	if !v.s.Point().Mul(k, nil).Equal(v.slotKeys[x.Slot]) {
		return nil, errors.New("checkpoint slot mismatch")
	}
	if x.Descriptor != nil {
		if e = v.valid(*x.Descriptor); e != nil {
			return nil, e
		}
	}
	return &Client{v: v, index: x.Index, slot: x.Slot, id: x.Identity, owner: k, d: x.Descriptor, input: x.Input, payloadHash: x.PayloadHash, acceptedHash: x.AcceptedHash, output: x.Output}, nil
}
func (c *Coordinator) LocalCheckpoint() ([]byte, error) {
	x := coordinatorCheckpoint{Version: 1, Index: c.index, Roster: c.roster, Identity: c.id, Hello: c.hello, Descriptor: c.d, Inputs: c.inputs, Vote: c.vote, Share: c.share, AcceptedHash: c.acceptedHash, Output: c.output, InputAttempts: c.inputProofAttempts, ShareAttempts: c.shareProofAttempts}
	for _, k := range c.keys {
		b, e := k.MarshalBinary()
		if e != nil {
			return nil, e
		}
		x.Keys = append(x.Keys, b)
	}
	if c.v != nil {
		x.Hellos = c.v.hellos
	}
	for _, row := range c.sumR {
		var b [][]byte
		for _, p := range row {
			b = append(b, raw(p))
		}
		x.SumR = append(x.SumR, b)
	}
	return json.Marshal(x)
}
func RestoreCoordinator(data []byte) (*Coordinator, error) {
	if len(data) > 2<<20 {
		return nil, errors.New("control checkpoint too large")
	}
	var x coordinatorCheckpoint
	if e := json.Unmarshal(data, &x); e != nil {
		return nil, e
	}
	if x.Version != 1 || x.Index < 0 || x.Index >= Coordinators || len(x.Keys) != Clients || len(x.Hello.Keys) != Clients || x.InputAttempts < 0 || x.InputAttempts > maxProofAttempts || x.ShareAttempts < 0 || x.ShareAttempts > maxProofAttempts {
		return nil, errors.New("invalid control checkpoint")
	}
	if e := checkRoster(x.Roster); e != nil {
		return nil, e
	}
	if !sameKey(ed25519.PrivateKey(x.Identity), x.Roster.CoordinatorKeys[x.Index]) || !signed(x.Roster.CoordinatorKeys[x.Index], "hello", helloSigned(x.Hello), x.Hello.Signature) {
		return nil, errors.New("checkpoint identity mismatch")
	}
	c := &Coordinator{s: newSuite(), roster: x.Roster, index: x.Index, id: x.Identity, hello: x.Hello, d: x.Descriptor, inputs: x.Inputs, vote: x.Vote, share: x.Share, acceptedHash: x.AcceptedHash, output: x.Output, inputProofAttempts: x.InputAttempts, shareProofAttempts: x.ShareAttempts}
	for i, b := range x.Keys {
		k, e := scalarFromBytes(c.s, b)
		if e != nil {
			return nil, e
		}
		if !bytes.Equal(raw(c.s.Point().Mul(k, nil)), x.Hello.Keys[i]) {
			return nil, errors.New("checkpoint server key mismatch")
		}
		c.keys[i] = k
	}
	if len(x.Hellos) != 0 {
		if e := c.Bind(x.Hellos); e != nil {
			return nil, e
		}
	}
	if x.Descriptor != nil {
		if c.v == nil {
			return nil, errors.New("unbound control descriptor")
		}
		if e := c.v.valid(*x.Descriptor); e != nil {
			return nil, e
		}
	}
	if len(x.SumR) != 0 && len(x.SumR) != Clients {
		return nil, errors.New("checkpoint aggregate shape")
	}
	for _, row := range x.SumR {
		if c.v == nil || len(row) != c.v.chunks() {
			return nil, errors.New("checkpoint aggregate width")
		}
		var points []kyber.Point
		for _, b := range row {
			p, e := c.s.point(b, false)
			if e != nil {
				return nil, e
			}
			points = append(points, p)
		}
		c.sumR = append(c.sumR, points)
	}
	return c, nil
}
