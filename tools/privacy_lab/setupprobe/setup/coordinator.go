package setup

import (
	"crypto/ed25519"
	"errors"

	"go.dedis.ch/kyber/v4"
	"go.dedis.ch/kyber/v4/proof"
	"go.dedis.ch/kyber/v4/shuffle"
)

type Coordinator struct {
	l          *local
	decrypt    kyber.Scalar
	mixedInput string
	mix        *Mix
	vote       *Vote
	share      *Share
	final      *Final
}
type CoordinatorMaterial struct {
	Public Final
	Seeds  [Clients][32]byte
}

func NewCoordinator(index int, id ed25519.PrivateKey) (*Coordinator, error) {
	l, e := newLocal("coordinator", index, id)
	if e != nil {
		return nil, e
	}
	s := newSuite()
	b := s.Scalar().Pick(s.RandomStream())
	pub := s.Point().Mul(b, nil)
	l.hello.DecryptKey = raw(pub)
	p := proof.Rep("B", "b", "G")
	pts := map[string]kyber.Point{"B": pub, "G": s.Point().Base()}
	l.hello.Proof, e = proof.HashProve(s, helloContext(l.hello), p.Prover(s, map[string]kyber.Scalar{"b": b}, pts, nil))
	if e != nil {
		return nil, e
	}
	l.sealHello()
	return &Coordinator{l: l, decrypt: b}, nil
}
func (c *Coordinator) Hello() Hello                   { return c.l.Hello() }
func (c *Coordinator) Bind(r Roster, h []Hello) error { return c.l.bind(r, h) }
func (c *Coordinator) Mix(t Transcript) (Mix, error) {
	if c.l.view == nil {
		return Mix{}, errors.New("coordinator not bound")
	}
	if len(t.Mixes) == 0 {
		t.Mixes = nil
	}
	v := c.l.view
	x, y, e := v.chain(t, c.l.index)
	if e != nil {
		return Mix{}, e
	}
	root := hash(t)
	if c.mix != nil {
		if c.mixedInput != root {
			return Mix{}, errors.New("conflicting shuffle input")
		}
		return clone(*c.mix), nil
	}
	xx, yy, prover := shuffle.Shuffle(v.s, nil, v.aggregate, x, y, v.s.RandomStream())
	m := Mix{Epoch: v.epoch, Stage: c.l.index, PreviousRoot: root}
	for j := range Clients {
		m.X = append(m.X, raw(xx[j]))
		m.Y = append(m.Y, raw(yy[j]))
	}
	m.Proof, e = proof.HashProve(v.s, mixContext(m), prover)
	if e != nil {
		return m, e
	}
	m.Signature = sign(c.l.identity, "mix", mixSigned(m))
	c.mix = &m
	c.mixedInput = root
	return clone(m), nil
}
func (c *Coordinator) Commit(t Transcript) (Vote, error) {
	if c.l.view == nil || c.mix == nil {
		return Vote{}, errors.New("shuffle not completed")
	}
	if _, _, e := c.l.view.chain(t, Coordinators); e != nil {
		return Vote{}, e
	}
	if hash(t.Mixes[c.l.index]) != hash(*c.mix) {
		return Vote{}, errors.New("own shuffle replaced")
	}
	root := hash(t)
	if c.vote != nil {
		if c.vote.Root != root {
			return Vote{}, errors.New("conflicting commit")
		}
		return clone(*c.vote), nil
	}
	v := Vote{Epoch: c.l.view.epoch, Root: root, Coordinator: c.l.index}
	v.Signature = sign(c.l.identity, "vote", voteSigned(v))
	c.vote = &v
	return clone(v), nil
}
func (c *Coordinator) Release(t Transcript, votes []Vote) (Share, error) {
	if c.vote == nil || c.l.view == nil {
		return Share{}, errors.New("not committed")
	}
	v := c.l.view
	x, _, e := v.chain(t, Coordinators)
	if e != nil {
		return Share{}, e
	}
	if c.vote.Root != hash(t) {
		return Share{}, errors.New("decryption root conflict")
	}
	if e = v.votes(t, votes); e != nil {
		return Share{}, e
	}
	if c.share != nil {
		return clone(*c.share), nil
	}
	sh := Share{Epoch: v.epoch, Root: c.vote.Root, Coordinator: c.l.index}
	for _, p := range x {
		sh.Points = append(sh.Points, raw(v.s.Point().Mul(c.decrypt, p)))
	}
	p, pts, e := v.sharePredicate(x, sh)
	if e != nil {
		return sh, e
	}
	sh.Proof, e = proof.HashProve(v.s, shareContext(sh), p.Prover(v.s, map[string]kyber.Scalar{"b": c.decrypt}, pts, nil))
	if e != nil {
		return sh, e
	}
	sh.Signature = sign(c.l.identity, "share", shareSigned(sh))
	c.share = &sh
	return clone(sh), nil
}
func (c *Coordinator) Accept(r Release) error {
	if c.vote == nil || c.l.view == nil || c.vote.Root != hash(r.Transcript) {
		return errors.New("uncommitted final transcript")
	}
	f, e := c.l.view.Finalize(r)
	if e != nil {
		return e
	}
	c.final = &f
	return nil
}

// The local coordinator material has no owner mapping or anonymous slot key.
func (c *Coordinator) Material() (CoordinatorMaterial, error) {
	if c.final == nil {
		return CoordinatorMaterial{}, errors.New("setup not accepted")
	}
	r := CoordinatorMaterial{Public: clone(*c.final)}
	for i := range Clients {
		var e error
		r.Seeds[i], e = c.l.derive(c.l.view, c.l.view.hellos[i])
		if e != nil {
			return CoordinatorMaterial{}, e
		}
	}
	return r, nil
}
