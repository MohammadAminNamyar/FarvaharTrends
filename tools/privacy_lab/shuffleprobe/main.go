// Feasibility probe of an established verifiable shuffle implementation.
// Not a deployed protocol: centralized key, local challenge exchange, no DKG,
// no threshold decryption, no radio, no membership or anonymity claim.
package main

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"os"
	"runtime"
	"sort"
	"time"

	"go.dedis.ch/kyber/v4"
	"go.dedis.ch/kyber/v4/group/edwards25519"
	"go.dedis.ch/kyber/v4/proof"
	"go.dedis.ch/kyber/v4/shuffle"
)

const context = "farvahartrends/shuffle-component-lab/v1"

func must(e error) {
	if e != nil {
		panic(e)
	}
}
func ms(t time.Duration) float64 { return float64(t) / float64(time.Millisecond) }

type matrix [][]kyber.Point
type fixture struct {
	suite    *edwards25519.SuiteEd25519
	key      kyber.Scalar
	pub      kyber.Point
	x, y     matrix
	messages [][]byte
}

func newFixture(count, size int) *fixture {
	s := edwards25519.NewBlakeSHA256Ed25519()
	f := &fixture{suite: s, key: s.Scalar().Pick(s.RandomStream())}
	f.pub = s.Point().Mul(f.key, nil)
	chunks := (size + s.Point().EmbedLen() - 1) / s.Point().EmbedLen()
	f.x = make(matrix, chunks)
	f.y = make(matrix, chunks)
	for j := 0; j < chunks; j++ {
		f.x[j] = make([]kyber.Point, count)
		f.y[j] = make([]kyber.Point, count)
	}
	for i := 0; i < count; i++ {
		message := make([]byte, size)
		_, e := rand.Read(message)
		must(e)
		f.messages = append(f.messages, message)
		for j := 0; j < chunks; j++ {
			begin := j * s.Point().EmbedLen()
			end := min(size, begin+s.Point().EmbedLen())
			m := s.Point().Embed(message[begin:end], s.RandomStream())
			ephemeral := s.Scalar().Pick(s.RandomStream())
			f.x[j][i] = s.Point().Mul(ephemeral, nil)
			f.y[j][i] = s.Point().Add(m, s.Point().Mul(ephemeral, f.pub))
		}
	}
	return f
}

type shuffled struct {
	x, y      matrix
	challenge []kyber.Scalar
	proof     []byte
}

func (f *fixture) mix(x, y matrix) (shuffled, float64, float64) {
	started := time.Now()
	xx, yy, get := shuffle.SequencesShuffle(f.suite, nil, f.pub, x, y, f.suite.RandomStream())
	// In this component benchmark the verifier samples only AFTER receiving
	// the whole output matrix. A future distributed protocol must enforce that
	// commitment and bind its membership/epoch/transcript before any release.
	e := make([]kyber.Scalar, len(x))
	for j := range e {
		e[j] = f.suite.Scalar().Pick(f.suite.RandomStream())
	}
	prover, err := get(e)
	must(err)
	p, err := proof.HashProve(f.suite, context, prover)
	must(err)
	creation := time.Since(started)
	output := shuffled{xx, yy, e, p}
	started = time.Now()
	must(f.verify(x, y, output, context))
	verified := time.Since(started)
	return output, ms(creation), ms(verified)
}
func (f *fixture) verify(x, y matrix, out shuffled, domain string) error {
	xu, yu, xd, yd := shuffle.GetSequenceVerifiable(f.suite, x, y, out.x, out.y, out.challenge)
	return proof.HashVerify(f.suite, domain, shuffle.Verifier(f.suite, nil, f.pub, xu, yu, xd, yd), out.proof)
}
func (f *fixture) decrypt(x, y matrix) error {
	expected := map[[32]byte]int{}
	for _, m := range f.messages {
		expected[sha256.Sum256(m)]++
	}
	for i := range x[0] {
		var message []byte
		for j := range x {
			point := f.suite.Point().Sub(y[j][i], f.suite.Point().Mul(f.key, x[j][i]))
			part, e := point.Data()
			if e != nil {
				return e
			}
			message = append(message, part...)
		}
		h := sha256.Sum256(message)
		if expected[h] < 1 {
			return fmt.Errorf("decrypted message absent or duplicated")
		}
		expected[h]--
	}
	for _, n := range expected {
		if n != 0 {
			return fmt.Errorf("message lost")
		}
	}
	return nil
}
func encodedBytes(x, y matrix) int {
	total := 0
	for j := range x {
		for i := range x[j] {
			a, e := x[j][i].MarshalBinary()
			must(e)
			b, e := y[j][i].MarshalBinary()
			must(e)
			total += len(a) + len(b)
		}
	}
	return total
}
func (f *fixture) attackChecks(x, y matrix, out shuffled) map[string]bool {
	// Mutating a ciphertext after the proof must invalidate it.
	badY := make(matrix, len(out.y))
	for j := range out.y {
		badY[j] = make([]kyber.Point, len(out.y[j]))
		for i := range out.y[j] {
			badY[j][i] = out.y[j][i].Clone()
		}
	}
	badY[0][0].Add(badY[0][0], f.suite.Point().Base())
	bad := out
	bad.y = badY
	valid := f.verify(x, y, out, context) == nil
	tamper := f.verify(x, y, bad, context) != nil
	replay := f.verify(x, y, out, context+"/different-epoch") != nil
	// Replacement before a new proof is possible only if admission accepts a
	// different input set. This probe DOES NOT implement accountable admission.
	return map[string]bool{"validProofAccepted": valid, "changedCiphertextRejected": tamper, "differentContextRejected": replay}
}
func stats(x []float64) map[string]float64 {
	if len(x) == 0 {
		panic("empty measurement")
	}
	y := append([]float64{}, x...)
	sort.Float64s(y)
	q := func(p float64) float64 { return y[max(0, int(math.Ceil(p*float64(len(y))))-1)] }
	return map[string]float64{"p50Ms": q(.5), "p95Ms": q(.95), "p99Ms": q(.99), "maxMs": y[len(y)-1]}
}
func main() {
	count := flag.Int("cohort", 8, "simulated clients")
	size := flag.Int("payload", 4096, "fixed padded bytes per client")
	hops := flag.Int("hops", 3, "sequential verifiable shuffles")
	samples := flag.Int("samples", 10, "measured batches after one warmup")
	flag.Parse()
	if *count < 2 || *count > 16 || *size < 32 || *size > 8192 || *hops < 1 || *hops > 3 || *samples < 1 || *samples > 50 {
		panic("invalid workload")
	}
	rows := []map[string]interface{}{}
	totals := []float64{}
	var checks map[string]bool
	for sample := -1; sample < *samples; sample++ {
		cpu := cpuTime()
		started := time.Now()
		f := newFixture(*count, *size)
		created := time.Now()
		x, y := f.x, f.y
		stages := []map[string]interface{}{}
		proofBytes := 0
		for hop := 0; hop < *hops; hop++ {
			out, makeMs, checkMs := f.mix(x, y)
			if sample == -1 && hop == 0 {
				checks = f.attackChecks(x, y, out)
			}
			stages = append(stages, map[string]interface{}{"hop": hop, "shuffleAndProveMs": makeMs, "verifyMs": checkMs, "proofBytes": len(out.proof)})
			proofBytes += len(out.proof)
			x, y = out.x, out.y
		}
		decryptStart := time.Now()
		must(f.decrypt(x, y))
		finished := time.Now()
		cpuMs := ms(cpuTime() - cpu)
		if sample >= 0 {
			elapsed := ms(finished.Sub(started))
			totals = append(totals, elapsed)
			rows = append(rows, map[string]interface{}{"sample": sample, "createAllInputsMs": ms(created.Sub(started)), "stages": stages,
				"centralizedDecryptAndCheckMs": ms(finished.Sub(decryptStart)), "totalMs": elapsed, "processCpuMs": cpuMs,
				"ciphertextBatchBytes": encodedBytes(x, y), "allShuffleProofBytes": proofBytes})
		}
	}
	for name, ok := range checks {
		if !ok {
			panic("component check failed: " + name)
		}
	}
	output := map[string]interface{}{"schema": 1, "component": "dedis kyber v4.0.2 Neff sequence shuffle feasibility",
		"scope":  "all simulated clients and mix roles sequentially in one process; NOT an application, mixnet or battery result",
		"cohort": *count, "payloadBytesPerClient": *size, "hops": *hops, "samples": *samples, "warmupBatches": 1,
		"runtime": runtime.Version(), "os": runtime.GOOS, "arch": runtime.GOARCH, "gomaxprocs": runtime.GOMAXPROCS(0),
		"componentChecks": checks, "rows": rows, "allRolesComputation": stats(totals), "productionIntegrationAllowed": false,
		"missing": []string{"authenticated common admission", "Sybil-resistant membership", "distributed key generation", "threshold decryption and proofs", "network and coordination", "slot wait", "phone churn", "continuous covers", "battery", "security review"}}
	data, e := json.MarshalIndent(output, "", "  ")
	must(e)
	fmt.Fprintln(os.Stdout, string(bytes.TrimSpace(data)))
}
