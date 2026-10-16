package main

// Transactional local crash recovery for the isolated protocol. The laboratory
// key file is NOT Android Keystore or rollback-resistant storage. An attacker
// able to copy/roll back the entire directory is outside this crash-only claim.
import (
	"bytes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	bolt "go.etcd.io/bbolt"
	"golang.org/x/crypto/chacha20poly1305"
)

const maxCheckpointBytes = 8 << 20
const maxJournalBytes = 64 << 20
const maxInterruptedAttempts = 3

var journalBucket = []byte("sealed-role-v1")

type pendingOperation struct {
	Eligibility *publicationEligibility `json:",omitempty"`
	Request     rpcRequest
	Attempts    int
	Local       *localSubmission `json:",omitempty"`
}
type journalTiming struct {
	Count          uint64
	TotalMs, MaxMs float64
}

func (s *journalTiming) observe(started time.Time) {
	elapsed := ms(time.Since(started))
	s.Count++
	s.TotalMs += elapsed
	s.MaxMs = max(s.MaxMs, elapsed)
}

type roleJournal struct {
	db                  *bolt.DB
	aead                cipher.AEAD
	configHash          [32]byte
	poisoned            bool
	commits             uint64
	plaintextBytes      uint64
	releaseLease        func() error
	closeOnce           sync.Once
	closeErr            error
	pendingTiming       journalTiming
	commitTiming        journalTiming
	pendingEncodeTiming journalTiming
	pendingWriteTiming  journalTiming
	stateEncodeTiming   journalTiming
	stateWriteTiming    journalTiming
	// Laboratory crash injection hooks; never exposed as RPC input.
	afterBegin, afterExecute, afterCommit func()
}

func (j *roleJournal) close() error {
	j.closeOnce.Do(func() {
		j.closeErr = j.db.Close()
		if j.releaseLease != nil {
			j.closeErr = errors.Join(j.closeErr, j.releaseLease())
		}
	})
	return j.closeErr
}

func (j *roleJournal) aad(label string) []byte {
	return append(append([]byte("FarvaharTrends/private-role/v1/"+label+"/"), j.configHash[:]...), 0)
}
func (j *roleJournal) seal(label string, value []byte) ([]byte, error) {
	if len(value) > maxCheckpointBytes {
		return nil, errors.New("private checkpoint too large")
	}
	nonce := make([]byte, j.aead.NonceSize())
	if _, e := rand.Read(nonce); e != nil {
		return nil, e
	}
	return j.aead.Seal(nonce, nonce, value, j.aad(label)), nil
}
func (j *roleJournal) open(label string, value []byte) ([]byte, error) {
	if len(value) < j.aead.NonceSize()+j.aead.Overhead() || len(value) > maxCheckpointBytes+j.aead.NonceSize()+j.aead.Overhead() {
		return nil, errors.New("invalid encrypted checkpoint size")
	}
	return j.aead.Open(nil, value[:j.aead.NonceSize()], value[j.aead.NonceSize():], j.aad(label))
}
func (j *roleJournal) load(label string) ([]byte, error) {
	var encrypted []byte
	e := j.db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket(journalBucket)
		if b == nil {
			return errors.New("missing role checkpoint bucket")
		}
		value := b.Get([]byte(label))
		if len(value) > maxCheckpointBytes+j.aead.NonceSize()+j.aead.Overhead() {
			return errors.New("oversized encrypted checkpoint")
		}
		encrypted = bytes.Clone(value)
		return nil
	})
	if e != nil || encrypted == nil {
		return nil, e
	}
	return j.open(label, encrypted)
}
func (j *roleJournal) savePending(p pendingOperation) error {
	started := time.Now()
	defer j.pendingTiming.observe(started)
	b, e := json.Marshal(p)
	if e != nil {
		return e
	}
	length := len(b)
	sealed, e := j.seal("pending", b)
	clear(b)
	if e != nil {
		return e
	}
	j.pendingEncodeTiming.observe(started)
	writeStarted := time.Now()
	e = j.db.Update(func(tx *bolt.Tx) error { return tx.Bucket(journalBucket).Put([]byte("pending"), sealed) })
	j.pendingWriteTiming.observe(writeStarted)
	if e == nil {
		j.commits++
		j.plaintextBytes += uint64(length)
	}
	return e
}
func (j *roleJournal) commitState(n *roleNode) error {
	started := time.Now()
	defer j.commitTiming.observe(started)
	b, e := n.checkpoint()
	if e != nil {
		return e
	}
	length := len(b)
	sealed, e := j.seal("state", b)
	clear(b)
	if e != nil {
		return e
	}
	j.stateEncodeTiming.observe(started)
	writeStarted := time.Now()
	e = j.db.Update(func(tx *bolt.Tx) error {
		bucket, e := tx.CreateBucketIfNotExists(journalBucket)
		if e != nil {
			return e
		}
		if e = bucket.Put([]byte("state"), sealed); e != nil {
			return e
		}
		return bucket.Delete([]byte("pending"))
	})
	j.stateWriteTiming.observe(writeStarted)
	if e == nil {
		j.commits++
		j.plaintextBytes += uint64(length)
	}
	return e
}
func (j *roleJournal) fail(e error) error {
	j.poisoned = true
	return fmt.Errorf("durable role unavailable; no response released: %w", e)
}
func (j *roleJournal) execute(n *roleNode, q rpcRequest, digest [32]byte) (rpcResponse, error) {
	if j.poisoned {
		return rpcResponse{}, errors.New("durable role requires recovery")
	}
	if n.atomicPublicationOperation(q.Op) {
		// No reply escapes complete until the state and exact retry response
		// have committed together. Before that commit a crash leaves only the
		// previous state; there is deliberately no request to auto-reexecute.
		return j.complete(n, q, digest)
	}
	if e := j.savePending(pendingOperation{Request: q, Attempts: 1}); e != nil {
		return rpcResponse{}, j.fail(e)
	}
	if j.afterBegin != nil {
		j.afterBegin()
	}
	return j.complete(n, q, digest)
}
func (j *roleJournal) complete(n *roleNode, q rpcRequest, digest [32]byte) (rpcResponse, error) {
	r, resultErr := n.executeCached(q, digest)
	if j.afterExecute != nil {
		j.afterExecute()
	}
	// Error paths can consume a proof/disclosure budget. Persist them too.
	if e := j.commitState(n); e != nil {
		return rpcResponse{}, j.fail(e)
	}
	if j.afterCommit != nil {
		j.afterCommit()
	}
	return r, resultErr
}
func openDurableRole(c nodeConfig, directory string) (*roleNode, error) {
	newDirectory := false
	if e := os.Mkdir(directory, 0700); e == nil {
		newDirectory = true
	} else if !os.IsExist(e) {
		return nil, e
	}
	// Android's bbolt lock is process-associated. Hold an additional open-file
	// description lock so a second handle in this process cannot bypass it.
	releaseLease, e := acquireJournalLease(directory)
	if e != nil {
		return nil, e
	}
	keepLease := false
	defer func() {
		if !keepLease {
			_ = releaseLease()
		}
	}()
	keyPath, dbPath := filepath.Join(directory, "lab-storage.key"), filepath.Join(directory, "role.db")
	if newDirectory {
		key := make([]byte, 32)
		if _, e := rand.Read(key); e != nil {
			return nil, e
		}
		f, e := os.OpenFile(keyPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if e != nil {
			return nil, e
		}
		_, e = f.Write(key)
		clear(key)
		if e == nil {
			e = f.Sync()
		}
		ce := f.Close()
		if e != nil {
			return nil, e
		}
		if ce != nil {
			return nil, ce
		}
	} else if _, e := os.Stat(dbPath); e != nil {
		return nil, errors.New("missing durable state; refusing to reinitialize this session")
	}
	info, e := os.Stat(keyPath)
	if e != nil || info.Size() != 32 {
		return nil, errors.New("missing or invalid local storage key")
	}
	if !newDirectory {
		info, e = os.Stat(dbPath)
		if e != nil || info.Size() > maxJournalBytes {
			return nil, errors.New("missing or oversized state database")
		}
	}
	key, e := os.ReadFile(keyPath)
	if e != nil {
		return nil, e
	}
	aead, e := chacha20poly1305.NewX(key)
	clear(key)
	if e != nil {
		return nil, e
	}
	db, e := bolt.Open(dbPath, 0600, &bolt.Options{Timeout: time.Second, MaxSize: maxJournalBytes})
	if e != nil {
		return nil, e
	}
	b, e := json.Marshal(c)
	if e != nil {
		_ = db.Close()
		return nil, e
	}
	j := &roleJournal{db: db, aead: aead, configHash: hash(b), releaseLease: releaseLease}
	failed := true
	defer func() {
		if failed {
			_ = db.Close()
		}
	}()
	var n *roleNode
	if newDirectory {
		n, e = newRoleNode(c)
		if e != nil {
			return nil, e
		}
		if e = j.commitState(n); e != nil {
			return nil, e
		}
	} else {
		b, e := j.load("state")
		if e != nil {
			return nil, e
		}
		if b == nil {
			return nil, errors.New("missing initial checkpoint; refusing regeneration")
		}
		n, e = restoreRole(b)
		clear(b)
		if e != nil {
			return nil, e
		}
		if n.config.Role != c.Role || n.config.Index != c.Index {
			return nil, errors.New("restored role identity mismatch")
		}
	}
	n.journal = j
	b, e = j.load("pending")
	if e != nil {
		return nil, e
	}
	if b != nil {
		var p pendingOperation
		e = json.Unmarshal(b, &p)
		clear(b)
		if e != nil {
			return nil, e
		}
		if p.Attempts < 1 || p.Attempts >= maxInterruptedAttempts {
			return nil, errors.New("interrupted-operation budget exhausted; session remains blocked")
		}
		p.Attempts++
		if (p.Local != nil) == (p.Request.Op != "") || p.Local == nil && p.Eligibility != nil {
			return nil, errors.New("ambiguous pending operation")
		}
		if e = j.savePending(p); e != nil {
			return nil, e
		}
		if p.Local != nil {
			_, _ = j.completeLocal(n, *p.Local, p.Eligibility)
		} else {
			encoded, e := json.Marshal(p.Request)
			if e != nil {
				return nil, e
			}
			_, _ = j.complete(n, p.Request, hash(encoded)) // A committed protocol rejection is a valid recovered state.
		}
		if j.poisoned {
			return nil, errors.New("failed to commit recovered operation")
		}
	}
	failed = false
	keepLease = true
	return n, nil
}
