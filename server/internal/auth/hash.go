package auth

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"golang.org/x/crypto/argon2"
	"golang.org/x/crypto/bcrypt"
)

// Argon2id parameters sized for the GCP e2-micro (1 GB RAM) budget.
// OWASP 2024 minimum profile: m=19 MiB, t=2, p=1. Combined with hashSlots
// (max 2 concurrent hashes) peak hashing RAM is bounded to ~38 MiB.
const (
	argonMemoryKiB uint32 = 19 * 1024
	argonTime      uint32 = 2
	argonThreads   uint8  = 1
	argonKeyLen    uint32 = 32
	argonSaltLen          = 16

	// Upper bounds accepted when parsing stored hashes (defence against a
	// tampered row forcing huge allocations).
	maxArgonMemoryKiB uint32 = 256 * 1024
	maxArgonTime      uint32 = 10
	maxBcryptCost     int    = 16
	hashSlotTimeout          = 5 * time.Second
)

var (
	ErrWeakPassword   = errors.New("password must be 8-128 characters")
	ErrInvalidPINForm = errors.New("PIN must be exactly 6 digits")
	ErrMalformedHash  = errors.New("malformed password hash")
	ErrHashBusy       = errors.New("authentication server busy")

	pinPattern = regexp.MustCompile(`^[0-9]{6}$`)

	// hashSlots caps concurrent Argon2id computations (RAM + CPU guard).
	hashSlots = make(chan struct{}, 2)

	// dummyHash is verified against when a username does not exist so that
	// response timing does not reveal which usernames are valid.
	dummyHash = mustHash("pasalx-timing-equaliser")
)

// ValidatePassword enforces the minimum password policy.
func ValidatePassword(pw string) error {
	if n := len(pw); n < 8 || n > 128 {
		return ErrWeakPassword
	}
	return nil
}

// ValidatePIN enforces the 6-digit staff PIN format.
func ValidatePIN(pin string) error {
	if !pinPattern.MatchString(pin) {
		return ErrInvalidPINForm
	}
	return nil
}

// HashSecret returns a PHC-formatted Argon2id hash:
// $argon2id$v=19$m=19456,t=2,p=1$<salt b64>$<hash b64>
func HashSecret(secret string) (string, error) {
	salt := make([]byte, argonSaltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", fmt.Errorf("salt generation failed: %w", err)
	}
	hashSlots <- struct{}{}
	key := argon2.IDKey([]byte(secret), salt, argonTime, argonMemoryKiB, argonThreads, argonKeyLen)
	<-hashSlots
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version, argonMemoryKiB, argonTime, argonThreads,
		base64.RawStdEncoding.EncodeToString(salt),
		base64.RawStdEncoding.EncodeToString(key)), nil
}

// VerifySecret checks secret against a PHC Argon2id hash (or legacy/migrated
// Bcrypt $2a$/$2b$/$2y$ hash per TECHNICAL_SPEC.md §4) in constant time.
// The context lets callers abandon waiting for a hashing slot.
func VerifySecret(ctx context.Context, secret, encoded string) (bool, error) {
	if isBcryptPrefix(encoded) {
		return verifyBcrypt(ctx, secret, encoded)
	}
	p, salt, want, err := parsePHC(encoded)
	if err != nil {
		return false, err
	}
	if err := acquireHashSlot(ctx); err != nil {
		return false, err
	}
	got := argon2.IDKey([]byte(secret), salt, p.time, p.memory, p.threads, uint32(len(want)))
	<-hashSlots
	return subtle.ConstantTimeCompare(got, want) == 1, nil
}

func isBcryptPrefix(s string) bool {
	return strings.HasPrefix(s, "$2a$") || strings.HasPrefix(s, "$2b$") || strings.HasPrefix(s, "$2y$")
}

func verifyBcrypt(ctx context.Context, secret, encoded string) (bool, error) {
	cost, err := bcrypt.Cost([]byte(encoded))
	if err != nil || cost < bcrypt.MinCost || cost > maxBcryptCost {
		return false, ErrMalformedHash
	}
	if err := acquireHashSlot(ctx); err != nil {
		return false, err
	}
	err = bcrypt.CompareHashAndPassword([]byte(encoded), []byte(secret))
	<-hashSlots
	if err == nil {
		return true, nil
	}
	if errors.Is(err, bcrypt.ErrMismatchedHashAndPassword) || errors.Is(err, bcrypt.ErrPasswordTooLong) {
		return false, nil
	}
	return false, ErrMalformedHash
}

func acquireHashSlot(ctx context.Context) error {
	timer := time.NewTimer(hashSlotTimeout)
	defer timer.Stop()
	select {
	case hashSlots <- struct{}{}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return ErrHashBusy
	}
}

type argonParams struct {
	memory  uint32
	time    uint32
	threads uint8
}

func parsePHC(encoded string) (argonParams, []byte, []byte, error) {
	var p argonParams
	parts := strings.Split(encoded, "$")
	// ["", "argon2id", "v=19", "m=..,t=..,p=..", salt, hash]
	if len(parts) != 6 || parts[0] != "" || parts[1] != "argon2id" {
		return p, nil, nil, ErrMalformedHash
	}
	var version int
	if _, err := fmt.Sscanf(parts[2], "v=%d", &version); err != nil || version != argon2.Version {
		return p, nil, nil, ErrMalformedHash
	}
	if _, err := fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &p.memory, &p.time, &p.threads); err != nil {
		return p, nil, nil, ErrMalformedHash
	}
	if p.memory < 8*1024 || p.memory > maxArgonMemoryKiB || p.time < 1 || p.time > maxArgonTime || p.threads < 1 {
		return p, nil, nil, ErrMalformedHash
	}
	salt, err := base64.RawStdEncoding.DecodeString(parts[4])
	if err != nil || len(salt) < 8 {
		return p, nil, nil, ErrMalformedHash
	}
	hash, err := base64.RawStdEncoding.DecodeString(parts[5])
	if err != nil || len(hash) < 16 || len(hash) > 64 {
		return p, nil, nil, ErrMalformedHash
	}
	return p, salt, hash, nil
}

func mustHash(s string) string {
	h, err := HashSecret(s)
	if err != nil {
		panic(err)
	}
	return h
}

