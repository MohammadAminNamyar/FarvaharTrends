package setup

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"fmt"

	"go.dedis.ch/kyber/v4"
	"go.dedis.ch/kyber/v4/proof"
)

// Roster is an explicit trust input. Keys/counts do not establish independent
// humans, an honest minimum, or safe changes across sessions.
type Roster struct {
	Version                     int
	ClientKeys, CoordinatorKeys [][]byte
	Policy                      string
}
type Hello struct {
	Role                                              string
	Index                                             int
	Identity, Nonce, DH, DecryptKey, Proof, Signature []byte
}

func helloStatement(h Hello) Hello { h.Proof = nil; h.Signature = nil; return h }
func helloSigned(h Hello) Hello    { h.Signature = nil; return h }
func helloContext(h Hello) string {
	return domain + "/decrypt-key-knowledge/" + hash(helloStatement(h))
}

type local struct {
	index    int
	role     string
	identity ed25519.PrivateKey
	dh       *ecdh.PrivateKey
	hello    Hello
	view     *View
}

func newLocal(role string, index int, id ed25519.PrivateKey) (*local, error) {
	limit := Clients
	if role == "coordinator" {
		limit = Coordinators
	} else if role != "client" {
		return nil, errors.New("role")
	}
	if index < 0 || index >= limit || len(id) != 64 {
		return nil, errors.New("local identity")
	}
	// Reject malformed seed/public suffix pairs supplied by a caller.
	if !bytes.Equal(ed25519.NewKeyFromSeed(id.Seed()), id) {
		return nil, errors.New("identity key mismatch")
	}
	dh, e := ecdh.X25519().GenerateKey(rand.Reader)
	if e != nil {
		return nil, e
	}
	nonce := make([]byte, 32)
	if _, e = rand.Read(nonce); e != nil {
		return nil, e
	}
	l := &local{index: index, role: role, identity: append(ed25519.PrivateKey{}, id...), dh: dh}
	l.hello = Hello{Role: role, Index: index, Identity: append([]byte{}, id.Public().(ed25519.PublicKey)...), Nonce: nonce, DH: dh.PublicKey().Bytes()}
	return l, nil
}
func (l *local) sealHello()   { l.hello.Signature = sign(l.identity, "hello", helloSigned(l.hello)) }
func (l *local) Hello() Hello { return clone(l.hello) }
func (l *local) bind(r Roster, hellos []Hello) error {
	v, e := NewView(r, hellos)
	if e != nil {
		return e
	}
	pos := l.index
	if l.role == "coordinator" {
		pos += Clients
	}
	if hash(v.hellos[pos]) != hash(l.hello) {
		return errors.New("own hello replaced")
	}
	if l.view != nil && l.view.epoch != v.epoch {
		return errors.New("role already bound to another epoch")
	}
	// Validate actual DH agreements before committing local state.
	for _, h := range v.hellos {
		if h.Role != l.role {
			if _, e = l.derive(v, h); e != nil {
				return e
			}
		}
	}
	l.view = v
	return nil
}
func (l *local) derive(v *View, peer Hello) ([32]byte, error) {
	var out [32]byte
	pub, e := ecdh.X25519().NewPublicKey(peer.DH)
	if e != nil {
		return out, e
	}
	shared, e := l.dh.ECDH(pub)
	if e != nil {
		return out, e
	}
	client, server := l.index, peer.Index
	if l.role == "coordinator" {
		client, server = peer.Index, l.index
	}
	b, e := hkdf.Key(sha256.New, shared, []byte(v.epoch), fmt.Sprintf("%s/mask-seed/client/%d/coordinator/%d", domain, client, server), 32)
	clear(shared)
	if e != nil {
		return out, e
	}
	copy(out[:], b)
	clear(b)
	return out, nil
}

type View struct {
	s         *suite
	epoch     string
	roster    Roster
	hellos    []Hello
	aggregate kyber.Point
}

func NewView(r Roster, hellos []Hello) (*View, error) {
	if r.Version != 1 || len(r.ClientKeys) != Clients || len(r.CoordinatorKeys) != Coordinators || len(r.Policy) == 0 || len(r.Policy) > 1024 || len(hellos) != Clients+Coordinators {
		return nil, errors.New("bounded roster required")
	}
	for _, h := range hellos {
		if len(h.Role) > 16 || len(h.Identity) != 32 || len(h.Nonce) != 32 || len(h.DH) != 32 || len(h.DecryptKey) > 32 || len(h.Proof) > maxProofBytes || len(h.Signature) != 64 {
			return nil, errors.New("hello bounds")
		}
	}
	for _, p := range append(append([][]byte{}, r.ClientKeys...), r.CoordinatorKeys...) {
		if len(p) != 32 {
			return nil, errors.New("roster key length")
		}
	}
	v := &View{s: newSuite(), roster: clone(r), hellos: clone(hellos)}
	v.aggregate = v.s.Point().Null()
	ids := map[string]bool{}
	dhs := map[string]bool{}
	for pos, h := range v.hellos {
		role, index, expected := "client", pos, []byte(nil)
		if pos >= Clients {
			role, index = "coordinator", pos-Clients
			expected = r.CoordinatorKeys[index]
		} else {
			expected = r.ClientKeys[index]
		}
		if h.Role != role || h.Index != index || len(expected) != 32 || !bytes.Equal(expected, h.Identity) || len(h.Nonce) != 32 || len(h.DH) != 32 || ids[string(expected)] || dhs[string(h.DH)] {
			return nil, errors.New("invalid/duplicate roster hello")
		}
		ids[string(expected)] = true
		dhs[string(h.DH)] = true
		if !signed(expected, "hello", helloSigned(h), h.Signature) {
			return nil, errors.New("hello signature")
		}
		if role == "client" {
			if len(h.DecryptKey) != 0 || len(h.Proof) != 0 {
				return nil, errors.New("client has coordinator fields")
			}
			continue
		}
		b, e := v.s.point(h.DecryptKey, true)
		if e != nil {
			return nil, e
		}
		p := proof.Rep("B", "b", "G")
		pts := map[string]kyber.Point{"B": b, "G": v.s.Point().Base()}
		if e = verifyProof(v.s, helloContext(h), p.Verifier(v.s, pts), h.Proof); e != nil {
			return nil, e
		}
		v.aggregate.Add(v.aggregate, b)
	}
	if v.aggregate.Equal(v.s.Point().Null()) {
		return nil, errors.New("degenerate aggregate key")
	}
	v.epoch = hash(struct {
		Domain string
		Roster Roster
		Hellos []Hello
	}{domain, r, v.hellos})
	return v, nil
}
func (v *View) Epoch() string { return v.epoch }
