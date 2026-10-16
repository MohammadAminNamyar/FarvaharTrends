package control

import (
	"bytes"
	"crypto/ed25519"
	"encoding/hex"
	"errors"
	"fmt"

	"go.dedis.ch/kyber/v4"
	"go.dedis.ch/kyber/v4/proof"
)

const PayloadBytes = 128

// Roster is supplied by an authenticated anonymous-key setup. It is not an
// admission or Sybil policy. A View holds only public material.
type Roster struct {
	Epoch                                 string
	ClientKeys, CoordinatorKeys, SlotKeys [][]byte
}
type Hello struct {
	Epoch            string
	Coordinator      int
	Keys             [][]byte // independently generated per anonymous slot
	Proof, Signature []byte
}

func helloStatement(h Hello) Hello { h.Proof = nil; h.Signature = nil; return h }
func helloSigned(h Hello) Hello    { h.Signature = nil; return h }
func helloContext(h Hello) string  { return domain + "/hello/" + hash(helloStatement(h)) }

type View struct {
	s          *suite
	roster     Roster
	hellos     []Hello
	session    string
	serverKeys [Coordinators][Clients]kyber.Point
	slotKeys   [Clients]kyber.Point
	sums       [Clients]kyber.Point
}

func (v *View) Session() string { return v.session }
func validHash(h string) bool {
	b, e := hex.DecodeString(h)
	return e == nil && len(b) == 32 && hex.EncodeToString(b) == h
}
func checkRoster(r Roster) error {
	if !validHash(r.Epoch) || len(r.ClientKeys) != Clients || len(r.CoordinatorKeys) != Coordinators || len(r.SlotKeys) != Clients {
		return errors.New("invalid fixed roster")
	}
	seen := map[string]bool{}
	for _, keys := range [][][]byte{r.ClientKeys, r.CoordinatorKeys, r.SlotKeys} {
		for _, p := range keys {
			if len(p) != 32 || seen[string(p)] {
				return errors.New("invalid or duplicated roster key")
			}
			seen[string(p)] = true
		}
	}
	return nil
}
func helloPredicate(s *suite, h Hello) (proof.Predicate, map[string]kyber.Point, error) {
	if len(h.Keys) != Clients {
		return nil, nil, errors.New("invalid coordinator key count")
	}
	pts := map[string]kyber.Point{"G": s.Point().Base()}
	var ps []proof.Predicate
	for slot, b := range h.Keys {
		p, e := s.point(b, true)
		if e != nil {
			return nil, nil, e
		}
		name := fmt.Sprint("B", slot)
		pts[name] = p
		ps = append(ps, proof.Rep(name, fmt.Sprint("b", slot), "G"))
	}
	return proof.And(ps...), pts, nil
}
func NewView(r Roster, hs []Hello) (*View, error) {
	if e := checkRoster(r); e != nil {
		return nil, e
	}
	if len(hs) != Coordinators {
		return nil, errors.New("missing control key hello")
	}
	v := &View{s: newSuite(), roster: clone(r), hellos: clone(hs)}
	seen := map[string]bool{}
	for i, h := range hs {
		if len(h.Proof) != Clients*64 || len(h.Signature) != 64 {
			return nil, errors.New("invalid bounded hello proof")
		}
		if h.Coordinator != i || h.Epoch != r.Epoch || !signed(r.CoordinatorKeys[i], "hello", helloSigned(h), h.Signature) {
			return nil, errors.New("invalid coordinator hello")
		}
		p, pts, e := helloPredicate(v.s, h)
		if e != nil {
			return nil, e
		}
		if e = verifyProof(v.s, helloContext(h), p.Verifier(v.s, pts), h.Proof); e != nil {
			return nil, e
		}
		for slot, b := range h.Keys {
			if seen[string(b)] {
				return nil, errors.New("reused control encryption key")
			}
			seen[string(b)] = true
			v.serverKeys[i][slot], e = v.s.point(b, true)
			if e != nil {
				return nil, e
			}
		}
	}
	for slot, b := range r.SlotKeys {
		p, e := v.s.point(b, true)
		if e != nil {
			return nil, e
		}
		v.slotKeys[slot] = p
		v.sums[slot] = v.s.Point().Null()
		for i := range Coordinators {
			v.sums[slot].Add(v.sums[slot], v.serverKeys[i][slot])
		}
		if v.sums[slot].Equal(v.s.Point().Null()) {
			return nil, errors.New("degenerate aggregate key")
		}
	}
	v.session = hash(struct {
		Roster Roster
		Hellos []Hello
	}{r, hs})
	return v, nil
}
func sameKey(a ed25519.PrivateKey, b []byte) bool {
	return len(a) == 64 && bytes.Equal(a.Public().(ed25519.PublicKey), b)
}

type Descriptor struct {
	Session  string
	Sequence uint64
	Context  string // authenticated failed-round transcript hash, supplied by adapter
}

func (v *View) valid(d Descriptor) error {
	if d.Session != v.session || d.Sequence == 0 || !validHash(d.Context) {
		return errors.New("invalid control descriptor")
	}
	return nil
}
