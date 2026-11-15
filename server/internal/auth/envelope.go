package auth

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"fmt"
	"strconv"
	"time"
)

// Two-Key Envelope Encryption (TECHNICAL_SPEC.md §7.2)
//
//	DEK  – 256-bit random key that encrypts the phone's SQLCipher database.
//	       One DEK per registered device. The server keeps it only sealed
//	       under the dek-at-rest subkey (AES-256-GCM, AAD bound to device id).
//	KEK  – 256-bit key valid for one 12-hour lease. Never stored server-side:
//	       re-derivable as HKDF-SHA256(kekRoot, salt=lease_id,
//	       info="pasalx/kek/v1|<device_id>|<expires_unix>").
//
// Lease envelope (exactly 64 bytes, safe to persist on phone flash):
//
//	[0:4]   header  'P' 'X' 0x01 0x00   (magic, version 1, reserved)
//	[4:16]  nonce   96-bit random
//	[16:64] AES-256-GCM(KEK, DEK) ciphertext(32) || tag(16)
//	AAD   = header || "<device_id>|<lease_id>|<expires_unix>"
//
// Because device id, lease id and expiry are authenticated, a phone cannot
// extend its lease or replay another device's envelope: any change makes
// GCM authentication fail.

const (
	DEKSize       = 32
	KEKSize       = 32
	EnvelopeSize  = 64
	LeaseDuration = 12 * time.Hour
	sealedDEKSize = 12 + DEKSize + 16
)

var (
	envelopeHeader = [4]byte{'P', 'X', 0x01, 0x00}

	ErrEnvelopeInvalid = errors.New("lease envelope invalid or tampered")
	ErrSealedDEK       = errors.New("sealed DEK invalid or tampered")
)

// Lease is the 12-hour KEK lease handed to a phone after successful login.
type Lease struct {
	LeaseID   string
	DeviceID  string
	IssuedAt  time.Time
	ExpiresAt time.Time
	KEK       []byte // 32 bytes – phone keeps in RAM / Keystore with TTL only
	Envelope  []byte // 64 bytes – phone may persist on flash
}

// GenerateDEK returns a fresh 256-bit random data encryption key.
func GenerateDEK() ([]byte, error) {
	dek := make([]byte, DEKSize)
	if _, err := rand.Read(dek); err != nil {
		return nil, fmt.Errorf("DEK generation failed: %w", err)
	}
	return dek, nil
}

// SealDEK encrypts a device DEK for storage in device_registrations.dek_sealed.
func (k *Keys) SealDEK(deviceID string, dek []byte) ([]byte, error) {
	if len(dek) != DEKSize {
		return nil, fmt.Errorf("DEK must be %d bytes", DEKSize)
	}
	gcm, err := newGCM(k.dekAtRest)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	return gcm.Seal(nonce, nonce, dek, []byte(infoDEKAtRest+"|"+deviceID)), nil
}

// OpenDEK decrypts a sealed device DEK. Callers must Zero() the result.
func (k *Keys) OpenDEK(deviceID string, sealed []byte) ([]byte, error) {
	if len(sealed) != sealedDEKSize {
		return nil, ErrSealedDEK
	}
	gcm, err := newGCM(k.dekAtRest)
	if err != nil {
		return nil, err
	}
	ns := gcm.NonceSize()
	dek, err := gcm.Open(nil, sealed[:ns], sealed[ns:], []byte(infoDEKAtRest+"|"+deviceID))
	if err != nil {
		return nil, ErrSealedDEK
	}
	return dek, nil
}

// DeriveKEK re-derives the KEK of a lease. Deterministic, so the server
// never has to store KEKs.
func (k *Keys) DeriveKEK(deviceID, leaseID string, expiresAt time.Time) ([]byte, error) {
	info := "pasalx/kek/v1|" + deviceID + "|" + strconv.FormatInt(expiresAt.Unix(), 10)
	return hkdf.Key(sha256.New, k.kekRoot, []byte(leaseID), info, KEKSize)
}

// IssueLease wraps the device DEK under a fresh per-lease KEK.
func (k *Keys) IssueLease(deviceID, leaseID string, issuedAt, expiresAt time.Time, dek []byte) (*Lease, error) {
	if len(dek) != DEKSize {
		return nil, fmt.Errorf("DEK must be %d bytes", DEKSize)
	}
	kek, err := k.DeriveKEK(deviceID, leaseID, expiresAt)
	if err != nil {
		return nil, err
	}
	gcm, err := newGCM(kek)
	if err != nil {
		return nil, err
	}
	env := make([]byte, 0, EnvelopeSize)
	env = append(env, envelopeHeader[:]...)
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	env = append(env, nonce...)
	env = gcm.Seal(env, nonce, dek, envelopeAAD(deviceID, leaseID, expiresAt))
	if len(env) != EnvelopeSize {
		return nil, fmt.Errorf("internal: envelope size %d != %d", len(env), EnvelopeSize)
	}
	return &Lease{
		LeaseID:   leaseID,
		DeviceID:  deviceID,
		IssuedAt:  issuedAt,
		ExpiresAt: expiresAt,
		KEK:       kek,
		Envelope:  env,
	}, nil
}

// OpenEnvelope is the reference unwrap routine the mobile client mirrors in
// Dart (Step 7). Returns the DEK; callers must Zero() it when done.
func OpenEnvelope(kek, envelope []byte, deviceID, leaseID string, expiresAt time.Time) ([]byte, error) {
	if len(kek) != KEKSize || len(envelope) != EnvelopeSize || [4]byte(envelope[:4]) != envelopeHeader {
		return nil, ErrEnvelopeInvalid
	}
	gcm, err := newGCM(kek)
	if err != nil {
		return nil, err
	}
	nonce := envelope[4:16]
	dek, err := gcm.Open(nil, nonce, envelope[16:], envelopeAAD(deviceID, leaseID, expiresAt))
	if err != nil {
		return nil, ErrEnvelopeInvalid
	}
	return dek, nil
}

func envelopeAAD(deviceID, leaseID string, expiresAt time.Time) []byte {
	aad := append([]byte{}, envelopeHeader[:]...)
	return append(aad, deviceID+"|"+leaseID+"|"+strconv.FormatInt(expiresAt.Unix(), 10)...)
}

func newGCM(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

// Zero overwrites key material in place (best effort in a GC'd runtime).
func Zero(b []byte) {
	for i := range b {
		b[i] = 0
	}
}

