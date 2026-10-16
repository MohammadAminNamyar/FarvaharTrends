package main

import (
	"bytes"
	"encoding/json"
	"testing"
)

func TestRPCInputCopyPreservesWireAndOwnsAllMutableBytes(t *testing.T) {
	// Include nil/empty fields and invalid field lengths: copying must preserve
	// these exactly so it cannot normalize malformed peer input into valid input.
	fixtures := [][]rpcInput{
		nil,
		{},
		{{Client: -1}, {Client: 12, Body: []byte{}, Signature: []byte{}, KeyHashes: [][]byte{nil, {}}}},
		{{Client: 0, Body: []byte{1, 2}, Signature: []byte{3, 4}, KeyHashes: [][]byte{{5, 6}, {7, 8}}}},
	}
	encode := func(xs []rpcInput) []byte {
		b, e := json.Marshal(xs)
		if e != nil {
			t.Fatal(e)
		}
		return b
	}
	mutate := func(xs []rpcInput) {
		for i := range xs {
			xs[i].Client++
			if len(xs[i].Body) > 0 {
				xs[i].Body[0] ^= 255
			}
			if len(xs[i].Signature) > 0 {
				xs[i].Signature[0] ^= 255
			}
			for j, h := range xs[i].KeyHashes {
				if len(h) > 0 {
					h[0] ^= 255
				}
				xs[i].KeyHashes[j] = []byte{99}
			}
		}
	}
	for i, original := range fixtures {
		before := encode(original)
		copy := copyRPCInputs(original)
		if !bytes.Equal(before, encode(copy)) {
			t.Fatalf("fixture %d changed its wire representation", i)
		}
		mutate(copy)
		if !bytes.Equal(before, encode(original)) {
			t.Fatalf("fixture %d copy mutation changed its source", i)
		}
		copy = copyRPCInputs(original)
		mutate(original)
		if !bytes.Equal(before, encode(copy)) {
			t.Fatalf("fixture %d source mutation changed its copy", i)
		}
	}
}
