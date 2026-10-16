// Role objects own only their own secrets. Calls must be serialized. This is
// in-memory research state: no durable replay journal or crash-resume policy.
package control

import (
	"crypto/ed25519"
	"errors"
	"fmt"

	"go.dedis.ch/kyber/v4"
	"go.dedis.ch/kyber/v4/proof"
	"go.dedis.ch/kyber/v4/sign/eddsa"
)

const maxProofAttempts = 3

var errProofBudget = errors.New("control proof budget exhausted; round remains blocked")

type Client struct {
	v            *View
	index, slot  int
	id           ed25519.PrivateKey
	owner        kyber.Scalar
	d            *Descriptor
	input        *Contribution
	payloadHash  string
	acceptedHash string
	output       []Output
}

func NewClient(v *View, index, slot int, id, slotPrivate ed25519.PrivateKey) (*Client, error) {
	if v == nil || index < 0 || index >= Clients || slot < 0 || slot >= Clients || !sameKey(id, v.roster.ClientKeys[index]) || !sameKey(slotPrivate, v.roster.SlotKeys[slot]) {
		return nil, errors.New("invalid client-local control keys")
	}
	k := &eddsa.EdDSA{}
	if e := k.UnmarshalBinary(slotPrivate); e != nil {
		return nil, e
	}
	if !k.Public.Equal(v.slotKeys[slot]) {
		return nil, errors.New("wrong anonymous control scalar")
	}
	return &Client{v: v, index: index, slot: slot, id: append([]byte{}, id...), owner: k.Secret}, nil
}
func (c *Client) Begin(d Descriptor) error {
	if e := c.v.valid(d); e != nil {
		return e
	}
	if c.d != nil {
		if *c.d == d {
			return nil
		}
		if c.acceptedHash == "" || d.Sequence <= c.d.Sequence {
			return errors.New("unfinished or replayed control round")
		}
	}
	c.d = &d
	c.input = nil
	c.payloadHash = ""
	c.acceptedHash = ""
	c.output = nil
	return nil
}
func (c *Client) Prepare(payload []byte) (Contribution, error) {
	if c.d == nil || (payload != nil && len(payload) != PayloadBytes) {
		return Contribution{}, errors.New("control not begun or invalid payload")
	}
	h := hash(payload)
	if c.input != nil {
		if h != c.payloadHash {
			return Contribution{}, errors.New("control input fork")
		}
		return clone(*c.input), nil
	}
	x := Contribution{Client: c.index}
	for slot := range Clients {
		var p []byte
		var owner kyber.Scalar
		if slot == c.slot {
			p = payload
			owner = c.owner
		}
		cell, e := c.v.makeCell(*c.d, c.index, slot, owner, p)
		if e != nil {
			return x, e
		}
		x.Cells = append(x.Cells, cell)
	}
	x.Signature = sign(c.id, "input", contributionSigned(*c.d, x))
	c.input = &x
	c.payloadHash = h
	return clone(x), nil
}
func (c *Client) Accept(xs []Contribution, vs []Vote, ss []Share) ([]Output, error) {
	if c.d == nil || c.input == nil || len(xs) != Clients || hash(xs[c.index]) != hash(*c.input) {
		return nil, errors.New("own control input absent or replaced")
	}
	h := hash(struct {
		X []Contribution
		V []Vote
		S []Share
	}{xs, vs, ss})
	if c.acceptedHash != "" {
		if c.acceptedHash != h {
			return nil, errors.New("conflicting control output")
		}
		return clone(c.output), nil
	}
	out, e := c.v.Reveal(*c.d, xs, vs, ss)
	if e != nil {
		return nil, e
	}
	c.acceptedHash = h
	c.output = clone(out)
	return out, nil
}

func (c *Client) AcceptCertified(xs []Contribution, vs []Vote, out []Output, certs []Certificate) ([]Output, error) {
	if c.d == nil || c.input == nil || len(xs) != Clients || hash(xs[c.index]) != hash(*c.input) {
		return nil, errors.New("own control input absent or replaced")
	}
	h := hash(struct {
		X []Contribution
		V []Vote
		O []Output
		C []Certificate
	}{xs, vs, out, certs})
	if c.acceptedHash != "" {
		if c.acceptedHash != h {
			return nil, errors.New("conflicting control output")
		}
		return clone(c.output), nil
	}
	root, e := c.v.authenticateInputs(*c.d, xs)
	if e != nil {
		return nil, e
	}
	if e = c.v.verifyVotes(*c.d, root, vs); e != nil {
		return nil, e
	}
	if e = c.v.VerifyCertificates(*c.d, root, out, certs); e != nil {
		return nil, e
	}
	c.acceptedHash, c.output = h, clone(out)
	return clone(out), nil
}

type Coordinator struct {
	s                  *suite
	roster             Roster
	index              int
	id                 ed25519.PrivateKey
	keys               [Clients]kyber.Scalar
	hello              Hello
	v                  *View
	d                  *Descriptor
	inputs             []Contribution
	sumR               [][]kyber.Point
	vote               *Vote
	share              *Share
	acceptedHash       string
	output             []Output
	inputProofAttempts int
	shareProofAttempts int
}

func NewCoordinator(r Roster, index int, id ed25519.PrivateKey) (*Coordinator, error) {
	if e := checkRoster(r); e != nil {
		return nil, e
	}
	if index < 0 || index >= Coordinators || !sameKey(id, r.CoordinatorKeys[index]) {
		return nil, errors.New("invalid coordinator-local key")
	}
	c := &Coordinator{s: newSuite(), roster: clone(r), index: index, id: append([]byte{}, id...)}
	c.hello = Hello{Epoch: r.Epoch, Coordinator: index}
	sec := map[string]kyber.Scalar{}
	for slot := range Clients {
		k := c.s.Scalar().Pick(c.s.RandomStream())
		for k.Equal(c.s.Scalar().Zero()) {
			k = c.s.Scalar().Pick(c.s.RandomStream())
		}
		c.keys[slot] = k
		sec[fmt.Sprint("b", slot)] = k
		c.hello.Keys = append(c.hello.Keys, raw(c.s.Point().Mul(k, nil)))
	}
	p, pts, e := helloPredicate(c.s, c.hello)
	if e != nil {
		return nil, e
	}
	c.hello.Proof, e = proof.HashProve(c.s, helloContext(c.hello), p.Prover(c.s, sec, pts, nil))
	if e != nil {
		return nil, e
	}
	c.hello.Signature = sign(c.id, "hello", helloSigned(c.hello))
	return c, nil
}
func (c *Coordinator) Hello() Hello { return clone(c.hello) }
func (c *Coordinator) Bind(hs []Hello) error {
	if len(hs) != Coordinators || hash(hs[c.index]) != hash(c.hello) {
		return errors.New("own control keys replaced")
	}
	if c.v != nil {
		if hash(c.v.hellos) != hash(hs) {
			return errors.New("control session already bound")
		}
		return nil
	}
	v, e := NewView(c.roster, hs)
	if e != nil {
		return e
	}
	if c.v != nil && c.v.session != v.session {
		return errors.New("control session already bound")
	}
	c.v = v
	return nil
}
func (c *Coordinator) Begin(d Descriptor) error {
	if c.v == nil {
		return errors.New("control keys not bound")
	}
	if e := c.v.valid(d); e != nil {
		return e
	}
	if c.d != nil {
		if *c.d == d {
			return nil
		}
		if c.acceptedHash == "" || d.Sequence <= c.d.Sequence {
			return errors.New("unfinished or replayed control round")
		}
	}
	c.d = &d
	c.inputs = nil
	c.sumR = nil
	c.vote = nil
	c.share = nil
	c.acceptedHash = ""
	c.output = nil
	c.inputProofAttempts, c.shareProofAttempts = 0, 0
	return nil
}
func (c *Coordinator) Commit(xs []Contribution) (Vote, error) {
	if c.d == nil {
		return Vote{}, errors.New("control round not begun")
	}
	if c.vote != nil {
		h := hash(struct {
			D      Descriptor
			Inputs []Contribution
		}{*c.d, xs})
		if c.vote.Root != h {
			return Vote{}, errors.New("conflicting control input set")
		}
		return clone(*c.vote), nil
	}
	if _, e := c.v.authenticateInputs(*c.d, xs); e != nil {
		return Vote{}, e
	}
	if c.inputProofAttempts >= maxProofAttempts {
		return Vote{}, errProofBudget
	}
	c.inputProofAttempts++
	root, rs, e := c.v.checkedInputs(*c.d, xs)
	if e != nil {
		return Vote{}, e
	}
	x := Vote{Coordinator: c.index, Root: root}
	x.Signature = sign(c.id, "vote", voteSigned(*c.d, x))
	c.inputs = clone(xs)
	c.sumR = rs
	c.vote = &x
	return clone(x), nil
}
func (c *Coordinator) Release(vs []Vote) (Share, error) {
	if c.d == nil || c.vote == nil {
		return Share{}, errors.New("uncommitted control release")
	}
	if e := c.v.verifyVotes(*c.d, c.vote.Root, vs); e != nil {
		return Share{}, e
	}
	if c.share != nil {
		return clone(*c.share), nil
	}
	x := Share{Coordinator: c.index, Root: c.vote.Root}
	for slot, rs := range c.sumR {
		cell := ShareCell{}
		for _, r := range rs {
			cell.Points = append(cell.Points, raw(c.s.Point().Neg(c.s.Point().Mul(c.keys[slot], r))))
		}
		p, pts, e := c.v.sharePredicate(c.index, slot, cell, rs)
		if e != nil {
			return Share{}, e
		}
		cell.Proof, e = proof.HashProve(c.s, shareContext(*c.d, c.index, slot, x.Root, cell), p.Prover(c.s, map[string]kyber.Scalar{"b": c.keys[slot]}, pts, nil))
		if e != nil {
			return Share{}, e
		}
		x.Cells = append(x.Cells, cell)
	}
	x.Signature = sign(c.id, "share", shareSigned(*c.d, x))
	c.share = &x
	return clone(x), nil
}
func (c *Coordinator) Accept(vs []Vote, ss []Share) ([]Output, error) {
	if c.d == nil || c.vote == nil || c.share == nil {
		return nil, errors.New("local control share not released")
	}
	h := hash(struct {
		V []Vote
		S []Share
	}{vs, ss})
	if c.acceptedHash != "" {
		if h != c.acceptedHash {
			return nil, errors.New("conflicting control output")
		}
		return clone(c.output), nil
	}
	if e := c.v.authenticateShares(*c.d, c.vote.Root, vs, ss); e != nil {
		return nil, e
	}
	if c.shareProofAttempts >= maxProofAttempts {
		return nil, errProofBudget
	}
	c.shareProofAttempts++
	out, e := c.v.revealChecked(*c.d, c.vote.Root, c.sumR, c.inputs, vs, ss)
	if e != nil {
		return nil, e
	}
	c.acceptedHash = h
	c.output = clone(out)
	c.inputs = nil
	c.sumR = nil
	return out, nil
}

func (c *Coordinator) Certify() (Certificate, error) {
	if c.d == nil || c.vote == nil || c.acceptedHash == "" || len(c.output) != Clients {
		return Certificate{}, errors.New("control output not fully verified")
	}
	x := Certificate{Coordinator: c.index, Root: c.vote.Root}
	x.Signature = sign(c.id, "output", certificateSigned(*c.d, x, c.output))
	return x, nil
}
