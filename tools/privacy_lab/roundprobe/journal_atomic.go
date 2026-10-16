package main

// Opt-in publication-only experiment. These operations have no external side
// effects inside execute: their only output is the value returned to complete,
// which persists the resulting state and exact reply before returning it. A
// failed commit poisons the live role, including its in-memory retry cache.
// A pre-commit crash can lose unacknowledged work, but cannot expose two versions
// of a contribution. Committed outbox items survive, and restart clock fences
// still prevent fresh scheduled publication. This is not rollback resistance.
//
// Setup, schedule admission, disclosure/control operations, local enqueue and
// unknown operations retain pending records and their interrupted-work budget.
// Do not extend this allowlist to operations with network/file side effects or
// externally observable proof work without a separate recovery argument.
func validPublicationStorageConfig(c nodeConfig) bool {
	return !c.AtomicPublication || c.Durable && !c.AllowFaultInjection
}

func (n *roleNode) atomicPublicationOperation(op string) bool {
	if !n.config.AtomicPublication || n.state == nil {
		return false
	}
	switch n.config.Role {
	case "client":
		return op == "prepare" || op == "accept" || op == "accept-and-prepare"
	case "coordinator":
		return op == "commit" || op == "release" || op == "finish"
	default:
		return false
	}
}
