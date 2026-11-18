package auth

import (
	"bytes"
	"errors"
	"testing"
	"time"
)

func TestTokenConfusionBlocked(t *testing.T) {
	master := bytes.Repeat([]byte{0x42}, 32)
	k, err := NewKeys(master)
	if err != nil {
		t.Fatalf("NewKeys: %v", err)
	}
	if bytes.Equal(k.jwt, k.accountJWT) {
		t.Fatal("device JWT key and account JWT key must be distinct")
	}

	now := time.Now().UTC()
	devTok, err := k.IssueToken(Session{
		UserID: "u1", StoreID: "s1", Role: RoleOwner, DeviceID: "d1", DeviceCode: "01",
		LeaseID: "l1", TokenVersion: 1, ExpiresAt: now.Add(LeaseDuration),
	}, now)
	if err != nil {
		t.Fatalf("IssueToken: %v", err)
	}
	acctTok, _, err := k.IssueAccountToken("u1", 1, now)
	if err != nil {
		t.Fatalf("IssueAccountToken: %v", err)
	}

	if _, err := k.ParseAccountToken(devTok, now); !errors.Is(err, ErrTokenInvalid) {
		t.Fatalf("expected ErrTokenInvalid when device token passed to ParseAccountToken, got %v", err)
	}
	if _, err := k.ParseToken(acctTok, now); !errors.Is(err, ErrTokenInvalid) {
		t.Fatalf("expected ErrTokenInvalid when account token passed to ParseToken, got %v", err)
	}

	parsed, err := k.ParseAccountToken(acctTok, now)
	if err != nil || parsed.UserID != "u1" || parsed.TokenVersion != 1 {
		t.Fatalf("ParseAccountToken failed: %+v, err=%v", parsed, err)
	}
	if _, err := k.ParseAccountToken(acctTok, now.Add(AccountTokenTTL+time.Second)); !errors.Is(err, ErrTokenExpired) {
		t.Fatalf("expected ErrTokenExpired after TTL, got %v", err)
	}
}

func TestSignupPasswordAndPINValidation(t *testing.T) {
	if err := ValidateSignupPassword("short123", "alice", "alice@example.com"); err == nil {
		t.Fatal("expected <10 char password to fail")
	}
	if err := ValidateSignupPassword("password123", "alice", "alice@example.com"); err == nil {
		t.Fatal("expected common password to fail")
	}
	if err := ValidateSignupPassword("myalicepass99", "alice", "alice@example.com"); err == nil {
		t.Fatal("expected password containing username to fail")
	}
	if err := ValidateSignupPassword("katmandu-tea-2026!", "alice", "alice@example.com"); err != nil {
		t.Fatalf("expected strong password to pass, got %v", err)
	}

	for _, bad := range []string{"12345", "000000", "777777", "123456", "654321", "121212"} {
		if err := ValidateSignupPIN(bad); err == nil {
			t.Fatalf("expected trivial PIN %q to fail", bad)
		}
	}
	if err := ValidateSignupPIN("482913"); err != nil {
		t.Fatalf("expected valid PIN to pass, got %v", err)
	}
}

func TestInviteCodeGenerationAndNormalization(t *testing.T) {
	raw, formatted, hash, err := generateInviteCode()
	if err != nil {
		t.Fatalf("generateInviteCode: %v", err)
	}
	if len(raw) != 10 || len(hash) != 32 {
		t.Fatalf("unexpected lengths: raw=%d hash=%d", len(raw), len(hash))
	}
	if len(formatted) != 15 || formatted[:4] != "PSX-" {
		t.Fatalf("unexpected formatted code %q", formatted)
	}
	for _, ch := range raw {
		if ch == '0' || ch == 'O' || ch == '1' || ch == 'I' {
			t.Fatalf("ambiguous char %c in invite code %q", ch, raw)
		}
	}
	if norm := normalizeInviteCode(" psx-" + raw[:5] + " - " + raw[5:] + " "); norm != raw {
		t.Fatalf("normalizeInviteCode mismatch: got %q want %q", norm, raw)
	}
}

func TestSlidingWindowRateLimiter(t *testing.T) {
	rl := newRateLimiter(3, time.Minute)
	now := time.Now().UTC()
	for i := 0; i < 3; i++ {
		if ok, _ := rl.Allow("k1", now); !ok {
			t.Fatalf("attempt %d should be allowed", i+1)
		}
	}
	if ok, wait := rl.Allow("k1", now); ok || wait <= 0 {
		t.Fatalf("4th attempt should be blocked with positive wait, got ok=%v wait=%v", ok, wait)
	}
	if ok, _ := rl.Allow("k1", now.Add(61*time.Second)); !ok {
		t.Fatal("attempt after window should be allowed")
	}
}

