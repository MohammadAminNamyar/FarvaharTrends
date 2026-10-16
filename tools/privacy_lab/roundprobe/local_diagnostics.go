package main

// Private laboratory observations. These must never be returned on peer RPCs:
// queue-dependent work and storage timings can identify the publishing client.
import (
	"os"
	"time"
)

const localOperationLimit = 16

// Caller holds n.mu. Peer callers retain their existing redaction policy.
func (n *roleNode) statsLocked() rpcResponse {
	pending := 0
	if n.pending != nil {
		for _, x := range n.pending.inputs {
			pending += len(x.body) + len(x.signature)
		}
	}
	r := rpcResponse{CPUms: ms(cpuTime()), CacheEntries: len(n.cache), PendingInputBytes: pending, Role: n.config.Role, Index: n.config.Index}
	if n.journal != nil {
		r.JournalCommits, r.JournalPlaintextBytes = n.journal.commits, n.journal.plaintextBytes
		pending, commit := n.journal.pendingTiming, n.journal.commitTiming
		r.JournalPendingTiming, r.JournalCommitTiming = &pending, &commit
		pe, pw, se, sw := n.journal.pendingEncodeTiming, n.journal.pendingWriteTiming, n.journal.stateEncodeTiming, n.journal.stateWriteTiming
		r.JournalPendingEncodeTiming, r.JournalPendingWriteTiming = &pe, &pw
		r.JournalStateEncodeTiming, r.JournalStateWriteTiming = &se, &sw
		if info, e := os.Stat(n.journal.db.Path()); e == nil {
			r.JournalFileBytes = info.Size()
		}
	}
	return r
}

type localOperationTiming struct {
	Operation                       string
	Sequence                        uint64
	Phase                           uint8
	LockWaitMs, TotalMs             float64
	ProcessCPUms                    float64
	PendingEncodeMs, PendingWriteMs float64
	StateEncodeMs, StateWriteMs     float64
	JournalCommits                  uint64
	CheckpointPlaintextBytes        uint64
	DatabaseWriteMs                 float64
	DatabaseSpillMs                 float64
	DatabaseRebalanceMs             float64
	DatabaseAllocatedBytes          int64
	DatabaseAllocatedPages          int64
	Rejected                        bool
}

type localDiagnosticReport struct {
	Scope      string
	Stats      rpcResponse
	Operations []localOperationTiming
}

func (n *roleNode) privateDiagnostics() localDiagnosticReport {
	n.mu.Lock()
	defer n.mu.Unlock()
	return localDiagnosticReport{
		Scope:      "private parent/child laboratory pipe; operation CPU is whole-process delta and may include concurrent local work; bbolt WriteMs covers successful page/meta writes plus sync, excludes file-growth sync and is not fsync-only; allocated bytes are transaction allocations, not disk-file growth; not peer telemetry or phone energy",
		Stats:      n.statsLocked(),
		Operations: append([]localOperationTiming(nil), n.localOperations...),
	}
}

func (n *roleNode) observeOperation(q rpcRequest, started, locked time.Time, cpuStarted time.Duration, before journalObservation, rejected bool) {
	if q.Op == "stats" {
		return
	}
	// A fixed-size ring retains only phase/timing metadata, never messages,
	// signatures, keys, request hashes or arbitrary attacker-supplied op names.
	op := "other"
	switch q.Op {
	case "prepare", "accept", "accept-and-prepare", "commit", "release", "finish", "schedule-install", "schedule-vote":
		op = q.Op
	}
	after := observeJournal(n.journal)
	r := localOperationTiming{
		Operation: op, Sequence: q.Descriptor.Sequence, Phase: q.Descriptor.Phase,
		LockWaitMs: ms(locked.Sub(started)), TotalMs: ms(time.Since(started)),
		ProcessCPUms:    ms(cpuTime() - cpuStarted),
		PendingEncodeMs: after.pendingEncode - before.pendingEncode,
		PendingWriteMs:  after.pendingWrite - before.pendingWrite,
		StateEncodeMs:   after.stateEncode - before.stateEncode,
		StateWriteMs:    after.stateWrite - before.stateWrite,
		JournalCommits:  after.commits - before.commits, Rejected: rejected,
		CheckpointPlaintextBytes: after.plaintextBytes - before.plaintextBytes,
		DatabaseWriteMs:          after.databaseWrite - before.databaseWrite,
		DatabaseSpillMs:          after.databaseSpill - before.databaseSpill,
		DatabaseRebalanceMs:      after.databaseRebalance - before.databaseRebalance,
		DatabaseAllocatedBytes:   after.databaseAllocatedBytes - before.databaseAllocatedBytes,
		DatabaseAllocatedPages:   after.databaseAllocatedPages - before.databaseAllocatedPages,
	}
	if len(n.localOperations) == localOperationLimit {
		copy(n.localOperations, n.localOperations[1:])
		n.localOperations = n.localOperations[:localOperationLimit-1]
	}
	n.localOperations = append(n.localOperations, r)
}

type journalObservation struct {
	pendingEncode, pendingWrite, stateEncode, stateWrite float64
	commits                                              uint64
	plaintextBytes                                       uint64
	databaseWrite, databaseSpill, databaseRebalance      float64
	databaseAllocatedBytes, databaseAllocatedPages       int64
}

func observeJournal(j *roleJournal) journalObservation {
	if j == nil {
		return journalObservation{}
	}
	stats := j.db.Stats()
	return journalObservation{
		pendingEncode: j.pendingEncodeTiming.TotalMs, pendingWrite: j.pendingWriteTiming.TotalMs,
		stateEncode: j.stateEncodeTiming.TotalMs, stateWrite: j.stateWriteTiming.TotalMs,
		commits: j.commits, plaintextBytes: j.plaintextBytes,
		databaseWrite: ms(stats.TxStats.GetWriteTime()), databaseSpill: ms(stats.TxStats.GetSpillTime()),
		databaseRebalance:      ms(stats.TxStats.GetRebalanceTime()),
		databaseAllocatedBytes: stats.TxStats.GetPageAlloc(), databaseAllocatedPages: stats.TxStats.GetPageCount(),
	}
}
