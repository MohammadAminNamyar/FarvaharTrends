package setup

import (
	"bytes"
	"errors"
	"fmt"

	"go.dedis.ch/kyber/v4"
	"go.dedis.ch/kyber/v4/proof"
	"go.dedis.ch/kyber/v4/shuffle"
)

type Input struct {
	Epoch                  string
	Client                 int
	X, Y, Proof, Signature []byte
}
type Mix struct {
	Epoch            string
	Stage            int
	PreviousRoot     string
	X, Y             [][]byte
	Proof, Signature []byte
}
type Transcript struct {
	Epoch  string
	Inputs []Input
	Mixes  []Mix
}
type Vote struct {
	Epoch, Root string
	Coordinator int
	Signature   []byte
}
type Share struct {
	Epoch, Root      string
	Coordinator      int
	Points           [][]byte
	Proof, Signature []byte
}
type Release struct {
	Transcript Transcript
	Votes      []Vote
	Shares     []Share
}
type Final struct {
	Epoch, Root string
	SlotPublic  [][]byte
}

func inputStatement(i Input) Input { i.Proof = nil; i.Signature = nil; return i }
func inputSigned(i Input) Input    { i.Signature = nil; return i }
func mixStatement(m Mix) Mix       { m.Proof = nil; m.Signature = nil; return m }
func mixSigned(m Mix) Mix          { m.Signature = nil; return m }
func voteSigned(v Vote) Vote       { v.Signature = nil; return v }
func shareStatement(v Share) Share { v.Proof = nil; v.Signature = nil; return v }
func shareSigned(v Share) Share    { v.Signature = nil; return v }
func inputContext(i Input) string  { return domain + "/input/" + hash(inputStatement(i)) }
func mixContext(m Mix) string      { return domain + "/shuffle/" + hash(mixStatement(m)) }
func shareContext(v Share) string  { return domain + "/decryption/" + hash(shareStatement(v)) }

func (v *View) inputPredicate(i Input) (proof.Predicate, map[string]kyber.Point, error) {
	if i.Epoch != v.epoch || i.Client < 0 || i.Client >= Clients {
		return nil, nil, errors.New("input identity/context")
	}
	x, e := v.s.point(i.X, true)
	if e != nil {
		return nil, nil, e
	}
	y, e := v.s.point(i.Y, false)
	if e != nil {
		return nil, nil, e
	}
	pts := map[string]kyber.Point{"G": v.s.Point().Base(), "B": v.aggregate, "X": x, "Y": y}
	// Knowledge of the encrypted slot-key scalar prevents inserting a victim's
	// copied key while claiming a different input. It does not certify a human.
	p := proof.And(proof.Rep("X", "r", "G"), proof.Rep("Y", "r", "B", "y", "G"))
	return p, pts, nil
}
func (v *View) VerifyInputs(inputs []Input) error {
	if len(inputs) != Clients {
		return errors.New("incomplete input roster")
	}
	for c, i := range inputs {
		if i.Client != c || len(i.Proof) > maxProofBytes || len(i.Signature) != 64 {
			return errors.New("input ordering/bounds")
		}
		p, pts, e := v.inputPredicate(i)
		if e != nil {
			return e
		}
		if !signed(v.roster.ClientKeys[c], "input", inputSigned(i), i.Signature) {
			return errors.New("input signature")
		}
		if e = verifyProof(v.s, inputContext(i), p.Verifier(v.s, pts), i.Proof); e != nil {
			return fmt.Errorf("input %d: %w", c, e)
		}
	}
	return nil
}
func (v *View) vectors(x, y [][]byte) ([]kyber.Point, []kyber.Point, error) {
	if len(x) != Clients || len(y) != Clients {
		return nil, nil, errors.New("shuffle vector length")
	}
	xx, yy := make([]kyber.Point, Clients), make([]kyber.Point, Clients)
	for i := range Clients {
		var e error
		xx[i], e = v.s.point(x[i], true)
		if e != nil {
			return nil, nil, e
		}
		yy[i], e = v.s.point(y[i], false)
		if e != nil {
			return nil, nil, e
		}
	}
	return xx, yy, nil
}
func (v *View) chain(t Transcript, stages int) ([]kyber.Point, []kyber.Point, error) {
	if t.Epoch != v.epoch || stages < 0 || stages > Coordinators || len(t.Mixes) != stages {
		return nil, nil, errors.New("transcript stage/epoch")
	}
	if e := v.VerifyInputs(t.Inputs); e != nil {
		return nil, nil, e
	}
	var xb, yb [][]byte
	for _, i := range t.Inputs {
		xb = append(xb, i.X)
		yb = append(yb, i.Y)
	}
	x, y, e := v.vectors(xb, yb)
	if e != nil {
		return nil, nil, e
	}
	for j, m := range t.Mixes {
		prefix := Transcript{Epoch: t.Epoch, Inputs: t.Inputs, Mixes: t.Mixes[:j]}
		// Normalize an empty slice to nil so caller allocation is not semantic.
		if j == 0 {
			prefix.Mixes = nil
		}
		if m.Epoch != v.epoch || m.Stage != j || m.PreviousRoot != hash(prefix) || len(m.Proof) > maxProofBytes || len(m.Signature) != 64 {
			return nil, nil, errors.New("shuffle context/bounds")
		}
		xx, yy, e := v.vectors(m.X, m.Y)
		if e != nil {
			return nil, nil, e
		}
		if !signed(v.roster.CoordinatorKeys[j], "mix", mixSigned(m), m.Signature) {
			return nil, nil, errors.New("shuffle signature")
		}
		if e = verifyProof(v.s, mixContext(m), shuffle.Verifier(v.s, nil, v.aggregate, x, y, xx, yy), m.Proof); e != nil {
			return nil, nil, e
		}
		x, y = xx, yy
	}
	return x, y, nil
}
func (v *View) votes(t Transcript, votes []Vote) error {
	if len(votes) != Coordinators {
		return errors.New("all coordinator votes required")
	}
	root := hash(t)
	for j, x := range votes {
		if x.Coordinator != j || x.Epoch != v.epoch || x.Root != root || !signed(v.roster.CoordinatorKeys[j], "vote", voteSigned(x), x.Signature) {
			return errors.New("invalid/inconsistent vote")
		}
	}
	return nil
}
func (v *View) sharePredicate(x []kyber.Point, out Share) (proof.Predicate, map[string]kyber.Point, error) {
	if out.Coordinator < 0 || out.Coordinator >= Coordinators || len(out.Points) != Clients || len(x) != Clients {
		return nil, nil, errors.New("share shape")
	}
	b, e := v.s.point(v.hellos[Clients+out.Coordinator].DecryptKey, true)
	if e != nil {
		return nil, nil, e
	}
	pts := map[string]kyber.Point{"G": v.s.Point().Base(), "B": b}
	preds := []proof.Predicate{proof.Rep("B", "b", "G")}
	for i := range Clients {
		n, pn := fmt.Sprint("X", i), fmt.Sprint("D", i)
		p, e := v.s.point(out.Points[i], true)
		if e != nil {
			return nil, nil, e
		}
		pts[n], pts[pn] = x[i], p
		preds = append(preds, proof.Rep(pn, "b", n))
	}
	return proof.And(preds...), pts, nil
}
func (v *View) Finalize(r Release) (Final, error) {
	x, y, e := v.chain(r.Transcript, Coordinators)
	if e != nil {
		return Final{}, e
	}
	if e = v.votes(r.Transcript, r.Votes); e != nil {
		return Final{}, e
	}
	if len(r.Shares) != Coordinators {
		return Final{}, errors.New("all decryption shares required")
	}
	root := hash(r.Transcript)
	for j, sh := range r.Shares {
		if sh.Coordinator != j || sh.Root != root || sh.Epoch != v.epoch || len(sh.Proof) > maxProofBytes || len(sh.Signature) != 64 {
			return Final{}, errors.New("share context/bounds")
		}
		p, pts, e := v.sharePredicate(x, sh)
		if e != nil {
			return Final{}, e
		}
		if !signed(v.roster.CoordinatorKeys[j], "share", shareSigned(sh), sh.Signature) {
			return Final{}, errors.New("share signature")
		}
		if e = verifyProof(v.s, shareContext(sh), p.Verifier(v.s, pts), sh.Proof); e != nil {
			return Final{}, e
		}
		for i, b := range sh.Points {
			p, e := v.s.point(b, true)
			if e != nil {
				return Final{}, e
			}
			y[i].Sub(y[i], p)
		}
	}
	final := Final{Root: root}
	seen := map[string]bool{}
	for _, p := range y {
		b := raw(p)
		if _, e = v.s.point(b, true); e != nil {
			return Final{}, e
		}
		if seen[string(b)] {
			return Final{}, errors.New("duplicate slot key")
		}
		seen[string(b)] = true
		final.SlotPublic = append(final.SlotPublic, b)
	}
	final.Epoch = hash(struct {
		Domain, Session, Root string
		Slots                 [][]byte
	}{domain + "/round-epoch", v.epoch, root, final.SlotPublic})
	return final, nil
}
func equalPublic(a, b []byte) bool { return bytes.Equal(a, b) }
