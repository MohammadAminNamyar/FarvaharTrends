package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestLocalOutboxBoundsRetriesAndExpiredReceipts(t *testing.T) {
	o := &localOutbox{Next: 1}
	p := []byte("خبر فارسی")
	r, e := o.enqueue(localSubmission{1, p})
	if e != nil {
		t.Fatal(e)
	}
	p[0] ^= 1
	if hash(o.Pending[0].Payload) != r.Digest {
		t.Fatal("caller alias changed queued bytes")
	}
	_, e = o.enqueue(localSubmission{1, p})
	requireReject(t, e)
	_, e = o.enqueue(localSubmission{3, []byte("gap")})
	requireReject(t, e)
	for i := 2; i <= outboxMaxItems; i++ {
		if _, e = o.enqueue(localSubmission{uint64(i), []byte{1}}); e != nil {
			t.Fatal(e)
		}
	}
	_, e = o.enqueue(localSubmission{outboxMaxItems + 1, []byte{1}})
	requireReject(t, e)
	if o.Next != outboxMaxItems+1 {
		t.Fatal("full queue consumed sequence")
	}
	bytesBox := &localOutbox{Next: 1}
	body := bytes.Repeat([]byte{5}, maxCell-cellNonceSize-66)
	for i := uint64(1); i <= uint64(outboxMaxBytes/len(body)); i++ {
		if _, e = bytesBox.enqueue(localSubmission{i, body}); e != nil {
			t.Fatal(e)
		}
	}
	_, e = bytesBox.enqueue(localSubmission{bytesBox.Next, body})
	requireReject(t, e)
	if e = bytesBox.validate(); e != nil {
		t.Fatal(e)
	}
	receipts := &localOutbox{Next: 1}
	for i := uint64(1); i <= outboxReceiptLimit+2; i++ {
		body := []byte(fmt.Sprintf("خبر %d", i))
		_, e = receipts.enqueue(localSubmission{i, body})
		if e != nil {
			t.Fatal(e)
		}
		d := descriptor{epoch: hash([]byte("local-test")), sequence: 2 * (i - 1), phase: 0, slots: []int{0}, cell: reservationCell}
		if _, e = receipts.selectPayload(d, 0); e != nil {
			t.Fatal(e)
		}
		if e = receipts.accept(d, 0, map[int][]byte{0: {1}}, hash([]byte("reservation"))); e != nil {
			t.Fatal(e)
		}
		d.phase = 1
		d.sequence++
		d.cell = maxCell
		if _, e = receipts.selectPayload(d, 0); e != nil {
			t.Fatal(e)
		}
		if e = receipts.accept(d, 0, map[int][]byte{0: body}, hash(body)); e != nil {
			t.Fatal(e)
		}
	}
	if len(receipts.Released) != outboxReceiptLimit || len(receipts.Pending) != 0 {
		t.Fatal("unbounded receipts")
	}
	_, e = receipts.enqueue(localSubmission{1, []byte("خبر 1")})
	requireReject(t, e)
	if e = receipts.validate(); e != nil {
		t.Fatal(e)
	}
}

type outboxFixture struct {
	lab     *networkLab
	nodes   []*roleNode
	configs []nodeConfig
	dirs    []string
}

func newOutboxFixture(t *testing.T) *outboxFixture {
	return newOutboxFixtureWithSchedule(t, false)
}
func newOutboxFixtureWithSchedule(t *testing.T, scheduled bool) *outboxFixture {
	return newOutboxFixtureStorage(t, scheduled, false)
}
func newOutboxFixtureStorage(t *testing.T, scheduled, atomicPublication bool) *outboxFixture {
	return newOutboxFixtureCompletion(t, scheduled, atomicPublication, false)
}
func newOutboxFixtureCompletion(t *testing.T, scheduled, atomicPublication, frozen bool) *outboxFixture {
	t.Helper()
	root := t.TempDir() // Register removal before the journal-close cleanup (LIFO).
	f := &outboxFixture{lab: &networkLab{public: newFixtureWithLimit(clients)}}
	t.Cleanup(func() {
		for _, n := range f.nodes {
			_ = n.journal.close()
		}
	})
	for i := range clients + coordinators {
		role, index := "client", i
		if i >= clients {
			role, index = "coordinator", i-clients
		}
		c := configFor(f.lab.public, role, index)
		c.Durable = true
		c.AtomicPublication = atomicPublication
		c.RequireCommonSchedule = scheduled
		c.FrozenCompletion = frozen
		c.RoleLocalOutbox = role == "client"
		dir := filepath.Join(root, fmt.Sprintf("%s-%d", role, index))
		n, e := openDurableRole(c, dir)
		if e != nil {
			t.Fatal(e)
		}
		f.nodes = append(f.nodes, n)
		f.configs = append(f.configs, c)
		f.dirs = append(f.dirs, dir)
	}
	f.lab.componentCall = func(id int, q rpcRequest) (rpcResponse, error) {
		if len(q.Payload) != 0 {
			t.Fatal("plaintext queued content entered peer RPC")
		}
		return f.nodes[id].handle(q)
	}
	return f
}
func (f *outboxFixture) cycle(t *testing.T, round uint64) result {
	t.Helper()
	r, e := f.lab.run(f.lab.public.reservation(round), nil)
	if e != nil {
		t.Fatal(e)
	}
	if len(r.messages) == 0 {
		return r
	}
	b, e := f.lab.run(f.lab.public.bulk(round, r, maxCell), nil)
	if e != nil {
		t.Fatal(e)
	}
	return b
}

func TestLocalOutboxDoesNotExposePlaintextStatusOrMutatePinnedSelection(t *testing.T) {
	f := newOutboxFixture(t)
	before, e := f.nodes[0].handle(rpcRequest{Op: "stats"})
	if e != nil {
		t.Fatal(e)
	}
	a := []byte("خبر اول با متن فارسی بلند برای آزمایش صف خصوصی")
	if _, e = f.nodes[1].enqueueLocal(localSubmission{1, a}); e != nil {
		t.Fatal(e)
	}
	r, e := f.lab.run(f.lab.public.reservation(0), nil)
	if e != nil {
		t.Fatal(e)
	}
	// Arrival after reservation cannot create an unscheduled bulk publication.
	b := []byte("خبر دوم پس از رزرو رسید و باید تا دور بعد منتظر بماند")
	if _, e = f.nodes[0].enqueueLocal(localSubmission{1, b}); e != nil {
		t.Fatal(e)
	}
	after, e := f.nodes[0].handle(rpcRequest{Op: "stats"})
	if e != nil || !bytes.Equal(encodeSetup(before), encodeSetup(after)) {
		t.Fatal("peer stats exposed local activity", e)
	}
	_, e = f.nodes[0].handle(rpcRequest{Op: "prepare", Payload: b})
	requireReject(t, e)
	_, e = f.nodes[0].handle(rpcRequest{Op: "enqueue"})
	requireReject(t, e)
	_, e = f.nodes[clients].enqueueLocal(localSubmission{1, b})
	requireReject(t, e)
	out, e := f.lab.run(f.lab.public.bulk(0, r, maxCell), nil)
	if e != nil || !samePayloadMultiset(out, map[int][]byte{0: a}) {
		t.Fatal("wrong first release", e)
	}
	status, e := f.nodes[0].localStatus(1)
	if e != nil || status.Status != "queued" {
		t.Fatal("new arrival published without reservation", e)
	}
	out = f.cycle(t, 1)
	if !samePayloadMultiset(out, map[int][]byte{0: b}) {
		t.Fatal("queued message not released")
	}
	status, e = f.nodes[0].localStatus(1)
	if e != nil || status.Status != "released" {
		t.Fatal("missing local certificate receipt", e)
	}
	duplicate, e := f.nodes[0].enqueueLocal(localSubmission{1, b})
	if e != nil || duplicate != status {
		t.Fatal("lost enqueue reply caused duplicate publication", e)
	}
	if out = f.cycle(t, 2); len(out.messages) != 0 {
		t.Fatal("duplicate became fresh news")
	}
}

func TestLocalOutboxCommitFailureFencesAcknowledgementAndStatus(t *testing.T) {
	f := newOutboxFixture(t)
	n := f.nodes[0]
	n.journal.afterExecute = func() { _ = n.journal.db.Close() }
	r, e := n.enqueueLocal(localSubmission{1, []byte("ذخیره باید پیش از تأیید کامل شود")})
	requireReject(t, e)
	if r.Status != "" {
		t.Fatal("uncommitted enqueue acknowledged")
	}
	_, e = n.localStatus(1)
	requireReject(t, e)
	_, e = n.enqueueLocal(localSubmission{1, []byte("ذخیره باید پیش از تأیید کامل شود")})
	requireReject(t, e)
}

type outboxCrashCommand struct {
	Config                nodeConfig
	StateDirectory, Stage string
	Local                 *localSubmission
	Peer                  *rpcRequest
}

func TestOutboxCrashWorker(t *testing.T) {
	file := os.Getenv("FT_OUTBOX_CRASH_TEST")
	if file == "" {
		return
	}
	b, e := os.ReadFile(file)
	if e != nil {
		t.Fatal(e)
	}
	var q outboxCrashCommand
	if e = json.Unmarshal(b, &q); e != nil {
		t.Fatal(e)
	}
	n, e := openDurableRole(q.Config, q.StateDirectory)
	if e != nil {
		t.Fatal(e)
	}
	crash := func() { os.Exit(93) }
	switch q.Stage {
	case "begin":
		n.journal.afterBegin = crash
	case "execute":
		n.journal.afterExecute = crash
	case "commit":
		n.journal.afterCommit = crash
	default:
		t.Fatal("bad stage")
	}
	if q.Local != nil {
		_, e = n.enqueueLocal(*q.Local)
	} else if q.Peer != nil {
		_, e = n.handle(*q.Peer)
	} else {
		t.Fatal("missing operation")
	}
	t.Fatal("operation did not crash", e)
}
func runOutboxCrash(t *testing.T, q outboxCrashCommand) {
	t.Helper()
	file := filepath.Join(t.TempDir(), "operation.json")
	if e := saveJSON(file, q); e != nil {
		t.Fatal(e)
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestOutboxCrashWorker$")
	cmd.Env = append(os.Environ(), "FT_OUTBOX_CRASH_TEST="+file)
	output, e := cmd.CombinedOutput()
	if e == nil || cmd.ProcessState == nil || cmd.ProcessState.ExitCode() != 93 {
		t.Fatalf("outbox crash worker: %v %s", e, output)
	}
}
func TestLocalOutboxRecoversInterruptedEnqueueAtEveryCommitBoundary(t *testing.T) {
	for _, stage := range []string{"begin", "execute", "commit"} {
		t.Run(stage, func(t *testing.T) {
			c := configFor(newFixture(), "client", 0)
			c.Durable = true
			c.RoleLocalOutbox = true
			dir := filepath.Join(t.TempDir(), "state")
			q := localSubmission{1, []byte("خبر خصوصی پس از قطع فرایند باید در صف باقی بماند")}
			runOutboxCrash(t, outboxCrashCommand{Config: c, StateDirectory: dir, Stage: stage, Local: &q})
			n, e := openDurableRole(c, dir)
			if e != nil {
				t.Fatal(e)
			}
			defer n.journal.close()
			r, e := n.enqueueLocal(q)
			if e != nil || r.Status != "queued" || len(n.outbox.Pending) != 1 || n.outbox.Next != 2 {
				t.Fatal("enqueue not recovered exactly once", e)
			}
			stored, e := os.ReadFile(filepath.Join(dir, "role.db"))
			if e != nil {
				t.Fatal(e)
			}
			if bytes.Contains(stored, q.Payload) {
				t.Fatal("publication plaintext in database")
			}
		})
	}
}
func TestLocalOutboxRecoversCertifiedReleaseAtEveryCommitBoundary(t *testing.T) {
	for _, stage := range []string{"begin", "execute", "commit"} {
		t.Run(stage, func(t *testing.T) {
			f := newOutboxFixture(t)
			body := []byte("تأیید انتشار پس از راه‌اندازی دوباره باید تنها یک بار ثبت شود")
			if _, e := f.nodes[0].enqueueLocal(localSubmission{1, body}); e != nil {
				t.Fatal(e)
			}
			r, e := f.lab.run(f.lab.public.reservation(0), nil)
			if e != nil {
				t.Fatal(e)
			}
			var held rpcRequest
			f.lab.componentCall = func(id int, q rpcRequest) (rpcResponse, error) {
				if id == 0 && q.Op == "accept" && q.Descriptor.Phase == 1 {
					held = jsonCopy(q)
					return rpcResponse{}, errors.New("hold certified output before client acknowledgement")
				}
				return f.nodes[id].handle(q)
			}
			_, e = f.lab.run(f.lab.public.bulk(0, r, maxCell), nil)
			requireReject(t, e)
			if held.Op == "" {
				t.Fatal("no certified output captured")
			}
			if status, e := f.nodes[0].localStatus(1); e != nil || status.Status != "queued" {
				t.Fatal("unacknowledged output lost queued action", e)
			}
			_ = f.nodes[0].journal.close()
			runOutboxCrash(t, outboxCrashCommand{Config: f.configs[0], StateDirectory: f.dirs[0], Stage: stage, Peer: &held})
			f.nodes[0], e = openDurableRole(f.configs[0], f.dirs[0])
			if e != nil {
				t.Fatal(e)
			}
			if _, e = f.nodes[0].handle(held); e != nil {
				t.Fatal(e)
			}
			status, e := f.nodes[0].localStatus(1)
			if e != nil || status.Status != "released" || len(f.nodes[0].outbox.Pending) != 0 || len(f.nodes[0].outbox.Released) != 1 {
				t.Fatal("certified release not exactly once", e)
			}
			bad := held
			bad.Output = bytes.Clone(held.Output)
			bad.Output[0] ^= 1
			_, e = f.nodes[0].handle(bad)
			requireReject(t, e)
		})
	}
}
