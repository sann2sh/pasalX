package auth

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"regexp"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"pasalx/server/internal/db"
	pmail "pasalx/server/internal/mail"
)

func newPhase2TestApp(t *testing.T) (*pgxpool.Pool, *Service, *pmail.LogMailer, http.Handler, func()) {
	t.Helper()
	if testPool == nil {
		t.Skip("DB tests skipped")
	}
	ctx := context.Background()
	roleName := fmt.Sprintf("pasalx_p2_app_%d", time.Now().UnixNano())
	if _, err := testPool.Exec(ctx, fmt.Sprintf(`
		CREATE ROLE %s WITH LOGIN PASSWORD 'p2pass' NOSUPERUSER NOBYPASSRLS;
		GRANT USAGE ON SCHEMA public TO %s;
		GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO %s;
		GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO %s;
	`, roleName, roleName, roleName, roleName)); err != nil {
		t.Fatalf("create non-owner role: %v", err)
	}

	cfg := testPool.Config().ConnConfig
	appURL := fmt.Sprintf("postgres://%s:p2pass@%s:%d/%s?sslmode=disable", roleName, cfg.Host, cfg.Port, cfg.Database)
	appPool, err := pgxpool.New(ctx, appURL)
	if err != nil {
		t.Fatalf("connect as non-owner: %v", err)
	}

	keys, err := NewKeys(bytes.Repeat([]byte{0x77}, 32))
	if err != nil {
		t.Fatalf("NewKeys: %v", err)
	}
	svc := NewService(appPool, keys)
	mailer := pmail.NewLogMailer()
	svc.SetMailer(mailer)

	mux := http.NewServeMux()
	h := NewHandler(svc, false)
	h.Routes(mux)

	cleanup := func() {
		appPool.Close()
		_, _ = testPool.Exec(context.Background(), fmt.Sprintf(`
			REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM %s;
			REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public FROM %s;
			REVOKE USAGE ON SCHEMA public FROM %s;
			DROP ROLE IF EXISTS %s;
		`, roleName, roleName, roleName, roleName))
	}
	return appPool, svc, mailer, mux, cleanup
}

func doJSON(t *testing.T, handler http.Handler, method, path, token string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		if err := json.NewEncoder(&buf).Encode(body); err != nil {
			t.Fatalf("encode json: %v", err)
		}
	}
	req := httptest.NewRequest(method, path, &buf)
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	return rec
}

func extractSixDigitCode(t *testing.T, body string) string {
	t.Helper()
	re := regexp.MustCompile(`\b([0-9]{6})\b`)
	m := re.FindStringSubmatch(body)
	if len(m) < 2 {
		t.Fatalf("no 6-digit code found in email body: %s", body)
	}
	return m[1]
}

func TestGateB_FullMultiTenantOnboardingAndLifecycle(t *testing.T) {
	appPool, _, mailer, handler, cleanup := newPhase2TestApp(t)
	defer cleanup()

	// 1. Owner signs up (unverified)
	rec := doJSON(t, handler, "POST", "/api/auth/signup", "", map[string]any{
		"name":     "Sita Sharma",
		"email":    "Sita@Example.COM",
		"password": "himalaya-tea-strong-2026",
		"username": "sita_owner",
		"pin":      "482913",
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("signup expected 201, got %d: %s", rec.Code, rec.Body.String())
	}

	// Unverified account-login must be blocked with 403 EMAIL_NOT_VERIFIED
	rec = doJSON(t, handler, "POST", "/api/auth/account-login", "", map[string]any{
		"email":    "sita@example.com",
		"password": "himalaya-tea-strong-2026",
	})
	if rec.Code != http.StatusForbidden {
		t.Fatalf("unverified account-login expected 403, got %d: %s", rec.Code, rec.Body.String())
	}

	// Wrong code 5 times locks the code
	for i := 0; i < 5; i++ {
		rec = doJSON(t, handler, "POST", "/api/auth/verify-email", "", map[string]any{
			"email": "sita@example.com",
			"code":  "000001",
		})
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("wrong verify attempt %d expected 400, got %d: %s", i+1, rec.Code, rec.Body.String())
		}
	}
	rec = doJSON(t, handler, "POST", "/api/auth/verify-email", "", map[string]any{
		"email": "sita@example.com",
		"code":  "000001",
	})
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("6th verify attempt expected 429, got %d: %s", rec.Code, rec.Body.String())
	}

	// Resend verification -> 202 (and verify with real code from LogMailer)
	rec = doJSON(t, handler, "POST", "/api/auth/resend-verification", "", map[string]any{
		"email": "sita@example.com",
	})
	if rec.Code != http.StatusAccepted {
		t.Fatalf("resend expected 202, got %d: %s", rec.Code, rec.Body.String())
	}
	sent := mailer.Sent()
	ownerCode := extractSixDigitCode(t, sent[len(sent)-1].TextBody)

	rec = doJSON(t, handler, "POST", "/api/auth/verify-email", "", map[string]any{
		"email": "sita@example.com",
		"code":  ownerCode,
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("verify-email expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	// 2. Owner account-login -> gets Account JWT
	rec = doJSON(t, handler, "POST", "/api/auth/account-login", "", map[string]any{
		"email":    "sita@example.com",
		"password": "himalaya-tea-strong-2026",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("account-login expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var acctLogin AccountLoginResult
	if err := json.Unmarshal(rec.Body.Bytes(), &acctLogin); err != nil {
		t.Fatalf("decode account-login: %v", err)
	}
	if acctLogin.Membership != nil {
		t.Fatalf("expected nil membership before store creation, got %+v", acctLogin.Membership)
	}

	// Token confusion check: Account JWT rejected on device route
	rec = doJSON(t, handler, "GET", "/api/stores/current", acctLogin.AccessToken, nil)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("account token on device route expected 401, got %d", rec.Code)
	}

	// 3. Owner creates Store A -> auto-enrolls device 01 + returns Device JWT
	rec = doJSON(t, handler, "POST", "/api/stores", acctLogin.AccessToken, map[string]any{
		"store_name":  "Pasal Alpha",
		"pan_number":  "123456789",
		"phone":       "9800000001",
		"address":     "Kathmandu",
		"device_name": "Owner Pixel",
		"platform":    "ANDROID",
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("create store expected 201, got %d: %s", rec.Code, rec.Body.String())
	}
	var storeRes CreateStoreResult
	if err := json.Unmarshal(rec.Body.Bytes(), &storeRes); err != nil {
		t.Fatalf("decode create store: %v", err)
	}
	ownerDevTok := storeRes.AccessToken
	if storeRes.Device.Code != "01" || storeRes.Device.Status != "ACTIVE" {
		t.Fatalf("expected device 01 ACTIVE, got %+v", storeRes.Device)
	}

	// Token confusion check: Device JWT rejected on account route
	rec = doJSON(t, handler, "POST", "/api/stores", ownerDevTok, map[string]any{
		"store_name": "Should Fail", "device_name": "X", "platform": "ANDROID",
	})
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("device token on account route expected 401, got %d", rec.Code)
	}

	// Update store profile
	rec = doJSON(t, handler, "PATCH", "/api/stores/current", ownerDevTok, map[string]any{
		"name": "Pasal Alpha Updated",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("update store expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	// 4. Owner creates email-bound invitation for Staff
	staffEmail := "ram.staff@example.com"
	rec = doJSON(t, handler, "POST", "/api/stores/current/invitations", ownerDevTok, map[string]any{
		"role":          "STAFF",
		"invited_email": staffEmail,
		"send_email":    true,
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("create invitation expected 201, got %d: %s", rec.Code, rec.Body.String())
	}
	var invWrap struct {
		Invitation InvitationInfo `json:"invitation"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &invWrap)
	inviteCode := invWrap.Invitation.Code
	if inviteCode == "" {
		t.Fatal("expected invite code on creation")
	}

	// GET invitations must NOT expose code
	rec = doJSON(t, handler, "GET", "/api/stores/current/invitations", ownerDevTok, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("list invitations expected 200, got %d", rec.Code)
	}
	if bytes.Contains(rec.Body.Bytes(), []byte(inviteCode)) {
		t.Fatal("GET invitations leaked plaintext invite code")
	}

	// 5. Staff signs up, verifies email, logs into account
	staffAcctTok, staffID := signupVerifyLogin(t, handler, mailer, "Ram Bahadur", staffEmail, "ram_staff", "pokhara-lake-pass-2026", "593821")
	otherAcctTok, _ := signupVerifyLogin(t, handler, mailer, "Other User", "other@example.com", "other_user", "everest-peak-pass-2026", "739182")

	// Wrong email cannot accept email-bound invite
	rec = doJSON(t, handler, "POST", "/api/invitations/accept", otherAcctTok, map[string]any{
		"code": inviteCode, "device_name": "Other Phone", "platform": "ANDROID",
	})
	if rec.Code != http.StatusForbidden {
		t.Fatalf("wrong-email accept expected 403, got %d: %s", rec.Code, rec.Body.String())
	}

	// Staff accepts invite -> PENDING device
	rec = doJSON(t, handler, "POST", "/api/invitations/accept", staffAcctTok, map[string]any{
		"code": inviteCode, "device_name": "Staff Redmi", "platform": "ANDROID",
	})
	if rec.Code != http.StatusAccepted {
		t.Fatalf("accept invite expected 202, got %d: %s", rec.Code, rec.Body.String())
	}
	var devStatus DeviceStatusResult
	_ = json.Unmarshal(rec.Body.Bytes(), &devStatus)
	if devStatus.Status != "PENDING" {
		t.Fatalf("expected PENDING status, got %s", devStatus.Status)
	}

	// Staff cannot log in via PIN before Owner approves
	rec = doJSON(t, handler, "POST", "/api/auth/login", "", map[string]any{
		"username": "ram_staff", "pin": "593821", "device_id": devStatus.DeviceID,
	})
	if rec.Code != http.StatusUnauthorized || !bytes.Contains(rec.Body.Bytes(), []byte(CodeDeviceNotActive)) {
		t.Fatalf("PIN login on PENDING device expected 401 DEVICE_NOT_ACTIVE, got %d: %s", rec.Code, rec.Body.String())
	}

	// Owner sees PENDING device and approves it
	rec = doJSON(t, handler, "GET", "/api/stores/current/devices?status=PENDING", ownerDevTok, nil)
	if rec.Code != http.StatusOK || !bytes.Contains(rec.Body.Bytes(), []byte(devStatus.DeviceID)) {
		t.Fatalf("owner list pending devices failed: %d %s", rec.Code, rec.Body.String())
	}
	rec = doJSON(t, handler, "POST", "/api/stores/current/devices/"+devStatus.DeviceID+"/approve", ownerDevTok, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("approve device expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	// Staff polls status -> ACTIVE, code 02
	rec = doJSON(t, handler, "GET", "/api/devices/me/status?device_id="+devStatus.DeviceID, staffAcctTok, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("device status poll expected 200, got %d", rec.Code)
	}
	var polled DeviceStatusResult
	_ = json.Unmarshal(rec.Body.Bytes(), &polled)
	if polled.Status != "ACTIVE" || polled.DeviceCode == nil || *polled.DeviceCode != "02" {
		t.Fatalf("expected ACTIVE 02, got %+v", polled)
	}

	// Staff logs in via Username + PIN -> gets Device JWT
	rec = doJSON(t, handler, "POST", "/api/auth/login", "", map[string]any{
		"username": "ram_staff", "pin": "593821", "device_id": devStatus.DeviceID,
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("staff PIN login expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var staffLogin LoginResult
	_ = json.Unmarshal(rec.Body.Bytes(), &staffLogin)

	// 6. Owner promotes Staff -> MANAGER, resets PIN, then removes Staff mid-shift
	rec = doJSON(t, handler, "PATCH", "/api/stores/current/members/"+staffID, ownerDevTok, map[string]any{
		"role": "MANAGER",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("update role expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	// Seed an ACTIVE register_shift + staff_shift_session for Staff
	ctx := context.Background()
	shiftID := uuid.NewString()
	sessID := uuid.NewString()
	if err := db.WithTenantTx(ctx, appPool, storeRes.Store.ID, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `
			INSERT INTO register_shifts (id, store_id, opened_by_user_id, opening_float, expected_cash, status)
			VALUES ($1, $2, $3, 1000, 1000, 'OPEN')`, shiftID, storeRes.Store.ID, storeRes.User.ID); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `
			INSERT INTO staff_shift_sessions (id, store_id, register_shift_id, user_id, device_id, device_code, status)
			VALUES ($1, $2, $3, $4, $5, '02', 'ACTIVE')`,
			sessID, storeRes.Store.ID, shiftID, staffID, devStatus.DeviceID)
		return err
	}); err != nil {
		t.Fatalf("seed shift session: %v", err)
	}

	// Owner removes Staff -> membership REMOVED, device REVOKED, shift FORCE_CLOSED
	rec = doJSON(t, handler, "DELETE", "/api/stores/current/members/"+staffID, ownerDevTok, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("remove member expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var sessStatus string
	if err := db.WithTenantTx(ctx, appPool, storeRes.Store.ID, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT status FROM staff_shift_sessions WHERE id = $1`, sessID).Scan(&sessStatus)
	}); err != nil || sessStatus != "FORCE_CLOSED" {
		t.Fatalf("expected staff_shift_session FORCE_CLOSED, got %q err=%v", sessStatus, err)
	}

	// Staff's Device JWT is immediately rejected
	rec = doJSON(t, handler, "GET", "/api/auth/heartbeat", staffLogin.AccessToken, nil)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("removed member heartbeat expected 401, got %d: %s", rec.Code, rec.Body.String())
	}

	// 7. Owner cannot leave store
	rec = doJSON(t, handler, "POST", "/api/stores/current/leave", ownerDevTok, map[string]any{
		"outbox_empty": true,
	})
	if rec.Code != http.StatusConflict {
		t.Fatalf("owner leave expected 409, got %d: %s", rec.Code, rec.Body.String())
	}

	// 8. Export store, close store, delete account, public /delete-account page
	rec = doJSON(t, handler, "GET", "/api/stores/current/export", ownerDevTok, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("export store expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	rec = doJSON(t, handler, "POST", "/api/stores/current/close", ownerDevTok, map[string]any{
		"password": "himalaya-tea-strong-2026",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("close store expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	// Refresh owner account token (token_version was bumped on store close!) and delete account
	rec = doJSON(t, handler, "POST", "/api/auth/account-login", "", map[string]any{
		"email": "sita@example.com", "password": "himalaya-tea-strong-2026",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("owner re-login expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var acctLogin2 AccountLoginResult
	_ = json.Unmarshal(rec.Body.Bytes(), &acctLogin2)

	rec = doJSON(t, handler, "DELETE", "/api/account", acctLogin2.AccessToken, map[string]any{
		"password": "himalaya-tea-strong-2026",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("delete account expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	rec = doJSON(t, handler, "GET", "/delete-account", "", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /delete-account expected 200, got %d", rec.Code)
	}
}

func TestGateB_ConcurrentInviteRaceAndLimiter(t *testing.T) {
	_, _, mailer, handler, cleanup := newPhase2TestApp(t)
	defer cleanup()

	ownerTok, _ := signupVerifyLogin(t, handler, mailer, "Owner Race", "ownerrace@example.com", "owner_race", "annapurna-base-2026", "482913")
	rec := doJSON(t, handler, "POST", "/api/stores", ownerTok, map[string]any{
		"store_name": "Race Store", "device_name": "Dev1", "platform": "ANDROID",
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("create store: %d %s", rec.Code, rec.Body.String())
	}
	var storeRes CreateStoreResult
	_ = json.Unmarshal(rec.Body.Bytes(), &storeRes)

	rec = doJSON(t, handler, "POST", "/api/stores/current/invitations", storeRes.AccessToken, map[string]any{
		"role": "STAFF",
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("create invite: %d %s", rec.Code, rec.Body.String())
	}
	var invWrap struct {
		Invitation InvitationInfo `json:"invitation"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &invWrap)

	u1Tok, _ := signupVerifyLogin(t, handler, mailer, "Racer One", "racer1@example.com", "racer_one", "langtang-valley-2026", "482913")
	u2Tok, _ := signupVerifyLogin(t, handler, mailer, "Racer Two", "racer2@example.com", "racer_two", "mustang-trail-2026", "593821")

	// Race 2 users accepting the single-use invite concurrently -> exactly 1 succeeds
	var wg sync.WaitGroup
	codes := make([]int, 2)
	for i, tok := range []string{u1Tok, u2Tok} {
		wg.Add(1)
		go func(idx int, tkn string) {
			defer wg.Done()
			r := doJSON(t, handler, "POST", "/api/invitations/accept", tkn, map[string]any{
				"code": invWrap.Invitation.Code, "device_name": "Phone", "platform": "ANDROID",
			})
			codes[idx] = r.Code
		}(i, tok)
	}
	wg.Wait()
	accepted := 0
	for _, c := range codes {
		if c == http.StatusAccepted {
			accepted++
		}
	}
	if accepted != 1 {
		t.Fatalf("expected exactly 1 concurrent invite accept to succeed, got %v", codes)
	}

	// Per-account invite limiter (5/15m) -> 6th bad attempt returns 429 RATE_LIMITED
	u3Tok, _ := signupVerifyLogin(t, handler, mailer, "Limiter User", "limit@example.com", "limit_user", "bhaktapur-square-2026", "482913")
	for i := 0; i < 5; i++ {
		r := doJSON(t, handler, "POST", "/api/invitations/accept", u3Tok, map[string]any{
			"code": "PSX-23456-789AB", "device_name": "Phone", "platform": "ANDROID",
		})
		if r.Code != http.StatusBadRequest {
			t.Fatalf("attempt %d expected 400, got %d: %s", i+1, r.Code, r.Body.String())
		}
	}
	r6 := doJSON(t, handler, "POST", "/api/invitations/accept", u3Tok, map[string]any{
		"code": "PSX-23456-789AB", "device_name": "Phone", "platform": "ANDROID",
	})
	if r6.Code != http.StatusTooManyRequests {
		t.Fatalf("6th attempt expected 429 RATE_LIMITED, got %d: %s", r6.Code, r6.Body.String())
	}
}

func TestOwnerEnrollDeviceAutoApproves(t *testing.T) {
	_, _, mailer, handler, cleanup := newPhase2TestApp(t)
	defer cleanup()

	ownerTok, _ := signupVerifyLogin(t, handler, mailer, "Owner ReEnroll", "owner_reenroll@example.com", "owner_reenroll", "kathmandu-valley-2026", "482913")
	rec := doJSON(t, handler, "POST", "/api/stores", ownerTok, map[string]any{
		"store_name": "ReEnroll Mart", "device_name": "Phone 1", "platform": "ANDROID",
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("create store: %d %s", rec.Code, rec.Body.String())
	}

	// Owner clears app data / logs in on a replacement phone and calls /api/devices/enroll
	rec = doJSON(t, handler, "POST", "/api/devices/enroll", ownerTok, map[string]any{
		"device_name": "Replacement Phone", "platform": "ANDROID",
	})
	if rec.Code != http.StatusAccepted {
		t.Fatalf("owner enroll expected 202, got %d: %s", rec.Code, rec.Body.String())
	}
	var dev DeviceStatusResult
	if err := json.Unmarshal(rec.Body.Bytes(), &dev); err != nil {
		t.Fatalf("decode owner enroll: %v", err)
	}
	if dev.Status != "ACTIVE" {
		t.Fatalf("owner enroll expected ACTIVE, got %q", dev.Status)
	}
	if dev.DeviceCode == nil || *dev.DeviceCode != "02" {
		t.Fatalf("owner enroll expected device_code=02, got %v", dev.DeviceCode)
	}

	// Verify the auto-approved device can immediately log in with PIN
	rec = doJSON(t, handler, "POST", "/api/auth/login", "", map[string]any{
		"username": "owner_reenroll", "pin": "482913", "device_id": dev.DeviceID,
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("login on auto-approved owner device expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
}

func signupVerifyLogin(t *testing.T, handler http.Handler, mailer *pmail.LogMailer, name, email, username, password, pin string) (string, string) {
	t.Helper()
	rec := doJSON(t, handler, "POST", "/api/auth/signup", "", map[string]any{
		"name": name, "email": email, "username": username, "password": password, "pin": pin,
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("signup %s: %d %s", email, rec.Code, rec.Body.String())
	}
	var sr SignupResult
	_ = json.Unmarshal(rec.Body.Bytes(), &sr)

	sent := mailer.Sent()
	code := extractSixDigitCode(t, sent[len(sent)-1].TextBody)

	rec = doJSON(t, handler, "POST", "/api/auth/verify-email", "", map[string]any{
		"email": email, "code": code,
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("verify %s: %d %s", email, rec.Code, rec.Body.String())
	}

	rec = doJSON(t, handler, "POST", "/api/auth/account-login", "", map[string]any{
		"email": email, "password": password,
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("account-login %s: %d %s", email, rec.Code, rec.Body.String())
	}
	var lr AccountLoginResult
	_ = json.Unmarshal(rec.Body.Bytes(), &lr)
	return lr.AccessToken, sr.User.ID
}
