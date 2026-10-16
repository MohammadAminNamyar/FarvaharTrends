// Isolated feasibility implementation of Verdict's published ElGamal-style
// verifiable DC-net primitive (USENIX Security 2013, section 5.2), using Kyber's
// existing proof engine. NOT the Verdict system or a publisher protection claim.
// Central setup, no anonymous slot assignment, network, consensus, durable state,
// forward secrecy, Sybil policy or safe exclusion/reconfiguration protocol.
package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"go.dedis.ch/kyber/v4"
	"go.dedis.ch/kyber/v4/group/edwards25519"
	"go.dedis.ch/kyber/v4/proof"
)

const clients = 8
const servers = 3
const domain = "farvahartrends/verdict-elgamal-component/v1"

func must(e error) {
	if e != nil {
		panic(e)
	}
}
func ms(d time.Duration) float64 { return float64(d) / float64(time.Millisecond) }
func encoded(v any) []byte       { b, e := json.Marshal(v); must(e); return b }
func digest(v any) string        { h := sha256.Sum256(encoded(v)); return hex.EncodeToString(h[:]) }
func raw(p kyber.Point) []byte   { b, e := p.MarshalBinary(); must(e); return b }

type keyPair struct {
	private kyber.Scalar
	public  kyber.Point
}
type fixture struct {
	s           *edwards25519.SuiteEd25519
	epoch       string
	serverKeys  []keyPair
	slots       []keyPair
	identities  []ed25519.PrivateKey
	serverSum   kyber.Point
	setupProofs [][]byte
}
type descriptor struct {
	Epoch    string
	Sequence uint64
	Slot     int
	Size     int
}
type contribution struct {
	Index            int
	R, C             [][]byte
	Proof, Signature []byte
}
type share struct {
	Index            int
	Root             string
	S                [][]byte
	Proof, Signature []byte
}

func newFixture() *fixture {
	s := edwards25519.NewBlakeSHA256Ed25519()
	f := &fixture{s: s, serverSum: s.Point().Null()}
	newKey := func() keyPair {
		for {
			k := s.Scalar().Pick(s.RandomStream())
			if !k.Equal(s.Scalar().Zero()) {
				return keyPair{k, s.Point().Mul(k, nil)}
			}
		}
	}
	for range servers {
		k := newKey()
		f.serverKeys = append(f.serverKeys, k)
		f.serverSum.Add(f.serverSum, k.public)
	}
	for range clients {
		f.slots = append(f.slots, newKey())
	}
	for range clients + servers {
		_, k, e := ed25519.GenerateKey(rand.Reader)
		must(e)
		f.identities = append(f.identities, k)
	}
	var roster [][]byte
	for _, k := range f.serverKeys {
		roster = append(roster, raw(k.public))
	}
	for _, k := range f.slots {
		roster = append(roster, raw(k.public))
	}
	for _, k := range f.identities {
		roster = append(roster, k.Public().(ed25519.PublicKey))
	}
	nonce := make([]byte, 32)
	_, e := rand.Read(nonce)
	must(e)
	f.epoch = digest(struct {
		Keys  [][]byte
		Nonce []byte
	}{roster, nonce})
	if f.serverSum.Equal(s.Point().Null()) {
		panic("degenerate server-key sum")
	}
	// Prevent the elementary rogue-key cancellation attack in this fixture.
	// This is not distributed admission: the fixture still holds every secret.
	for i, k := range f.serverKeys {
		p := proof.Rep("B", "b", "G")
		points := map[string]kyber.Point{"B": k.public, "G": s.Point().Base()}
		ctx := domain + "/setup/" + f.epoch + fmt.Sprint("/", i)
		b, e := proof.HashProve(s, ctx, p.Prover(s, map[string]kyber.Scalar{"b": k.private}, points, nil))
		must(e)
		must(f.validProof(b, 1, 1))
		must(proof.HashVerify(s, ctx, p.Verifier(s, points), b))
		f.setupProofs = append(f.setupProofs, b)
	}
	return f
}
func (f *fixture) valid(d descriptor) error {
	if d.Epoch != f.epoch || d.Sequence == 0 || d.Slot < 0 || d.Slot >= clients || d.Size < 1 || d.Size > 8192 {
		return errors.New("invalid descriptor")
	}
	return nil
}
func (f *fixture) chunks(d descriptor) int {
	return (d.Size + f.s.Point().EmbedLen() - 1) / f.s.Point().EmbedLen()
}

// Reject noncanonical encodings and non-prime-subgroup points, including mixed
// torsion points (rejecting only small-order points is insufficient). [1/8][8]P
// equals P exactly on the prime subgroup. Identity is allowed for ciphertexts.
func (f *fixture) point(b []byte, nonzero bool) (kyber.Point, error) {
	if len(b) != 32 {
		return nil, errors.New("point length")
	}
	p := f.s.Point()
	if e := p.UnmarshalBinary(b); e != nil {
		return nil, e
	}
	if !bytes.Equal(raw(p), b) {
		return nil, errors.New("noncanonical point")
	}
	eight := f.s.Scalar().SetInt64(8)
	q := f.s.Point().Mul(f.s.Scalar().Inv(eight), f.s.Point().Mul(eight, p))
	if !q.Equal(p) || (nonzero && p.Equal(f.s.Point().Null())) {
		return nil, errors.New("point outside permitted subgroup")
	}
	return p, nil
}

// Kyber's pinned generic proof encoding is fixed here: commitments followed by
// scalar challenges/responses. Exact size rejects trailing data; group/scalar
// checks also cover commitments decoded internally by the proof library.
func (f *fixture) validProof(b []byte, npoints, nscalars int) error {
	if len(b) != 32*(npoints+nscalars) {
		return errors.New("proof length")
	}
	for i := range npoints {
		if _, e := f.point(b[32*i:32*(i+1)], false); e != nil {
			return e
		}
	}
	for i := npoints; i < npoints+nscalars; i++ {
		s := f.s.Scalar()
		part := b[32*i : 32*(i+1)]
		canonical, ok := s.(interface{ IsCanonical([]byte) bool })
		if !ok || !canonical.IsCanonical(part) {
			return errors.New("noncanonical proof scalar")
		}
	}
	return nil
}
func (f *fixture) clientPredicate(d descriptor, c contribution) (proof.Predicate, map[string]kyber.Point, error) {
	if e := f.valid(d); e != nil {
		return nil, nil, e
	}
	n := f.chunks(d)
	if c.Index < 0 || c.Index >= clients || len(c.R) != n || len(c.C) != n {
		return nil, nil, errors.New("invalid contribution shape")
	}
	pts := map[string]kyber.Point{"G": f.s.Point().Base(), "B": f.serverSum, "Y": f.slots[d.Slot].public}
	var cover []proof.Predicate
	for j := range n {
		rn, cn, kn := fmt.Sprint("R", j), fmt.Sprint("C", j), fmt.Sprint("r", j)
		r, e := f.point(c.R[j], true)
		if e != nil {
			return nil, nil, e
		}
		v, e := f.point(c.C[j], false)
		if e != nil {
			return nil, nil, e
		}
		pts[rn], pts[cn] = r, v
		cover = append(cover, proof.Rep(rn, kn, "G"), proof.Rep(cn, kn, "B"))
	}
	return proof.Or(proof.And(cover...), proof.Rep("Y", "y", "G")), pts, nil
}
func clientContext(d descriptor, c contribution) string {
	c.Proof = nil
	c.Signature = nil
	return domain + "/client/" + digest(struct {
		D descriptor
		C contribution
	}{d, c})
}
func clientSigned(d descriptor, c contribution) []byte {
	c.Signature = nil
	return encoded(struct {
		Domain string
		D      descriptor
		C      contribution
	}{domain + "/client-signature", d, c})
}

func (f *fixture) create(d descriptor, index int, message []byte) (contribution, error) {
	if e := f.valid(d); e != nil {
		return contribution{}, e
	}
	if index < 0 || index >= clients || (message != nil && len(message) != d.Size) {
		return contribution{}, errors.New("invalid client/message")
	}
	if message != nil && index != d.Slot {
		return contribution{}, errors.New("fixture client lacks this slot key")
	}
	c := contribution{Index: index}
	secrets := map[string]kyber.Scalar{}
	for j := range f.chunks(d) {
		r := f.s.Scalar().Pick(f.s.RandomStream())
		secrets[fmt.Sprint("r", j)] = r
		m := f.s.Point().Null()
		if message != nil {
			start := j * f.s.Point().EmbedLen()
			m = f.s.Point().Embed(message[start:min(len(message), start+f.s.Point().EmbedLen())], f.s.RandomStream())
		}
		c.R = append(c.R, raw(f.s.Point().Mul(r, nil)))
		c.C = append(c.C, raw(f.s.Point().Add(m, f.s.Point().Mul(r, f.serverSum))))
	}
	p, pts, e := f.clientPredicate(d, c)
	if e != nil {
		return c, e
	}
	branch := 0
	if message != nil {
		branch = 1
		secrets = map[string]kyber.Scalar{"y": f.slots[d.Slot].private}
	}
	c.Proof, e = proof.HashProve(f.s, clientContext(d, c), p.Prover(f.s, secrets, pts, map[proof.Predicate]int{p: branch}))
	if e != nil {
		return c, e
	}
	c.Signature = ed25519.Sign(f.identities[index], clientSigned(d, c))
	return c, nil
}
func (f *fixture) verifyClient(d descriptor, c contribution) error {
	p, pts, e := f.clientPredicate(d, c)
	if e != nil {
		return e
	}
	if !ed25519.Verify(f.identities[c.Index].Public().(ed25519.PublicKey), clientSigned(d, c), c.Signature) {
		return errors.New("client signature")
	}
	n := f.chunks(d)
	if e = f.validProof(c.Proof, 2*n+1, n+3); e != nil {
		return e
	}
	return proof.HashVerify(f.s, clientContext(d, c), p.Verifier(f.s, pts), c.Proof)
}
func (f *fixture) checkedInputs(d descriptor, c []contribution) (string, []kyber.Point, error) {
	if e := f.valid(d); e != nil {
		return "", nil, e
	}
	if len(c) != clients {
		return "", nil, errors.New("incomplete fixed roster")
	}
	r := make([]kyber.Point, f.chunks(d))
	for j := range r {
		r[j] = f.s.Point().Null()
	}
	for i, x := range c {
		if x.Index != i {
			return "", nil, errors.New("duplicate/reordered participant")
		}
		if e := f.verifyClient(d, x); e != nil {
			return "", nil, fmt.Errorf("client %d: %w", i, e)
		}
		for j := range r {
			p, e := f.point(x.R[j], true)
			if e != nil {
				return "", nil, e
			}
			r[j].Add(r[j], p)
		}
	}
	return digest(struct {
		D      descriptor
		Inputs []contribution
	}{d, c}), r, nil
}
func serverContext(d descriptor, v share) string {
	v.Proof = nil
	v.Signature = nil
	return domain + "/server/" + digest(struct {
		D descriptor
		S share
	}{d, v})
}
func serverSigned(d descriptor, v share) []byte {
	v.Signature = nil
	return encoded(struct {
		Domain string
		D      descriptor
		S      share
	}{domain + "/server-signature", d, v})
}
func (f *fixture) serverPredicate(d descriptor, v share, sumR []kyber.Point) (proof.Predicate, map[string]kyber.Point, error) {
	if e := f.valid(d); e != nil {
		return nil, nil, e
	}
	if v.Index < 0 || v.Index >= servers || len(v.S) != f.chunks(d) || len(sumR) != f.chunks(d) {
		return nil, nil, errors.New("invalid share shape")
	}
	pts := map[string]kyber.Point{"G": f.s.Point().Base(), "B": f.serverKeys[v.Index].public}
	preds := []proof.Predicate{proof.Rep("B", "b", "G")}
	for j, r := range sumR {
		n, sn := fmt.Sprint("N", j), fmt.Sprint("S", j)
		s, e := f.point(v.S[j], false)
		if e != nil {
			return nil, nil, e
		}
		pts[n], pts[sn] = f.s.Point().Neg(r), s
		preds = append(preds, proof.Rep(sn, "b", n))
	}
	return proof.And(preds...), pts, nil
}
func (f *fixture) release(d descriptor, index int, c []contribution) (share, error) {
	if index < 0 || index >= servers {
		return share{}, errors.New("invalid server")
	}
	root, r, e := f.checkedInputs(d, c)
	if e != nil {
		return share{}, e
	}
	v := share{Index: index, Root: root}
	for _, p := range r {
		v.S = append(v.S, raw(f.s.Point().Neg(f.s.Point().Mul(f.serverKeys[index].private, p))))
	}
	p, pts, e := f.serverPredicate(d, v, r)
	if e != nil {
		return v, e
	}
	v.Proof, e = proof.HashProve(f.s, serverContext(d, v), p.Prover(f.s, map[string]kyber.Scalar{"b": f.serverKeys[index].private}, pts, nil))
	if e != nil {
		return v, e
	}
	v.Signature = ed25519.Sign(f.identities[clients+index], serverSigned(d, v))
	return v, nil
}
func (f *fixture) reveal(d descriptor, c []contribution, v []share) ([]byte, error) {
	root, r, e := f.checkedInputs(d, c)
	if e != nil {
		return nil, e
	}
	if len(v) != servers {
		return nil, errors.New("incomplete release")
	}
	for i, x := range v {
		if x.Index != i || x.Root != root {
			return nil, errors.New("inconsistent release")
		}
		if !ed25519.Verify(f.identities[clients+i].Public().(ed25519.PublicKey), serverSigned(d, x), x.Signature) {
			return nil, errors.New("server signature")
		}
		p, pts, e := f.serverPredicate(d, x, r)
		if e != nil {
			return nil, e
		}
		if e = f.validProof(x.Proof, len(r)+1, 1); e != nil {
			return nil, e
		}
		if e = proof.HashVerify(f.s, serverContext(d, x), p.Verifier(f.s, pts), x.Proof); e != nil {
			return nil, e
		}
	}
	var message []byte
	for j := range r {
		p := f.s.Point().Null()
		for _, x := range c {
			q, e := f.point(x.C[j], false)
			if e != nil {
				return nil, e
			}
			p.Add(p, q)
		}
		for _, x := range v {
			q, e := f.point(x.S[j], false)
			if e != nil {
				return nil, e
			}
			p.Add(p, q)
		}
		part, e := p.Data()
		if e != nil {
			return nil, e
		}
		message = append(message, part...)
	}
	if len(message) != d.Size {
		return nil, errors.New("decoded payload length")
	}
	return message, nil
}
