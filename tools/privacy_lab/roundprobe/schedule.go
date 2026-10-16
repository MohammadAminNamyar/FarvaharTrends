package main

// Experimental common cutoff, not a clock-synchronization protocol. Every role
// must independently have a clock within the declared bound. Signatures agree
// on a schedule; they do not prove the accuracy of a phone's clock.
import (
	"bytes"
	"crypto/ed25519"
	"errors"
	"math"
	"time"
)

const schedulePeriod = 2 * time.Second
const scheduleSkew = 100 * time.Millisecond
const scheduleMaxRounds = 1800
const frozenCompletionSlack = 2 * time.Second

type reservationSchedule struct {
	Epoch                [32]byte
	StartUnixNano        int64
	PeriodNano, SkewNano int64
	Rounds               uint64
	CompletionSlackNano  int64 `json:",omitempty"`
}
type scheduleCertificate struct {
	Proposal   reservationSchedule
	Signatures [][]byte
}
type scheduleState struct {
	Voted       *reservationSchedule `json:",omitempty"`
	Certificate *scheduleCertificate `json:",omitempty"`
}
type publicationEligibility struct {
	ScheduleHash [32]byte
	Round        uint64
}
type clockReading struct {
	wall int64
	mono time.Duration
}
type scheduleClock struct {
	anchor clockReading
	fenced bool
}

var scheduleProcessOrigin = time.Now()

func readScheduleClock() clockReading {
	now := time.Now()
	return clockReading{now.UnixNano(), now.Sub(scheduleProcessOrigin)}
}
func (n *roleNode) clockNow() clockReading {
	if n.localNow != nil {
		return n.localNow()
	}
	return readScheduleClock()
}
func (p reservationSchedule) valid(f *fixture) error {
	if f == nil || p.Epoch != f.epoch || p.Epoch == [32]byte{} ||
		p.PeriodNano != int64(schedulePeriod) || p.SkewNano != int64(scheduleSkew) ||
		p.Rounds == 0 || p.Rounds > scheduleMaxRounds || p.StartUnixNano <= 0 ||
		(p.CompletionSlackNano != 0 && p.CompletionSlackNano != int64(frozenCompletionSlack)) ||
		p.StartUnixNano > math.MaxInt64-int64(p.Rounds)*p.PeriodNano-p.SkewNano-p.CompletionSlackNano {
		return errors.New("invalid common reservation schedule")
	}
	return nil
}
func (p reservationSchedule) signed(f *fixture) []byte {
	domain := "FarvaharTrends/common-reservation-schedule/v1\x00"
	if p.CompletionSlackNano != 0 {
		domain = "FarvaharTrends/common-reservation-schedule/v2\x00"
	}
	b := bytes.NewBufferString(domain)
	b.Write(p.Epoch[:])
	for _, k := range f.clientKeys {
		b.Write(k.pub)
	}
	for _, k := range f.serverKeys {
		b.Write(k.pub)
	}
	for _, k := range f.slotKeys {
		b.Write(k.pub)
	}
	put64(b, uint64(f.slotLimit))
	put64(b, uint64(p.StartUnixNano))
	put64(b, uint64(p.PeriodNano))
	put64(b, uint64(p.SkewNano))
	put64(b, p.Rounds)
	if p.CompletionSlackNano != 0 {
		put64(b, uint64(p.CompletionSlackNano))
	}
	return b.Bytes()
}
func (c scheduleCertificate) verify(f *fixture) error {
	if e := c.Proposal.valid(f); e != nil {
		return e
	}
	if len(c.Signatures) != coordinators {
		return errors.New("incomplete schedule certificate")
	}
	signed := c.Proposal.signed(f)
	for i, s := range c.Signatures {
		if !ed25519.Verify(f.serverKeys[i].pub, signed, s) {
			return errors.New("invalid schedule signature")
		}
	}
	return nil
}
func validScheduleConfig(c nodeConfig) bool {
	if c.FrozenCompletion && !c.RequireCommonSchedule {
		return false
	}
	return !c.RequireCommonSchedule || (c.Durable && !c.AllowFaultInjection &&
		(c.Role == "coordinator" || c.Role == "client" && c.RoleLocalOutbox))
}
func (n *roleNode) matchesCompletionPolicy(p reservationSchedule) error {
	want := int64(0)
	if n.config.FrozenCompletion {
		want = int64(frozenCompletionSlack)
	}
	if p.CompletionSlackNano != want {
		return errors.New("schedule completion policy differs from explicit local configuration")
	}
	return nil
}
func (n *roleNode) scheduleCall(q rpcRequest) (rpcResponse, error) {
	if !n.config.RequireCommonSchedule || n.state == nil {
		return rpcResponse{}, errors.New("common schedule unavailable before setup")
	}
	f := n.state
	if q.Op == "schedule-vote" {
		if n.config.Role != "coordinator" || q.Schedule == nil || f.expected.sequence != 0 {
			return rpcResponse{}, errors.New("schedule vote unavailable")
		}
		p := *q.Schedule
		if e := p.valid(f); e != nil {
			return rpcResponse{}, e
		}
		if e := n.matchesCompletionPolicy(p); e != nil {
			return rpcResponse{}, e
		}
		if n.schedule != nil && n.schedule.Voted != nil {
			if *n.schedule.Voted != p {
				return rpcResponse{}, errors.New("schedule equivocation rejected")
			}
		} else {
			now := n.clockNow()
			lead := p.StartUnixNano - now.wall
			if now.wall <= 0 || lead < int64(time.Second) || lead > int64(30*time.Second) {
				return rpcResponse{}, errors.New("schedule is not within local admission window")
			}
			if n.schedule == nil {
				n.schedule = &scheduleState{}
			}
			n.schedule.Voted = &p
		}
		return rpcResponse{Signature: ed25519.Sign(f.serverKeys[n.config.Index].private, p.signed(f))}, nil
	}
	if q.Op != "schedule-install" || q.ScheduleCertificate == nil {
		return rpcResponse{}, errors.New("invalid schedule operation")
	}
	c := q.ScheduleCertificate
	if e := c.verify(f); e != nil {
		return rpcResponse{}, e
	}
	if e := n.matchesCompletionPolicy(c.Proposal); e != nil {
		return rpcResponse{}, e
	}
	if n.schedule != nil && n.schedule.Certificate != nil {
		if n.schedule.Certificate.Proposal != c.Proposal {
			return rpcResponse{}, errors.New("schedule replacement rejected")
		}
		// Replays cannot re-arm a restarted/fenced clock.
		return rpcResponse{}, nil
	}
	if f.expected.sequence != 0 {
		return rpcResponse{}, errors.New("schedule installed after round start")
	}
	if n.config.Role == "coordinator" && (n.schedule == nil || n.schedule.Voted == nil || *n.schedule.Voted != c.Proposal) {
		return rpcResponse{}, errors.New("schedule differs from local durable vote")
	}
	now := n.clockNow()
	lead := c.Proposal.StartUnixNano - now.wall
	if now.wall <= 0 || lead < int64(scheduleSkew) || lead > int64(30*time.Second) {
		return rpcResponse{}, errors.New("schedule installation outside admission window")
	}
	copy := jsonCopy(*c)
	if n.schedule == nil {
		n.schedule = &scheduleState{}
	}
	n.schedule.Certificate = &copy
	if !n.restored {
		n.scheduleClock = &scheduleClock{anchor: now}
	}
	return rpcResponse{}, nil
}

// A live monotonic anchor is intentionally never serialized. On process/device
// restart, cached exact replies and already pinned output receipts remain usable,
// but fresh submissions/preparations require a new admitted epoch. No wall-clock
// guess silently re-arms publication. Safe epoch/queue migration is still open.
func (n *roleNode) scheduleNow() (reservationSchedule, int64, error) {
	if n.schedule == nil || n.schedule.Certificate == nil || n.scheduleClock == nil || n.scheduleClock.fenced {
		return reservationSchedule{}, 0, errors.New("local schedule clock unavailable; retain queue without fallback")
	}
	p, g := n.schedule.Certificate.Proposal, n.scheduleClock
	now := n.clockNow()
	elapsed := now.mono - g.anchor.mono
	lifetime := time.Duration(p.Rounds)*schedulePeriod + 30*time.Second
	if now.wall <= 0 || elapsed < 0 || elapsed > lifetime {
		g.fenced = true
		return p, 0, errors.New("local schedule clock expired or moved backwards")
	}
	estimate := g.anchor.wall + int64(elapsed)
	difference := now.wall - estimate
	if difference < -p.SkewNano/2 || difference > p.SkewNano/2 {
		g.fenced = true
		return p, 0, errors.New("clock discontinuity; new epoch required")
	}
	return p, estimate, nil
}
func (n *roleNode) scheduleAllows(op string, d descriptor) error {
	p, now, e := n.scheduleNow()
	if e != nil {
		return e
	}
	round := d.sequence / 2
	if d.epoch != p.Epoch || round >= p.Rounds {
		return errors.New("round outside schedule")
	}
	cutoff := p.StartUnixNano + int64(round)*p.PeriodNano
	completionSlack := int64(0)
	if n.config.FrozenCompletion && p.CompletionSlackNano == int64(frozenCompletionSlack) {
		if n.config.Role == "coordinator" && op == "commit" {
			// commit still authenticates ALL fixed members' contributions and
			// the exact expected descriptor before making a signed commitment.
			// Honest members never create a new reservation after its cutoff.
			completionSlack = p.CompletionSlackNano
		} else if n.config.Role == "client" && n.outbox != nil &&
			n.outbox.SelectionMade && n.outbox.SelectionRound == round {
			// These operations cannot select from the current queue: bulk uses
			// its immutable pin, and fused acceptance verifies the unanimous
			// reservation output before deriving that same bulk descriptor.
			if op == "prepare" && d.phase == 1 && n.state.clientNext[n.config.Index] == d.sequence ||
				op == "accept-and-prepare" && d.phase == 0 && n.state.clientNext[n.config.Index] == d.sequence+1 {
				completionSlack = p.CompletionSlackNano
			}
		}
	}
	// The lower bound must have reached cutoff and the upper bound must still
	// precede the admitted phase boundary. Fresh reservation selection always
	// retains the original boundary; the optional slack is never applied to it.
	if now-p.SkewNano < cutoff || now+p.SkewNano >= cutoff+p.PeriodNano+completionSlack {
		return errors.New("prepare/commit outside local common round window")
	}
	return nil
}
func (n *roleNode) localEligibility() (*publicationEligibility, error) {
	if !n.config.RequireCommonSchedule {
		return nil, nil
	}
	p, now, e := n.scheduleNow()
	if e != nil {
		return nil, e
	}
	upper := now + p.SkewNano
	var round uint64
	if upper >= p.StartUnixNano {
		round = uint64((upper-p.StartUnixNano)/p.PeriodNano) + 1
	}
	if round >= p.Rounds {
		return nil, errors.New("schedule expired; submission not acknowledged")
	}
	return &publicationEligibility{hash(p.signed(n.state)), round}, nil
}
func (n *roleNode) validEligibility(p *publicationEligibility) bool {
	if !n.config.RequireCommonSchedule {
		return p == nil
	}
	return p != nil && n.schedule != nil && n.schedule.Certificate != nil &&
		p.Round < n.schedule.Certificate.Proposal.Rounds && p.ScheduleHash == hash(n.schedule.Certificate.Proposal.signed(n.state))
}
func (n *roleNode) restoreSchedule(s *scheduleState) error {
	if !validScheduleConfig(n.config) {
		return errors.New("invalid scheduled role configuration")
	}
	if !n.config.RequireCommonSchedule {
		if s != nil {
			return errors.New("unexpected saved schedule")
		}
		return nil
	}
	if s != nil {
		if n.state == nil || s.Voted == nil && s.Certificate == nil {
			return errors.New("invalid saved schedule state")
		}
		if s.Voted != nil {
			if n.config.Role != "coordinator" {
				return errors.New("client has coordinator schedule vote")
			}
			if e := s.Voted.valid(n.state); e != nil {
				return e
			}
			if e := n.matchesCompletionPolicy(*s.Voted); e != nil {
				return e
			}
		}
		if s.Certificate != nil {
			if e := s.Certificate.verify(n.state); e != nil {
				return e
			}
			if e := n.matchesCompletionPolicy(s.Certificate.Proposal); e != nil {
				return e
			}
			if n.config.Role == "coordinator" && (s.Voted == nil || *s.Voted != s.Certificate.Proposal) {
				return errors.New("saved certificate/vote mismatch")
			}
		}
	}
	n.schedule = s
	if n.state != nil && (s == nil || s.Certificate == nil) {
		used := n.state.expected.sequence != 0 || n.prepared != nil || n.pending != nil
		for _, next := range n.state.clientNext {
			used = used || next != 0
		}
		for _, server := range n.state.servers {
			used = used || server.next != 0 || server.committed
		}
		if used {
			return errors.New("scheduled round without certificate")
		}
	}
	if n.outbox != nil {
		for _, p := range n.outbox.Pending {
			if !n.validEligibility(p.Eligibility) {
				return errors.New("saved queue eligibility mismatch")
			}
		}
		if n.outbox.Pinned != 0 && n.outbox.Pending[0].Eligibility.Round > n.outbox.SelectionRound {
			return errors.New("pinned publication before its local eligibility")
		}
	}
	return nil
}
