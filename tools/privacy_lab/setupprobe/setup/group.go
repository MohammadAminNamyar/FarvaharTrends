// Package setup is an isolated experimental, all-coordinator anonymous slot
// setup using Kyber's Neff shuffle and representation proofs. Not a reviewed
// anonymity protocol or a deployment. Membership is supplied, not discovered
// or made Sybil-resistant here. State is memory-only and must never be restored
// into a reused epoch. Each role owns only its local secrets.
package setup

import (
	"bytes"
	"crypto/cipher"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"reflect"

	"go.dedis.ch/kyber/v4"
	"go.dedis.ch/kyber/v4/group/edwards25519"
	"go.dedis.ch/kyber/v4/proof"
)

const Clients = 8
const Coordinators = 3
const domain = "farvahartrends/anonymous-setup-lab/v1"
const maxProofBytes = 65536

func must(e error) {
	if e != nil {
		panic(e)
	}
}
func encode(v any) []byte      { b, e := json.Marshal(v); must(e); return b }
func hash(v any) string        { h := sha256.Sum256(encode(v)); return hex.EncodeToString(h[:]) }
func clone[T any](x T) T       { var y T; must(json.Unmarshal(encode(x), &y)); return y }
func raw(p kyber.Point) []byte { b, e := p.MarshalBinary(); must(e); return b }
func sign(k ed25519.PrivateKey, scope string, v any) []byte {
	return ed25519.Sign(k, append([]byte(domain+"/"+scope+"/"), encode(v)...))
}
func signed(k []byte, scope string, v any, sig []byte) bool {
	return len(k) == 32 && ed25519.Verify(k, append([]byte(domain+"/"+scope+"/"), encode(v)...), sig)
}

type suite struct {
	*edwards25519.SuiteEd25519
	readBytes int
}

func newSuite() *suite { return &suite{SuiteEd25519: edwards25519.NewBlakeSHA256Ed25519()} }
func (s *suite) point(b []byte, nonzero bool) (kyber.Point, error) {
	if len(b) != 32 {
		return nil, errors.New("point length")
	}
	p := s.Point()
	if e := p.UnmarshalBinary(b); e != nil {
		return nil, e
	}
	if !bytes.Equal(raw(p), b) {
		return nil, errors.New("noncanonical point")
	}
	if e := s.prime(p); e != nil {
		return nil, e
	}
	if nonzero && p.Equal(s.Point().Null()) {
		return nil, errors.New("identity public point")
	}
	return p, nil
}
func (s *suite) prime(p kyber.Point) error {
	eight := s.Scalar().SetInt64(8)
	q := s.Point().Mul(s.Scalar().Inv(eight), s.Point().Mul(eight, p))
	if !p.Equal(q) {
		return errors.New("non-prime-subgroup point")
	}
	return nil
}

// Keep the upstream proof algorithm and Fiat-Shamir framing. Add canonical
// re-encoding and subgroup validation to each untrusted proof-message read.
// Random streams MUST retain their cipher.Stream interface and upstream Pick
// behavior; wrapping those in TeeReader would change the proof challenges.
func (s *suite) Read(r io.Reader, objs ...any) error {
	if _, ok := r.(cipher.Stream); ok {
		return s.SuiteEd25519.Read(r, objs...)
	}
	var original bytes.Buffer
	if e := s.SuiteEd25519.Read(io.TeeReader(r, &original), objs...); e != nil {
		return e
	}
	s.readBytes += original.Len()
	var canonical bytes.Buffer
	if e := s.SuiteEd25519.Write(&canonical, objs...); e != nil {
		return e
	}
	if !bytes.Equal(original.Bytes(), canonical.Bytes()) {
		return errors.New("noncanonical proof encoding")
	}
	for _, x := range objs {
		if e := s.validate(reflect.ValueOf(x)); e != nil {
			return e
		}
	}
	return nil
}
func (s *suite) validate(v reflect.Value) error {
	if !v.IsValid() {
		return errors.New("invalid proof value")
	}
	if v.CanInterface() {
		if p, ok := v.Interface().(kyber.Point); ok {
			return s.prime(p)
		}
		if _, ok := v.Interface().(kyber.Scalar); ok {
			return nil
		} // exact canonical re-encoding above
	}
	switch v.Kind() {
	case reflect.Pointer, reflect.Interface:
		if v.IsNil() {
			return errors.New("nil proof value")
		}
		return s.validate(v.Elem())
	case reflect.Struct:
		for i := 0; i < v.NumField(); i++ {
			if e := s.validate(v.Field(i)); e != nil {
				return e
			}
		}
	case reflect.Slice, reflect.Array:
		for i := 0; i < v.Len(); i++ {
			if e := s.validate(v.Index(i)); e != nil {
				return e
			}
		}
	default:
		return fmt.Errorf("unexpected proof value %s", v.Kind())
	}
	return nil
}
func verifyProof(s *suite, ctx string, v proof.Verifier, b []byte) error {
	if len(b) == 0 || len(b) > maxProofBytes {
		return errors.New("proof size")
	}
	s.readBytes = 0
	if e := proof.HashVerify(s, ctx, v, b); e != nil {
		return e
	}
	if s.readBytes != len(b) {
		return errors.New("trailing proof bytes")
	}
	return nil
}
