package main

import (
	"bytes"
	"crypto/ed25519"
	"testing"
)

// The finish optimization must return a root only after the complete input,
// vote and share checks succeed. A partly validated root must not be signed.
func TestCombineReturnsOnlyFullyAuthenticatedRoot(t *testing.T) {
	for _, attack := range []string{
		"none", "input-signature", "input-body", "input-equivocation",
		"missing-input", "duplicate-input", "missing-vote", "duplicate-vote",
		"vote-signature", "round-key-commitment", "missing-share", "duplicate-share",
		"share-signature", "share-root", "share-equivocation",
	} {
		t.Run(attack, func(t *testing.T) {
			f := newFixture()
			d := f.reservation(0)
			xs := inputsFor(t, f, d, 0, []byte{1})
			vs := votesFor(t, f, d, xs)
			ss := sharesFor(t, f, d, vs)
			wantRoot, e := f.validate(d, xs)
			if e != nil {
				t.Fatal(e)
			}
			switch attack {
			case "input-signature":
				xs[0].signature[0] ^= 1
			case "input-body":
				xs[0].body[0] ^= 1
			case "input-equivocation":
				xs[0].body[0] ^= 1
				xs[0].signature = ed25519.Sign(f.clientKeys[0].private, xs[0].signed(d))
			case "missing-input":
				xs = xs[:len(xs)-1]
			case "duplicate-input":
				xs[1] = xs[0]
			case "missing-vote":
				vs = vs[:len(vs)-1]
			case "duplicate-vote":
				vs[1] = vs[0]
			case "vote-signature":
				vs[0].signature[0] ^= 1
			case "round-key-commitment":
				vs[0].keyHashes[0][0] ^= 1
				vs[0].signature = ed25519.Sign(f.serverKeys[0].private, vs[0].signed(d))
			case "missing-share":
				ss = ss[:len(ss)-1]
			case "duplicate-share":
				ss[1] = ss[0]
			case "share-signature":
				ss[0].signature[0] ^= 1
			case "share-root":
				ss[0].root[0] ^= 1
				ss[0].signature = ed25519.Sign(f.serverKeys[0].private, ss[0].signed(d))
			case "share-equivocation":
				ss[0].body[0] ^= 1
				ss[0].signature = ed25519.Sign(f.serverKeys[0].private, ss[0].signed(d))
			}
			body, root, e := f.combineWithRoot(d, xs, ss, vs)
			if attack != "none" {
				if e == nil || body != nil || root != [32]byte{} {
					t.Fatal("invalid batch exposed a signable result", e)
				}
				return
			}
			if e != nil || root != wantRoot {
				t.Fatal("authenticated root changed", e)
			}
			messages, e := f.decode(d, body)
			if e != nil || len(messages) != 1 || !bytes.Equal(messages[f.ownerSlot[0]], []byte{1}) {
				t.Fatal("output changed", e)
			}
		})
	}
}
