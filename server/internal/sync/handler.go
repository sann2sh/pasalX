package sync

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"pasalx/server/internal/auth"
)

// Handler exposes the sync push, delta pull, and SSE event endpoints over HTTP.
type Handler struct {
	svc *Service
}

// NewHandler creates an HTTP sync handler.
func NewHandler(svc *Service) *Handler {
	return &Handler{svc: svc}
}

// Routes registers all /api/sync/* endpoints on mux wrapped with requireAuth
// (so DEVICE_REVOKED, SESSION_ENDED, and TOKEN_EXPIRED take effect on every sync call).
func (h *Handler) Routes(mux *http.ServeMux, requireAuth func(http.Handler) http.Handler) {
	mux.Handle("POST /api/sync/push", requireAuth(http.HandlerFunc(h.push)))
	mux.Handle("GET /api/sync/pull", requireAuth(http.HandlerFunc(h.pull)))
	mux.Handle("GET /api/sync/events", requireAuth(http.HandlerFunc(h.events)))
}

func (h *Handler) push(w http.ResponseWriter, r *http.Request) {
	sess, ok := auth.SessionFrom(r.Context())
	if !ok {
		writeError(w, newErr(http.StatusUnauthorized, "TOKEN_MISSING", "not authenticated"))
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, MaxPushBodyBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()

	var req PushRequest
	if err := dec.Decode(&req); err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			writeError(w, newErr(http.StatusRequestEntityTooLarge, CodeBadRequest, "push batch exceeds 1 MiB limit"))
			return
		}
		writeError(w, newErr(http.StatusBadRequest, CodeBadRequest, "invalid JSON body"))
		return
	}
	if err := dec.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		writeError(w, newErr(http.StatusBadRequest, CodeBadRequest, "body must contain a single JSON object"))
		return
	}

	res, err := h.svc.Push(r.Context(), sess, req)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (h *Handler) pull(w http.ResponseWriter, r *http.Request) {
	sess, ok := auth.SessionFrom(r.Context())
	if !ok {
		writeError(w, newErr(http.StatusUnauthorized, "TOKEN_MISSING", "not authenticated"))
		return
	}

	q := r.URL.Query()
	since := time.Unix(0, 0).UTC()
	if rawSince := strings.TrimSpace(q.Get("since")); rawSince != "" {
		parsed, err := time.Parse(time.RFC3339Nano, rawSince)
		if err != nil {
			writeError(w, newErr(http.StatusBadRequest, CodeBadRequest, "invalid since timestamp (expected RFC3339/RFC3339Nano)"))
			return
		}
		since = parsed.UTC()
	}

	var limit int
	if rawLim := strings.TrimSpace(q.Get("limit")); rawLim != "" {
		n, err := strconv.Atoi(rawLim)
		if err != nil || n <= 0 {
			writeError(w, newErr(http.StatusBadRequest, CodeBadRequest, "limit must be a positive integer"))
			return
		}
		limit = n
	}

	res, err := h.svc.Pull(r.Context(), sess, since, limit)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (h *Handler) events(w http.ResponseWriter, r *http.Request) {
	sess, ok := auth.SessionFrom(r.Context())
	if !ok {
		writeError(w, newErr(http.StatusUnauthorized, "TOKEN_MISSING", "not authenticated"))
		return
	}

	hub := h.svc.Hub()
	sub, subscribed := hub.Subscribe(sess.StoreID, sess.DeviceID, sess.DeviceCode)
	if !subscribed {
		writeError(w, newErr(http.StatusServiceUnavailable, CodeTooManyConn, "sync event stream capacity reached or server shutting down"))
		return
	}
	defer hub.Unsubscribe(sub)

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache, no-store")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)

	rc := http.NewResponseController(w)

	helloJSON, _ := json.Marshal(map[string]any{
		"device_code": sess.DeviceCode,
		"server_time": time.Now().UTC(),
	})
	if err := writeSSEFrame(rc, w, fmt.Sprintf("event: %s\ndata: %s\n\n", EventConnected, helloJSON)); err != nil {
		return
	}

	keepaliveInterval := hub.keepalive
	if keepaliveInterval <= 0 {
		keepaliveInterval = defaultKeepalive
	}
	keepaliveTicker := time.NewTicker(keepaliveInterval)
	defer keepaliveTicker.Stop()

	leaseTTL := time.Until(sess.ExpiresAt)
	if leaseTTL <= 0 {
		leaseTTL = time.Millisecond
	}
	leaseTimer := time.NewTimer(leaseTTL)
	defer leaseTimer.Stop()

	for {
		select {
		case <-r.Context().Done():
			return
		case <-hub.Done():
			return
		case <-sub.Replaced():
			return
		case <-sub.Revoked():
			revJSON, _ := json.Marshal(map[string]string{
				"error":       auth.CodeDeviceRevoked,
				"device_id":   sess.DeviceID,
				"device_code": sess.DeviceCode,
			})
			_ = writeSSEFrame(rc, w, fmt.Sprintf("event: %s\ndata: %s\n\n", EventDeviceRevoked, revJSON))
			return
		case <-leaseTimer.C:
			expJSON, _ := json.Marshal(map[string]string{
				"error": auth.CodeTokenExpired,
			})
			_ = writeSSEFrame(rc, w, fmt.Sprintf("event: SESSION_EXPIRED\ndata: %s\n\n", expJSON))
			return
		case <-sub.Notify():
			ev, hasEv := sub.TakePending()
			if !hasEv {
				continue
			}
			payload, err := json.Marshal(ev)
			if err != nil {
				continue
			}
			frame := fmt.Sprintf("id: %s\nevent: %s\ndata: %s\n\n",
				ev.ServerTime.UTC().Format(time.RFC3339Nano), EventDataChanged, payload)
			if err := writeSSEFrame(rc, w, frame); err != nil {
				return
			}
		case <-keepaliveTicker.C:
			if err := writeSSEFrame(rc, w, ": keepalive\n\n"); err != nil {
				return
			}
		}
	}
}

func writeSSEFrame(rc *http.ResponseController, w io.Writer, frame string) error {
	_ = rc.SetWriteDeadline(time.Now().Add(10 * time.Second))
	if _, err := io.WriteString(w, frame); err != nil {
		return err
	}
	if err := rc.Flush(); err != nil {
		return err
	}
	_ = rc.SetWriteDeadline(time.Time{})
	return nil
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(15 * time.Second))
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Pragma", "no-cache")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("sync: write response failed: %v", err)
	}
}

func writeError(w http.ResponseWriter, err error) {
	var se *Error
	if !errors.As(err, &se) {
		log.Printf("sync: unexpected error: %v", err)
		se = errInternal
	}
	writeJSON(w, se.Status, map[string]string{"error": se.Code, "message": se.Message})
}

