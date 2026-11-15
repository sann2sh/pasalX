package auth

import (
	"errors"
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

const (
	jwtIssuer   = "pasalx-server"
	jwtAudience = "pasalx-mobile"
)

var (
	ErrTokenExpired = errors.New("token expired")
	ErrTokenInvalid = errors.New("token invalid")
)

// Claims are the PasalX session claims. A token is bound to exactly one
// device and one 12h lease; its exp always equals the lease expiry.
type Claims struct {
	Role       string `json:"role"`
	DeviceID   string `json:"did"`
	DeviceCode string `json:"dcode"`
	LeaseID    string `json:"lid"`
	jwt.RegisteredClaims
}

// Session is the validated identity attached to an authenticated request.
type Session struct {
	UserID     string
	Role       string
	DeviceID   string
	DeviceCode string
	LeaseID    string
	ExpiresAt  time.Time
}

// IssueToken signs an HS256 session JWT that expires with the lease.
func (k *Keys) IssueToken(s Session, issuedAt time.Time) (string, error) {
	c := Claims{
		Role:       s.Role,
		DeviceID:   s.DeviceID,
		DeviceCode: s.DeviceCode,
		LeaseID:    s.LeaseID,
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    jwtIssuer,
			Subject:   s.UserID,
			Audience:  jwt.ClaimStrings{jwtAudience},
			IssuedAt:  jwt.NewNumericDate(issuedAt),
			NotBefore: jwt.NewNumericDate(issuedAt),
			ExpiresAt: jwt.NewNumericDate(s.ExpiresAt),
			ID:        uuid.NewString(),
		},
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, c).SignedString(k.jwt)
}

// ParseToken verifies signature (HS256 only – rejects "none"/RS/ES
// algorithm-confusion), issuer, audience and expiry.
func (k *Keys) ParseToken(raw string, now time.Time) (Session, error) {
	parser := jwt.NewParser(
		jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}),
		jwt.WithIssuer(jwtIssuer),
		jwt.WithAudience(jwtAudience),
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
	if c.Subject == "" || c.DeviceID == "" || c.LeaseID == "" || !validRole(c.Role) {
		return Session{}, fmt.Errorf("%w: missing required claims", ErrTokenInvalid)
	}
	return Session{
		UserID:     c.Subject,
		Role:       c.Role,
		DeviceID:   c.DeviceID,
		DeviceCode: c.DeviceCode,
		LeaseID:    c.LeaseID,
		ExpiresAt:  c.ExpiresAt.Time,
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
	if c.Issuer != jwtIssuer || c.DeviceID == "" {
		return Session{}, ErrTokenInvalid
	}
	return Session{UserID: c.Subject, Role: c.Role, DeviceID: c.DeviceID, DeviceCode: c.DeviceCode, LeaseID: c.LeaseID}, nil
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
