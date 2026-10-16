package control

import (
	"errors"
	"fmt"

	"go.dedis.ch/kyber/v4"
	"go.dedis.ch/kyber/v4/proof"
)

type Cell struct {
	R, C                  [][]byte
	Proof, EphemeralProof []byte
}
type Contribution struct {
	Client    int
	Cells     []Cell
	Signature []byte
}
type ShareCell struct {
	Points [][]byte
	Proof  []byte
}
type Share struct {
	Coordinator int
	Root        string
	Cells       []ShareCell
	Signature   []byte
}
type Vote struct {
	Coordinator int
	Root        string
	Signature   []byte
}
type Output struct {
	Slot    int
	Payload []byte
	Invalid bool
}
type Certificate struct {
	Coordinator int
	Root        string
	Signature   []byte
}

func certificateSigned(d Descriptor, x Certificate, out []Output) any {
	x.Signature = nil
	return struct {
		D      Descriptor
		C      Certificate
		Output []Output
	}{d, x, out}
}

func contributionSigned(d Descriptor, c Contribution) any {
	c.Signature = nil
	return struct {
		D Descriptor
		C Contribution
	}{d, c}
}
func shareSigned(d Descriptor, x Share) any {
	x.Signature = nil
	return struct {
		D Descriptor
		S Share
	}{d, x}
}
func voteSigned(d Descriptor, x Vote) any {
	x.Signature = nil
	return struct {
		D Descriptor
		V Vote
	}{d, x}
}
func cellContext(d Descriptor, client, slot int, c Cell) string {
	c.Proof = nil
	c.EphemeralProof = nil
	return domain + "/cell/" + hash(struct {
		D            Descriptor
		Client, Slot int
		Cell         Cell
	}{d, client, slot, c})
}
func shareContext(d Descriptor, server, slot int, root string, c ShareCell) string {
	c.Proof = nil
	return domain + "/share/" + hash(struct {
		D            Descriptor
		Server, Slot int
		Root         string
		Cell         ShareCell
	}{d, server, slot, root, c})
}
func (v *View) chunks() int {
	return (PayloadBytes + v.s.Point().EmbedLen() - 1) / v.s.Point().EmbedLen()
}
func (v *View) cellPredicates(slot int, c Cell) (proof.Predicate, proof.Predicate, map[string]kyber.Point, error) {
	if slot < 0 || slot >= Clients || len(c.R) != v.chunks() || len(c.C) != v.chunks() {
		return nil, nil, nil, errors.New("invalid fixed cell shape")
	}
	pts := map[string]kyber.Point{"G": v.s.Point().Base(), "B": v.sums[slot], "Y": v.slotKeys[slot]}
	var cover, ephemeral []proof.Predicate
	for j := range v.chunks() {
		r, e := v.s.point(c.R[j], true)
		if e != nil {
			return nil, nil, nil, e
		}
		p, e := v.s.point(c.C[j], false)
		if e != nil {
			return nil, nil, nil, e
		}
		rn, cn, kn := fmt.Sprint("R", j), fmt.Sprint("C", j), fmt.Sprint("r", j)
		pts[rn] = r
		pts[cn] = p
		ephemeral = append(ephemeral, proof.Rep(rn, kn, "G"))
		cover = append(cover, proof.Rep(rn, kn, "G"), proof.Rep(cn, kn, "B"))
	}
	// The independent ephemeral proof is mandatory even for a slot owner. It
	// prevents using that owner's OR branch as an arbitrary decryption oracle.
	return proof.Or(proof.And(cover...), proof.Rep("Y", "y", "G")), proof.And(ephemeral...), pts, nil
}
func (v *View) makeCell(d Descriptor, client, slot int, owner kyber.Scalar, message []byte) (Cell, error) {
	if message != nil && (owner == nil || len(message) != PayloadBytes) {
		return Cell{}, errors.New("invalid owner payload")
	}
	c := Cell{}
	randomness := map[string]kyber.Scalar{}
	for j := range v.chunks() {
		r := v.s.Scalar().Pick(v.s.RandomStream())
		for r.Equal(v.s.Scalar().Zero()) {
			r = v.s.Scalar().Pick(v.s.RandomStream())
		}
		randomness[fmt.Sprint("r", j)] = r
		m := v.s.Point().Null()
		if message != nil {
			start := j * v.s.Point().EmbedLen()
			m = v.s.Point().Embed(message[start:min(len(message), start+v.s.Point().EmbedLen())], v.s.RandomStream())
		}
		c.R = append(c.R, raw(v.s.Point().Mul(r, nil)))
		c.C = append(c.C, raw(v.s.Point().Add(m, v.s.Point().Mul(r, v.sums[slot]))))
	}
	p, ep, pts, e := v.cellPredicates(slot, c)
	if e != nil {
		return c, e
	}
	ctx := cellContext(d, client, slot, c)
	c.EphemeralProof, e = proof.HashProve(v.s, ctx+"/ephemeral", ep.Prover(v.s, randomness, pts, nil))
	if e != nil {
		return c, e
	}
	secrets, branch := randomness, 0
	if message != nil {
		secrets = map[string]kyber.Scalar{"y": owner}
		branch = 1
	}
	c.Proof, e = proof.HashProve(v.s, ctx+"/owner-or-cover", p.Prover(v.s, secrets, pts, map[proof.Predicate]int{p: branch}))
	return c, e
}
func (v *View) authenticateContribution(d Descriptor, c Contribution) error {
	if e := v.valid(d); e != nil {
		return e
	}
	if c.Client < 0 || c.Client >= Clients || len(c.Cells) != Clients || len(c.Signature) != 64 {
		return errors.New("invalid control contribution shape")
	}
	for _, x := range c.Cells {
		if len(x.R) != v.chunks() || len(x.C) != v.chunks() || len(x.Proof) != 32*(3*v.chunks()+4) || len(x.EphemeralProof) != 64*v.chunks() {
			return errors.New("invalid bounded client proof shape")
		}
		for _, list := range [][][]byte{x.R, x.C} {
			for _, b := range list {
				if len(b) != 32 {
					return errors.New("invalid point length")
				}
			}
		}
	}
	if !signed(v.roster.ClientKeys[c.Client], "input", contributionSigned(d, c), c.Signature) {
		return errors.New("invalid control contribution")
	}
	return nil
}
func (v *View) authenticateInputs(d Descriptor, xs []Contribution) (string, error) {
	if len(xs) != Clients {
		return "", errors.New("incomplete control cohort")
	}
	for i, x := range xs {
		if x.Client != i {
			return "", errors.New("duplicate/out-of-order client")
		}
		if e := v.authenticateContribution(d, x); e != nil {
			return "", e
		}
	}
	return hash(struct {
		D      Descriptor
		Inputs []Contribution
	}{d, xs}), nil
}
func (v *View) verifyContribution(d Descriptor, c Contribution) error {
	if e := v.authenticateContribution(d, c); e != nil {
		return e
	}
	for slot, x := range c.Cells {
		p, ep, pts, e := v.cellPredicates(slot, x)
		if e != nil {
			return e
		}
		ctx := cellContext(d, c.Client, slot, x)
		if e = verifyProof(v.s, ctx+"/ephemeral", ep.Verifier(v.s, pts), x.EphemeralProof); e != nil {
			return e
		}
		if e = verifyProof(v.s, ctx+"/owner-or-cover", p.Verifier(v.s, pts), x.Proof); e != nil {
			return e
		}
	}
	return nil
}
func (v *View) checkedInputs(d Descriptor, xs []Contribution) (string, [][]kyber.Point, error) {
	root, e := v.authenticateInputs(d, xs)
	if e != nil {
		return "", nil, e
	}
	if len(xs) != Clients {
		return "", nil, errors.New("incomplete control cohort")
	}
	sums := make([][]kyber.Point, Clients)
	for slot := range Clients {
		for range v.chunks() {
			sums[slot] = append(sums[slot], v.s.Point().Null())
		}
	}
	for i, x := range xs {
		if x.Client != i {
			return "", nil, errors.New("duplicate/out-of-order client")
		}
		if e := v.verifyContribution(d, x); e != nil {
			return "", nil, fmt.Errorf("client %d: %w", i, e)
		}
		for slot, cell := range x.Cells {
			for j, b := range cell.R {
				p, e := v.s.point(b, true)
				if e != nil {
					return "", nil, e
				}
				sums[slot][j].Add(sums[slot][j], p)
			}
		}
	}
	return root, sums, nil
}

// Clients may rely on unanimous output certificates under the existing
// at-least-one-honest-coordinator assumption. Every coordinator still checks
// all client proofs and decryption proofs before signing the exact output.
func (v *View) VerifyCertificates(d Descriptor, root string, out []Output, certs []Certificate) error {
	if e := v.valid(d); e != nil {
		return e
	}
	if !validHash(root) || len(out) != Clients || len(certs) != Coordinators {
		return errors.New("incomplete certified control output")
	}
	for i, x := range out {
		if x.Slot != i || (x.Payload != nil && len(x.Payload) != PayloadBytes) || (x.Invalid && x.Payload != nil) {
			return errors.New("invalid certified output shape")
		}
	}
	for i, x := range certs {
		if x.Coordinator != i || x.Root != root || len(x.Signature) != 64 || !signed(v.roster.CoordinatorKeys[i], "output", certificateSigned(d, x, out), x.Signature) {
			return errors.New("invalid unanimous control certificate")
		}
	}
	return nil
}
func (v *View) sharePredicate(server, slot int, c ShareCell, rs []kyber.Point) (proof.Predicate, map[string]kyber.Point, error) {
	if len(c.Points) != v.chunks() || len(rs) != v.chunks() {
		return nil, nil, errors.New("invalid share shape")
	}
	pts := map[string]kyber.Point{"G": v.s.Point().Base(), "B": v.serverKeys[server][slot]}
	ps := []proof.Predicate{proof.Rep("B", "b", "G")}
	for j, b := range c.Points {
		p, e := v.s.point(b, false)
		if e != nil {
			return nil, nil, e
		}
		n, s := fmt.Sprint("N", j), fmt.Sprint("S", j)
		pts[n] = v.s.Point().Neg(rs[j])
		pts[s] = p
		ps = append(ps, proof.Rep(s, "b", n))
	}
	return proof.And(ps...), pts, nil
}
func (v *View) verifyVotes(d Descriptor, root string, vs []Vote) error {
	if len(vs) != Coordinators {
		return errors.New("missing control commitments")
	}
	for i, x := range vs {
		if x.Coordinator != i || x.Root != root || !signed(v.roster.CoordinatorKeys[i], "vote", voteSigned(d, x), x.Signature) {
			return errors.New("inconsistent control commitment")
		}
	}
	return nil
}
func (v *View) authenticateShares(d Descriptor, root string, vs []Vote, ss []Share) error {
	if e := v.verifyVotes(d, root, vs); e != nil {
		return e
	}
	if len(ss) != Coordinators {
		return errors.New("missing control share")
	}
	for server, x := range ss {
		if x.Coordinator != server || x.Root != root || len(x.Cells) != Clients || len(x.Signature) != 64 {
			return errors.New("invalid share shape")
		}
		for _, cell := range x.Cells {
			if len(cell.Points) != v.chunks() || len(cell.Proof) != 32*(v.chunks()+2) {
				return errors.New("invalid bounded share proof")
			}
			for _, b := range cell.Points {
				if len(b) != 32 {
					return errors.New("invalid share point length")
				}
			}
		}
		if !signed(v.roster.CoordinatorKeys[server], "share", shareSigned(d, x), x.Signature) {
			return errors.New("invalid control share")
		}
	}
	return nil
}
func (v *View) revealChecked(d Descriptor, root string, rs [][]kyber.Point, xs []Contribution, vs []Vote, ss []Share) ([]Output, error) {
	if e := v.authenticateShares(d, root, vs, ss); e != nil {
		return nil, e
	}
	for server, x := range ss {
		for slot, c := range x.Cells {
			p, pts, e := v.sharePredicate(server, slot, c, rs[slot])
			if e != nil {
				return nil, e
			}
			if e = verifyProof(v.s, shareContext(d, server, slot, root, c), p.Verifier(v.s, pts), c.Proof); e != nil {
				return nil, e
			}
		}
	}
	var out []Output
	for slot := range Clients {
		x := Output{Slot: slot}
		nulls := 0
		for j := range v.chunks() {
			p := v.s.Point().Null()
			for _, c := range xs {
				q, e := v.s.point(c.Cells[slot].C[j], false)
				if e != nil {
					return nil, e
				}
				p.Add(p, q)
			}
			for _, s := range ss {
				q, e := v.s.point(s.Cells[slot].Points[j], false)
				if e != nil {
					return nil, e
				}
				p.Add(p, q)
			}
			if p.Equal(v.s.Point().Null()) {
				nulls++
				continue
			}
			b, e := p.Data()
			expected := min(v.s.Point().EmbedLen(), PayloadBytes-j*v.s.Point().EmbedLen())
			if e != nil || len(b) != expected {
				x.Invalid = true
			}
			x.Payload = append(x.Payload, b...)
		}
		if nulls == v.chunks() {
			x.Payload = nil
			x.Invalid = false
		} else if nulls != 0 || len(x.Payload) != PayloadBytes {
			x.Invalid = true
		}
		if x.Invalid {
			x.Payload = nil
		}
		out = append(out, x)
	}
	return out, nil
}
func (v *View) Reveal(d Descriptor, xs []Contribution, vs []Vote, ss []Share) ([]Output, error) {
	root, rs, e := v.checkedInputs(d, xs)
	if e != nil {
		return nil, e
	}
	return v.revealChecked(d, root, rs, xs, vs, ss)
}
