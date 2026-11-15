package auth

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/crypto/bcrypt"
)

func testKeys(t *testing.T, seed byte) *Keys {
	t.Helper()
	k, err := NewKeys(bytes.Repeat([]byte{seed}, 32))
	if err != nil {
		t.Fatalf("NewKeys: %v", err)
	}
	return k
}

// ---------------------------------------------------------------- keys

func TestNewKeys_RejectsShortMaster(t *testing.T) {
	if _, err := NewKeys(make([]byte, 31)); err == nil {
		t.Fatal("expected error for 31-byte master key")
	}
}

func TestNewKeys_DomainSeparatedAndDeterministic(t *testing.T) {
	a, b := testKeys(t, 7), testKeys(t, 7)
	if !bytes.Equal(a.jwt, b.jwt) || !bytes.Equal(a.kekRoot, b.kekRoot) || !bytes.Equal(a.dekAtRest, b.dekAtRest) {
		t.Fatal("derivation must be deterministic")
	}
	if bytes.Equal(a.jwt, a.kekRoot) || bytes.Equal(a.jwt, a.dekAtRest) || bytes.Equal(a.kekRoot, a.dekAtRest) {
		t.Fatal("subkeys must differ (domain separation)")
	}
	if c := testKeys(t, 8); bytes.Equal(a.jwt, c.jwt) {
		t.Fatal("different master keys must give different subkeys")
	}
}

func TestLoadKeysFromEnv(t *testing.T) {
	t.Setenv(MasterKeyEnv, "")
	if _, err := LoadKeysFromEnv(); err == nil {
		t.Fatal("expected error when master key unset (no insecure default)")
	}
	t.Setenv(MasterKeyEnv, "not base64 !!")
	if _, err := LoadKeysFromEnv(); err == nil {
		t.Fatal("expected error for invalid base64")
	}
	t.Setenv(MasterKeyEnv, base64.StdEncoding.EncodeToString(make([]byte, 16)))
	if _, err := LoadKeysFromEnv(); err == nil {
		t.Fatal("expected error for 16-byte key")
	}
	t.Setenv(MasterKeyEnv, base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32)))
	if _, err := LoadKeysFromEnv(); err != nil {
		t.Fatalf("valid key rejected: %v", err)
	}
}

// ---------------------------------------------------------------- argon2id

func TestHashSecret_RoundTrip(t *testing.T) {
	ctx := context.Background()
	h, err := HashSecret("S3cure!pass")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(h, "$argon2id$v=19$m=19456,t=2,p=1$") {
		t.Fatalf("unexpected PHC prefix: %s", h)
	}
	if ok, err := VerifySecret(ctx, "S3cure!pass", h); err != nil || !ok {
		t.Fatalf("correct secret rejected: ok=%v err=%v", ok, err)
	}
	if ok, _ := VerifySecret(ctx, "S3cure!pasS", h); ok {
		t.Fatal("wrong secret accepted")
	}
	h2, _ := HashSecret("S3cure!pass")
	if h == h2 {
		t.Fatal("hashes of same secret must differ (random salt)")
	}
}

func TestVerifySecret_BcryptCompatibility(t *testing.T) {
	ctx := context.Background()
	bh, err := bcrypt.GenerateFromPassword([]byte("LegacyPass#9"), bcrypt.DefaultCost)
	if err != nil {
		t.Fatal(err)
	}
	if ok, err := VerifySecret(ctx, "LegacyPass#9", string(bh)); err != nil || !ok {
		t.Fatalf("valid bcrypt secret rejected: ok=%v err=%v", ok, err)
	}
	if ok, err := VerifySecret(ctx, "WrongPass#9", string(bh)); err != nil || ok {
		t.Fatalf("wrong bcrypt secret result: ok=%v err=%v", ok, err)
	}
}

func TestVerifySecret_MalformedHashes(t *testing.T) {
	salt := base64.RawStdEncoding.EncodeToString(make([]byte, 16))
	sum := base64.RawStdEncoding.EncodeToString(make([]byte, 32))
	cases := []string{
		"",
		"plaintext",
		"$2a$10$notavalidbcrypthash",
		"$2a$25$R9h/cIPz0gi.URNNX3kh2OPST9/PgBkqquzi.Ss7KIUgO2t0jWMUW", // cost=25 CPU bomb
		"$argon2i$v=19$m=19456,t=2,p=1$" + salt + "$" + sum,
		"$argon2id$v=16$m=19456,t=2,p=1$" + salt + "$" + sum,
		"$argon2id$v=19$m=9999999,t=2,p=1$" + salt + "$" + sum, // memory bomb
		"$argon2id$v=19$m=19456,t=99,p=1$" + salt + "$" + sum,  // CPU bomb
		"$argon2id$v=19$m=19456,t=2,p=1$!!$" + sum,
		"$argon2id$v=19$m=19456,t=2,p=1$" + salt + "$short",
	}
	for _, c := range cases {
		if ok, err := VerifySecret(context.Background(), "x", c); ok || !errors.Is(err, ErrMalformedHash) {
			t.Errorf("hash %q: ok=%v err=%v, want ErrMalformedHash", c, ok, err)
		}
	}
}

func TestValidatePINAndPassword(t *testing.T) {
	for _, p := range []string{"123456", "000000"} {
		if ValidatePIN(p) != nil {
			t.Errorf("PIN %q should be valid", p)
		}
	}
	for _, p := range []string{"", "12345", "1234567", "12a456", " 123456", "१२३४५६"} {
		if ValidatePIN(p) == nil {
			t.Errorf("PIN %q should be invalid", p)
		}
	}
	if ValidatePassword("short") == nil || ValidatePassword(strings.Repeat("a", 129)) == nil {
		t.Error("password length policy not enforced")
	}
	if ValidatePassword("longenough") != nil {
		t.Error("valid password rejected")
	}
}

// ---------------------------------------------------------------- envelope

func TestSealDEK_RoundTripAndDeviceBinding(t *testing.T) {
	k := testKeys(t, 1)
	dek, _ := GenerateDEK()
	sealed, err := k.SealDEK("dev-a", dek)
	if err != nil {
		t.Fatal(err)
	}
	if len(sealed) != sealedDEKSize || bytes.Contains(sealed, dek) {
		t.Fatal("sealed DEK has wrong size or leaks plaintext")
	}
	got, err := k.OpenDEK("dev-a", sealed)
	if err != nil || !bytes.Equal(got, dek) {
		t.Fatalf("OpenDEK round trip failed: %v", err)
	}
	if _, err := k.OpenDEK("dev-b", sealed); !errors.Is(err, ErrSealedDEK) {
		t.Fatal("sealed DEK must be bound to its device id (row-swap attack)")
	}
	if _, err := testKeys(t, 2).OpenDEK("dev-a", sealed); !errors.Is(err, ErrSealedDEK) {
		t.Fatal("different master key must not open sealed DEK")
	}
}

func TestLeaseEnvelope_64BytesAndRoundTrip(t *testing.T) {
	k := testKeys(t, 3)
	dek, _ := GenerateDEK()
	issued := time.Unix(1_800_000_000, 0).UTC()
	exp := issued.Add(LeaseDuration)
	l, err := k.IssueLease("dev-1", "lease-1", issued, exp, dek)
	if err != nil {
		t.Fatal(err)
	}
	if len(l.Envelope) != EnvelopeSize || !bytes.Equal(l.Envelope[:4], []byte{'P', 'X', 1, 0}) {
		t.Fatalf("envelope must be 64 bytes with PX v1 header, got %d bytes % x", len(l.Envelope), l.Envelope[:4])
	}
	if len(l.KEK) != KEKSize || l.ExpiresAt.Sub(l.IssuedAt) != 12*time.Hour {
		t.Fatal("KEK size or 12h lease duration wrong")
	}
	got, err := OpenEnvelope(l.KEK, l.Envelope, "dev-1", "lease-1", exp)
	if err != nil || !bytes.Equal(got, dek) {
		t.Fatalf("unwrap failed: %v", err)
	}
	// Server can re-derive the same KEK without storing it.
	again, _ := k.DeriveKEK("dev-1", "lease-1", exp)
	if !bytes.Equal(again, l.KEK) {
		t.Fatal("KEK must be re-derivable")
	}
}

func TestLeaseEnvelope_TamperAndBindingRejected(t *testing.T) {
	k := testKeys(t, 4)
	dek, _ := GenerateDEK()
	now := time.Unix(1_800_000_000, 0).UTC()
	exp := now.Add(LeaseDuration)
	l, _ := k.IssueLease("dev-1", "lease-1", now, exp, dek)

	for i := range l.Envelope {
		bad := append([]byte{}, l.Envelope...)
		bad[i] ^= 0x01
		if _, err := OpenEnvelope(l.KEK, bad, "dev-1", "lease-1", exp); !errors.Is(err, ErrEnvelopeInvalid) {
			t.Fatalf("bit flip at byte %d not detected", i)
		}
	}
	checks := []struct {
		name, dev, lease string
		exp              time.Time
	}{
		{"other device", "dev-2", "lease-1", exp},
		{"other lease", "dev-1", "lease-2", exp},
		{"extended expiry +1s", "dev-1", "lease-1", exp.Add(time.Second)},
	}
	for _, c := range checks {
		if _, err := OpenEnvelope(l.KEK, l.Envelope, c.dev, c.lease, c.exp); !errors.Is(err, ErrEnvelopeInvalid) {
			t.Errorf("%s: envelope must not open", c.name)
		}
	}
	l2, _ := k.IssueLease("dev-1", "lease-2", now, exp, dek)
	if bytes.Equal(l.KEK, l2.KEK) {
		t.Fatal("each lease must get a distinct KEK")
	}
	if _, err := OpenEnvelope(l2.KEK, l.Envelope, "dev-1", "lease-1", exp); err == nil {
		t.Fatal("KEK from another lease must not open envelope")
	}
}

// ---------------------------------------------------------------- jwt

func testSession(exp time.Time) Session {
	return Session{UserID: "u1", Role: RoleStaff, DeviceID: "d1", DeviceCode: "01", LeaseID: "l1", ExpiresAt: exp}
}

func TestJWT_RoundTripAndExpiry(t *testing.T) {
	k := testKeys(t, 5)
	now := time.Now().UTC().Truncate(time.Second)
	tok, err := k.IssueToken(testSession(now.Add(LeaseDuration)), now)
	if err != nil {
		t.Fatal(err)
	}
	s, err := k.ParseToken(tok, now.Add(time.Hour))
	if err != nil || s.UserID != "u1" || s.DeviceCode != "01" || s.LeaseID != "l1" || !s.ExpiresAt.Equal(now.Add(LeaseDuration)) {
		t.Fatalf("parse failed: %+v %v", s, err)
	}
	if _, err := k.ParseToken(tok, now.Add(LeaseDuration+time.Second)); !errors.Is(err, ErrTokenExpired) {
		t.Fatalf("want ErrTokenExpired after 12h, got %v", err)
	}
	if s, err := k.parseTokenIgnoringTime(tok); err != nil || s.DeviceID != "d1" {
		t.Fatalf("parseTokenIgnoringTime should read expired token's device: %v", err)
	}
}

func TestJWT_RejectsForgeries(t *testing.T) {
	k := testKeys(t, 6)
	now := time.Now().UTC()
	tok, _ := k.IssueToken(testSession(now.Add(time.Hour)), now)

	if _, err := testKeys(t, 9).ParseToken(tok, now); !errors.Is(err, ErrTokenInvalid) {
		t.Error("token signed by another key accepted")
	}
	parts := strings.Split(tok, ".")
	tampered := parts[0] + "." + parts[1] + "x." + parts[2]
	if _, err := k.ParseToken(tampered, now); err == nil {
		t.Error("tampered payload accepted")
	}

	claims := Claims{Role: RoleOwner, DeviceID: "d1", LeaseID: "l1", RegisteredClaims: jwt.RegisteredClaims{
		Issuer: jwtIssuer, Subject: "attacker", Audience: jwt.ClaimStrings{jwtAudience},
		IssuedAt: jwt.NewNumericDate(now), ExpiresAt: jwt.NewNumericDate(now.Add(time.Hour)),
	}}
	none, _ := jwt.NewWithClaims(jwt.SigningMethodNone, claims).SignedString(jwt.UnsafeAllowNoneSignatureType)
	if _, err := k.ParseToken(none, now); err == nil {
		t.Error(`alg "none" token accepted`)
	}
	hs512, _ := jwt.NewWithClaims(jwt.SigningMethodHS512, claims).SignedString(k.jwt)
	if _, err := k.ParseToken(hs512, now); err == nil {
		t.Error("non-HS256 algorithm accepted")
	}
	wrongAud := claims
	wrongAud.Audience = jwt.ClaimStrings{"someone-else"}
	wa, _ := jwt.NewWithClaims(jwt.SigningMethodHS256, wrongAud).SignedString(k.jwt)
	if _, err := k.ParseToken(wa, now); err == nil {
		t.Error("wrong audience accepted")
	}
	noExp := claims
	noExp.ExpiresAt = nil
	ne, _ := jwt.NewWithClaims(jwt.SigningMethodHS256, noExp).SignedString(k.jwt)
	if _, err := k.ParseToken(ne, now); err == nil {
		t.Error("token without exp accepted")
	}
	badRole := claims
	badRole.Role = "SUPERUSER"
	br, _ := jwt.NewWithClaims(jwt.SigningMethodHS256, badRole).SignedString(k.jwt)
	if _, err := k.ParseToken(br, now); err == nil {
		t.Error("unknown role accepted")
	}
}

// ---------------------------------------------------------------- limiter

func TestFailureLimiter(t *testing.T) {
	l := newFailureLimiter(3, time.Minute, 5*time.Minute, true)
	t0 := time.Unix(0, 0)
	l.Fail("k", t0)
	l.Fail("k", t0)
	if b, _ := l.Blocked("k", t0); b {
		t.Fatal("blocked too early")
	}
	if !l.Fail("k", t0) {
		t.Fatal("3rd failure should trigger lockout")
	}
	if b, wait := l.Blocked("k", t0.Add(time.Minute)); !b || wait != 4*time.Minute {
		t.Fatalf("expected 4m remaining lockout, got blocked=%v wait=%v", b, wait)
	}
	if b, _ := l.Blocked("k", t0.Add(5*time.Minute)); b {
		t.Fatal("lockout should expire")
	}
	l.Fail("w", t0)
	l.Fail("w", t0)
	l.Fail("w", t0.Add(2*time.Minute)) // window expired => counter restarts
	if b, _ := l.Blocked("w", t0.Add(2*time.Minute)); b {
		t.Fatal("failures outside window must not accumulate")
	}
	l.Fail("r", t0)
	l.Fail("r", t0)
	l.Reset("r")
	l.Fail("r", t0)
	if b, _ := l.Blocked("r", t0); b {
		t.Fatal("Reset must clear failures")
	}

	// Inflight TOCTOU guard: max*2 (6) concurrent Acquire calls saturate inflight cap immediately.
	var rels []func(attemptOutcome)
	for i := 0; i < 6; i++ {
		b, _, rel := l.Acquire("burst", t0)
		if b {
			t.Fatalf("inflight %d should be allowed", i+1)
		}
		rels = append(rels, rel)
	}
	if b, _, _ := l.Acquire("burst", t0); !b {
		t.Fatal("7th concurrent inflight request must be rejected immediately")
	}
	rels[0](outcomeFailure)
	rels[1](outcomeFailure)
	// Aborted attempts preserve existing failures (count=2), while success clears bucket.
	rels[2](outcomeAborted)
	if l.entries["burst"] == nil || l.entries["burst"].count != 2 {
		t.Fatalf("outcomeAborted must preserve failure count=2, got %+v", l.entries["burst"])
	}
	for _, rel := range rels[3:] {
		rel(outcomeSuccess)
	}
	if b, _ := l.Blocked("burst", t0); b {
		t.Fatal("resetOnSuccess should clear bucket when inflight drains")
	}

	// Bounded memory cap: spraying >maxItems fresh keys never exceeds maxItems.
	bounded := newFailureLimiter(5, 15*time.Minute, 15*time.Minute, true)
	bounded.maxItems = 50
	for i := 0; i < 200; i++ {
		bounded.Fail(fmt.Sprintf("spray-%d", i), t0)
		if len(bounded.entries) > bounded.maxItems {
			t.Fatalf("limiter exceeded maxItems: %d > %d", len(bounded.entries), bounded.maxItems)
		}
	}
}

func TestClientIP_RightmostXFFAndSpoofDefense(t *testing.T) {
	h := &Handler{trustProxy: true}
	req := &http.Request{
		RemoteAddr: "10.0.0.1:4321",
		Header:     http.Header{"X-Forwarded-For": []string{"spoofed-by-client, 198.51.100.7, 203.0.113.42"}},
	}
	if got := h.clientIP(req); got != "203.0.113.42" {
		t.Fatalf("expected rightmost proxy IP 203.0.113.42, got %q", got)
	}
	req.Header.Set("X-Forwarded-For", "not-an-ip, ;;drop table")
	req.Header.Set("X-Real-IP", "192.0.2.99")
	if got := h.clientIP(req); got != "192.0.2.99" {
		t.Fatalf("expected fallback to valid X-Real-IP, got %q", got)
	}
	if tok, ok := extractBearer("bearer my-jwt-token"); !ok || tok != "my-jwt-token" {
		t.Fatalf("case-insensitive bearer extraction failed: ok=%v tok=%q", ok, tok)
	}
}

