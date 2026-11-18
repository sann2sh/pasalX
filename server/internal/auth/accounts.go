package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/mail"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	pmail "pasalx/server/internal/mail"
)

const (
	emailCodeTTL         = 15 * time.Minute
	maxEmailCodeAttempts = 5
	purposeEmailVerify   = "EMAIL_VERIFY"
	purposePasswordReset = "PASSWORD_RESET"
)

// ---------------------------------------------------------------- Account Types

type SignupInput struct {
	Name     string `json:"name"`
	Email    string `json:"email"`
	Password string `json:"password"`
	Username string `json:"username"`
	PIN      string `json:"pin"`
}

type SignupResult struct {
	User                 UserInfo `json:"user"`
	VerificationRequired bool     `json:"verification_required"`
}

type VerifyEmailInput struct {
	Email string `json:"email"`
	Code  string `json:"code"`
}

type EmailInput struct {
	Email string `json:"email"`
}

type AccountLoginInput struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

type StoreSummary struct {
	StoreID     string `json:"store_id"`
	StoreName   string `json:"store_name"`
	Role        string `json:"role"`
	StoreStatus string `json:"store_status"`
}

type AccountLoginResult struct {
	AccessToken string        `json:"access_token"`
	TokenType   string        `json:"token_type"`
	ExpiresAt   time.Time     `json:"expires_at"`
	User        UserInfo      `json:"user"`
	Membership  *StoreSummary `json:"membership"`
}

type ResetPasswordInput struct {
	Email       string `json:"email"`
	Code        string `json:"code"`
	NewPassword string `json:"new_password"`
}

type DeleteAccountInput struct {
	Password string `json:"password"`
}

// ---------------------------------------------------------------- Account JWT Auth

// AuthenticateAccount validates an Account JWT (aud=pasalx-account, signed with
// k.accountJWT) and checks live user status + token_version in Postgres.
func (s *Service) AuthenticateAccount(ctx context.Context, rawToken string) (AccountSession, error) {
	sess, err := s.keys.ParseAccountToken(rawToken, s.now())
	if err != nil {
		if errors.Is(err, ErrTokenExpired) {
			return AccountSession{}, newErr(http.StatusUnauthorized, CodeTokenExpired, "account token expired")
		}
		return AccountSession{}, newErr(http.StatusUnauthorized, CodeTokenInvalid, "invalid account token")
	}

	var (
		email         string
		name          string
		username      string
		emailVerified *time.Time
		active        bool
		tokenVersion  int
	)
	err = s.db.QueryRow(ctx, `
		SELECT email::text, name, username, email_verified_at, COALESCE(is_active, FALSE), token_version
		FROM users
		WHERE id = $1 AND deleted_at IS NULL`, sess.UserID).
		Scan(&email, &name, &username, &emailVerified, &active, &tokenVersion)
	if errors.Is(err, pgx.ErrNoRows) {
		return AccountSession{}, newErr(http.StatusUnauthorized, CodeTokenInvalid, "account not found")
	}
	if err != nil {
		log.Printf("auth: account lookup failed: %v", err)
		return AccountSession{}, errInternal
	}
	if !active {
		return AccountSession{}, newErr(http.StatusUnauthorized, CodeUserDisabled, "user account is disabled")
	}
	if tokenVersion != sess.TokenVersion {
		return AccountSession{}, newErr(http.StatusUnauthorized, CodeTokenInvalid, "account session invalidated")
	}

	sess.Email = email
	sess.Name = name
	sess.Username = username
	sess.EmailVerified = emailVerified != nil
	return sess, nil
}

// ---------------------------------------------------------------- Sign-up & Email Verification

func normalizeEmail(raw string) (string, error) {
	e := strings.ToLower(strings.TrimSpace(raw))
	if e == "" || len(e) > 254 {
		return "", errors.New("valid email is required")
	}
	addr, err := mail.ParseAddress(e)
	if err != nil || strings.ToLower(addr.Address) != e || !strings.Contains(e, ".") {
		return "", errors.New("valid email is required")
	}
	return e, nil
}

// Signup creates a new unverified user account and sends a 6-digit verification code.
func (s *Service) Signup(ctx context.Context, in SignupInput, ip string) (SignupResult, error) {
	now := s.now()
	if ok, wait := s.signupGlobalLimit.Allow("global", now); !ok {
		return SignupResult{}, &Error{Status: http.StatusTooManyRequests, Code: CodeRateLimited, Message: "too many signups right now; please try again shortly", RetryAfter: wait}
	}
	if ok, wait := s.signupIPLimit.Allow("ip:"+ip, now); !ok {
		return SignupResult{}, &Error{Status: http.StatusTooManyRequests, Code: CodeRateLimited, Message: "too many signup attempts from this network", RetryAfter: wait}
	}

	name := strings.TrimSpace(in.Name)
	if name == "" || len(name) > 100 {
		return SignupResult{}, newErr(http.StatusBadRequest, CodeBadRequest, "name must be 1-100 characters")
	}
	email, err := normalizeEmail(in.Email)
	if err != nil {
		return SignupResult{}, newErr(http.StatusBadRequest, CodeBadRequest, err.Error())
	}
	username := normaliseUsername(in.Username)
	if !signupUsernamePattern.MatchString(username) {
		return SignupResult{}, newErr(http.StatusBadRequest, CodeBadRequest, "username must be 3-30 lowercase characters (a-z, 0-9, ., _, -)")
	}
	if err := ValidateSignupPassword(in.Password, username, email); err != nil {
		return SignupResult{}, newErr(http.StatusBadRequest, CodeBadRequest, err.Error())
	}
	if err := ValidateSignupPIN(in.PIN); err != nil {
		return SignupResult{}, newErr(http.StatusBadRequest, CodeBadRequest, err.Error())
	}

	pwHash, err := HashSecret(in.Password)
	if err != nil {
		log.Printf("auth: signup password hash failed: %v", err)
		return SignupResult{}, errInternal
	}
	pinHash, err := HashSecret(in.PIN)
	if err != nil {
		log.Printf("auth: signup pin hash failed: %v", err)
		return SignupResult{}, errInternal
	}

	userID := uuid.NewString()
	code, err := generateSixDigitCode()
	if err != nil {
		return SignupResult{}, errInternal
	}
	codeHash := hashEmailCode(purposeEmailVerify, userID, code)
	expiresAt := now.Add(emailCodeTTL)

	tx, err := s.db.Begin(ctx)
	if err != nil {
		return SignupResult{}, errInternal
	}
	defer tx.Rollback(ctx)

	_, err = tx.Exec(ctx, `
		INSERT INTO users (id, name, email, email_verified_at, username, password_hash, pin_hash, is_active, token_version)
		VALUES ($1, $2, $3, NULL, $4, $5, $6, TRUE, 1)`,
		userID, name, email, username, pwHash, pinHash)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return SignupResult{}, newErr(http.StatusConflict, CodeConflict, "an account with that email or username already exists")
		}
		log.Printf("auth: signup insert user failed: %v", err)
		return SignupResult{}, errInternal
	}

	if _, err := tx.Exec(ctx, `
		INSERT INTO email_verification_codes (id, user_id, code_hash, purpose, expires_at)
		VALUES ($1, $2, $3, $4, $5)`,
		uuid.NewString(), userID, codeHash, purposeEmailVerify, expiresAt); err != nil {
		log.Printf("auth: signup insert code failed: %v", err)
		return SignupResult{}, errInternal
	}

	if err := s.audit(ctx, tx, nil, "SIGNUP", &userID, nil, "", map[string]any{"username": username}, ip); err != nil {
		return SignupResult{}, errInternal
	}
	if err := tx.Commit(ctx); err != nil {
		return SignupResult{}, errInternal
	}

	s.mailer.Enqueue(pmail.VerificationMessage(email, name, code))

	return SignupResult{
		User: UserInfo{
			ID:       userID,
			Name:     name,
			Email:    email,
			Username: username,
		},
		VerificationRequired: true,
	}, nil
}

// VerifyEmail checks the 6-digit code and marks the user's email as verified.
func (s *Service) VerifyEmail(ctx context.Context, in VerifyEmailInput, ip string) error {
	email, err := normalizeEmail(in.Email)
	if err != nil {
		return newErr(http.StatusBadRequest, CodeBadRequest, err.Error())
	}
	code := strings.TrimSpace(in.Code)
	if len(code) != 6 {
		return newErr(http.StatusBadRequest, CodeCodeInvalid, "6-digit verification code is required")
	}

	now := s.now()
	if blocked, wait := s.ipFail.Blocked("verify:"+ip, now); blocked {
		return &Error{Status: http.StatusTooManyRequests, Code: CodeRateLimited, Message: "too many verification attempts", RetryAfter: wait}
	}

	tx, err := s.db.Begin(ctx)
	if err != nil {
		return errInternal
	}
	defer tx.Rollback(ctx)

	var (
		userID     string
		verifiedAt *time.Time
		active     bool
	)
	err = tx.QueryRow(ctx, `
		SELECT id, email_verified_at, COALESCE(is_active, FALSE)
		FROM users WHERE email = $1 AND deleted_at IS NULL FOR UPDATE`, email).
		Scan(&userID, &verifiedAt, &active)
	if errors.Is(err, pgx.ErrNoRows) || !active {
		s.ipFail.Fail("verify:"+ip, now)
		return newErr(http.StatusBadRequest, CodeCodeInvalid, "invalid verification code")
	}
	if err != nil {
		return errInternal
	}
	if verifiedAt != nil {
		return nil // idempotent
	}

	if err := s.consumeEmailCodeTx(ctx, tx, userID, purposeEmailVerify, code, now); err != nil {
		var ae *Error
		if errors.As(err, &ae) {
			s.ipFail.Fail("verify:"+ip, now)
			// Persist incremented attempts count before returning error.
			_ = tx.Commit(ctx)
			return ae
		}
		return errInternal
	}

	if _, err := tx.Exec(ctx, `
		UPDATE users SET email_verified_at = $1, updated_at = $1
		WHERE id = $2 AND email_verified_at IS NULL`, now, userID); err != nil {
		return errInternal
	}
	if err := s.audit(ctx, tx, nil, "EMAIL_VERIFIED", &userID, nil, "", nil, ip); err != nil {
		return errInternal
	}
	return tx.Commit(ctx)
}

// ResendVerification generates a fresh 6-digit verification code for unverified
// accounts. Always succeeds (202) to prevent email enumeration.
func (s *Service) ResendVerification(ctx context.Context, emailRaw, ip string) error {
	email, err := normalizeEmail(emailRaw)
	if err != nil {
		return newErr(http.StatusBadRequest, CodeBadRequest, err.Error())
	}
	now := s.now()
	if ok, wait := s.resendLimit.Allow("resend:"+email, now); !ok {
		return &Error{Status: http.StatusTooManyRequests, Code: CodeRateLimited, Message: "please wait before requesting another code", RetryAfter: wait}
	}
	if ok, wait := s.signupIPLimit.Allow("resend_ip:"+ip, now); !ok {
		return &Error{Status: http.StatusTooManyRequests, Code: CodeRateLimited, Message: "too many requests from this network", RetryAfter: wait}
	}

	var (
		userID     string
		name       string
		verifiedAt *time.Time
		active     bool
	)
	err = s.db.QueryRow(ctx, `
		SELECT id, name, email_verified_at, COALESCE(is_active, FALSE)
		FROM users WHERE email = $1 AND deleted_at IS NULL`, email).
		Scan(&userID, &name, &verifiedAt, &active)
	if errors.Is(err, pgx.ErrNoRows) || !active || verifiedAt != nil {
		return nil // no enumeration
	}
	if err != nil {
		return errInternal
	}

	code, err := generateSixDigitCode()
	if err != nil {
		return errInternal
	}
	codeHash := hashEmailCode(purposeEmailVerify, userID, code)
	expiresAt := now.Add(emailCodeTTL)

	tx, err := s.db.Begin(ctx)
	if err != nil {
		return errInternal
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `
		UPDATE email_verification_codes SET consumed_at = $1
		WHERE user_id = $2 AND purpose = $3 AND consumed_at IS NULL`, now, userID, purposeEmailVerify); err != nil {
		return errInternal
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO email_verification_codes (id, user_id, code_hash, purpose, expires_at)
		VALUES ($1, $2, $3, $4, $5)`,
		uuid.NewString(), userID, codeHash, purposeEmailVerify, expiresAt); err != nil {
		return errInternal
	}
	if err := tx.Commit(ctx); err != nil {
		return errInternal
	}

	s.mailer.Enqueue(pmail.VerificationMessage(email, name, code))
	return nil
}

// ---------------------------------------------------------------- Account Login

// AccountLogin authenticates with email + password and issues a 15-minute
// Account JWT (separate from Device JWT).
func (s *Service) AccountLogin(ctx context.Context, in AccountLoginInput, ip string) (*AccountLoginResult, error) {
	email, err := normalizeEmail(in.Email)
	if err != nil {
		return nil, newErr(http.StatusBadRequest, CodeBadRequest, err.Error())
	}
	if in.Password == "" {
		return nil, newErr(http.StatusBadRequest, CodeBadRequest, "password is required")
	}

	now := s.now()
	userKey := "acct:" + email
	ipKey := "acct_ip:" + ip

	if blocked, wait := s.ipFail.Blocked(ipKey, now); blocked {
		return nil, &Error{Status: http.StatusTooManyRequests, Code: CodeRateLimited, Message: "too many failed attempts from this IP", RetryAfter: wait}
	}
	blocked, wait, releaseUser := s.userFail.Acquire(userKey, now)
	if blocked {
		return nil, &Error{Status: http.StatusTooManyRequests, Code: CodeRateLimited, Message: "account temporarily locked after repeated failures", RetryAfter: wait}
	}
	outcome := outcomeAborted
	defer func() { releaseUser(outcome) }()

	var (
		userID        string
		name          string
		username      string
		passwordHash  string
		emailVerified *time.Time
		active        bool
		tokenVersion  int
	)
	err = s.db.QueryRow(ctx, `
		SELECT id, name, username, password_hash, email_verified_at, COALESCE(is_active, FALSE), token_version
		FROM users WHERE email = $1 AND deleted_at IS NULL`, email).
		Scan(&userID, &name, &username, &passwordHash, &emailVerified, &active, &tokenVersion)
	notFound := errors.Is(err, pgx.ErrNoRows)
	if err != nil && !notFound {
		log.Printf("auth: account login lookup failed: %v", err)
		return nil, errInternal
	}

	hashToCheck := dummyHash
	if !notFound {
		hashToCheck = passwordHash
	}
	ok, err := VerifySecret(ctx, in.Password, hashToCheck)
	if err != nil {
		if errors.Is(err, ErrHashBusy) {
			return nil, newErr(http.StatusServiceUnavailable, CodeInternal, "authentication server busy, retry shortly")
		}
		return nil, errInternal
	}

	if notFound || !ok {
		outcome = outcomeFailure
		s.ipFail.Fail(ipKey, now)
		s.auditBestEffort(ctx, nil, "ACCOUNT_LOGIN_FAILED", nil, nil, "", map[string]any{"email": truncate(email, 64)}, ip)
		return nil, newErr(http.StatusUnauthorized, CodeInvalidCredentials, "invalid email or password")
	}
	if !active {
		outcome = outcomeFailure
		return nil, newErr(http.StatusForbidden, CodeUserDisabled, "user account is disabled")
	}

	outcome = outcomeSuccess
	if emailVerified == nil {
		return nil, newErr(http.StatusForbidden, CodeEmailNotVerified, "please verify your email before logging in")
	}

	var membership *StoreSummary
	var ms StoreSummary
	mErr := s.db.QueryRow(ctx, `SELECT store_id, store_name, role, store_status FROM lookup_user_active_membership($1)`, userID).
		Scan(&ms.StoreID, &ms.StoreName, &ms.Role, &ms.StoreStatus)
	if mErr == nil {
		membership = &ms
	} else if !errors.Is(mErr, pgx.ErrNoRows) {
		log.Printf("auth: active membership lookup failed: %v", mErr)
		return nil, errInternal
	}

	tok, exp, err := s.keys.IssueAccountToken(userID, tokenVersion, now)
	if err != nil {
		return nil, errInternal
	}
	s.auditBestEffort(ctx, nil, "ACCOUNT_LOGIN", &userID, nil, "", nil, ip)

	return &AccountLoginResult{
		AccessToken: tok,
		TokenType:   "Bearer",
		ExpiresAt:   exp,
		User: UserInfo{
			ID:       userID,
			Name:     name,
			Email:    email,
			Username: username,
		},
		Membership: membership,
	}, nil
}

// ---------------------------------------------------------------- Forgot / Reset Password

// ForgotPassword issues a 6-digit password reset code if the account exists.
// Always succeeds (202) to prevent email enumeration.
func (s *Service) ForgotPassword(ctx context.Context, emailRaw, ip string) error {
	email, err := normalizeEmail(emailRaw)
	if err != nil {
		return newErr(http.StatusBadRequest, CodeBadRequest, err.Error())
	}
	now := s.now()
	if ok, wait := s.resendLimit.Allow("fp:"+email, now); !ok {
		return &Error{Status: http.StatusTooManyRequests, Code: CodeRateLimited, Message: "please wait before requesting another reset code", RetryAfter: wait}
	}
	if ok, wait := s.signupIPLimit.Allow("fp_ip:"+ip, now); !ok {
		return &Error{Status: http.StatusTooManyRequests, Code: CodeRateLimited, Message: "too many requests from this network", RetryAfter: wait}
	}

	var (
		userID string
		name   string
		active bool
	)
	err = s.db.QueryRow(ctx, `
		SELECT id, name, COALESCE(is_active, FALSE)
		FROM users WHERE email = $1 AND deleted_at IS NULL`, email).
		Scan(&userID, &name, &active)
	if errors.Is(err, pgx.ErrNoRows) || !active {
		return nil // no enumeration
	}
	if err != nil {
		return errInternal
	}

	code, err := generateSixDigitCode()
	if err != nil {
		return errInternal
	}
	codeHash := hashEmailCode(purposePasswordReset, userID, code)
	expiresAt := now.Add(emailCodeTTL)

	tx, err := s.db.Begin(ctx)
	if err != nil {
		return errInternal
	}
	defer tx.Rollback(ctx)

	if _, err := tx.Exec(ctx, `
		UPDATE email_verification_codes SET consumed_at = $1
		WHERE user_id = $2 AND purpose = $3 AND consumed_at IS NULL`, now, userID, purposePasswordReset); err != nil {
		return errInternal
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO email_verification_codes (id, user_id, code_hash, purpose, expires_at)
		VALUES ($1, $2, $3, $4, $5)`,
		uuid.NewString(), userID, codeHash, purposePasswordReset, expiresAt); err != nil {
		return errInternal
	}
	if err := s.audit(ctx, tx, nil, "PASSWORD_RESET_REQUEST", &userID, nil, "", nil, ip); err != nil {
		return errInternal
	}
	if err := tx.Commit(ctx); err != nil {
		return errInternal
	}

	s.mailer.Enqueue(pmail.PasswordResetMessage(email, name, code))
	return nil
}

// ResetPassword validates the 6-digit reset code, sets the new password,
// bumps token_version (invalidating all Account & Device JWTs), and clears
// active device leases for the user.
func (s *Service) ResetPassword(ctx context.Context, in ResetPasswordInput, ip string) error {
	email, err := normalizeEmail(in.Email)
	if err != nil {
		return newErr(http.StatusBadRequest, CodeBadRequest, err.Error())
	}
	code := strings.TrimSpace(in.Code)
	if len(code) != 6 {
		return newErr(http.StatusBadRequest, CodeCodeInvalid, "6-digit reset code is required")
	}

	now := s.now()
	if blocked, wait := s.ipFail.Blocked("reset:"+ip, now); blocked {
		return &Error{Status: http.StatusTooManyRequests, Code: CodeRateLimited, Message: "too many reset attempts", RetryAfter: wait}
	}

	tx, err := s.db.Begin(ctx)
	if err != nil {
		return errInternal
	}
	defer tx.Rollback(ctx)

	var (
		userID   string
		username string
		active   bool
	)
	err = tx.QueryRow(ctx, `
		SELECT id, username, COALESCE(is_active, FALSE)
		FROM users WHERE email = $1 AND deleted_at IS NULL FOR UPDATE`, email).
		Scan(&userID, &username, &active)
	if errors.Is(err, pgx.ErrNoRows) || !active {
		s.ipFail.Fail("reset:"+ip, now)
		return newErr(http.StatusBadRequest, CodeCodeInvalid, "invalid or expired reset code")
	}
	if err != nil {
		return errInternal
	}

	if err := ValidateSignupPassword(in.NewPassword, username, email); err != nil {
		return newErr(http.StatusBadRequest, CodeBadRequest, err.Error())
	}

	if err := s.consumeEmailCodeTx(ctx, tx, userID, purposePasswordReset, code, now); err != nil {
		var ae *Error
		if errors.As(err, &ae) {
			s.ipFail.Fail("reset:"+ip, now)
			_ = tx.Commit(ctx)
			return ae
		}
		return errInternal
	}

	newHash, err := HashSecret(in.NewPassword)
	if err != nil {
		return errInternal
	}
	if _, err := tx.Exec(ctx, `
		UPDATE users
		SET password_hash = $1,
		    token_version = token_version + 1,
		    email_verified_at = COALESCE(email_verified_at, $2),
		    updated_at = $2
		WHERE id = $3`, newHash, now, userID); err != nil {
		return errInternal
	}

	// Clear active device leases held by this user inside their active store (if any).
	var storeID string
	if err := tx.QueryRow(ctx, `SELECT store_id FROM lookup_user_active_membership($1)`, userID).Scan(&storeID); err == nil && storeID != "" {
		if _, err := tx.Exec(ctx, `SELECT set_config('app.store_id', $1, true)`, storeID); err != nil {
			return errInternal
		}
		if _, err := tx.Exec(ctx, `
			UPDATE device_registrations
			SET current_lease_id = NULL, current_user_id = NULL, updated_at = $1
			WHERE store_id = $2 AND current_user_id = $3`, now, storeID, userID); err != nil {
			return errInternal
		}
	}

	if err := s.audit(ctx, tx, nil, "PASSWORD_RESET", &userID, nil, "", nil, ip); err != nil {
		return errInternal
	}
	return tx.Commit(ctx)
}

// ---------------------------------------------------------------- Delete Account (Play Console)

// DeleteAccount verifies password, ensures the user is not an active store OWNER,
// leaves any active store membership (revoking devices + force-closing shifts),
// and anonymizes all PII.
func (s *Service) DeleteAccount(ctx context.Context, acct AccountSession, in DeleteAccountInput, ip string) error {
	if in.Password == "" {
		return newErr(http.StatusBadRequest, CodeBadRequest, "password is required")
	}

	var pwHash string
	err := s.db.QueryRow(ctx, `SELECT password_hash FROM users WHERE id = $1 AND deleted_at IS NULL`, acct.UserID).Scan(&pwHash)
	if errors.Is(err, pgx.ErrNoRows) {
		return newErr(http.StatusUnauthorized, CodeTokenInvalid, "account not found")
	}
	if err != nil {
		return errInternal
	}
	ok, err := VerifySecret(ctx, in.Password, pwHash)
	if err != nil {
		return errInternal
	}
	if !ok {
		return newErr(http.StatusUnauthorized, CodeInvalidCredentials, "incorrect password")
	}

	var (
		storeID string
		role    string
	)
	mErr := s.db.QueryRow(ctx, `SELECT store_id, role FROM lookup_user_active_membership($1)`, acct.UserID).
		Scan(&storeID, &role)
	if mErr == nil {
		if role == RoleOwner {
			return newErr(http.StatusConflict, CodeOwnerMustTransfer, "store owners must transfer ownership or close the store before deleting their account")
		}
	} else if !errors.Is(mErr, pgx.ErrNoRows) {
		return errInternal
	}

	now := s.now()
	var revokedDevices []deviceCodePair
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return errInternal
	}
	defer tx.Rollback(ctx)

	if storeID != "" {
		if _, err := tx.Exec(ctx, `SELECT set_config('app.store_id', $1, true)`, storeID); err != nil {
			return errInternal
		}
		if _, err := tx.Exec(ctx, `
			UPDATE store_memberships
			SET status = 'LEFT', ended_at = $1, updated_at = $1
			WHERE store_id = $2 AND user_id = $3 AND status = 'ACTIVE'`, now, storeID, acct.UserID); err != nil {
			return errInternal
		}
		if _, err := tx.Exec(ctx, `
			UPDATE staff_shift_sessions
			SET status = 'FORCE_CLOSED', punched_out_at = $1, updated_at = $1
			WHERE store_id = $2 AND user_id = $3 AND status = 'ACTIVE'`, now, storeID, acct.UserID); err != nil {
			return errInternal
		}
		rows, err := tx.Query(ctx, `
			UPDATE device_registrations
			SET status = CASE WHEN status = 'PENDING' THEN 'REJECTED' ELSE 'REVOKED' END,
			    is_active = FALSE,
			    revoked_at = CASE WHEN status = 'PENDING' THEN NULL::timestamptz ELSE $1::timestamptz END,
			    revocation_reason = 'account deleted',
			    current_lease_id = NULL,
			    current_user_id = NULL,
			    updated_at = $1
			WHERE store_id = $2
			  AND (current_user_id = $3 OR requested_by_user_id = $3)
			  AND status IN ('ACTIVE', 'PENDING')
			RETURNING id, COALESCE(device_code, '')`, now, storeID, acct.UserID)
		if err != nil {
			return errInternal
		}
		for rows.Next() {
			var p deviceCodePair
			if err := rows.Scan(&p.id, &p.code); err == nil {
				revokedDevices = append(revokedDevices, p)
			}
		}
		rows.Close()
	}

	anonEmail := fmt.Sprintf("deleted-%s@deleted.pasalx.local", acct.UserID)
	anonUser := "deleted_" + strings.ReplaceAll(acct.UserID, "-", "")
	if len(anonUser) > 50 {
		anonUser = anonUser[:50]
	}
	if _, err := tx.Exec(ctx, `
		UPDATE users
		SET name = 'Deleted User',
		    email = $1,
		    username = $2,
		    password_hash = '!deleted',
		    pin_hash = NULL,
		    phone = NULL,
		    is_active = FALSE,
		    token_version = token_version + 1,
		    deleted_at = $3,
		    updated_at = $3
		WHERE id = $4 AND deleted_at IS NULL`, anonEmail, anonUser, now, acct.UserID); err != nil {
		return errInternal
	}
	if err := s.audit(ctx, tx, nil, "ACCOUNT_DELETE", &acct.UserID, nil, "", nil, ip); err != nil {
		return errInternal
	}
	if err := tx.Commit(ctx); err != nil {
		return errInternal
	}

	if storeID != "" {
		if s.onDeviceRevoked != nil {
			for _, d := range revokedDevices {
				s.onDeviceRevoked(storeID, d.id, d.code)
			}
		}
		if s.onStoreDataChanged != nil {
			s.onStoreDataChanged(storeID)
		}
	}
	return nil
}

// ---------------------------------------------------------------- Admin CLI helpers

// AdminResetPassword resets a user's password by email or username and bumps token_version.
func (s *Service) AdminResetPassword(ctx context.Context, identifier, newPassword string) error {
	id := strings.ToLower(strings.TrimSpace(identifier))
	if id == "" {
		return errors.New("email or username is required")
	}
	var userID, username, email string
	err := s.db.QueryRow(ctx, `
		SELECT id, username, email::text FROM users
		WHERE (email = $1 OR username = $1) AND deleted_at IS NULL`, id).
		Scan(&userID, &username, &email)
	if err != nil {
		return fmt.Errorf("user %q not found: %w", identifier, err)
	}
	if err := ValidateSignupPassword(newPassword, username, email); err != nil {
		return err
	}
	h, err := HashSecret(newPassword)
	if err != nil {
		return err
	}
	_, err = s.db.Exec(ctx, `
		UPDATE users SET password_hash = $1, token_version = token_version + 1, updated_at = CURRENT_TIMESTAMP
		WHERE id = $2`, h, userID)
	return err
}

// AdminVerifyEmail marks a user's email verified by email or username.
func (s *Service) AdminVerifyEmail(ctx context.Context, identifier string) error {
	id := strings.ToLower(strings.TrimSpace(identifier))
	if id == "" {
		return errors.New("email or username is required")
	}
	tag, err := s.db.Exec(ctx, `
		UPDATE users SET email_verified_at = COALESCE(email_verified_at, CURRENT_TIMESTAMP), updated_at = CURRENT_TIMESTAMP
		WHERE (email = $1 OR username = $1) AND deleted_at IS NULL`, id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("user %q not found", identifier)
	}
	return nil
}

// ---------------------------------------------------------------- Helpers

func generateSixDigitCode() (string, error) {
	var b [4]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	n := binary.BigEndian.Uint32(b[:]) % 1_000_000
	return fmt.Sprintf("%06d", n), nil
}

func hashEmailCode(purpose, userID, code string) []byte {
	sum := sha256.Sum256([]byte(purpose + ":" + userID + ":" + code))
	return sum[:]
}

func (s *Service) consumeEmailCodeTx(ctx context.Context, tx pgx.Tx, userID, purpose, code string, now time.Time) error {
	var (
		codeID    string
		codeHash  []byte
		expiresAt time.Time
		attempts  int
	)
	err := tx.QueryRow(ctx, `
		SELECT id, code_hash, expires_at, attempts
		FROM email_verification_codes
		WHERE user_id = $1 AND purpose = $2 AND consumed_at IS NULL
		ORDER BY created_at DESC
		LIMIT 1
		FOR UPDATE`, userID, purpose).
		Scan(&codeID, &codeHash, &expiresAt, &attempts)
	if errors.Is(err, pgx.ErrNoRows) {
		return newErr(http.StatusBadRequest, CodeCodeInvalid, "invalid or expired code")
	}
	if err != nil {
		return err
	}
	if !expiresAt.After(now) {
		return newErr(http.StatusBadRequest, CodeCodeExpired, "code has expired; please request a new one")
	}
	if attempts >= maxEmailCodeAttempts {
		return newErr(http.StatusTooManyRequests, CodeCodeExpired, "too many attempts for this code; please request a new one")
	}

	if _, err := tx.Exec(ctx, `UPDATE email_verification_codes SET attempts = attempts + 1 WHERE id = $1`, codeID); err != nil {
		return err
	}
	gotHash := hashEmailCode(purpose, userID, code)
	if subtle.ConstantTimeCompare(gotHash, codeHash) != 1 {
		return newErr(http.StatusBadRequest, CodeCodeInvalid, "invalid verification code")
	}
	if _, err := tx.Exec(ctx, `UPDATE email_verification_codes SET consumed_at = $1 WHERE id = $2`, now, codeID); err != nil {
		return err
	}
	return nil
}

type deviceCodePair struct {
	id   string
	code string
}
