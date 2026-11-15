package auth

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Error is a client-facing auth error with a stable machine-readable code.
// The mobile app keys its behaviour off Code (e.g. DEVICE_REVOKED => wipe).
type Error struct {
	Status     int
	Code       string
	Message    string
	RetryAfter time.Duration
}

func (e *Error) Error() string { return e.Code + ": " + e.Message }

// Stable error codes (contract with the Step 7 mobile client).
const (
	CodeBadRequest          = "BAD_REQUEST"
	CodeInvalidCredentials  = "INVALID_CREDENTIALS"
	CodeRateLimited         = "RATE_LIMITED"
	CodeUserDisabled        = "USER_DISABLED"
	CodeDeviceNotRegistered = "DEVICE_NOT_REGISTERED"
	CodeDeviceNotActive     = "DEVICE_NOT_ACTIVE"
	CodeDeviceRevoked       = "DEVICE_REVOKED"
	CodeDeviceLimit         = "DEVICE_LIMIT_REACHED"
	CodeTokenMissing        = "TOKEN_MISSING"
	CodeTokenInvalid        = "TOKEN_INVALID"
	CodeTokenExpired        = "TOKEN_EXPIRED"
	CodeSessionEnded        = "SESSION_ENDED"
	CodeForbidden           = "FORBIDDEN"
	CodeCannotRevokeSelf    = "CANNOT_REVOKE_SELF"
	CodeConflict            = "CONFLICT"
	CodeInternal            = "INTERNAL_ERROR"
)

func newErr(status int, code, msg string) *Error { return &Error{Status: status, Code: code, Message: msg} }

var (
	errInvalidCreds  = newErr(http.StatusUnauthorized, CodeInvalidCredentials, "invalid username or credentials")
	errDeviceRevoked = newErr(http.StatusUnauthorized, CodeDeviceRevoked, "this device has been revoked by the owner")
	errInternal      = newErr(http.StatusInternalServerError, CodeInternal, "internal server error")

	usernamePattern = regexp.MustCompile(`^[a-z0-9._-]{3,50}$`)
)

const (
	maxDeviceCode     = 99
	deviceCodeLockKey = 0x50415358 // "PASX" – pg advisory lock for code allocation
)

// Service implements authentication, device registration, leases and revocation.
type Service struct {
	db              *pgxpool.Pool
	keys            *Keys
	now             func() time.Time
	userFail        *failureLimiter
	ipFail          *failureLimiter
	onDeviceRevoked func(deviceID, deviceCode string)
}

// SetOnDeviceRevoked registers a post-commit hook fired whenever Revoke
// marks a device REVOKED, used to terminate live SSE streams immediately.
func (s *Service) SetOnDeviceRevoked(fn func(deviceID, deviceCode string)) {
	s.onDeviceRevoked = fn
}

// NewService wires the auth service. Lockout policy: 5 failed attempts per
// username or 20 per client IP within 15 min => 15 min lockout.
func NewService(db *pgxpool.Pool, keys *Keys) *Service {
	return &Service{
		db:       db,
		keys:     keys,
		now:      func() time.Time { return time.Now().UTC() },
		userFail: newFailureLimiter(5, 15*time.Minute, 15*time.Minute, true),
		ipFail:   newFailureLimiter(20, 15*time.Minute, 15*time.Minute, false),
	}
}

// ---------------------------------------------------------------- types

type UserInfo struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Username string `json:"username"`
	Role     string `json:"role"`
}

type DeviceInfo struct {
	ID               string     `json:"id"`
	Code             string     `json:"code"`
	Name             string     `json:"name"`
	Platform         string     `json:"platform"`
	Status           string     `json:"status"`
	CurrentUserID    *string    `json:"current_user_id,omitempty"`
	CurrentUserName  *string    `json:"current_user_name,omitempty"`
	LeaseExpiresAt   *time.Time `json:"lease_expires_at,omitempty"`
	RevokedAt        *time.Time `json:"revoked_at,omitempty"`
	RevocationReason *string    `json:"revocation_reason,omitempty"`
}

type LeaseInfo struct {
	LeaseID         string    `json:"lease_id"`
	IssuedAt        time.Time `json:"issued_at"`
	ExpiresAt       time.Time `json:"expires_at"`
	ExpiresUnix     int64     `json:"expires_unix"`
	TTLSeconds      int64     `json:"ttl_seconds"`
	KEK             []byte    `json:"kek_b64"`      // base64 in JSON
	Envelope        []byte    `json:"envelope_b64"` // base64 in JSON, 64 bytes
	EnvelopeVersion int       `json:"envelope_version"`
}

type LoginResult struct {
	AccessToken string     `json:"access_token"`
	TokenType   string     `json:"token_type"`
	ExpiresAt   time.Time  `json:"expires_at"`
	User        UserInfo   `json:"user"`
	Device      DeviceInfo `json:"device"`
	Lease       LeaseInfo  `json:"lease"`
}

type userRow struct {
	UserInfo
	passwordHash string
	pinHash      *string
	active       bool
}

type deviceRow struct {
	DeviceInfo
	active         bool
	dekSealed      []byte
	currentLeaseID *string
}

type querier interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// ---------------------------------------------------------------- users

// CreateUser provisions a staff/manager/owner account (used by the admin CLI;
// the OWNER-only staff management API lands in Step 10).
func (s *Service) CreateUser(ctx context.Context, name, username, password, pin, role string) (UserInfo, error) {
	username = normaliseUsername(username)
	name = strings.TrimSpace(name)
	if !usernamePattern.MatchString(username) {
		return UserInfo{}, fmt.Errorf("username must match %s", usernamePattern)
	}
	if name == "" || len(name) > 100 {
		return UserInfo{}, errors.New("name must be 1-100 characters")
	}
	if !validRole(role) {
		return UserInfo{}, fmt.Errorf("invalid role %q", role)
	}
	if err := ValidatePassword(password); err != nil {
		return UserInfo{}, err
	}
	pwHash, err := HashSecret(password)
	if err != nil {
		return UserInfo{}, err
	}
	var pinHash *string
	if pin != "" {
		if err := ValidatePIN(pin); err != nil {
			return UserInfo{}, err
		}
		h, err := HashSecret(pin)
		if err != nil {
			return UserInfo{}, err
		}
		pinHash = &h
	}
	u := UserInfo{ID: uuid.NewString(), Name: name, Username: username, Role: role}
	_, err = s.db.Exec(ctx, `
		INSERT INTO users (id, name, username, password_hash, pin_hash, role, is_active)
		VALUES ($1, $2, $3, $4, $5, $6, TRUE)`,
		u.ID, u.Name, u.Username, pwHash, pinHash, u.Role)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return UserInfo{}, fmt.Errorf("username %q already exists", username)
		}
		return UserInfo{}, err
	}
	return u, nil
}

func normaliseUsername(u string) string { return strings.ToLower(strings.TrimSpace(u)) }

func (s *Service) loadUserByUsername(ctx context.Context, username string) (*userRow, error) {
	var u userRow
	err := s.db.QueryRow(ctx, `
		SELECT id, name, username, password_hash, pin_hash, role, COALESCE(is_active, FALSE)
		FROM users WHERE username = $1 AND deleted_at IS NULL`, username).
		Scan(&u.ID, &u.Name, &u.Username, &u.passwordHash, &u.pinHash, &u.Role, &u.active)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &u, nil
}

// verifyCredentials performs throttled, timing-equalised credential checks.
// Exactly one of password / pin must be non-empty. scope isolates lockout
// buckets so /devices/register probes or one device's failed logins cannot
// lock out the owner or staff on other registered devices.
func (s *Service) verifyCredentials(ctx context.Context, scope, username, password, pin, ip string) (*userRow, error) {
	username = normaliseUsername(username)
	if username == "" || len(username) > 64 || (password == "") == (pin == "") || len(password) > 256 || len(pin) > 32 {
		return nil, newErr(http.StatusBadRequest, CodeBadRequest, "provide username and exactly one of password or pin")
	}
	now := s.now()
	userKey, ipKey := scope+":"+username, "ip:"+ip

	uBlocked, uWait, releaseUser := s.userFail.Acquire(userKey, now)
	if uBlocked {
		return nil, &Error{Status: http.StatusTooManyRequests, Code: CodeRateLimited,
			Message: "too many failed attempts, try again later", RetryAfter: uWait}
	}
	ipBlocked, ipWait, releaseIP := s.ipFail.Acquire(ipKey, now)
	if ipBlocked {
		releaseUser(outcomeAborted) // preserve user's existing failure count when IP is blocked
		return nil, &Error{Status: http.StatusTooManyRequests, Code: CodeRateLimited,
			Message: "too many failed attempts, try again later", RetryAfter: ipWait}
	}

	outcome := outcomeFailure
	defer func() {
		releaseUser(outcome)
		releaseIP(outcome)
	}()

	u, err := s.loadUserByUsername(ctx, username)
	if err != nil {
		outcome = outcomeAborted // DB transient error is not a credential check
		log.Printf("auth: user lookup failed: %v", err)
		return nil, errInternal
	}

	secret, hash := password, dummyHash
	if u != nil {
		if pin != "" {
			secret = pin
			if u.pinHash != nil {
				hash = *u.pinHash
			}
		} else {
			hash = u.passwordHash
		}
	} else if pin != "" {
		secret = pin
	}
	ok, err := VerifySecret(ctx, secret, hash)
	if errors.Is(err, ErrHashBusy) {
		outcome = outcomeAborted
		return nil, &Error{Status: http.StatusTooManyRequests, Code: CodeRateLimited,
			Message: "authentication server busy, retry shortly", RetryAfter: 2 * time.Second}
	}
	if err != nil && !errors.Is(err, ErrMalformedHash) {
		outcome = outcomeAborted
		return nil, errInternal
	}
	// A user with no PIN set compares against dummyHash: always fails.
	if u == nil || !ok || hash == dummyHash {
		var uid *string
		if u != nil {
			uid = &u.ID
		}
		s.auditBestEffort(ctx, "LOGIN_FAILED", uid, "", map[string]any{"username": username, "method": method(pin), "scope": scope}, ip)
		return nil, errInvalidCreds
	}
	outcome = outcomeSuccess
	if !u.active {
		return nil, newErr(http.StatusUnauthorized, CodeUserDisabled, "this account has been disabled")
	}
	return u, nil
}

func method(pin string) string {
	if pin != "" {
		return "PIN"
	}
	return "PASSWORD"
}

// ---------------------------------------------------------------- devices

type RegisterDeviceInput struct {
	OwnerUsername string `json:"owner_username"`
	OwnerPassword string `json:"owner_password"`
	DeviceName    string `json:"device_name"`
	Platform      string `json:"platform"`
}

// RegisterDevice enrols a phone. The OWNER authorises it on-site with their
// password. Device codes are allocated sequentially ("01", "02", ...) under
// an advisory lock and are never reused, because sale/invoice numbers are
// prefixed with the device code and must stay globally unique forever.
func (s *Service) RegisterDevice(ctx context.Context, in RegisterDeviceInput, ip string) (DeviceInfo, error) {
	name := strings.TrimSpace(in.DeviceName)
	platform := strings.ToUpper(strings.TrimSpace(in.Platform))
	if name == "" || len(name) > 100 {
		return DeviceInfo{}, newErr(http.StatusBadRequest, CodeBadRequest, "device_name must be 1-100 characters")
	}
	if platform != "ANDROID" && platform != "IOS" && platform != "LINUX" {
		return DeviceInfo{}, newErr(http.StatusBadRequest, CodeBadRequest, "platform must be ANDROID, IOS or LINUX")
	}
	if in.OwnerPassword == "" {
		return DeviceInfo{}, newErr(http.StatusBadRequest, CodeBadRequest, "owner_password is required")
	}
	owner, err := s.verifyCredentials(ctx, "reg", in.OwnerUsername, in.OwnerPassword, "", ip)
	if err != nil {
		return DeviceInfo{}, err
	}
	if owner.Role != RoleOwner {
		return DeviceInfo{}, newErr(http.StatusForbidden, CodeForbidden, "only the OWNER can register devices")
	}

	dek, err := GenerateDEK()
	if err != nil {
		return DeviceInfo{}, errInternal
	}
	defer Zero(dek)
	d := DeviceInfo{ID: uuid.NewString(), Name: name, Platform: platform, Status: "ACTIVE"}
	sealed, err := s.keys.SealDEK(d.ID, dek)
	if err != nil {
		return DeviceInfo{}, errInternal
	}

	err = pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, deviceCodeLockKey); err != nil {
			return err
		}
		var maxCode int
		if err := tx.QueryRow(ctx, `
			SELECT COALESCE(MAX(device_code::int), 0) FROM device_registrations
			WHERE device_code ~ '^[0-9]{1,4}$'`).Scan(&maxCode); err != nil {
			return err
		}
		if maxCode >= maxDeviceCode {
			return newErr(http.StatusConflict, CodeDeviceLimit, "device code space 01-99 exhausted")
		}
		d.Code = fmt.Sprintf("%02d", maxCode+1)
		if _, err := tx.Exec(ctx, `
			INSERT INTO device_registrations
				(id, device_code, device_name, platform, is_active, status, dek_sealed, registered_by_user_id)
			VALUES ($1, $2, $3, $4, TRUE, 'ACTIVE', $5, $6)`,
			d.ID, d.Code, d.Name, d.Platform, sealed, owner.ID); err != nil {
			return err
		}
		return s.audit(ctx, tx, "REGISTER_DEVICE", &owner.ID, d.Code,
			map[string]any{"device_id": d.ID, "device_name": d.Name, "platform": d.Platform}, ip)
	})
	if err != nil {
		var ae *Error
		if errors.As(err, &ae) {
			return DeviceInfo{}, ae
		}
		log.Printf("auth: register device failed: %v", err)
		return DeviceInfo{}, errInternal
	}
	return d, nil
}

func (s *Service) loadDevice(ctx context.Context, q querier, deviceID string, forUpdate bool) (*deviceRow, error) {
	sql := `SELECT id, device_code, device_name, platform, COALESCE(status, 'PENDING'),
	               COALESCE(is_active, FALSE), revoked_at, dek_sealed, current_lease_id
	        FROM device_registrations WHERE id = $1`
	if forUpdate {
		sql += " FOR UPDATE"
	}
	var d deviceRow
	err := q.QueryRow(ctx, sql, deviceID).Scan(&d.ID, &d.Code, &d.Name, &d.Platform, &d.Status,
		&d.active, &d.RevokedAt, &d.dekSealed, &d.currentLeaseID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &d, nil
}

// deviceGate maps a device row to the kill-switch decision.
func deviceGate(d *deviceRow) *Error {
	switch {
	case d == nil:
		return newErr(http.StatusUnauthorized, CodeDeviceNotRegistered, "device is not registered")
	case d.Status == "REVOKED":
		return errDeviceRevoked
	case d.Status != "ACTIVE" || !d.active:
		return newErr(http.StatusUnauthorized, CodeDeviceNotActive, "device is not active")
	}
	return nil
}

// ---------------------------------------------------------------- login / lease

type LoginInput struct {
	Username string `json:"username"`
	Password string `json:"password,omitempty"`
	PIN      string `json:"pin,omitempty"`
	DeviceID string `json:"device_id"`
}

// Login verifies credentials on a registered device and issues a 12h JWT
// plus the 12h KEK lease that unwraps the device DEK.
func (s *Service) Login(ctx context.Context, in LoginInput, ip string) (*LoginResult, error) {
	if _, err := uuid.Parse(in.DeviceID); err != nil {
		return nil, newErr(http.StatusBadRequest, CodeBadRequest, "device_id must be a UUID")
	}
	// Kill-switch first: a revoked phone is told so immediately (triggering a
	// local wipe) without spending an Argon2 computation.
	pre, err := s.loadDevice(ctx, s.db, in.DeviceID, false)
	if err != nil {
		log.Printf("auth: device lookup failed: %v", err)
		return nil, errInternal
	}
	if gate := deviceGate(pre); gate != nil {
		return nil, gate
	}

	u, err := s.verifyCredentials(ctx, "login:"+in.DeviceID, in.Username, in.Password, in.PIN, ip)
	if err != nil {
		return nil, err
	}

	issued := s.now().Truncate(time.Second)
	expires := issued.Add(LeaseDuration)
	leaseID := uuid.NewString()
	var res *LoginResult

	err = pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		// Re-check under row lock: closes the race with a concurrent revoke.
		d, err := s.loadDevice(ctx, tx, in.DeviceID, true)
		if err != nil {
			return err
		}
		if gate := deviceGate(d); gate != nil {
			return gate
		}
		if len(d.dekSealed) == 0 {
			dek, err := GenerateDEK()
			if err != nil {
				return err
			}
			sealed, err := s.keys.SealDEK(d.ID, dek)
			Zero(dek)
			if err != nil {
				return err
			}
			d.dekSealed = sealed
		}
		lease, err := s.leaseFor(d, leaseID, issued, expires)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `
			UPDATE device_registrations
			SET dek_sealed = $2, current_lease_id = $3, current_user_id = $4,
			    last_kek_lease_issued_at = $5, last_kek_lease_expires_at = $6, updated_at = $5
			WHERE id = $1`, d.ID, d.dekSealed, leaseID, u.ID, issued, expires); err != nil {
			return err
		}
		if err := s.audit(ctx, tx, "LOGIN", &u.ID, d.Code,
			map[string]any{"method": method(in.PIN), "lease_id": leaseID, "lease_expires_at": expires}, ip); err != nil {
			return err
		}
		res, err = s.buildResult(u.UserInfo, d.DeviceInfo, lease, issued)
		return err
	})
	if err != nil {
		var ae *Error
		if errors.As(err, &ae) {
			return nil, ae
		}
		log.Printf("auth: login failed: %v", err)
		return nil, errInternal
	}
	return res, nil
}

// Refresh re-issues the JWT and re-derives the SAME lease for an
// already-authenticated session (e.g. app cold-start while online). It
// NEVER extends the 12h ceiling: expiry stays pinned to the original login.
func (s *Service) Refresh(ctx context.Context, sess Session) (*LoginResult, error) {
	issued := s.now().Truncate(time.Second)
	if !sess.ExpiresAt.After(issued) {
		return nil, newErr(http.StatusUnauthorized, CodeTokenExpired, "session expired, please log in again")
	}
	d, err := s.loadDevice(ctx, s.db, sess.DeviceID, false)
	if err != nil {
		return nil, errInternal
	}
	if gate := deviceGate(d); gate != nil {
		return nil, gate
	}
	if d.currentLeaseID == nil || *d.currentLeaseID != sess.LeaseID {
		return nil, newErr(http.StatusUnauthorized, CodeSessionEnded, "session ended (logged out or replaced by a newer login)")
	}
	var (
		u           UserInfo
		userActive  bool
		userDeleted bool
	)
	err = s.db.QueryRow(ctx, `
		SELECT id, name, username, role, COALESCE(is_active, FALSE), deleted_at IS NOT NULL
		FROM users WHERE id = $1`, sess.UserID).
		Scan(&u.ID, &u.Name, &u.Username, &u.Role, &userActive, &userDeleted)
	if errors.Is(err, pgx.ErrNoRows) || !userActive || userDeleted {
		return nil, newErr(http.StatusUnauthorized, CodeUserDisabled, "this account has been disabled")
	}
	if err != nil {
		return nil, errInternal
	}
	if u.Role != sess.Role {
		return nil, newErr(http.StatusUnauthorized, CodeSessionEnded, "role changed, please log in again")
	}
	lease, err := s.leaseFor(d, sess.LeaseID, issued, sess.ExpiresAt)
	if err != nil {
		return nil, errInternal
	}
	return s.buildResult(u, d.DeviceInfo, lease, issued)
}

func (s *Service) leaseFor(d *deviceRow, leaseID string, issued, expires time.Time) (*Lease, error) {
	if len(d.dekSealed) == 0 {
		return nil, fmt.Errorf("device %s has no sealed DEK", d.ID)
	}
	dek, err := s.keys.OpenDEK(d.ID, d.dekSealed)
	if err != nil {
		return nil, err
	}
	defer Zero(dek)
	return s.keys.IssueLease(d.ID, leaseID, issued, expires, dek)
}

func (s *Service) buildResult(u UserInfo, d DeviceInfo, l *Lease, issued time.Time) (*LoginResult, error) {
	token, err := s.keys.IssueToken(Session{
		UserID: u.ID, Role: u.Role, DeviceID: d.ID, DeviceCode: d.Code,
		LeaseID: l.LeaseID, ExpiresAt: l.ExpiresAt,
	}, issued)
	if err != nil {
		return nil, err
	}
	return &LoginResult{
		AccessToken: token,
		TokenType:   "Bearer",
		ExpiresAt:   l.ExpiresAt,
		User:        u,
		Device:      d,
		Lease: LeaseInfo{
			LeaseID:         l.LeaseID,
			IssuedAt:        l.IssuedAt,
			ExpiresAt:       l.ExpiresAt,
			ExpiresUnix:     l.ExpiresAt.Unix(),
			TTLSeconds:      int64(l.ExpiresAt.Sub(issued).Seconds()),
			KEK:             l.KEK,
			Envelope:        l.Envelope,
			EnvelopeVersion: int(envelopeHeader[2]),
		},
	}, nil
}

// Logout ends the device's current lease server-side; the JWT stops working.
func (s *Service) Logout(ctx context.Context, sess Session, ip string) error {
	now := s.now()
	return pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `
			UPDATE device_registrations SET current_lease_id = NULL, current_user_id = NULL, updated_at = $3
			WHERE id = $1 AND current_lease_id = $2`, sess.DeviceID, sess.LeaseID, now); err != nil {
			return err
		}
		return s.audit(ctx, tx, "LOGOUT", &sess.UserID, sess.DeviceCode, map[string]any{"lease_id": sess.LeaseID}, ip)
	})
}

// ListDevices returns all registered shop devices ordered by device_code
// for the OWNER's Settings & Kill-Switch screen.
func (s *Service) ListDevices(ctx context.Context) ([]DeviceInfo, error) {
	rows, err := s.db.Query(ctx, `
		SELECT d.id, d.device_code, d.device_name, d.platform, COALESCE(d.status, 'PENDING'),
		       d.current_user_id, u.name, d.last_kek_lease_expires_at, d.revoked_at, d.revocation_reason
		FROM device_registrations d
		LEFT JOIN users u ON u.id = d.current_user_id
		ORDER BY d.device_code ASC`)
	if err != nil {
		log.Printf("auth: list devices failed: %v", err)
		return nil, errInternal
	}
	defer rows.Close()

	devices := make([]DeviceInfo, 0, 4)
	for rows.Next() {
		var d DeviceInfo
		if err := rows.Scan(&d.ID, &d.Code, &d.Name, &d.Platform, &d.Status,
			&d.CurrentUserID, &d.CurrentUserName, &d.LeaseExpiresAt, &d.RevokedAt, &d.RevocationReason); err != nil {
			log.Printf("auth: scan device row failed: %v", err)
			return nil, errInternal
		}
		devices = append(devices, d)
	}
	if err := rows.Err(); err != nil {
		return nil, errInternal
	}
	return devices, nil
}

// ---------------------------------------------------------------- kill-switch

type RevokeInput struct {
	DeviceID   string `json:"device_id,omitempty"`
	DeviceCode string `json:"device_code,omitempty"`
	Reason     string `json:"reason"`
}

// RevokeResult reports the revoked device; AlreadyRevoked makes the call idempotent.
type RevokeResult struct {
	Device         DeviceInfo `json:"device"`
	AlreadyRevoked bool       `json:"already_revoked"`
}

// Revoke permanently disables a device (OWNER only, TECHNICAL_SPEC §7.4/§7.5).
// Effect is immediate: every authenticated request re-checks device status,
// so the next sync heartbeat receives HTTP 401 DEVICE_REVOKED.
func (s *Service) Revoke(ctx context.Context, sess Session, in RevokeInput, ip string) (*RevokeResult, error) {
	if sess.Role != RoleOwner {
		return nil, newErr(http.StatusForbidden, CodeForbidden, "only the OWNER can revoke devices")
	}
	in.DeviceID = strings.TrimSpace(in.DeviceID)
	in.DeviceCode = strings.TrimSpace(in.DeviceCode)
	reason := strings.TrimSpace(in.Reason)
	if (in.DeviceID == "") == (in.DeviceCode == "") {
		return nil, newErr(http.StatusBadRequest, CodeBadRequest, "provide exactly one of device_id or device_code")
	}
	if in.DeviceID != "" {
		if _, err := uuid.Parse(in.DeviceID); err != nil {
			return nil, newErr(http.StatusBadRequest, CodeBadRequest, "device_id must be a UUID")
		}
	}
	if reason == "" || len(reason) > 500 {
		return nil, newErr(http.StatusBadRequest, CodeBadRequest, "reason must be 1-500 characters")
	}
	var res RevokeResult
	err := pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		var id string
		err := tx.QueryRow(ctx, `SELECT id FROM device_registrations WHERE id = $1 OR device_code = $2`,
			in.DeviceID, in.DeviceCode).Scan(&id)
		if errors.Is(err, pgx.ErrNoRows) {
			return newErr(http.StatusNotFound, CodeDeviceNotRegistered, "device not found")
		}
		if err != nil {
			return err
		}
		if id == sess.DeviceID {
			return newErr(http.StatusConflict, CodeCannotRevokeSelf, "cannot revoke the device you are using; revoke it from another owner device")
		}
		d, err := s.loadDevice(ctx, tx, id, true)
		if err != nil {
			return err
		}
		if d.Status == "REVOKED" {
			res = RevokeResult{Device: d.DeviceInfo, AlreadyRevoked: true}
			return nil
		}
		now := s.now()
		if _, err := tx.Exec(ctx, `
			UPDATE device_registrations
			SET status = 'REVOKED', is_active = FALSE, revoked_at = $2, revoked_by_user_id = $3,
			    revocation_reason = $4, current_lease_id = NULL, current_user_id = NULL, updated_at = $2
			WHERE id = $1`, id, now, sess.UserID, reason); err != nil {
			return err
		}
		d.Status, d.RevokedAt = "REVOKED", &now
		res = RevokeResult{Device: d.DeviceInfo}
		return s.audit(ctx, tx, "REVOKE_DEVICE", &sess.UserID, d.Code,
			map[string]any{"device_id": d.ID, "reason": reason, "revoked_from_device": sess.DeviceCode}, ip)
	})
	if err != nil {
		var ae *Error
		if errors.As(err, &ae) {
			return nil, ae
		}
		log.Printf("auth: revoke failed: %v", err)
		return nil, errInternal
	}
	if s.onDeviceRevoked != nil {
		s.onDeviceRevoked(res.Device.ID, res.Device.Code)
	}
	return &res, nil
}

// ---------------------------------------------------------------- request auth

// Authenticate validates a bearer token AND the live device/user state on
// every request. DEVICE_REVOKED takes precedence even over an expired token,
// so a phone that was offline past its lease still learns it must wipe.
func (s *Service) Authenticate(ctx context.Context, raw string) (Session, error) {
	now := s.now()
	sess, err := s.keys.ParseToken(raw, now)
	if errors.Is(err, ErrTokenExpired) {
		if expired, perr := s.keys.parseTokenIgnoringTime(raw); perr == nil {
			if d, derr := s.loadDevice(ctx, s.db, expired.DeviceID, false); derr == nil && d != nil && d.Status == "REVOKED" {
				return Session{}, errDeviceRevoked
			}
		}
		return Session{}, newErr(http.StatusUnauthorized, CodeTokenExpired, "session expired, please log in again")
	}
	if err != nil {
		return Session{}, newErr(http.StatusUnauthorized, CodeTokenInvalid, "invalid token")
	}

	var (
		status        string
		devActive     bool
		currentLease  *string
		currentUserID *string
		userActive    *bool
		userDeleted   *bool
		dbRole        *string
	)
	err = s.db.QueryRow(ctx, `
		SELECT COALESCE(d.status, 'PENDING'), COALESCE(d.is_active, FALSE), d.current_lease_id, d.current_user_id,
		       COALESCE(u.is_active, FALSE), u.deleted_at IS NOT NULL, u.role
		FROM device_registrations d
		LEFT JOIN users u ON u.id = $2
		WHERE d.id = $1`, sess.DeviceID, sess.UserID).
		Scan(&status, &devActive, &currentLease, &currentUserID, &userActive, &userDeleted, &dbRole)
	if errors.Is(err, pgx.ErrNoRows) {
		return Session{}, newErr(http.StatusUnauthorized, CodeDeviceNotRegistered, "device or user not found")
	}
	if err != nil {
		log.Printf("auth: session lookup failed: %v", err)
		return Session{}, errInternal
	}
	switch {
	case status == "REVOKED":
		return Session{}, errDeviceRevoked
	case status != "ACTIVE" || !devActive:
		return Session{}, newErr(http.StatusUnauthorized, CodeDeviceNotActive, "device is not active")
	case dbRole == nil || userActive == nil || !*userActive || (userDeleted != nil && *userDeleted):
		return Session{}, newErr(http.StatusUnauthorized, CodeUserDisabled, "this account has been disabled")
	case currentLease == nil || *currentLease != sess.LeaseID || currentUserID == nil || *currentUserID != sess.UserID:
		return Session{}, newErr(http.StatusUnauthorized, CodeSessionEnded, "session ended (logged out or replaced by a newer login)")
	case *dbRole != sess.Role:
		return Session{}, newErr(http.StatusUnauthorized, CodeSessionEnded, "role changed, please log in again")
	}
	return sess, nil
}

// ---------------------------------------------------------------- audit

func (s *Service) audit(ctx context.Context, q querier, event string, userID *string, deviceCode string, meta map[string]any, ip string) error {
	metaJSON, err := json.Marshal(meta)
	if err != nil {
		return err
	}
	var dc *string
	if deviceCode != "" {
		dc = &deviceCode
	}
	_, err = q.Exec(ctx, `
		INSERT INTO app_audit_logs (id, event_type, user_id, device_code, metadata, ip_address)
		VALUES ($1, $2, $3, $4, $5, $6)`,
		uuid.NewString(), event, userID, dc, metaJSON, truncate(ip, 50))
	return err
}

func (s *Service) auditBestEffort(ctx context.Context, event string, userID *string, deviceCode string, meta map[string]any, ip string) {
	if err := s.audit(ctx, s.db, event, userID, deviceCode, meta, ip); err != nil {
		log.Printf("auth: audit %s failed: %v", event, err)
	}
}

func truncate(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}

// retryAfterSeconds rounds a lockout duration up to whole seconds.
func retryAfterSeconds(d time.Duration) string {
	sec := int64((d + time.Second - 1) / time.Second)
	if sec < 1 {
		sec = 1
	}
	return strconv.FormatInt(sec, 10)
}

