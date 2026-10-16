package main

// Opt-in transport representation only. Signatures, transcript construction,
// JSON request-cache digests and encrypted checkpoint formats are unchanged.
// No compression dictionary, traffic-dependent negotiation or codec fallback.
import (
	"bytes"
	"encoding/json"
	"errors"
	"io"

	"github.com/fxamacker/cbor/v2"
)

const compactRPCContentType = "application/vnd.farvahar-lab.rpc+cbor;v=1"

var rpcCBOR = func() cbor.EncMode {
	opts := cbor.CoreDetEncOptions()
	opts.TagsMd = cbor.TagsForbidden
	m, e := opts.EncMode()
	must(e)
	return m
}()
var rpcCBORDecoder = func() cbor.DecMode {
	m, e := (cbor.DecOptions{
		DupMapKey:       cbor.DupMapKeyEnforcedAPF,
		MaxNestedLevels: 16, MaxArrayElements: 128, MaxMapPairs: 64,
		IndefLength: cbor.IndefLengthForbidden, TagsMd: cbor.TagsForbidden,
		ExtraReturnErrors: cbor.ExtraDecErrorUnknownField,
		UTF8:              cbor.UTF8RejectInvalid, FieldNameMatching: cbor.FieldNameMatchingCaseSensitive,
		NaN: cbor.NaNDecodeForbidden, Inf: cbor.InfDecodeForbidden,
	}).DecMode()
	must(e)
	return m
}()

func validWireCodec(codec string) bool {
	return codec == "" || codec == "json" || codec == "cbor-v1" || codec == "cbor-framed-v1"
}
func compactRPC(codec string) bool { return codec == "cbor-v1" || codec == "cbor-framed-v1" }
func rpcContentType(codec string) string {
	if compactRPC(codec) {
		return compactRPCContentType
	}
	return "application/json"
}
func encodeRPC(codec string, value any) ([]byte, error) {
	if !validWireCodec(codec) {
		return nil, errors.New("unsupported RPC codec")
	}
	var b []byte
	var e error
	if compactRPC(codec) {
		b, e = rpcCBOR.Marshal(value)
	} else {
		b, e = json.Marshal(value)
	}
	if e != nil {
		return nil, e
	}
	if len(b) == 0 || len(b) > maxRPCBytes {
		return nil, errors.New("RPC exceeds byte limit")
	}
	return b, nil
}
func decodeRPC(codec string, data []byte, target any) error {
	if !validWireCodec(codec) {
		return errors.New("unsupported RPC codec")
	}
	if len(data) == 0 || len(data) > maxRPCBytes {
		return errors.New("RPC exceeds byte limit")
	}
	if compactRPC(codec) {
		// RPCs must be a single definite map. Decode into a fresh object and
		// discard it on any error; the decoder may partially fill the target.
		if data[0]>>5 != 5 {
			return errors.New("RPC must be a map")
		}
		if e := rpcCBORDecoder.Unmarshal(data, target); e != nil {
			return e
		}
		canonical, e := rpcCBOR.Marshal(target)
		if e != nil || !bytes.Equal(canonical, data) {
			return errors.New("noncanonical compact RPC")
		}
		return nil
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if e := d.Decode(target); e != nil {
		return e
	}
	var extra any
	if d.Decode(&extra) != io.EOF {
		return errors.New("trailing RPC data")
	}
	return nil
}
