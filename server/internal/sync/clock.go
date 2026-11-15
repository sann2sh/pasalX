package sync

import (
	"sync"
	"time"
)

// syncClock assigns strictly monotonic microsecond commit timestamps to SyncPush
// batches and computes safe high-watermark cutoffs for SyncPull snapshots so
// concurrent out-of-order push transactions can never cause a pull cursor to
// skip a slow-to-commit transaction.
type syncClock struct {
	mu       sync.Mutex
	now      func() time.Time
	lastTS   time.Time
	inFlight map[uint64]time.Time
	nextID   uint64
}

func newSyncClock() *syncClock {
	return &syncClock{
		now:      func() time.Time { return time.Now().UTC() },
		inFlight: make(map[uint64]time.Time, 8),
	}
}

// beginPush reserves a monotonic commit timestamp and marks it in-flight until
// the returned release callback is invoked (after Postgres Commit/Rollback).
func (c *syncClock) beginPush() (time.Time, func()) {
	c.mu.Lock()
	ts := c.now().UTC().Truncate(time.Microsecond)
	if !ts.After(c.lastTS) {
		ts = c.lastTS.Add(time.Microsecond)
	}
	c.lastTS = ts
	c.nextID++
	id := c.nextID
	c.inFlight[id] = ts
	c.mu.Unlock()

	var once sync.Once
	return ts, func() {
		once.Do(func() {
			c.mu.Lock()
			delete(c.inFlight, id)
			c.mu.Unlock()
		})
	}
}

// acquirePullCutoff returns an upper-bound timestamp <= every committed write
// currently safe to advance the pull cursor past. If any push is still in-flight,
// the cutoff stops 1µs before the earliest in-flight push timestamp.
func (c *syncClock) acquirePullCutoff() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()

	if len(c.inFlight) > 0 {
		var earliest time.Time
		for _, ts := range c.inFlight {
			if earliest.IsZero() || ts.Before(earliest) {
				earliest = ts
			}
		}
		return earliest.Add(-time.Microsecond)
	}

	// No pushes active: advance past current wall-clock microsecond (accounting
	// for any sub-microsecond SQL CURRENT_TIMESTAMP writes made prior to the pull)
	// so all subsequent pushes are stamped strictly after this cutoff.
	cutoff := c.now().UTC().Truncate(time.Microsecond).Add(time.Microsecond)
	if !cutoff.After(c.lastTS) {
		cutoff = c.lastTS.Add(time.Microsecond)
	}
	c.lastTS = cutoff
	return cutoff
}

