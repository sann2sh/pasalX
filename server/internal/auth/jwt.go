package auth

import (
	"errors"
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

const (
	jwtIssuer          = "pasalx-server"
	jwtDeviceAudience  = "pasalx-device"
	jwtAccountAudience = "pasalx-account"
	AccountTokenTTL    = 15 * time.Minute
)

var (
	ErrTokenExpired = errors.New("token expired")
	ErrTokenInvalid = errors.New("token invalid")
)

// Claims are the PasalX device session claims. A token is bound to one store,
// one device, one 12h lease, and one user token_version; its exp always equals
// the lease expiry.
type Claims struct {
	StoreID      string `json:"sid"`
	Role         string `json:"role"`
	DeviceID     string `json:"did"`
	DeviceCode   string `json:"dcode"`
	LeaseID      string `json:"lid"`
	TokenVersion int    `json:"tv"`
	jwt.RegisteredClaims
}

// Session is the validated identity attached to an authenticated device request.
type Session struct {
	UserID       string
	StoreID      string
	Role         string
	DeviceID     string
	DeviceCode   string
	LeaseID      string
	TokenVersion int
	ExpiresAt    time.Time
}

// IssueToken signs an HS256 device session JWT that expires with the lease.
func (k *Keys) IssueToken(s Session, issuedAt time.Time) (string, error) {
	c := Claims{
		StoreID:      s.StoreID,
		Role:         s.Role,
		DeviceID:     s.DeviceID,
		DeviceCode:   s.DeviceCode,
		LeaseID:      s.LeaseID,
		TokenVersion: s.TokenVersion,
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    jwtIssuer,
			Subject:   s.UserID,
			Audience:  jwt.ClaimStrings{jwtDeviceAudience},
			IssuedAt:  jwt.NewNumericDate(issuedAt),
			NotBefore: jwt.NewNumericDate(issuedAt),
			ExpiresAt: jwt.NewNumericDate(s.ExpiresAt),
			ID:        uuid.NewString(),
		},
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, c).SignedString(k.jwt)
}

// ParseToken verifies signature (HS256 only – rejects "none"/RS/ES
// algorithm-confusion), issuer, audience, store claim, and expiry.
func (k *Keys) ParseToken(raw string, now time.Time) (Session, error) {
	parser := jwt.NewParser(
		jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}),
		jwt.WithIssuer(jwtIssuer),
		jwt.WithAudience(jwtDeviceAudience),
		jwt.WithExpirationRequired(),
		jwt.WithIssuedAt(),
		jwt.WithTimeFunc(func() time.Time { return now }),
	)
	var c Claims
	_, err := parser.ParseWithClaims(raw, &c, func(*jwt.Token) (any, error) { return k.jwt, nil })
	if err != nil {
		if errors.Is(err, jwt.ErrTokenExpired) {
			return Session{}, ErrTokenExpired
		}
		return Session{}, fmt.Errorf("%w: %v", ErrTokenInvalid, err)
	}
	if c.Subject == "" || c.StoreID == "" || c.DeviceID == "" || c.LeaseID == "" || c.TokenVersion < 1 || !validRole(c.Role) {
		return Session{}, fmt.Errorf("%w: missing required claims", ErrTokenInvalid)
	}
	return Session{
		UserID:       c.Subject,
		StoreID:      c.StoreID,
		Role:         c.Role,
		DeviceID:     c.DeviceID,
		DeviceCode:   c.DeviceCode,
		LeaseID:      c.LeaseID,
		TokenVersion: c.TokenVersion,
		ExpiresAt:    c.ExpiresAt.Time,
	}, nil
}

// parseTokenIgnoringTime verifies the HS256 signature but skips time-based
// claims. Used ONLY to identify the device of an expired token so the
// kill-switch can still answer DEVICE_REVOKED; never grants access.
func (k *Keys) parseTokenIgnoringTime(raw string) (Session, error) {
	parser := jwt.NewParser(
		jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}),
		jwt.WithoutClaimsValidation(),
	)
	var c Claims
	if _, err := parser.ParseWithClaims(raw, &c, func(*jwt.Token) (any, error) { return k.jwt, nil }); err != nil {
		return Session{}, fmt.Errorf("%w: %v", ErrTokenInvalid, err)
	}
	if c.Issuer != jwtIssuer || c.DeviceID == "" || c.StoreID == "" {
		return Session{}, ErrTokenInvalid
	}
	return Session{
		UserID:       c.Subject,
		StoreID:      c.StoreID,
		Role:         c.Role,
		DeviceID:     c.DeviceID,
		DeviceCode:   c.DeviceCode,
		LeaseID:      c.LeaseID,
		TokenVersion: c.TokenVersion,
	}, nil
}

// Roles (TECHNICAL_SPEC.md §7.5)
const (
	RoleOwner   = "OWNER"
	RoleManager = "MANAGER"
	RoleStaff   = "STAFF"
)

func validRole(r string) bool {
	return r == RoleOwner || r == RoleManager || r == RoleStaff
}

// AccountClaims are the short-lived (15 min) account-level JWT claims used
// before a device is enrolled or for account-level actions (create store,
// accept invite, poll device approval, delete account). Signed with a distinct
// HKDF key (k.accountJWT) and audience (pasalx-account) so it can never be
// confused with a device session token.
type AccountClaims struct {
	TokenVersion int `json:"tv"`
	jwt.RegisteredClaims
}

// AccountSession is the validated identity attached by RequireAccountAuth.
type AccountSession struct {
	UserID        string
	Email         string
	Name          string
	Username      string
	EmailVerified bool
	TokenVersion  int
	ExpiresAt     time.Time
}

// IssueAccountToken signs an HS256 account JWT with a 15-minute TTL.
func (k *Keys) IssueAccountToken(userID string, tokenVersion int, issuedAt time.Time) (string, time.Time, error) {
	exp := issuedAt.Add(AccountTokenTTL)
	c := AccountClaims{
		TokenVersion: tokenVersion,
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    jwtIssuer,
			Subject:   userID,
			Audience:  jwt.ClaimStrings{jwtAccountAudience},
			IssuedAt:  jwt.NewNumericDate(issuedAt),
			NotBefore: jwt.NewNumericDate(issuedAt),
			ExpiresAt: jwt.NewNumericDate(exp),
			ID:        uuid.NewString(),
		},
	}
	tok, err := jwt.NewWithClaims(jwt.SigningMethodHS256, c).SignedString(k.accountJWT)
	return tok, exp, err
}

// ParseAccountToken verifies signature (with k.accountJWT), issuer,
// audience (pasalx-account), and expiry.
func (k *Keys) ParseAccountToken(raw string, now time.Time) (AccountSession, error) {
	parser := jwt.NewParser(
		jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}),
		jwt.WithIssuer(jwtIssuer),
		jwt.WithAudience(jwtAccountAudience),
		jwt.WithExpirationRequired(),
		jwt.WithIssuedAt(),
		jwt.WithTimeFunc(func() time.Time { return now }),
	)
	var c AccountClaims
	_, err := parser.ParseWithClaims(raw, &c, func(*jwt.Token) (any, error) { return k.accountJWT, nil })
	if err != nil {
		if errors.Is(err, jwt.ErrTokenExpired) {
			return AccountSession{}, ErrTokenExpired
		}
		return AccountSession{}, fmt.Errorf("%w: %v", ErrTokenInvalid, err)
	}
	if c.Subject == "" || c.TokenVersion < 1 {
		return AccountSession{}, fmt.Errorf("%w: missing required claims", ErrTokenInvalid)
	}
	return AccountSession{
		UserID:       c.Subject,
		TokenVersion: c.TokenVersion,
		ExpiresAt:    c.ExpiresAt.Time,
	}, nil
}
