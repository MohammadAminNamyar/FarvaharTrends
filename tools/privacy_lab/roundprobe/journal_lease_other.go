//go:build !android

package main

// On the currently tested Windows host, bbolt itself holds the required
// per-handle exclusive lock. Other host platforms require their own checks.
func acquireJournalLease(string) (func() error, error) {
	return func() error { return nil }, nil
}
