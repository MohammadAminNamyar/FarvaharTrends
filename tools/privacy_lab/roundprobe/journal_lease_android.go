package main

import (
	"fmt"
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

// Unlike Android bbolt's F_SETLK lock, flock belongs to this open file
// description. Independent opens conflict even in one process. Kernel cleanup
// releases it on process death; never unlink the lock file (that permits two
// different inodes to represent the same session lock).
func acquireJournalLease(directory string) (func() error, error) {
	f, e := os.OpenFile(filepath.Join(directory, "session.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if e != nil {
		return nil, e
	}
	if e = unix.Flock(int(f.Fd()), unix.LOCK_EX|unix.LOCK_NB); e != nil {
		_ = f.Close()
		return nil, fmt.Errorf("durable role already open or cannot be locked: %w", e)
	}
	return f.Close, nil
}
