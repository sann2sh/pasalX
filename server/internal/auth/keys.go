// Package auth implements PasalX staff authentication, the per-device DEK
// custody + 12-hour KEK lease (two-key envelope encryption), JWT sessions,
// and the remote device kill-switch.
package auth

import (
	"crypto/hkdf"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"strings"
)

// MasterKeyEnv is the single root secret of the server. Everything else
// (DEK sealing key, KEK lease root, JWT signing key) is derived from it with
// HKDF-SHA256 using distinct info labels (domain separation), so leaking one
// derived key never reveals another.
const MasterKeyEnv = "PASALX_MASTER_KEY"

const (
	infoDEKAtRest = "pasalx/dek-at-rest/v1"
	infoKEKRoot   = "pasalx/kek-lease-root/v1"
	infoJWT       = "pasalx/jwt-hs256/v1"
)

// Keys holds the derived 256-bit subkeys. It never exposes the master key.
type Keys struct {
	dekAtRest []byte // seals per-device DEKs stored in Postgres
	kekRoot   []byte // root for per-lease KEK derivation
	jwt       []byte // HS256 signing key
}

// NewKeys derives all subkeys from a 32-byte (or longer) master secret.
func NewKeys(master []byte) (*Keys, error) {
	if len(master) < 32 {
		return nil, fmt.Errorf("master key must be at least 32 bytes, got %d", len(master))
	}
	derive := func(info string) ([]byte, error) {
		return hkdf.Key(sha256.New, master, nil, info, 32)
	}
	k := &Keys{}
	var err error
	if k.dekAtRest, err = derive(infoDEKAtRest); err != nil {
		return nil, err
	}
	if k.kekRoot, err = derive(infoKEKRoot); err != nil {
		return nil, err
	}
	if k.jwt, err = derive(infoJWT); err != nil {
		return nil, err
	}
	return k, nil
}

// LoadKeysFromEnv reads PASALX_MASTER_KEY (standard or URL-safe base64 of
// >= 32 random bytes). There is deliberately no default: the server refuses
// to start without a real secret.
func LoadKeysFromEnv() (*Keys, error) {
	raw := strings.TrimSpace(os.Getenv(MasterKeyEnv))
	if raw == "" {
		return nil, errors.New(MasterKeyEnv + " is not set (generate one with: go run ./cmd/pasalx-admin gen-master-key)")
	}
	master, err := decodeB64(raw)
	if err != nil {
		return nil, fmt.Errorf("%s is not valid base64: %w", MasterKeyEnv, err)
	}
	return NewKeys(master)
}

func decodeB64(s string) ([]byte, error) {
	for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
		if b, err := enc.DecodeString(s); err == nil {
			return b, nil
		}
	}
	return nil, errors.New("unrecognised base64 encoding")
}

