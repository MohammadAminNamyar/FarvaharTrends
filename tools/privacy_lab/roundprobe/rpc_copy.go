package main

import "bytes"

// Preserve independent ownership without base64 encoding and decoding the
// complete encrypted batch merely to copy it. Every mutable byte slice, including
// nested commitments, must be copied; peer authentication still happens at each
// coordinator. This is not a validation or a shortcut around signatures.
func copyRPCInputs(xs []rpcInput) []rpcInput {
	if xs == nil {
		return nil
	}
	out := make([]rpcInput, len(xs))
	for i, x := range xs {
		out[i] = x
		out[i].Body = bytes.Clone(x.Body)
		out[i].Signature = bytes.Clone(x.Signature)
		if x.KeyHashes != nil {
			out[i].KeyHashes = make([][]byte, len(x.KeyHashes))
			for j, h := range x.KeyHashes {
				out[i].KeyHashes[j] = bytes.Clone(h)
			}
		}
	}
	return out
}
