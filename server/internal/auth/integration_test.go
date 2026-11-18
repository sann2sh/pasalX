package auth

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"pasalx/server/internal/db"
)

// Integration tests run against a throw-away database (pasalx_authtest_<ts>)
// created on the dev Postgres, migrated from ../../migrations, and dropped
// afterwards — so device codes in the real dev DB are never consumed.
// Set PASALX_SKIP_DB_TESTS=1 to run unit tests only.

var testPool *pgxpool.Pool

func TestMain(m *testing.M) {
	if os.Getenv("PASALX_SKIP_DB_TESTS") == "1" {
		os.Exit(m.Run())
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	admin, err := db.ConnectPool(ctx)
	if err != nil {
		fmt.Fprintf(os.Stderr, "integration DB unavailable (set PASALX_SKIP_DB_TESTS=1 to skip): %v\n", err)
		os.Exit(1)
	}
	name := fmt.Sprintf("pasalx_authtest_%d", time.Now().UnixNano())
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+name); err != nil {
		fmt.Fprintf(os.Stderr, "create test db: %v\n", err)
		os.Exit(1)
	}
	cfg := admin.Config().ConnConfig
	url := fmt.Sprintf("postgres://%s:%s@%s:%d/%s?sslmode=disable", cfg.User, cfg.Password, cfg.Host, cfg.Port, name)
	testPool, err = pgxpool.New(ctx, url)
	if err == nil {
		err = applyMigrations(ctx, testPool)
	}
	cancel()

	code := 1
	if err != nil {
		fmt.Fprintf(os.Stderr, "test db setup: %v\n", err)
	} else {
		code = m.Run()
	}

	if testPool != nil {
		testPool.Close()
	}
	dropCtx, dropCancel := context.WithTimeout(context.Background(), 10*time.Second)
	if _, err := admin.Exec(dropCtx, "DROP DATABASE IF EXISTS "+name+" WITH (FORCE)"); err != nil {
		fmt.Fprintf(os.Stderr, "drop test db: %v\n", err)
	}
	dropCancel()
	admin.Close()
	os.Exit(code)
}

func applyMigrations(ctx context.Context, pool *pgxpool.Pool) error {
	files, err := filepath.Glob(filepath.Join("..", "..", "migrations", "*.up.sql"))
	if err != nil || len(files) < 3 {
		return fmt.Errorf("expected >=3 up migrations, found %d (%v)", len(files), err)
	}
	sort.Strings(files)
	for _, f := range files {
		sql, err := os.ReadFile(f)
		if err != nil {
			return err
		}
		if _, err := pool.Exec(ctx, string(sql)); err != nil { // no args => simple protocol, multi-statement OK
			return fmt.Errorf("%s: %w", filepath.Base(f), err)
		}
	}
	return nil
}

// ---------------------------------------------------------------- harness

type harness struct {
	t       *testing.T
	svc     *Service
	srv     *httptest.Server
	storeID string
	clock   atomic.Int64 // unix nanos; 0 => real time
}

var userSeq atomic.Int64

func newHarness(t *testing.T) *harness {
	t.Helper()
	if testPool == nil {
		t.Skip("integration DB disabled")
	}
	h := &harness{t: t}
	h.svc = NewService(testPool, testKeys(t, 42))
	h.svc.now = func() time.Time {
		if n := h.clock.Load(); n != 0 {
			return time.Unix(0, n).UTC()
		}
		return time.Now().UTC()
	}
	mux := http.NewServeMux()
	NewHandler(h.svc, false).Routes(mux)
	h.srv = httptest.NewServer(mux)
	t.Cleanup(h.srv.Close)
	return h
}

func (h *harness) travel(d time.Duration) { h.clock.Store(time.Now().Add(d).UnixNano()) }

func (h *harness) user(role, password, pin string) UserInfo {
	h.t.Helper()
	seq := userSeq.Add(1)
	uname := fmt.Sprintf("%s_%d_%d", strings.ToLower(role), time.Now().UnixNano()%1e6, seq)
	email := uname + "@test.local"
	u, err := h.svc.CreateUser(context.Background(), "Test "+role, email, uname, password, pin)
	if err != nil {
		h.t.Fatalf("CreateUser: %v", err)
	}
	if role == RoleOwner && h.storeID == "" {
		sid, err := h.svc.CreateStoreWithOwner(context.Background(), u.ID, "Store "+uname)
		if err != nil {
			h.t.Fatalf("CreateStoreWithOwner: %v", err)
		}
		h.storeID = sid
	} else if h.storeID != "" {
		if err := h.svc.AddStoreMember(context.Background(), h.storeID, u.ID, role); err != nil {
			h.t.Fatalf("AddStoreMember: %v", err)
		}
	}
	u.Role = role
	return u
}

type resp struct {
	status int
	header http.Header
	body   map[string]any
	raw    []byte
}

func (h *harness) do(method, path, token string, body any) resp {
	h.t.Helper()
	var buf bytes.Buffer
	if body != nil {
		if s, ok := body.(string); ok {
			buf.WriteString(s)
		} else {
			json.NewEncoder(&buf).Encode(body)
		}
	}
	req, _ := http.NewRequest(method, h.srv.URL+path, &buf)
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	r, err := http.DefaultClient.Do(req)
	if err != nil {
		h.t.Fatalf("%s %s: %v", method, path, err)
	}
	defer r.Body.Close()
	var out resp
	out.status, out.header = r.StatusCode, r.Header
	dec := json.NewDecoder(r.Body)
	var m map[string]any
	_ = dec.Decode(&m)
	out.body = m
	out.raw, _ = json.Marshal(m)
	return out
}

func (h *harness) expect(r resp, status int, code string) {
	h.t.Helper()
	if r.status != status {
		h.t.Fatalf("want HTTP %d %s, got %d %s", status, code, r.status, r.raw)
	}
	if code != "" && r.body["error"] != code {
		h.t.Fatalf("want error %q, got %s", code, r.raw)
	}
}

func (h *harness) register(owner UserInfo, ownerPw, name string) DeviceInfo {
	h.t.Helper()
	r := h.do("POST", "/api/auth/devices/register", "", map[string]string{
		"owner_username": owner.Username, "owner_password": ownerPw, "device_name": name, "platform": "android",
	})
	h.expect(r, http.StatusCreated, "")
	var out struct{ Device DeviceInfo }
	json.Unmarshal(r.raw, &out)
	return out.Device
}

func (h *harness) login(username, password, pin, deviceID string) (resp, *LoginResult) {
	h.t.Helper()
	body := map[string]string{"username": username, "device_id": deviceID}
	if password != "" {
		body["password"] = password
	}
	if pin != "" {
		body["pin"] = pin
	}
	r := h.do("POST", "/api/auth/login", "", body)
	if r.status != http.StatusOK {
		return r, nil
	}
	var lr LoginResult
	if err := json.Unmarshal(r.raw, &lr); err != nil {
		h.t.Fatalf("decode login: %v", err)
	}
	return r, &lr
}

func (h *harness) mustLogin(username, password, pin, deviceID string) *LoginResult {
	h.t.Helper()
	r, lr := h.login(username, password, pin, deviceID)
	if lr == nil {
		h.t.Fatalf("login failed: %d %s", r.status, r.raw)
	}
	return lr
}

const (
	ownerPw = "OwnerPass#2026"
	staffPw = "StaffPass#2026"
)

// ---------------------------------------------------------------- tests

func TestIntegration_DeviceRegistration(t *testing.T) {
	h := newHarness(t)
	owner := h.user(RoleOwner, ownerPw, "")
	staff := h.user(RoleStaff, staffPw, "111111")

	d1 := h.register(owner, ownerPw, "Counter Redmi 12")
	d2 := h.register(owner, ownerPw, "Counter Samsung A15")
	n1, _ := strconv.Atoi(d1.Code)
	n2, _ := strconv.Atoi(d2.Code)
	if len(d1.Code) != 2 || len(d2.Code) != 2 || n2 != n1+1 || d1.Platform != "ANDROID" || d1.Status != "ACTIVE" {
		t.Fatalf("expected sequential 2-digit codes, got %+v %+v", d1, d2)
	}

	// Concurrent enrolment: advisory lock must give unique, contiguous codes.
	const n = 6
	codes := make([]string, n)
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			codes[i] = h.register(owner, ownerPw, fmt.Sprintf("Concurrent %d", i)).Code
		}(i)
	}
	wg.Wait()
	sort.Strings(codes)
	for i, c := range codes {
		if want := fmt.Sprintf("%02d", n2+1+i); c != want {
			t.Fatalf("concurrent codes not unique/contiguous: %v", codes)
		}
	}

	// DEK is stored sealed only (60 bytes), never plaintext.
	var sealed []byte
	testPool.QueryRow(context.Background(), `SELECT dek_sealed FROM device_registrations WHERE id=$1`, d1.ID).Scan(&sealed)
	if len(sealed) != sealedDEKSize {
		t.Fatalf("dek_sealed must be %d bytes, got %d", sealedDEKSize, len(sealed))
	}

	h.expect(h.do("POST", "/api/auth/devices/register", "", map[string]string{
		"owner_username": staff.Username, "owner_password": staffPw, "device_name": "x", "platform": "ANDROID",
	}), http.StatusForbidden, CodeForbidden)
	h.expect(h.do("POST", "/api/auth/devices/register", "", map[string]string{
		"owner_username": owner.Username, "owner_password": "wrong-password", "device_name": "x", "platform": "ANDROID",
	}), http.StatusUnauthorized, CodeInvalidCredentials)
	h.expect(h.do("POST", "/api/auth/devices/register", "", map[string]string{
		"owner_username": owner.Username, "owner_password": ownerPw, "device_name": "x", "platform": "WINDOWS",
	}), http.StatusBadRequest, CodeBadRequest)
	h.expect(h.do("POST", "/api/auth/devices/register", "", `{"owner_username":"a","owner_password":"b","device_name":"c","platform":"ANDROID","role":"OWNER"}`),
		http.StatusBadRequest, CodeBadRequest) // unknown fields rejected
}

func TestIntegration_LoginIssues12hDEKLease(t *testing.T) {
	h := newHarness(t)
	owner := h.user(RoleOwner, ownerPw, "")
	staff := h.user(RoleStaff, staffPw, "246810")
	dev := h.register(owner, ownerPw, "Phone A")

	r, lr := h.login(staff.Username, staffPw, "", dev.ID)
	if lr == nil {
		t.Fatalf("login: %s", r.raw)
	}
	if r.header.Get("Cache-Control") != "no-store" {
		t.Error("login response must be Cache-Control: no-store")
	}
	if lr.TokenType != "Bearer" || lr.User.Role != RoleStaff || lr.Device.Code != dev.Code {
		t.Fatalf("unexpected login payload: %s", r.raw)
	}
	L := lr.Lease
	if L.ExpiresAt.Sub(L.IssuedAt) != 12*time.Hour || L.TTLSeconds != 43200 || L.ExpiresUnix != L.ExpiresAt.Unix() {
		t.Fatalf("lease must be exactly 12h: %+v", L)
	}
	if !lr.ExpiresAt.Equal(L.ExpiresAt) {
		t.Fatal("JWT expiry must equal lease expiry")
	}
	if len(L.KEK) != 32 || len(L.Envelope) != 64 || L.EnvelopeVersion != 1 {
		t.Fatalf("bad lease material sizes kek=%d env=%d", len(L.KEK), len(L.Envelope))
	}

	// The phone-side unwrap yields exactly the server-custodied device DEK.
	dek, err := OpenEnvelope(L.KEK, L.Envelope, dev.ID, L.LeaseID, L.ExpiresAt)
	if err != nil {
		t.Fatalf("client unwrap failed: %v", err)
	}
	var sealed []byte
	var curLease string
	var leaseExp time.Time
	testPool.QueryRow(context.Background(),
		`SELECT dek_sealed, current_lease_id, last_kek_lease_expires_at FROM device_registrations WHERE id=$1`, dev.ID).
		Scan(&sealed, &curLease, &leaseExp)
	serverDEK, _ := h.svc.keys.OpenDEK(dev.ID, sealed)
	if !bytes.Equal(dek, serverDEK) {
		t.Fatal("unwrapped DEK differs from server DEK")
	}
	if curLease != L.LeaseID || !leaseExp.Equal(L.ExpiresAt) {
		t.Fatal("device row must record current lease id and expiry")
	}
	// A phone cannot stretch its own lease: altered expiry breaks unwrap.
	if _, err := OpenEnvelope(L.KEK, L.Envelope, dev.ID, L.LeaseID, L.ExpiresAt.Add(time.Hour)); err == nil {
		t.Fatal("envelope opened with extended expiry")
	}

	// Each login gets a fresh lease/KEK but the same underlying DEK.
	lr2 := h.mustLogin(staff.Username, "", "246810", dev.ID) // PIN login
	if lr2.Lease.LeaseID == L.LeaseID || bytes.Equal(lr2.Lease.KEK, L.KEK) {
		t.Fatal("new login must issue a new lease and KEK")
	}
	dek2, _ := OpenEnvelope(lr2.Lease.KEK, lr2.Lease.Envelope, dev.ID, lr2.Lease.LeaseID, lr2.Lease.ExpiresAt)
	if !bytes.Equal(dek2, dek) {
		t.Fatal("DEK must be stable across leases (no SQLite re-encryption)")
	}

	// Heartbeat with the new token works; the superseded token is rejected.
	h.expect(h.do("GET", "/api/auth/heartbeat", lr2.AccessToken, nil), http.StatusOK, "")
	h.expect(h.do("GET", "/api/auth/heartbeat", lr.AccessToken, nil), http.StatusUnauthorized, CodeSessionEnded)

	// Audit trail recorded.
	var logins int
	testPool.QueryRow(context.Background(), `SELECT count(*) FROM app_audit_logs WHERE event_type='LOGIN' AND user_id=$1`, staff.ID).Scan(&logins)
	if logins != 2 {
		t.Fatalf("expected 2 LOGIN audit rows, got %d", logins)
	}
}

func TestIntegration_CredentialFailures(t *testing.T) {
	h := newHarness(t)
	owner := h.user(RoleOwner, ownerPw, "")
	staff := h.user(RoleStaff, staffPw, "135790")
	noPin := h.user(RoleStaff, staffPw, "")
	dev := h.register(owner, ownerPw, "Phone")

	for _, c := range []struct{ name, user, pw, pin string }{
		{"wrong password", staff.Username, "nope-nope", ""},
		{"wrong PIN", staff.Username, "", "000000"},
		{"unknown user", "ghost_user", staffPw, ""},
		{"PIN on account without PIN", noPin.Username, "", "123456"},
	} {
		r, _ := h.login(c.user, c.pw, c.pin, dev.ID)
		if r.status != http.StatusUnauthorized || r.body["error"] != CodeInvalidCredentials {
			t.Errorf("%s: got %d %s", c.name, r.status, r.raw)
		}
	}
	r, _ := h.login(staff.Username, staffPw, "135790", dev.ID)
	h.expect(r, http.StatusBadRequest, CodeBadRequest) // both password & pin
	r, _ = h.login(staff.Username, staffPw, "", "not-a-uuid")
	h.expect(r, http.StatusBadRequest, CodeBadRequest)
	r, _ = h.login(staff.Username, staffPw, "", "00000000-0000-4000-8000-000000000000")
	h.expect(r, http.StatusUnauthorized, CodeDeviceNotRegistered)

	h.expect(h.do("GET", "/api/auth/heartbeat", "", nil), http.StatusUnauthorized, CodeTokenMissing)
	h.expect(h.do("GET", "/api/auth/heartbeat", "garbage.token.value", nil), http.StatusUnauthorized, CodeTokenInvalid)
	forged, _ := testKeys(t, 99).IssueToken(Session{UserID: staff.ID, Role: RoleOwner, DeviceID: dev.ID, LeaseID: "x", ExpiresAt: time.Now().Add(time.Hour)}, time.Now())
	h.expect(h.do("GET", "/api/auth/heartbeat", forged, nil), http.StatusUnauthorized, CodeTokenInvalid)
}

func TestIntegration_BruteForceLockout(t *testing.T) {
	h := newHarness(t)
	owner := h.user(RoleOwner, ownerPw, "")
	staff := h.user(RoleStaff, staffPw, "112233")
	dev := h.register(owner, ownerPw, "Phone")

	for i := 0; i < 5; i++ {
		r, _ := h.login(staff.Username, "", fmt.Sprintf("%06d", i), dev.ID)
		h.expect(r, http.StatusUnauthorized, CodeInvalidCredentials)
	}
	// Locked: even the correct PIN is refused for 15 minutes.
	r, _ := h.login(staff.Username, "", "112233", dev.ID)
	h.expect(r, http.StatusTooManyRequests, CodeRateLimited)
	if ra, _ := strconv.Atoi(r.header.Get("Retry-After")); ra < 800 || ra > 900 {
		t.Fatalf("Retry-After should be ~900s, got %q", r.header.Get("Retry-After"))
	}
	h.travel(16 * time.Minute)
	h.mustLogin(staff.Username, "", "112233", dev.ID)

	var fails int
	testPool.QueryRow(context.Background(), `SELECT count(*) FROM app_audit_logs WHERE event_type='LOGIN_FAILED' AND user_id=$1`, staff.ID).Scan(&fails)
	if fails != 5 {
		t.Fatalf("expected 5 LOGIN_FAILED audit rows, got %d", fails)
	}

	// Scope isolation: 5 failed /devices/register probes for owner must NOT lock owner out of /login.
	ownerDev := h.register(owner, ownerPw, "Owner Pixel")
	for i := 0; i < 5; i++ {
		rr := h.do("POST", "/api/auth/devices/register", "", map[string]string{
			"owner_username": owner.Username, "owner_password": "bad-password", "device_name": "Rogue", "platform": "ANDROID",
		})
		h.expect(rr, http.StatusUnauthorized, CodeInvalidCredentials)
	}
	rr := h.do("POST", "/api/auth/devices/register", "", map[string]string{
		"owner_username": owner.Username, "owner_password": ownerPw, "device_name": "Rogue", "platform": "ANDROID",
	})
	h.expect(rr, http.StatusTooManyRequests, CodeRateLimited)
	// Owner can still log in on their registered phone to pull the Kill-Switch!
	h.mustLogin(owner.Username, ownerPw, "", ownerDev.ID)
}

func TestIntegration_KillSwitchRevocation(t *testing.T) {
	h := newHarness(t)
	owner := h.user(RoleOwner, ownerPw, "")
	staff := h.user(RoleStaff, staffPw, "778899")
	manager := h.user(RoleManager, "ManagerPass#1", "")
	ownerDev := h.register(owner, ownerPw, "Owner Phone")
	staffDev := h.register(owner, ownerPw, "Counter Phone")

	ownerSess := h.mustLogin(owner.Username, ownerPw, "", ownerDev.ID)
	staffSess := h.mustLogin(staff.Username, "", "778899", staffDev.ID)
	h.expect(h.do("GET", "/api/auth/heartbeat", staffSess.AccessToken, nil), http.StatusOK, "")

	// RBAC: STAFF and MANAGER cannot trigger revocation.
	h.expect(h.do("POST", "/api/auth/revoke", staffSess.AccessToken, map[string]string{"device_code": ownerDev.Code, "reason": "x"}),
		http.StatusForbidden, CodeForbidden)
	mgrSess := h.mustLogin(manager.Username, "ManagerPass#1", "", ownerDev.ID) // replaces owner's session on ownerDev
	h.expect(h.do("POST", "/api/auth/revoke", mgrSess.AccessToken, map[string]string{"device_code": staffDev.Code, "reason": "x"}),
		http.StatusForbidden, CodeForbidden)
	ownerSess = h.mustLogin(owner.Username, ownerPw, "", ownerDev.ID)

	// Validation and self-revoke protection.
	h.expect(h.do("POST", "/api/auth/revoke", ownerSess.AccessToken, map[string]string{"device_code": staffDev.Code}),
		http.StatusBadRequest, CodeBadRequest)
	h.expect(h.do("POST", "/api/auth/revoke", ownerSess.AccessToken, map[string]string{"device_code": ownerDev.Code, "reason": "oops"}),
		http.StatusConflict, CodeCannotRevokeSelf)
	h.expect(h.do("POST", "/api/auth/revoke", ownerSess.AccessToken, map[string]string{"device_code": "98", "reason": "x"}),
		http.StatusNotFound, CodeDeviceNotRegistered)

	// Owner pulls the kill-switch on the counter phone.
	r := h.do("POST", "/api/auth/revoke", ownerSess.AccessToken, map[string]string{"device_code": staffDev.Code, "reason": "Phone stolen"})
	h.expect(r, http.StatusOK, "")
	if r.body["already_revoked"] != false || r.body["device"].(map[string]any)["status"] != "REVOKED" {
		t.Fatalf("unexpected revoke response: %s", r.raw)
	}

	// Immediately: the still-unexpired token gets 401 DEVICE_REVOKED on every protected route.
	for _, ep := range []struct{ m, p string }{{"GET", "/api/auth/heartbeat"}, {"POST", "/api/auth/refresh"}, {"POST", "/api/auth/logout"}} {
		rr := h.do(ep.m, ep.p, staffSess.AccessToken, nil)
		h.expect(rr, http.StatusUnauthorized, CodeDeviceRevoked)
		if rr.header.Get("WWW-Authenticate") != `Bearer error="DEVICE_REVOKED"` {
			t.Errorf("%s: missing WWW-Authenticate DEVICE_REVOKED header", ep.p)
		}
	}
	// No new lease can ever be obtained on the revoked phone.
	lr, _ := h.login(staff.Username, "", "778899", staffDev.ID)
	h.expect(lr, http.StatusUnauthorized, CodeDeviceRevoked)
	lr, _ = h.login(owner.Username, ownerPw, "", staffDev.ID)
	h.expect(lr, http.StatusUnauthorized, CodeDeviceRevoked)

	// Phone offline past its 12h lease then reconnects: still told DEVICE_REVOKED (not just TOKEN_EXPIRED).
	h.travel(13 * time.Hour)
	h.expect(h.do("GET", "/api/auth/heartbeat", staffSess.AccessToken, nil), http.StatusUnauthorized, CodeDeviceRevoked)
	h.clock.Store(0)

	// Idempotent repeat.
	r = h.do("POST", "/api/auth/revoke", ownerSess.AccessToken, map[string]string{"device_id": staffDev.ID, "reason": "again"})
	h.expect(r, http.StatusOK, "")
	if r.body["already_revoked"] != true {
		t.Fatalf("second revoke should report already_revoked: %s", r.raw)
	}

	// DB state + audit.
	var status, reason, by string
	var active bool
	var lease *string
	testPool.QueryRow(context.Background(), `SELECT status, is_active, revocation_reason, revoked_by_user_id, current_lease_id
		FROM device_registrations WHERE id=$1`, staffDev.ID).Scan(&status, &active, &reason, &by, &lease)
	if status != "REVOKED" || active || reason != "Phone stolen" || by != owner.ID || lease != nil {
		t.Fatalf("bad revoked row: %s %v %q %s %v", status, active, reason, by, lease)
	}
	var audits int
	testPool.QueryRow(context.Background(), `SELECT count(*) FROM app_audit_logs WHERE event_type='REVOKE_DEVICE' AND device_code=$1`, staffDev.Code).Scan(&audits)
	if audits != 1 {
		t.Fatalf("expected exactly 1 REVOKE_DEVICE audit row, got %d", audits)
	}

	// Other devices are unaffected.
	h.expect(h.do("GET", "/api/auth/heartbeat", ownerSess.AccessToken, nil), http.StatusOK, "")

	// OWNER can list devices for the Settings & Kill-Switch screen; non-owners cannot.
	h.expect(h.do("GET", "/api/auth/devices", mgrSess.AccessToken, nil), http.StatusUnauthorized, CodeSessionEnded)
	listResp := h.do("GET", "/api/auth/devices", ownerSess.AccessToken, nil)
	h.expect(listResp, http.StatusOK, "")
	var listed struct{ Devices []DeviceInfo }
	if err := json.Unmarshal(listResp.raw, &listed); err != nil || len(listed.Devices) < 2 {
		t.Fatalf("expected >=2 listed devices, got %v (%v)", len(listed.Devices), err)
	}
	var foundRevoked bool
	for _, dv := range listed.Devices {
		if dv.ID == staffDev.ID {
			foundRevoked = true
			if dv.Status != "REVOKED" || dv.RevocationReason == nil || *dv.RevocationReason != "Phone stolen" {
				t.Fatalf("unexpected revoked device entry in list: %+v", dv)
			}
		}
	}
	if !foundRevoked {
		t.Fatal("revoked device missing from GET /api/auth/devices")
	}
}

func TestIntegration_RefreshNeverExtendsLease(t *testing.T) {
	h := newHarness(t)
	owner := h.user(RoleOwner, ownerPw, "")
	dev := h.register(owner, ownerPw, "Phone")
	lr := h.mustLogin(owner.Username, ownerPw, "", dev.ID)

	h.travel(3 * time.Hour)
	r := h.do("POST", "/api/auth/refresh", lr.AccessToken, nil)
	h.expect(r, http.StatusOK, "")
	var rf LoginResult
	json.Unmarshal(r.raw, &rf)
	if !rf.Lease.ExpiresAt.Equal(lr.Lease.ExpiresAt) || !rf.ExpiresAt.Equal(lr.ExpiresAt) {
		t.Fatalf("refresh extended the lease: %v -> %v", lr.Lease.ExpiresAt, rf.Lease.ExpiresAt)
	}
	if rf.Lease.LeaseID != lr.Lease.LeaseID || !bytes.Equal(rf.Lease.KEK, lr.Lease.KEK) {
		t.Fatal("refresh must re-derive the same lease")
	}
	if rf.Lease.TTLSeconds > 9*3600+5 || rf.Lease.TTLSeconds < 9*3600-5 {
		t.Fatalf("remaining TTL should be ~9h, got %ds", rf.Lease.TTLSeconds)
	}
	if bytes.Equal(rf.Lease.Envelope, lr.Lease.Envelope) {
		t.Fatal("re-wrapped envelope must use a fresh nonce")
	}
	if _, err := OpenEnvelope(rf.Lease.KEK, rf.Lease.Envelope, dev.ID, rf.Lease.LeaseID, rf.Lease.ExpiresAt); err != nil {
		t.Fatalf("refreshed envelope does not open: %v", err)
	}
	h.expect(h.do("GET", "/api/auth/heartbeat", rf.AccessToken, nil), http.StatusOK, "")

	// After the 12h ceiling neither token works; only a fresh login does.
	h.travel(12*time.Hour + time.Minute)
	h.expect(h.do("POST", "/api/auth/refresh", rf.AccessToken, nil), http.StatusUnauthorized, CodeTokenExpired)
	h.expect(h.do("GET", "/api/auth/heartbeat", lr.AccessToken, nil), http.StatusUnauthorized, CodeTokenExpired)
}

func TestIntegration_LogoutDisableAndRoleChange(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	owner := h.user(RoleOwner, ownerPw, "")
	staff := h.user(RoleStaff, staffPw, "202020")
	dev := h.register(owner, ownerPw, "Phone")

	lr := h.mustLogin(staff.Username, staffPw, "", dev.ID)
	h.expect(h.do("POST", "/api/auth/logout", lr.AccessToken, nil), http.StatusOK, "")
	h.expect(h.do("GET", "/api/auth/heartbeat", lr.AccessToken, nil), http.StatusUnauthorized, CodeSessionEnded)

	// Role change invalidates existing session immediately.
	lr = h.mustLogin(staff.Username, staffPw, "", dev.ID)
	testPool.Exec(ctx, `UPDATE store_memberships SET role='MANAGER' WHERE user_id=$1 AND store_id=$2`, staff.ID, h.storeID)
	h.expect(h.do("GET", "/api/auth/heartbeat", lr.AccessToken, nil), http.StatusUnauthorized, CodeSessionEnded)

	// Terminated staff: disabled account loses access immediately and cannot log back in.
	lr = h.mustLogin(staff.Username, staffPw, "", dev.ID)
	testPool.Exec(ctx, `UPDATE users SET is_active=FALSE WHERE id=$1`, staff.ID)
	h.expect(h.do("GET", "/api/auth/heartbeat", lr.AccessToken, nil), http.StatusUnauthorized, CodeUserDisabled)
	r, _ := h.login(staff.Username, staffPw, "", dev.ID)
	h.expect(r, http.StatusUnauthorized, CodeUserDisabled)
	// Wrong password on a disabled account must not reveal it is disabled.
	r, _ = h.login(staff.Username, "wrong-password", "", dev.ID)
	h.expect(r, http.StatusUnauthorized, CodeInvalidCredentials)
}

