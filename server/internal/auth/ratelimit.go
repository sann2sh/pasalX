package auth

import (
	"sync"
	"time"
)

// failureLimiter is an in-memory brute-force guard for credential checks.
// A 6-digit PIN has only 10^6 combinations, so online guessing MUST be
// throttled. Single-instance e2-micro deployment => in-process state is
// sufficient; memory is strictly bounded by maxItems with oldest-first
// eviction when full, and Acquire reserves inflight capacity BEFORE
// Argon2id runs to defeat concurrent burst TOCTOU bypasses.
type failureLimiter struct {
	mu             sync.Mutex
	max            int
	window         time.Duration
	lockout        time.Duration
	resetOnSuccess bool
	entries        map[string]*failureEntry
	lastGC         time.Time
	maxItems       int
}

type failureEntry struct {
	count       int
	inflight    int
	windowStart time.Time
	lockedUntil time.Time
}

func newFailureLimiter(max int, window, lockout time.Duration, resetOnSuccess bool) *failureLimiter {
	return &failureLimiter{
		max:            max,
		window:         window,
		lockout:        lockout,
		resetOnSuccess: resetOnSuccess,
		entries:        make(map[string]*failureEntry),
		maxItems:       10000,
	}
}

type attemptOutcome uint8

const (
	outcomeAborted attemptOutcome = iota // blocked elsewhere or transient error: keep existing count intact
	outcomeSuccess                       // valid credentials verified
	outcomeFailure                       // invalid credentials
)

// Acquire checks whether key is locked out and reserves one inflight attempt
// slot before expensive password hashing begins. If count >= max or
// inflight >= max*2, concurrent callers are immediately rejected with a lockout
// window instead of piling up on Argon2id slots.
func (l *failureLimiter) Acquire(key string, now time.Time) (bool, time.Duration, func(attemptOutcome)) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.gc(now)

	e, ok := l.entries[key]
	if ok {
		if now.Before(e.lockedUntil) {
			return true, e.lockedUntil.Sub(now), nil
		}
		if now.Sub(e.windowStart) > l.window && e.inflight == 0 {
			e.count = 0
			e.windowStart = now
		}
		if e.count >= l.max || e.inflight >= l.max*2 {
			wait := l.lockout
			if now.Before(e.lockedUntil) {
				wait = e.lockedUntil.Sub(now)
			}
			return true, wait, nil
		}
	} else {
		l.ensureCapacity()
		e = &failureEntry{windowStart: now}
		l.entries[key] = e
	}

	e.inflight++
	var once sync.Once
	release := func(outcome attemptOutcome) {
		once.Do(func() {
			l.mu.Lock()
			defer l.mu.Unlock()
			cur, exists := l.entries[key]
			if !exists {
				return
			}
			if cur.inflight > 0 {
				cur.inflight--
			}
			switch outcome {
			case outcomeAborted:
				// Remove empty placeholder if this key had no prior failures.
				if cur.inflight == 0 && cur.count == 0 && cur.lockedUntil.IsZero() {
					delete(l.entries, key)
				}
				return
			case outcomeSuccess:
				if l.resetOnSuccess && cur.inflight == 0 {
					delete(l.entries, key)
				}
				return
			}
			t := time.Now().UTC()
			if !now.IsZero() {
				t = now
			}
			if t.Sub(cur.windowStart) > l.window {
				cur.count = 0
				cur.windowStart = t
			}
			cur.count++
			if cur.count >= l.max {
				cur.lockedUntil = t.Add(l.lockout)
				cur.count = 0
				cur.windowStart = t
			}
		})
	}
	return false, 0, release
}

// Blocked reports whether key is currently locked out and for how long.
func (l *failureLimiter) Blocked(key string, now time.Time) (bool, time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	e, ok := l.entries[key]
	if !ok {
		return false, 0
	}
	if now.Before(e.lockedUntil) {
		return true, e.lockedUntil.Sub(now)
	}
	if e.count >= l.max {
		return true, l.lockout
	}
	return false, 0
}

// Fail records a failed attempt; returns true if this failure triggered a lockout.
func (l *failureLimiter) Fail(key string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.gc(now)
	e, ok := l.entries[key]
	if !ok || now.Sub(e.windowStart) > l.window {
		if !ok {
			l.ensureCapacity()
		}
		e = &failureEntry{windowStart: now}
		l.entries[key] = e
	}
	e.count++
	if e.count >= l.max {
		e.lockedUntil = now.Add(l.lockout)
		e.count = 0
		e.windowStart = now
		return true
	}
	return false
}

// Reset clears failures after a successful authentication.
func (l *failureLimiter) Reset(key string) {
	l.mu.Lock()
	delete(l.entries, key)
	l.mu.Unlock()
}

func (l *failureLimiter) gc(now time.Time) {
	if !l.lastGC.IsZero() && now.Sub(l.lastGC) < time.Minute && len(l.entries) < l.maxItems {
		return
	}
	l.lastGC = now
	for k, e := range l.entries {
		if e.inflight == 0 && now.Sub(e.windowStart) > l.window && !now.Before(e.lockedUntil) {
			delete(l.entries, k)
		}
	}
}

// ensureCapacity bounds map growth when all entries are still within l.window
// (e.g. an attacker spraying >maxItems distinct usernames within 15 minutes).
func (l *failureLimiter) ensureCapacity() {
	if len(l.entries) < l.maxItems {
		return
	}
	var oldestKey string
	var oldestTime time.Time
	for k, e := range l.entries {
		if e.inflight > 0 {
			continue
		}
		// Prefer evicting unlocked entries with the oldest windowStart.
		if e.lockedUntil.IsZero() {
			delete(l.entries, k)
			if len(l.entries) < l.maxItems {
				return
			}
		} else if oldestKey == "" || e.windowStart.Before(oldestTime) {
			oldestKey = k
			oldestTime = e.windowStart
		}
	}
	if len(l.entries) >= l.maxItems && oldestKey != "" {
		delete(l.entries, oldestKey)
	}
}
