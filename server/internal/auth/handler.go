package auth

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"strings"
	"time"
)

const maxAuthBody = 16 << 10 // 16 KiB

type ctxKey struct{}

// SessionFrom returns the authenticated session attached by RequireAuth.
func SessionFrom(ctx context.Context) (Session, bool) {
	s, ok := ctx.Value(ctxKey{}).(Session)
	return s, ok
}

// Handler exposes the auth service over HTTP.
type Handler struct {
	svc        *Service
	trustProxy bool // honour X-Forwarded-For (only behind a trusted reverse proxy)
}

func NewHandler(svc *Service, trustProxy bool) *Handler {
	return &Handler{svc: svc, trustProxy: trustProxy}
}

// Routes registers all /api/auth endpoints on mux (Go 1.22+ method patterns).
func (h *Handler) Routes(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/auth/devices/register", h.registerDevice)
	mux.Handle("GET /api/auth/devices", h.RequireAuth(RequireRole(RoleOwner)(http.HandlerFunc(h.listDevices))))
	mux.HandleFunc("POST /api/auth/login", h.login)
	mux.Handle("POST /api/auth/refresh", h.RequireAuth(http.HandlerFunc(h.refresh)))
	mux.Handle("POST /api/auth/logout", h.RequireAuth(http.HandlerFunc(h.logout)))
	mux.Handle("POST /api/auth/revoke", h.RequireAuth(RequireRole(RoleOwner)(http.HandlerFunc(h.revoke))))
	mux.Handle("GET /api/auth/heartbeat", h.RequireAuth(http.HandlerFunc(h.heartbeat)))
	h.registerPhase2Routes(mux)
}

// RequireAuth is the kill-switch middleware reused by every protected route
// (Step 4 sync push/pull/events included).
func (h *Handler) RequireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, ok := extractBearer(r.Header.Get("Authorization"))
		if !ok {
			writeError(w, newErr(http.StatusUnauthorized, CodeTokenMissing, "missing bearer token"))
			return
		}
		sess, err := h.svc.Authenticate(r.Context(), raw)
		if err != nil {
			writeError(w, err)
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), ctxKey{}, sess)))
	})
}

func extractBearer(authz string) (string, bool) {
	if len(authz) <= 7 || !strings.EqualFold(authz[:7], "Bearer ") {
		return "", false
	}
	tok := strings.TrimSpace(authz[7:])
	return tok, tok != ""
}

// RequireRole gates a handler to the listed roles (must run after RequireAuth).
func RequireRole(roles ...string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			sess, ok := SessionFrom(r.Context())
			if !ok {
				writeError(w, newErr(http.StatusUnauthorized, CodeTokenMissing, "not authenticated"))
				return
			}
			for _, role := range roles {
				if sess.Role == role {
					next.ServeHTTP(w, r)
					return
				}
			}
			writeError(w, newErr(http.StatusForbidden, CodeForbidden, "insufficient role"))
		})
	}
}

func (h *Handler) registerDevice(w http.ResponseWriter, r *http.Request) {
	var in RegisterDeviceInput
	if !decodeJSON(w, r, &in) {
		return
	}
	d, err := h.svc.RegisterDevice(r.Context(), in, h.clientIP(r))
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"device": d})
}

func (h *Handler) listDevices(w http.ResponseWriter, r *http.Request) {
	sess, _ := SessionFrom(r.Context())
	devices, err := h.svc.ListDevices(r.Context(), sess)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": devices})
}

func (h *Handler) login(w http.ResponseWriter, r *http.Request) {
	var in LoginInput
	if !decodeJSON(w, r, &in) {
		return
	}
	res, err := h.svc.Login(r.Context(), in, h.clientIP(r))
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (h *Handler) refresh(w http.ResponseWriter, r *http.Request) {
	sess, _ := SessionFrom(r.Context())
	res, err := h.svc.Refresh(r.Context(), sess)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (h *Handler) logout(w http.ResponseWriter, r *http.Request) {
	sess, _ := SessionFrom(r.Context())
	if err := h.svc.Logout(r.Context(), sess, h.clientIP(r)); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "LOGGED_OUT"})
}

func (h *Handler) revoke(w http.ResponseWriter, r *http.Request) {
	sess, _ := SessionFrom(r.Context())
	var in RevokeInput
	if !decodeJSON(w, r, &in) {
		return
	}
	res, err := h.svc.Revoke(r.Context(), sess, in, h.clientIP(r))
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

// heartbeat is the lightweight sync heartbeat. A revoked phone receives
// 401 DEVICE_REVOKED from RequireAuth before reaching this handler.
func (h *Handler) heartbeat(w http.ResponseWriter, r *http.Request) {
	sess, _ := SessionFrom(r.Context())
	writeJSON(w, http.StatusOK, map[string]any{
		"status":           "ACTIVE",
		"device_code":      sess.DeviceCode,
		"role":             sess.Role,
		"lease_expires_at": sess.ExpiresAt,
		"server_time":      h.svc.now(),
	})
}

// ---------------------------------------------------------------- helpers

// clientIP extracts the client IP address. When trustProxy is enabled behind a
// reverse proxy (e.g. Nginx/Caddy/GCP LB), it inspects the rightmost valid IP
// in X-Forwarded-For (the address appended by the trusted proxy) or X-Real-IP,
// preventing clients from spoofing leftmost X-Forwarded-For entries.
func (h *Handler) clientIP(r *http.Request) string {
	if h.trustProxy {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			parts := strings.Split(xff, ",")
			for i := len(parts) - 1; i >= 0; i-- {
				cand := strings.TrimSpace(parts[i])
				if ip := net.ParseIP(cand); ip != nil {
					return ip.String()
				}
			}
		}
		if xrip := strings.TrimSpace(r.Header.Get("X-Real-IP")); xrip != "" {
			if ip := net.ParseIP(xrip); ip != nil {
				return ip.String()
			}
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func decodeJSON(w http.ResponseWriter, r *http.Request, dst any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxAuthBody)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		writeError(w, newErr(http.StatusBadRequest, CodeBadRequest, "invalid JSON body"))
		return false
	}
	if err := dec.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		writeError(w, newErr(http.StatusBadRequest, CodeBadRequest, "body must contain a single JSON object"))
		return false
	}
	return true
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(15 * time.Second))
	w.Header().Set("Content-Type", "application/json")
	// Responses can carry KEK material and tokens: never cache.
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Pragma", "no-cache")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("auth: write response failed: %v", err)
	}
}

func writeError(w http.ResponseWriter, err error) {
	var ae *Error
	if !errors.As(err, &ae) {
		log.Printf("auth: unexpected error: %v", err)
		ae = errInternal
	}
	if ae.RetryAfter > 0 {
		w.Header().Set("Retry-After", retryAfterSeconds(ae.RetryAfter))
	}
	if ae.Status == http.StatusUnauthorized {
		w.Header().Set("WWW-Authenticate", `Bearer error="`+ae.Code+`"`)
	}
	writeJSON(w, ae.Status, map[string]string{"error": ae.Code, "message": ae.Message})
}

