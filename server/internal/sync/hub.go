package sync

import (
	"sync"
	"time"
)

const (
	defaultMaxSubscribers = 100
	defaultMaxPerDevice   = 4
	defaultKeepalive      = 25 * time.Second
)

// EventType names the SSE event sent to mobile clients.
type EventType string

const (
	EventConnected     EventType = "CONNECTED"
	EventDataChanged   EventType = "DATA_CHANGED"
	EventDeviceRevoked EventType = "DEVICE_REVOKED"
)

// BroadcastEvent is the tiny coalescible payload emitted over GET /api/sync/events.
type BroadcastEvent struct {
	OriginDeviceCode string    `json:"origin_device_code"`
	ServerTime       time.Time `json:"server_time"`
	HasDiscrepancy   bool      `json:"has_discrepancy,omitempty"`
}

// Subscriber represents one active SSE stream held by an authenticated mobile client.
type Subscriber struct {
	id         uint64
	deviceID   string
	deviceCode string
	hub        *Hub

	notifyCh   chan struct{} // buffered(1): coalesced wakeups for DATA_CHANGED
	revokeCh   chan struct{} // closed immediately if this device is revoked
	replacedCh chan struct{} // closed if the same device opens > maxPerDevice streams

	mu      sync.Mutex
	pending *BroadcastEvent
	onceRev sync.Once
	onceRep sync.Once
}

// Notify signals waiting consumers of pending DATA_CHANGED updates.
func (s *Subscriber) Notify() <-chan struct{} { return s.notifyCh }

// Revoked fires once the device receives a live kill-switch command.
func (s *Subscriber) Revoked() <-chan struct{} { return s.revokeCh }

// Replaced fires if this stream was evicted as stale by newer connections from the same device.
func (s *Subscriber) Replaced() <-chan struct{} { return s.replacedCh }

// TakePending pops the latest coalesced BroadcastEvent, if any.
func (s *Subscriber) TakePending() (BroadcastEvent, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.pending == nil {
		return BroadcastEvent{}, false
	}
	ev := *s.pending
	s.pending = nil
	return ev, true
}

func (s *Subscriber) enqueue(ev BroadcastEvent) {
	s.mu.Lock()
	if s.pending == nil {
		cp := ev
		s.pending = &cp
	} else {
		if ev.ServerTime.After(s.pending.ServerTime) {
			s.pending.ServerTime = ev.ServerTime
		}
		if ev.HasDiscrepancy {
			s.pending.HasDiscrepancy = true
		}
		if s.pending.OriginDeviceCode != ev.OriginDeviceCode {
			s.pending.OriginDeviceCode = ev.OriginDeviceCode
		}
	}
	s.mu.Unlock()

	select {
	case s.notifyCh <- struct{}{}:
	default:
	}
}

func (s *Subscriber) markRevoked()  { s.onceRev.Do(func() { close(s.revokeCh) }) }
func (s *Subscriber) markReplaced() { s.onceRep.Do(func() { close(s.replacedCh) }) }

// Hub maintains active shop floor SSE listeners with bounded memory (<1 MB for 50 clients).
type Hub struct {
	mu             sync.RWMutex
	subs           map[uint64]*Subscriber
	nextID         uint64
	maxSubscribers int
	maxPerDevice   int
	keepalive      time.Duration
	done           chan struct{}
	closeOnce      sync.Once
}

// NewHub constructs an SSE broadcaster.
func NewHub() *Hub {
	return &Hub{
		subs:           make(map[uint64]*Subscriber, 16),
		maxSubscribers: defaultMaxSubscribers,
		maxPerDevice:   defaultMaxPerDevice,
		keepalive:      defaultKeepalive,
		done:           make(chan struct{}),
	}
}

// Shutdown closes the done channel so all active SSE goroutines exit promptly during server shutdown.
func (h *Hub) Shutdown() {
	h.closeOnce.Do(func() { close(h.done) })
}

// Done is closed when Shutdown is invoked.
func (h *Hub) Done() <-chan struct{} { return h.done }

// ActiveCount reports current active SSE listener count.
func (h *Hub) ActiveCount() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.subs)
}

// Subscribe registers an SSE stream for (deviceID, deviceCode). Returns nil if the
// server is shutting down or has reached maxSubscribers.
func (h *Hub) Subscribe(deviceID, deviceCode string) (*Subscriber, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()

	select {
	case <-h.done:
		return nil, false
	default:
	}

	// Reap oldest connection for this same device if stale reconnects accumulate.
	var deviceSubs []*Subscriber
	for _, sub := range h.subs {
		if sub.deviceID == deviceID {
			deviceSubs = append(deviceSubs, sub)
		}
	}
	if len(deviceSubs) >= h.maxPerDevice {
		oldest := deviceSubs[0]
		for _, sub := range deviceSubs[1:] {
			if sub.id < oldest.id {
				oldest = sub
			}
		}
		delete(h.subs, oldest.id)
		oldest.markReplaced()
	}

	if len(h.subs) >= h.maxSubscribers {
		return nil, false
	}

	h.nextID++
	sub := &Subscriber{
		id:         h.nextID,
		deviceID:   deviceID,
		deviceCode: deviceCode,
		hub:        h,
		notifyCh:   make(chan struct{}, 1),
		revokeCh:   make(chan struct{}),
		replacedCh: make(chan struct{}),
	}
	h.subs[sub.id] = sub
	return sub, true
}

// Unsubscribe removes a finished SSE listener.
func (h *Hub) Unsubscribe(sub *Subscriber) {
	if sub == nil {
		return
	}
	h.mu.Lock()
	if cur, ok := h.subs[sub.id]; ok && cur == sub {
		delete(h.subs, sub.id)
	}
	h.mu.Unlock()
}

// BroadcastDataChanged fans out a lightweight DATA_CHANGED wakeup ping to all
// active shop phones other than the originating deviceCode.
func (h *Hub) BroadcastDataChanged(ev BroadcastEvent) int {
	h.mu.RLock()
	targets := make([]*Subscriber, 0, len(h.subs))
	for _, sub := range h.subs {
		if ev.OriginDeviceCode != "" && sub.deviceCode == ev.OriginDeviceCode {
			continue
		}
		targets = append(targets, sub)
	}
	h.mu.RUnlock()

	for _, sub := range targets {
		sub.enqueue(ev)
	}
	return len(targets)
}

// RevokeDevice notifies and disconnects all live SSE streams belonging to deviceID.
func (h *Hub) RevokeDevice(deviceID string) {
	h.mu.Lock()
	var killed []*Subscriber
	for id, sub := range h.subs {
		if sub.deviceID == deviceID {
			delete(h.subs, id)
			killed = append(killed, sub)
		}
	}
	h.mu.Unlock()

	for _, sub := range killed {
		sub.markRevoked()
	}
}

