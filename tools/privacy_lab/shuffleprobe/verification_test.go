package main

import "testing"

func TestPayloadPermutationAndRejectedModifications(t *testing.T) {
	f := newFixture(4, 512)
	out, _, _ := f.mix(f.x, f.y)
	if e := f.decrypt(out.x, out.y); e != nil {
		t.Fatal(e)
	}
	for name, ok := range f.attackChecks(f.x, f.y, out) {
		if !ok {
			t.Fatal(name)
		}
	}
}
