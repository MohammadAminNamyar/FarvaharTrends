package setup

import (
	"crypto/ed25519"
	"errors"

	"go.dedis.ch/kyber/v4"
	"go.dedis.ch/kyber/v4/proof"
	"go.dedis.ch/kyber/v4/sign/eddsa"
)

type Client struct {
	l       *local
	slot    *eddsa.EdDSA
	input   *Input
	final   *Final
	ownSlot int
}
type ClientMaterial struct {
	Public      Final
	OwnSlot     int
	SlotPrivate ed25519.PrivateKey
	Seeds       [Coordinators][32]byte
}

func NewClient(index int, id ed25519.PrivateKey) (*Client, error) {
	l, e := newLocal("client", index, id)
	if e != nil {
		return nil, e
	}
	l.sealHello()
	return &Client{l: l, slot: eddsa.NewEdDSA(newSuite().RandomStream()), ownSlot: -1}, nil
}
func (c *Client) Hello() Hello                   { return c.l.Hello() }
func (c *Client) Bind(r Roster, h []Hello) error { return c.l.bind(r, h) }
func (c *Client) Input() (Input, error) {
	if c.l.view == nil {
		return Input{}, errors.New("client not bound")
	}
	if c.input != nil {
		return clone(*c.input), nil
	}
	v := c.l.view
	r := v.s.Scalar().Pick(v.s.RandomStream())
	i := Input{Epoch: v.epoch, Client: c.l.index, X: raw(v.s.Point().Mul(r, nil)), Y: raw(v.s.Point().Add(c.slot.Public, v.s.Point().Mul(r, v.aggregate)))}
	p, pts, e := v.inputPredicate(i)
	if e != nil {
		return i, e
	}
	i.Proof, e = proof.HashProve(v.s, inputContext(i), p.Prover(v.s, map[string]kyber.Scalar{"r": r, "y": c.slot.Secret}, pts, nil))
	if e != nil {
		return i, e
	}
	i.Signature = sign(c.l.identity, "input", inputSigned(i))
	c.input = &i
	return clone(i), nil
}
func (c *Client) Accept(r Release) error {
	if c.l.view == nil || c.input == nil {
		return errors.New("client has not submitted")
	}
	if len(r.Transcript.Inputs) != Clients || hash(r.Transcript.Inputs[c.l.index]) != hash(*c.input) {
		return errors.New("own input replaced")
	}
	f, e := c.l.view.Finalize(r)
	if e != nil {
		return e
	}
	if c.final != nil && c.final.Root != f.Root {
		return errors.New("conflicting final setup")
	}
	pos := -1
	for i, p := range f.SlotPublic {
		if equalPublic(p, raw(c.slot.Public)) {
			pos = i
		}
	}
	if pos < 0 {
		return errors.New("own slot missing")
	}
	c.final = &f
	c.ownSlot = pos
	return nil
}

// Material is for the calling local role only; never transmit/log this result.
func (c *Client) Material() (ClientMaterial, error) {
	if c.final == nil {
		return ClientMaterial{}, errors.New("setup not accepted")
	}
	r := ClientMaterial{Public: clone(*c.final), OwnSlot: c.ownSlot}
	b, e := c.slot.MarshalBinary()
	if e != nil {
		return r, e
	}
	r.SlotPrivate = ed25519.PrivateKey(b)
	for j := range Coordinators {
		r.Seeds[j], e = c.l.derive(c.l.view, c.l.view.hellos[Clients+j])
		if e != nil {
			return ClientMaterial{}, e
		}
	}
	return r, nil
}
