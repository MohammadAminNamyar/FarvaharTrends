package main

import (
	"bytes"
	"crypto/ed25519"
	"testing"

	"go.dedis.ch/kyber/v4"
	"go.dedis.ch/kyber/v4/proof"
)

// Negative composition experiment: the original single-slot benchmark must NOT
// be reused across slots with one common server encryption key. A malicious
// owner knows its own pseudonym secret and can use that OR branch to submit a
// ciphertext borrowed from an honest client in another slot. The common key
// then turns the malicious owner's slot into a decryption oracle.
func TestSharedServerKeyAcrossSlotsExposesBorrowedClientCiphertext(t *testing.T) {
	f, victim, message, previous, _ := trial(t, 32)
	d := descriptor{f.epoch, 2, 1, 32}
	var inputs []contribution
	for i := range clients {
		c, e := f.create(d, i, nil)
		if e != nil {
			t.Fatal(e)
		}
		if i == d.Slot {
			c.R = previous[victim.Slot].R
			c.C = previous[victim.Slot].C
			p, pts, e := f.clientPredicate(d, c)
			if e != nil {
				t.Fatal(e)
			}
			c.Proof, e = proof.HashProve(f.s, clientContext(d, c), p.Prover(f.s, map[string]kyber.Scalar{"y": f.slots[d.Slot].private}, pts, map[proof.Predicate]int{p: 1}))
			if e != nil {
				t.Fatal(e)
			}
			c.Signature = ed25519.Sign(f.identities[i], clientSigned(d, c))
		}
		inputs = append(inputs, c)
	}
	var shares []share
	for s := range servers {
		v, e := f.release(d, s, inputs)
		if e != nil {
			t.Fatal(e)
		}
		shares = append(shares, v)
	}
	recovered, e := f.reveal(d, inputs, shares)
	if e != nil || !bytes.Equal(recovered, message) {
		t.Fatal("expected composition failure was not reproduced", e)
	}
}
