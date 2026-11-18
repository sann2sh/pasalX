package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"pasalx/server/internal/db"
	pmail "pasalx/server/internal/mail"
)

const (
	inviteCodeAlphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ" // 32 chars, no 0/O/1/I
	inviteTTL          = 48 * time.Hour
)

// ---------------------------------------------------------------- Store & Team Types

type StoreInfo struct {
	ID        string     `json:"id"`
	Name      string     `json:"name"`
	PANNumber *string    `json:"pan_number,omitempty"`
	Phone     *string    `json:"phone,omitempty"`
	Address   *string    `json:"address,omitempty"`
	Status    string     `json:"status"`
	ClosedAt  *time.Time `json:"closed_at,omitempty"`
	CreatedAt time.Time  `json:"created_at"`
	UpdatedAt time.Time  `json:"updated_at"`
}

type CreateStoreInput struct {
	StoreName  string  `json:"store_name"`
	PANNumber  *string `json:"pan_number"`
	Phone      *string `json:"phone"`
	Address    *string `json:"address"`
	DeviceName string  `json:"device_name"`
	Platform   string  `json:"platform"`
}

type CreateStoreResult struct {
	Store       StoreInfo  `json:"store"`
	AccessToken string     `json:"access_token"`
	TokenType   string     `json:"token_type"`
	ExpiresAt   time.Time  `json:"expires_at"`
	User        UserInfo   `json:"user"`
	Device      DeviceInfo `json:"device"`
	Lease       LeaseInfo  `json:"lease"`
}

type UpdateStoreInput struct {
	Name      *string `json:"name"`
	PANNumber *string `json:"pan_number"`
	Phone     *string `json:"phone"`
	Address   *string `json:"address"`
}

type CreateInvitationInput struct {
	Role         string  `json:"role"`
	InvitedEmail *string `json:"invited_email"`
	SendEmail    bool    `json:"send_email"`
}

type InvitationInfo struct {
	ID           string     `json:"id"`
	StoreID      string     `json:"store_id"`
	Role         string     `json:"role"`
	InvitedEmail *string    `json:"invited_email,omitempty"`
	Status       string     `json:"status"`
	ExpiresAt    time.Time  `json:"expires_at"`
	CreatedAt    time.Time  `json:"created_at"`
	Code         string     `json:"code,omitempty"` // populated ONLY on creation
}

type AcceptInvitationInput struct {
	Code       string `json:"code"`
	DeviceName string `json:"device_name"`
	Platform   string `json:"platform"`
}

type EnrollDeviceInput struct {
	DeviceName string `json:"device_name"`
	Platform   string `json:"platform"`
}

type DeviceStatusResult struct {
	DeviceID         string  `json:"device_id"`
	DeviceCode       *string `json:"device_code,omitempty"`
	DeviceName       string  `json:"device_name"`
	Platform         string  `json:"platform"`
	Status           string  `json:"status"`
	StoreID          string  `json:"store_id"`
	StoreName        string  `json:"store_name"`
	Role             string  `json:"role"`
	RevocationReason *string `json:"revocation_reason,omitempty"`
}

type RejectDeviceInput struct {
	Reason string `json:"reason"`
}

type MemberInfo struct {
	UserID   string    `json:"user_id"`
	Name     string    `json:"name"`
	Username string    `json:"username"`
	Email    string    `json:"email,omitempty"`
	Role     string    `json:"role"`
	Status   string    `json:"status"`
	JoinedAt time.Time `json:"joined_at"`
}

type UpdateMemberRoleInput struct {
	Role string `json:"role"`
}

type ResetMemberPINInput struct {
	NewPIN string `json:"new_pin"`
}

type LeaveStoreInput struct {
	OutboxEmpty    bool `json:"outbox_empty"`
	DiscardUnsynced bool `json:"discard_unsynced"`
}

type TransferOwnershipInput struct {
	TargetUserID string `json:"target_user_id"`
	Password     string `json:"password"`
}

type CloseStoreInput struct {
	Password string `json:"password"`
}

// ---------------------------------------------------------------- Store Lifecycle

// CreateStore creates a new store, assigns the verified caller as OWNER,
// enrolls their current device as 01 ACTIVE, and returns a Device JWT + KEK lease.
func (s *Service) CreateStore(ctx context.Context, acct AccountSession, in CreateStoreInput, ip string) (*CreateStoreResult, error) {
	if !acct.EmailVerified {
		return nil, newErr(http.StatusForbidden, CodeEmailNotVerified, "verify your email before creating a store")
	}
	storeName := strings.TrimSpace(in.StoreName)
	if storeName == "" || len(storeName) > 150 {
		return nil, newErr(http.StatusBadRequest, CodeBadRequest, "store_name must be 1-150 characters")
	}
	devName := strings.TrimSpace(in.DeviceName)
	if devName == "" || len(devName) > 100 {
		return nil, newErr(http.StatusBadRequest, CodeBadRequest, "device_name must be 1-100 characters")
	}
	platform := strings.ToUpper(strings.TrimSpace(in.Platform))
	if platform != "ANDROID" && platform != "IOS" && platform != "LINUX" {
		return nil, newErr(http.StatusBadRequest, CodeBadRequest, "platform must be ANDROID, IOS or LINUX")
	}

	var existingStore string
	if err := s.db.QueryRow(ctx, `SELECT store_id FROM lookup_user_active_membership($1)`, acct.UserID).Scan(&existingStore); err == nil && existingStore != "" {
		return nil, newErr(http.StatusConflict, CodeAlreadyInStore, "you already belong to an active store; leave it before creating a new one")
	} else if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, errInternal
	}

	dek, err := GenerateDEK()
	if err != nil {
		return nil, errInternal
	}
	defer Zero(dek)

	storeID := uuid.NewString()
	deviceID := uuid.NewString()
	sealed, err := s.keys.SealDEK(deviceID, dek)
	if err != nil {
		return nil, errInternal
	}
	now := s.now()
	leaseID := uuid.NewString()
	expires := now.Add(LeaseDuration)
	lease, err := s.keys.IssueLease(deviceID, leaseID, now, expires, dek)
	if err != nil {
		return nil, errInternal
	}

	tx, err := s.db.Begin(ctx)
	if err != nil {
		return nil, errInternal
	}
	defer tx.Rollback(ctx)

	var st StoreInfo
	err = tx.QueryRow(ctx, `
		INSERT INTO stores (id, name, pan_number, phone, address, status, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, 'ACTIVE', $6, $6)
		RETURNING id, name, pan_number, phone, address, status, created_at, updated_at`,
		storeID, storeName, trimOpt(in.PANNumber), trimOpt(in.Phone), trimOpt(in.Address), now).
		Scan(&st.ID, &st.Name, &st.PANNumber, &st.Phone, &st.Address, &st.Status, &st.CreatedAt, &st.UpdatedAt)
	if err != nil {
		log.Printf("auth: create store insert failed: %v", err)
		return nil, errInternal
	}

	if _, err := tx.Exec(ctx, `SELECT set_config('app.store_id', $1, true)`, storeID); err != nil {
		return nil, errInternal
	}

	if _, err := tx.Exec(ctx, `
		INSERT INTO store_memberships (id, store_id, user_id, role, status, joined_at, created_at, updated_at)
		VALUES ($1, $2, $3, $4, 'ACTIVE', $5, $5, $5)`,
		uuid.NewString(), storeID, acct.UserID, RoleOwner, now); err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return nil, newErr(http.StatusConflict, CodeAlreadyInStore, "you already belong to an active store")
		}
		log.Printf("auth: create store membership failed: %v", err)
		return nil, errInternal
	}

	const devCode = "01"
	if _, err := tx.Exec(ctx, `
		INSERT INTO device_registrations
			(id, store_id, device_code, device_name, platform, is_active, status, dek_sealed,
			 requested_by_user_id, registered_by_user_id, current_lease_id, current_user_id,
			 last_kek_lease_issued_at, last_kek_lease_expires_at, registered_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, TRUE, 'ACTIVE', $6, $7, $7, $8, $7, $9, $10, $9, $9)`,
		deviceID, storeID, devCode, devName, platform, sealed, acct.UserID, leaseID, now, expires); err != nil {
		log.Printf("auth: create store device failed: %v", err)
		return nil, errInternal
	}

	if err := s.audit(ctx, tx, &storeID, "STORE_CREATE", &acct.UserID, &deviceID, devCode,
		map[string]any{"store_name": storeName, "device_name": devName}, ip); err != nil {
		return nil, errInternal
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, errInternal
	}

	u := UserInfo{ID: acct.UserID, Name: acct.Name, Email: acct.Email, Username: acct.Username, Role: RoleOwner}
	d := DeviceInfo{
		ID: deviceID, StoreID: storeID, Code: devCode, Name: devName, Platform: platform,
		Status: "ACTIVE", CurrentUserID: &acct.UserID, CurrentUserName: &acct.Name, LeaseExpiresAt: &expires,
	}
	res, err := s.buildResult(u, acct.TokenVersion, d, lease, now)
	if err != nil {
		return nil, errInternal
	}

	return &CreateStoreResult{
		Store:       st,
		AccessToken: res.AccessToken,
		TokenType:   res.TokenType,
		ExpiresAt:   res.ExpiresAt,
		User:        res.User,
		Device:      res.Device,
		Lease:       res.Lease,
	}, nil
}

// GetCurrentStore returns the store profile for the caller's device session.
func (s *Service) GetCurrentStore(ctx context.Context, sess Session) (StoreInfo, error) {
	var st StoreInfo
	err := db.WithTenantTxOptions(ctx, s.db, sess.StoreID, pgx.TxOptions{AccessMode: pgx.ReadOnly}, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `
			SELECT id, name, pan_number, phone, address, status, closed_at, created_at, updated_at
			FROM stores WHERE id = $1`, sess.StoreID).
			Scan(&st.ID, &st.Name, &st.PANNumber, &st.Phone, &st.Address, &st.Status, &st.ClosedAt, &st.CreatedAt, &st.UpdatedAt)
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return StoreInfo{}, newErr(http.StatusNotFound, CodeNotFound, "store not found")
	}
	if err != nil {
		return StoreInfo{}, errInternal
	}
	return st, nil
}

// UpdateCurrentStore updates store metadata (OWNER or MANAGER) and triggers SSE sync.
func (s *Service) UpdateCurrentStore(ctx context.Context, sess Session, in UpdateStoreInput, ip string) (StoreInfo, error) {
	if in.Name != nil {
		trimmed := strings.TrimSpace(*in.Name)
		if trimmed == "" || len(trimmed) > 150 {
			return StoreInfo{}, newErr(http.StatusBadRequest, CodeBadRequest, "store name must be 1-150 characters")
		}
		in.Name = &trimmed
	}
	now := s.now()
	var st StoreInfo
	err := db.WithTenantTx(ctx, s.db, sess.StoreID, func(tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `
			UPDATE stores
			SET name = COALESCE($1, name),
			    pan_number = COALESCE($2, pan_number),
			    phone = COALESCE($3, phone),
			    address = COALESCE($4, address),
			    updated_at = $5
			WHERE id = $6 AND status = 'ACTIVE'
			RETURNING id, name, pan_number, phone, address, status, closed_at, created_at, updated_at`,
			in.Name, trimOpt(in.PANNumber), trimOpt(in.Phone), trimOpt(in.Address), now, sess.StoreID).
			Scan(&st.ID, &st.Name, &st.PANNumber, &st.Phone, &st.Address, &st.Status, &st.ClosedAt, &st.CreatedAt, &st.UpdatedAt)
		if err != nil {
			return err
		}
		return s.audit(ctx, tx, &sess.StoreID, "STORE_UPDATE", &sess.UserID, &sess.DeviceID, sess.DeviceCode, nil, ip)
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return StoreInfo{}, newErr(http.StatusNotFound, CodeNotFound, "active store not found")
	}
	if err != nil {
		return StoreInfo{}, errInternal
	}
	if s.onStoreDataChanged != nil {
		s.onStoreDataChanged(sess.StoreID)
	}
	return st, nil
}

// ---------------------------------------------------------------- Hashed Invitations

// CreateInvitation generates a single-use 48h invitation code (PSX-XXXXX-XXXXX),
// stores only its SHA-256 hash, and optionally emails it.
func (s *Service) CreateInvitation(ctx context.Context, sess Session, in CreateInvitationInput, ip string) (InvitationInfo, error) {
	role := strings.ToUpper(strings.TrimSpace(in.Role))
	if role != RoleManager && role != RoleStaff {
		return InvitationInfo{}, newErr(http.StatusBadRequest, CodeBadRequest, "invitation role must be MANAGER or STAFF")
	}

	var invitedEmail *string
	if in.InvitedEmail != nil && strings.TrimSpace(*in.InvitedEmail) != "" {
		em, err := normalizeEmail(*in.InvitedEmail)
		if err != nil {
			return InvitationInfo{}, newErr(http.StatusBadRequest, CodeBadRequest, err.Error())
		}
		invitedEmail = &em
	}

	rawCode, formattedCode, codeHash, err := generateInviteCode()
	if err != nil {
		return InvitationInfo{}, errInternal
	}
	_ = rawCode

	now := s.now()
	expiresAt := now.Add(inviteTTL)
	invID := uuid.NewString()
	var storeName, inviterName string

	err = db.WithTenantTx(ctx, s.db, sess.StoreID, func(tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `SELECT name FROM stores WHERE id = $1`, sess.StoreID).Scan(&storeName); err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `SELECT name FROM users WHERE id = $1`, sess.UserID).Scan(&inviterName); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO store_invitations
				(id, store_id, invited_by_user_id, role, code_hash, invited_email, status, expires_at, created_at, updated_at)
			VALUES ($1, $2, $3, $4, $5, $6, 'PENDING', $7, $8, $8)`,
			invID, sess.StoreID, sess.UserID, role, codeHash, invitedEmail, expiresAt, now); err != nil {
			return err
		}
		return s.audit(ctx, tx, &sess.StoreID, "INVITE_CREATE", &sess.UserID, &sess.DeviceID, sess.DeviceCode,
			map[string]any{"invitation_id": invID, "role": role, "email_bound": invitedEmail != nil}, ip)
	})
	if err != nil {
		log.Printf("auth: create invitation failed: %v", err)
		return InvitationInfo{}, errInternal
	}

	if in.SendEmail && invitedEmail != nil {
		s.mailer.Enqueue(pmail.InvitationMessage(*invitedEmail, storeName, inviterName, role, formattedCode, expiresAt))
	}

	return InvitationInfo{
		ID:           invID,
		StoreID:      sess.StoreID,
		Role:         role,
		InvitedEmail: invitedEmail,
		Status:       "PENDING",
		ExpiresAt:    expiresAt,
		CreatedAt:    now,
		Code:         formattedCode,
	}, nil
}

// ListInvitations lists pending invitations in the caller's store (never exposes codes).
func (s *Service) ListInvitations(ctx context.Context, sess Session) ([]InvitationInfo, error) {
	var list []InvitationInfo
	err := db.WithTenantTxOptions(ctx, s.db, sess.StoreID, pgx.TxOptions{AccessMode: pgx.ReadOnly}, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT id, store_id, role, invited_email::text, status, expires_at, created_at
			FROM store_invitations
			WHERE store_id = $1 AND status = 'PENDING' AND expires_at > CURRENT_TIMESTAMP
			ORDER BY created_at DESC`, sess.StoreID)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var inv InvitationInfo
			if err := rows.Scan(&inv.ID, &inv.StoreID, &inv.Role, &inv.InvitedEmail, &inv.Status, &inv.ExpiresAt, &inv.CreatedAt); err != nil {
				return err
			}
			list = append(list, inv)
		}
		return rows.Err()
	})
	if err != nil {
		return nil, errInternal
	}
	if list == nil {
		list = []InvitationInfo{}
	}
	return list, nil
}

// RevokeInvitation revokes a pending invitation in the caller's store.
func (s *Service) RevokeInvitation(ctx context.Context, sess Session, invitationID, ip string) error {
	now := s.now()
	err := db.WithTenantTx(ctx, s.db, sess.StoreID, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `
			UPDATE store_invitations SET status = 'REVOKED', updated_at = $1
			WHERE id = $2 AND store_id = $3 AND status = 'PENDING'`, now, invitationID, sess.StoreID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return newErr(http.StatusNotFound, CodeNotFound, "pending invitation not found")
		}
		return s.audit(ctx, tx, &sess.StoreID, "INVITE_REVOKE", &sess.UserID, &sess.DeviceID, sess.DeviceCode,
			map[string]any{"invitation_id": invitationID}, ip)
	})
	if err != nil {
		var ae *Error
		if errors.As(err, &ae) {
			return ae
		}
		log.Printf("auth: revoke invitation failed: %v", err)
		return errInternal
	}
	return nil
}

// ---------------------------------------------------------------- Invite Acceptance & Device Approval

// AcceptInvitation validates an invite code, joins the store, and registers
// the caller's phone in PENDING status (no DEK, no lease, no data until Owner approves).
func (s *Service) AcceptInvitation(ctx context.Context, acct AccountSession, in AcceptInvitationInput, ip string) (DeviceStatusResult, error) {
	if !acct.EmailVerified {
		return DeviceStatusResult{}, newErr(http.StatusForbidden, CodeEmailNotVerified, "verify your email before accepting an invitation")
	}
	now := s.now()
	if ok, wait := s.inviteGlobalLimit.Allow("global", now); !ok {
		return DeviceStatusResult{}, &Error{Status: http.StatusTooManyRequests, Code: CodeRateLimited, Message: "too many invitation attempts; try again shortly", RetryAfter: wait}
	}
	if ok, wait := s.inviteIPLimit.Allow("ip:"+ip, now); !ok {
		return DeviceStatusResult{}, &Error{Status: http.StatusTooManyRequests, Code: CodeRateLimited, Message: "too many invitation attempts from this network", RetryAfter: wait}
	}
	if ok, wait := s.inviteAcctLimit.Allow("acct:"+acct.UserID, now); !ok {
		return DeviceStatusResult{}, &Error{Status: http.StatusTooManyRequests, Code: CodeRateLimited, Message: "too many invitation attempts; wait 15 minutes", RetryAfter: wait}
	}

	devName := strings.TrimSpace(in.DeviceName)
	if devName == "" || len(devName) > 100 {
		return DeviceStatusResult{}, newErr(http.StatusBadRequest, CodeBadRequest, "device_name must be 1-100 characters")
	}
	platform := strings.ToUpper(strings.TrimSpace(in.Platform))
	if platform != "ANDROID" && platform != "IOS" && platform != "LINUX" {
		return DeviceStatusResult{}, newErr(http.StatusBadRequest, CodeBadRequest, "platform must be ANDROID, IOS or LINUX")
	}
	normCode := normalizeInviteCode(in.Code)
	if len(normCode) != 10 {
		return DeviceStatusResult{}, newErr(http.StatusBadRequest, CodeInviteInvalid, "invalid invitation code")
	}
	sum := sha256.Sum256([]byte(normCode))

	var existingStore string
	if err := s.db.QueryRow(ctx, `SELECT store_id FROM lookup_user_active_membership($1)`, acct.UserID).Scan(&existingStore); err == nil && existingStore != "" {
		return DeviceStatusResult{}, newErr(http.StatusConflict, CodeAlreadyInStore, "you already belong to an active store; leave it first")
	} else if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return DeviceStatusResult{}, errInternal
	}

	var (
		invID        string
		storeID      string
		role         string
		invitedEmail *string
		status       string
		expiresAt    time.Time
	)
	err := s.db.QueryRow(ctx, `SELECT id, store_id, role, invited_email::text, status, expires_at FROM lookup_invitation_by_hash($1)`, sum[:]).
		Scan(&invID, &storeID, &role, &invitedEmail, &status, &expiresAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return DeviceStatusResult{}, newErr(http.StatusBadRequest, CodeInviteInvalid, "invalid or expired invitation code")
	}
	if err != nil {
		return DeviceStatusResult{}, errInternal
	}
	if status != "PENDING" || !expiresAt.After(now) {
		return DeviceStatusResult{}, newErr(http.StatusBadRequest, CodeInviteInvalid, "invitation has expired or already been used")
	}
	if invitedEmail != nil && !strings.EqualFold(acct.Email, *invitedEmail) {
		return DeviceStatusResult{}, newErr(http.StatusForbidden, CodeInviteEmailMismatch, "this invitation was issued for a different email address")
	}

	deviceID := uuid.NewString()
	var storeName string

	err = db.WithTenantTx(ctx, s.db, storeID, func(tx pgx.Tx) error {
		var curStatus, storeStatus string
		var curExpires time.Time
		if err := tx.QueryRow(ctx, `
			SELECT i.status, i.expires_at, s.name, s.status
			FROM store_invitations i
			JOIN stores s ON s.id = i.store_id
			WHERE i.id = $1 AND i.store_id = $2
			FOR UPDATE OF i`, invID, storeID).
			Scan(&curStatus, &curExpires, &storeName, &storeStatus); err != nil {
			return err
		}
		if curStatus != "PENDING" || !curExpires.After(now) || storeStatus != "ACTIVE" {
			return newErr(http.StatusBadRequest, CodeInviteInvalid, "invitation is no longer valid")
		}

		if _, err := tx.Exec(ctx, `
			UPDATE store_invitations
			SET status = 'ACCEPTED', accepted_by_user_id = $1, accepted_at = $2, updated_at = $2
			WHERE id = $3 AND store_id = $4`, acct.UserID, now, invID, storeID); err != nil {
			return err
		}

		if _, err := tx.Exec(ctx, `
			INSERT INTO store_memberships (id, store_id, user_id, role, status, joined_at, created_at, updated_at)
			VALUES ($1, $2, $3, $4, 'ACTIVE', $5, $5, $5)`,
			uuid.NewString(), storeID, acct.UserID, role, now); err != nil {
			var pgErr *pgconn.PgError
			if errors.As(err, &pgErr) && pgErr.Code == "23505" {
				return newErr(http.StatusConflict, CodeAlreadyInStore, "you already belong to an active store")
			}
			return err
		}

		if _, err := tx.Exec(ctx, `
			INSERT INTO device_registrations
				(id, store_id, device_code, device_name, platform, is_active, status, dek_sealed,
				 requested_by_user_id, registered_at, updated_at)
			VALUES ($1, $2, NULL, $3, $4, FALSE, 'PENDING', NULL, $5, $6, $6)`,
			deviceID, storeID, devName, platform, acct.UserID, now); err != nil {
			return err
		}

		return s.audit(ctx, tx, &storeID, "INVITE_ACCEPT", &acct.UserID, &deviceID, "",
			map[string]any{"invitation_id": invID, "role": role, "device_name": devName}, ip)
	})
	if err != nil {
		var ae *Error
		if errors.As(err, &ae) {
			return DeviceStatusResult{}, ae
		}
		log.Printf("auth: accept invitation failed: %v", err)
		return DeviceStatusResult{}, errInternal
	}

	if s.onStoreDataChanged != nil {
		s.onStoreDataChanged(storeID)
	}

	return DeviceStatusResult{
		DeviceID:   deviceID,
		DeviceName: devName,
		Platform:   platform,
		Status:     "PENDING",
		StoreID:    storeID,
		StoreName:  storeName,
		Role:       role,
	}, nil
}

// EnrollDevice lets an existing active member request approval for an additional phone.
func (s *Service) EnrollDevice(ctx context.Context, acct AccountSession, in EnrollDeviceInput, ip string) (DeviceStatusResult, error) {
	if !acct.EmailVerified {
		return DeviceStatusResult{}, newErr(http.StatusForbidden, CodeEmailNotVerified, "verify your email first")
	}
	devName := strings.TrimSpace(in.DeviceName)
	if devName == "" || len(devName) > 100 {
		return DeviceStatusResult{}, newErr(http.StatusBadRequest, CodeBadRequest, "device_name must be 1-100 characters")
	}
	platform := strings.ToUpper(strings.TrimSpace(in.Platform))
	if platform != "ANDROID" && platform != "IOS" && platform != "LINUX" {
		return DeviceStatusResult{}, newErr(http.StatusBadRequest, CodeBadRequest, "platform must be ANDROID, IOS or LINUX")
	}

	var storeID, role, storeName, storeStatus string
	err := s.db.QueryRow(ctx, `SELECT store_id, role, store_name, store_status FROM lookup_user_active_membership($1)`, acct.UserID).
		Scan(&storeID, &role, &storeName, &storeStatus)
	if errors.Is(err, pgx.ErrNoRows) {
		return DeviceStatusResult{}, newErr(http.StatusForbidden, CodeForbidden, "you do not belong to an active store")
	}
	if err != nil {
		return DeviceStatusResult{}, errInternal
	}
	if storeStatus != "ACTIVE" {
		return DeviceStatusResult{}, newErr(http.StatusForbidden, CodeForbidden, "store is closed")
	}

	deviceID := uuid.NewString()
	now := s.now()
	var (
		devCode *string
		status  = "PENDING"
	)

	var sealed []byte
	if role == "OWNER" {
		dek, err := GenerateDEK()
		if err != nil {
			return DeviceStatusResult{}, errInternal
		}
		defer Zero(dek)
		sealed, err = s.keys.SealDEK(deviceID, dek)
		if err != nil {
			return DeviceStatusResult{}, errInternal
		}
		status = "ACTIVE"
	}

	err = db.WithTenantTx(ctx, s.db, storeID, func(tx pgx.Tx) error {
		if role == "OWNER" {
			if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('devcode:' || $1))`, storeID); err != nil {
				return err
			}
			var maxCode int
			if err := tx.QueryRow(ctx, `
				SELECT COALESCE(MAX(device_code::int), 0) FROM device_registrations
				WHERE store_id = $1 AND device_code ~ '^[0-9]{1,4}$'`, storeID).Scan(&maxCode); err != nil {
				return err
			}
			if maxCode >= maxDeviceCode {
				return newErr(http.StatusConflict, CodeDeviceLimit, "device code space 01-99 exhausted")
			}
			c := fmt.Sprintf("%02d", maxCode+1)
			devCode = &c
			if _, err := tx.Exec(ctx, `
				INSERT INTO device_registrations
					(id, store_id, device_code, device_name, platform, is_active, status, dek_sealed,
					 requested_by_user_id, registered_by_user_id, registered_at, updated_at)
				VALUES ($1, $2, $3, $4, $5, TRUE, 'ACTIVE', $6, $7, $7, $8, $8)`,
				deviceID, storeID, c, devName, platform, sealed, acct.UserID, now); err != nil {
				return err
			}
			return s.audit(ctx, tx, &storeID, "DEVICE_ENROLL_OWNER_AUTO", &acct.UserID, &deviceID, "",
				map[string]any{"device_name": devName, "platform": platform, "device_code": c}, ip)
		}

		if _, err := tx.Exec(ctx, `
			INSERT INTO device_registrations
				(id, store_id, device_code, device_name, platform, is_active, status, dek_sealed,
				 requested_by_user_id, registered_at, updated_at)
			VALUES ($1, $2, NULL, $3, $4, FALSE, 'PENDING', NULL, $5, $6, $6)`,
			deviceID, storeID, devName, platform, acct.UserID, now); err != nil {
			return err
		}
		return s.audit(ctx, tx, &storeID, "DEVICE_ENROLL_REQUEST", &acct.UserID, &deviceID, "",
			map[string]any{"device_name": devName, "platform": platform}, ip)
	})
	if err != nil {
		var appErr *Error
		if errors.As(err, &appErr) {
			return DeviceStatusResult{}, appErr
		}
		return DeviceStatusResult{}, errInternal
	}
	if s.onStoreDataChanged != nil {
		s.onStoreDataChanged(storeID)
	}
	return DeviceStatusResult{
		DeviceID:   deviceID,
		DeviceCode: devCode,
		DeviceName: devName,
		Platform:   platform,
		Status:     status,
		StoreID:    storeID,
		StoreName:  storeName,
		Role:       role,
	}, nil
}

// GetMyDeviceStatus is polled by a pending phone (Account JWT) until approved/rejected.
func (s *Service) GetMyDeviceStatus(ctx context.Context, acct AccountSession, deviceID string) (DeviceStatusResult, error) {
	var storeID, role, storeName string
	err := s.db.QueryRow(ctx, `SELECT store_id, role, store_name FROM lookup_user_active_membership($1)`, acct.UserID).
		Scan(&storeID, &role, &storeName)
	if errors.Is(err, pgx.ErrNoRows) {
		return DeviceStatusResult{}, newErr(http.StatusNotFound, CodeNotFound, "no active store membership")
	}
	if err != nil {
		return DeviceStatusResult{}, errInternal
	}

	var res DeviceStatusResult
	res.StoreID = storeID
	res.StoreName = storeName
	res.Role = role

	err = db.WithTenantTxOptions(ctx, s.db, storeID, pgx.TxOptions{AccessMode: pgx.ReadOnly}, func(tx pgx.Tx) error {
		if strings.TrimSpace(deviceID) != "" {
			return tx.QueryRow(ctx, `
				SELECT id, device_code, device_name, platform, status, revocation_reason
				FROM device_registrations
				WHERE store_id = $1 AND id = $2 AND requested_by_user_id = $3`,
				storeID, deviceID, acct.UserID).
				Scan(&res.DeviceID, &res.DeviceCode, &res.DeviceName, &res.Platform, &res.Status, &res.RevocationReason)
		}
		return tx.QueryRow(ctx, `
			SELECT id, device_code, device_name, platform, status, revocation_reason
			FROM device_registrations
			WHERE store_id = $1 AND requested_by_user_id = $2
			ORDER BY registered_at DESC LIMIT 1`,
			storeID, acct.UserID).
			Scan(&res.DeviceID, &res.DeviceCode, &res.DeviceName, &res.Platform, &res.Status, &res.RevocationReason)
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return DeviceStatusResult{}, newErr(http.StatusNotFound, CodeNotFound, "device registration not found")
	}
	if err != nil {
		return DeviceStatusResult{}, errInternal
	}
	return res, nil
}

// ListStoreDevices lists devices in the caller's store, optionally filtered by status.
func (s *Service) ListStoreDevices(ctx context.Context, sess Session, statusFilter string) ([]DeviceInfo, error) {
	statusFilter = strings.ToUpper(strings.TrimSpace(statusFilter))
	if statusFilter != "" && statusFilter != "PENDING" && statusFilter != "ACTIVE" && statusFilter != "REVOKED" && statusFilter != "REJECTED" {
		return nil, newErr(http.StatusBadRequest, CodeBadRequest, "invalid status filter")
	}
	var out []DeviceInfo
	err := db.WithTenantTxOptions(ctx, s.db, sess.StoreID, pgx.TxOptions{AccessMode: pgx.ReadOnly}, func(tx pgx.Tx) error {
		query := `
			SELECT d.id, d.store_id, COALESCE(d.device_code, ''), d.device_name, d.platform, d.status,
			       COALESCE(d.current_user_id, d.requested_by_user_id),
			       COALESCE(u.name, ru.name),
			       d.last_kek_lease_expires_at, d.revoked_at, d.revocation_reason
			FROM device_registrations d
			LEFT JOIN users u ON u.id = d.current_user_id
			LEFT JOIN users ru ON ru.id = d.requested_by_user_id
			WHERE d.store_id = $1`
		var rows pgx.Rows
		var err error
		if statusFilter != "" {
			rows, err = tx.Query(ctx, query+` AND d.status = $2 ORDER BY d.registered_at DESC`, sess.StoreID, statusFilter)
		} else {
			rows, err = tx.Query(ctx, query+` ORDER BY COALESCE(d.device_code, 'ZZ') ASC, d.registered_at DESC`, sess.StoreID)
		}
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var d DeviceInfo
			if err := rows.Scan(&d.ID, &d.StoreID, &d.Code, &d.Name, &d.Platform, &d.Status,
				&d.CurrentUserID, &d.CurrentUserName, &d.LeaseExpiresAt, &d.RevokedAt, &d.RevocationReason); err != nil {
				return err
			}
			out = append(out, d)
		}
		return rows.Err()
	})
	if err != nil {
		return nil, errInternal
	}
	if out == nil {
		out = []DeviceInfo{}
	}
	return out, nil
}

// ApproveDevice allocates a device code, seals a new DEK, and activates a PENDING device.
func (s *Service) ApproveDevice(ctx context.Context, sess Session, deviceID, ip string) (DeviceInfo, error) {
	dek, err := GenerateDEK()
	if err != nil {
		return DeviceInfo{}, errInternal
	}
	defer Zero(dek)

	sealed, err := s.keys.SealDEK(deviceID, dek)
	if err != nil {
		return DeviceInfo{}, errInternal
	}

	now := s.now()
	var (
		dev       DeviceInfo
		reqUserID *string
		storeName string
	)
	err = db.WithTenantTx(ctx, s.db, sess.StoreID, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('devcode:' || $1))`, sess.StoreID); err != nil {
			return err
		}
		var curStatus string
		if err := tx.QueryRow(ctx, `
			SELECT d.id, d.store_id, d.device_name, d.platform, d.status, d.requested_by_user_id, s.name
			FROM device_registrations d
			JOIN stores s ON s.id = d.store_id
			WHERE d.store_id = $1 AND d.id = $2
			FOR UPDATE OF d`, sess.StoreID, deviceID).
			Scan(&dev.ID, &dev.StoreID, &dev.Name, &dev.Platform, &curStatus, &reqUserID, &storeName); err != nil {
			return err
		}
		if curStatus != "PENDING" {
			return newErr(http.StatusConflict, CodeConflict, "device is not pending approval")
		}

		var maxCode int
		if err := tx.QueryRow(ctx, `
			SELECT COALESCE(MAX(device_code::int), 0) FROM device_registrations
			WHERE store_id = $1 AND device_code ~ '^[0-9]{1,4}$'`, sess.StoreID).Scan(&maxCode); err != nil {
			return err
		}
		if maxCode >= maxDeviceCode {
			return newErr(http.StatusConflict, CodeDeviceLimit, "device code space 01-99 exhausted")
		}
		dev.Code = fmt.Sprintf("%02d", maxCode+1)
		dev.Status = "ACTIVE"

		if _, err := tx.Exec(ctx, `
			UPDATE device_registrations
			SET status = 'ACTIVE', is_active = TRUE, device_code = $1, dek_sealed = $2,
			    registered_by_user_id = $3, updated_at = $4
			WHERE store_id = $5 AND id = $6`,
			dev.Code, sealed, sess.UserID, now, sess.StoreID, deviceID); err != nil {
			return err
		}
		return s.audit(ctx, tx, &sess.StoreID, "DEVICE_APPROVE", &sess.UserID, &dev.ID, dev.Code,
			map[string]any{"device_name": dev.Name}, ip)
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return DeviceInfo{}, newErr(http.StatusNotFound, CodeNotFound, "pending device not found")
	}
	if err != nil {
		var ae *Error
		if errors.As(err, &ae) {
			return DeviceInfo{}, ae
		}
		log.Printf("auth: approve device failed: %v", err)
		return DeviceInfo{}, errInternal
	}

	if reqUserID != nil {
		var email, name string
		if qErr := s.db.QueryRow(ctx, `SELECT email::text, name FROM users WHERE id = $1 AND deleted_at IS NULL`, *reqUserID).Scan(&email, &name); qErr == nil {
			s.mailer.Enqueue(pmail.DeviceApprovalMessage(email, name, storeName, dev.Name, dev.Code, true))
		}
	}
	if s.onStoreDataChanged != nil {
		s.onStoreDataChanged(sess.StoreID)
	}
	return dev, nil
}

// RejectDevice marks a PENDING device REJECTED.
func (s *Service) RejectDevice(ctx context.Context, sess Session, deviceID string, in RejectDeviceInput, ip string) error {
	reason := strings.TrimSpace(in.Reason)
	if reason == "" {
		reason = "declined by owner"
	}
	now := s.now()
	var (
		reqUserID  *string
		deviceName string
		storeName  string
	)
	err := db.WithTenantTx(ctx, s.db, sess.StoreID, func(tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `
			UPDATE device_registrations d
			SET status = 'REJECTED', is_active = FALSE, revoked_by_user_id = $1,
			    revocation_reason = $2, updated_at = $3
			FROM stores s
			WHERE d.store_id = $4 AND d.id = $5 AND d.status = 'PENDING' AND s.id = d.store_id
			RETURNING d.requested_by_user_id, d.device_name, s.name`,
			sess.UserID, reason, now, sess.StoreID, deviceID).
			Scan(&reqUserID, &deviceName, &storeName)
		if err != nil {
			return err
		}
		return s.audit(ctx, tx, &sess.StoreID, "DEVICE_REJECT", &sess.UserID, &deviceID, "",
			map[string]any{"reason": reason}, ip)
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return newErr(http.StatusNotFound, CodeNotFound, "pending device not found")
	}
	if err != nil {
		return errInternal
	}
	if reqUserID != nil {
		var email, name string
		if qErr := s.db.QueryRow(ctx, `SELECT email::text, name FROM users WHERE id = $1 AND deleted_at IS NULL`, *reqUserID).Scan(&email, &name); qErr == nil {
			s.mailer.Enqueue(pmail.DeviceApprovalMessage(email, name, storeName, deviceName, "", false))
		}
	}
	return nil
}

// ---------------------------------------------------------------- Members, Removal & PIN Reset

// ListMembers lists active members of the caller's store.
func (s *Service) ListMembers(ctx context.Context, sess Session) ([]MemberInfo, error) {
	var out []MemberInfo
	err := db.WithTenantTxOptions(ctx, s.db, sess.StoreID, pgx.TxOptions{AccessMode: pgx.ReadOnly}, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT m.user_id, u.name, u.username,
			       CASE WHEN $2 = 'OWNER' THEN u.email::text ELSE '' END,
			       m.role, m.status, m.joined_at
			FROM store_memberships m
			JOIN users u ON u.id = m.user_id
			WHERE m.store_id = $1 AND m.status = 'ACTIVE'
			ORDER BY CASE m.role WHEN 'OWNER' THEN 1 WHEN 'MANAGER' THEN 2 ELSE 3 END, u.name ASC`,
			sess.StoreID, sess.Role)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var m MemberInfo
			if err := rows.Scan(&m.UserID, &m.Name, &m.Username, &m.Email, &m.Role, &m.Status, &m.JoinedAt); err != nil {
				return err
			}
			out = append(out, m)
		}
		return rows.Err()
	})
	if err != nil {
		return nil, errInternal
	}
	if out == nil {
		out = []MemberInfo{}
	}
	return out, nil
}

// UpdateMemberRole changes a member's role between MANAGER and STAFF (Owner only).
func (s *Service) UpdateMemberRole(ctx context.Context, sess Session, targetUserID string, in UpdateMemberRoleInput, ip string) error {
	role := strings.ToUpper(strings.TrimSpace(in.Role))
	if role != RoleManager && role != RoleStaff {
		return newErr(http.StatusBadRequest, CodeBadRequest, "role must be MANAGER or STAFF")
	}
	if targetUserID == sess.UserID {
		return newErr(http.StatusBadRequest, CodeBadRequest, "use transfer-ownership to change owner role")
	}
	now := s.now()
	err := db.WithTenantTx(ctx, s.db, sess.StoreID, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `
			UPDATE store_memberships
			SET role = $1, updated_at = $2
			WHERE store_id = $3 AND user_id = $4 AND status = 'ACTIVE' AND role <> 'OWNER'`,
			role, now, sess.StoreID, targetUserID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return newErr(http.StatusNotFound, CodeNotFound, "active non-owner member not found")
		}
		return s.audit(ctx, tx, &sess.StoreID, "MEMBER_ROLE_CHANGE", &sess.UserID, &sess.DeviceID, sess.DeviceCode,
			map[string]any{"target_user_id": targetUserID, "new_role": role}, ip)
	})
	if err != nil {
		var ae *Error
		if errors.As(err, &ae) {
			return ae
		}
		log.Printf("auth: update member role failed: %v", err)
		return errInternal
	}
	if s.onStoreDataChanged != nil {
		s.onStoreDataChanged(sess.StoreID)
	}
	return nil
}

// RemoveMember removes a staff/manager from the store, revokes all their devices,
// force-closes any ACTIVE staff_shift_sessions (so Z-Report is never blocked),
// and bumps token_version.
func (s *Service) RemoveMember(ctx context.Context, sess Session, targetUserID, ip string) error {
	if targetUserID == sess.UserID {
		return newErr(http.StatusBadRequest, CodeBadRequest, "owner cannot remove self")
	}
	now := s.now()
	var revoked []deviceCodePair
	err := db.WithTenantTx(ctx, s.db, sess.StoreID, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `
			UPDATE store_memberships
			SET status = 'REMOVED', ended_at = $1, updated_at = $1
			WHERE store_id = $2 AND user_id = $3 AND status = 'ACTIVE' AND role <> 'OWNER'`,
			now, sess.StoreID, targetUserID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return newErr(http.StatusNotFound, CodeNotFound, "active non-owner member not found")
		}

		if _, err := tx.Exec(ctx, `
			UPDATE staff_shift_sessions
			SET status = 'FORCE_CLOSED', punched_out_at = $1, force_closed_by_user_id = $2, updated_at = $1
			WHERE store_id = $3 AND user_id = $4 AND status = 'ACTIVE'`,
			now, sess.UserID, sess.StoreID, targetUserID); err != nil {
			return err
		}

		rows, err := tx.Query(ctx, `
			UPDATE device_registrations
			SET status = CASE WHEN status = 'PENDING' THEN 'REJECTED' ELSE 'REVOKED' END,
			    is_active = FALSE,
			    revoked_at = CASE WHEN status = 'PENDING' THEN NULL::timestamptz ELSE $1::timestamptz END,
			    revoked_by_user_id = $2,
			    revocation_reason = 'member removed',
			    current_lease_id = NULL,
			    current_user_id = NULL,
			    updated_at = $1
			WHERE store_id = $3
			  AND (current_user_id = $4 OR requested_by_user_id = $4)
			  AND status IN ('ACTIVE', 'PENDING')
			RETURNING id, COALESCE(device_code, '')`,
			now, sess.UserID, sess.StoreID, targetUserID)
		if err != nil {
			return err
		}
		for rows.Next() {
			var p deviceCodePair
			if err := rows.Scan(&p.id, &p.code); err == nil {
				revoked = append(revoked, p)
			}
		}
		rows.Close()

		if _, err := tx.Exec(ctx, `
			UPDATE users SET token_version = token_version + 1, updated_at = $1 WHERE id = $2`,
			now, targetUserID); err != nil {
			return err
		}
		return s.audit(ctx, tx, &sess.StoreID, "MEMBER_REMOVE", &sess.UserID, &sess.DeviceID, sess.DeviceCode,
			map[string]any{"target_user_id": targetUserID, "revoked_devices": len(revoked)}, ip)
	})
	if err != nil {
		var ae *Error
		if errors.As(err, &ae) {
			return ae
		}
		log.Printf("auth: remove member failed: %v", err)
		return errInternal
	}
	if s.onDeviceRevoked != nil {
		for _, d := range revoked {
			s.onDeviceRevoked(sess.StoreID, d.id, d.code)
		}
	}
	if s.onStoreDataChanged != nil {
		s.onStoreDataChanged(sess.StoreID)
	}
	return nil
}

// ResetMemberPIN sets a new 6-digit PIN for an active member of the store and
// bumps their token_version.
func (s *Service) ResetMemberPIN(ctx context.Context, sess Session, targetUserID string, in ResetMemberPINInput, ip string) error {
	if err := ValidateSignupPIN(in.NewPIN); err != nil {
		return newErr(http.StatusBadRequest, CodeBadRequest, err.Error())
	}
	pinHash, err := HashSecret(in.NewPIN)
	if err != nil {
		return errInternal
	}
	now := s.now()
	err = db.WithTenantTx(ctx, s.db, sess.StoreID, func(tx pgx.Tx) error {
		var exists bool
		if err := tx.QueryRow(ctx, `
			SELECT EXISTS(SELECT 1 FROM store_memberships WHERE store_id = $1 AND user_id = $2 AND status = 'ACTIVE')`,
			sess.StoreID, targetUserID).Scan(&exists); err != nil {
			return err
		}
		if !exists {
			return newErr(http.StatusNotFound, CodeNotFound, "active store member not found")
		}
		if _, err := tx.Exec(ctx, `
			UPDATE users SET pin_hash = $1, token_version = token_version + 1, updated_at = $2 WHERE id = $3`,
			pinHash, now, targetUserID); err != nil {
			return err
		}
		return s.audit(ctx, tx, &sess.StoreID, "MEMBER_PIN_RESET", &sess.UserID, &sess.DeviceID, sess.DeviceCode,
			map[string]any{"target_user_id": targetUserID}, ip)
	})
	if err != nil {
		var ae *Error
		if errors.As(err, &ae) {
			return ae
		}
		log.Printf("auth: reset member pin failed: %v", err)
		return errInternal
	}
	return nil
}

// ---------------------------------------------------------------- Leave, Transfer, Export & Close Store

// LeaveStore lets a MANAGER or STAFF leave their active store after confirming
// outbox status, revoking their devices and force-closing active shift sessions.
func (s *Service) LeaveStore(ctx context.Context, sess Session, in LeaveStoreInput, ip string) error {
	if !in.OutboxEmpty && !in.DiscardUnsynced {
		return newErr(http.StatusConflict, CodeUnsyncedData, "sync pending outbox items or confirm discard_unsynced=true before leaving")
	}
	if sess.Role == RoleOwner {
		return newErr(http.StatusConflict, CodeOwnerMustTransfer, "owner cannot leave store; transfer ownership or close the store first")
	}
	now := s.now()
	var revoked []deviceCodePair
	err := db.WithTenantTx(ctx, s.db, sess.StoreID, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `
			UPDATE store_memberships
			SET status = 'LEFT', ended_at = $1, updated_at = $1
			WHERE store_id = $2 AND user_id = $3 AND status = 'ACTIVE'`,
			now, sess.StoreID, sess.UserID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return newErr(http.StatusNotFound, CodeNotFound, "active membership not found")
		}

		if _, err := tx.Exec(ctx, `
			UPDATE staff_shift_sessions
			SET status = 'FORCE_CLOSED', punched_out_at = $1, updated_at = $1
			WHERE store_id = $2 AND user_id = $3 AND status = 'ACTIVE'`,
			now, sess.StoreID, sess.UserID); err != nil {
			return err
		}

		rows, err := tx.Query(ctx, `
			UPDATE device_registrations
			SET status = CASE WHEN status = 'PENDING' THEN 'REJECTED' ELSE 'REVOKED' END,
			    is_active = FALSE,
			    revoked_at = CASE WHEN status = 'PENDING' THEN NULL::timestamptz ELSE $1::timestamptz END,
			    revocation_reason = 'member left store',
			    current_lease_id = NULL,
			    current_user_id = NULL,
			    updated_at = $1
			WHERE store_id = $2
			  AND (current_user_id = $3 OR requested_by_user_id = $3 OR id = $4)
			  AND status IN ('ACTIVE', 'PENDING')
			RETURNING id, COALESCE(device_code, '')`,
			now, sess.StoreID, sess.UserID, sess.DeviceID)
		if err != nil {
			return err
		}
		for rows.Next() {
			var p deviceCodePair
			if err := rows.Scan(&p.id, &p.code); err == nil {
				revoked = append(revoked, p)
			}
		}
		rows.Close()

		if _, err := tx.Exec(ctx, `
			UPDATE users SET token_version = token_version + 1, updated_at = $1 WHERE id = $2`,
			now, sess.UserID); err != nil {
			return err
		}
		return s.audit(ctx, tx, &sess.StoreID, "MEMBER_LEAVE", &sess.UserID, &sess.DeviceID, sess.DeviceCode,
			map[string]any{"discard_unsynced": in.DiscardUnsynced}, ip)
	})
	if err != nil {
		var ae *Error
		if errors.As(err, &ae) {
			return ae
		}
		log.Printf("auth: leave store failed: %v", err)
		return errInternal
	}
	if s.onDeviceRevoked != nil {
		for _, d := range revoked {
			s.onDeviceRevoked(sess.StoreID, d.id, d.code)
		}
	}
	if s.onStoreDataChanged != nil {
		s.onStoreDataChanged(sess.StoreID)
	}
	return nil
}

// TransferOwnership atomically swaps OWNER role to another active member after
// password re-authentication.
func (s *Service) TransferOwnership(ctx context.Context, sess Session, in TransferOwnershipInput, ip string) error {
	if in.Password == "" || strings.TrimSpace(in.TargetUserID) == "" {
		return newErr(http.StatusBadRequest, CodeBadRequest, "target_user_id and password are required")
	}
	if in.TargetUserID == sess.UserID {
		return newErr(http.StatusBadRequest, CodeBadRequest, "cannot transfer ownership to yourself")
	}
	if err := s.verifyOwnerPassword(ctx, sess.UserID, in.Password); err != nil {
		return err
	}

	now := s.now()
	err := db.WithTenantTx(ctx, s.db, sess.StoreID, func(tx pgx.Tx) error {
		var targetRole string
		if err := tx.QueryRow(ctx, `
			SELECT role FROM store_memberships
			WHERE store_id = $1 AND user_id = $2 AND status = 'ACTIVE'
			FOR UPDATE`, sess.StoreID, in.TargetUserID).Scan(&targetRole); err != nil {
			return err
		}
		// Demote current OWNER first so ux_one_owner_per_store is never violated.
		if _, err := tx.Exec(ctx, `
			UPDATE store_memberships SET role = 'MANAGER', updated_at = $1
			WHERE store_id = $2 AND user_id = $3 AND role = 'OWNER' AND status = 'ACTIVE'`,
			now, sess.StoreID, sess.UserID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `
			UPDATE store_memberships SET role = 'OWNER', updated_at = $1
			WHERE store_id = $2 AND user_id = $3 AND status = 'ACTIVE'`,
			now, sess.StoreID, in.TargetUserID); err != nil {
			return err
		}
		return s.audit(ctx, tx, &sess.StoreID, "OWNERSHIP_TRANSFER", &sess.UserID, &sess.DeviceID, sess.DeviceCode,
			map[string]any{"new_owner_user_id": in.TargetUserID}, ip)
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return newErr(http.StatusNotFound, CodeNotFound, "target active member not found")
	}
	if err != nil {
		return errInternal
	}
	if s.onStoreDataChanged != nil {
		s.onStoreDataChanged(sess.StoreID)
	}
	return nil
}

// ExportStore returns a read-only JSON snapshot of the store's data before closing.
func (s *Service) ExportStore(ctx context.Context, sess Session) (map[string]any, error) {
	out := make(map[string]any)
	err := db.WithTenantTxOptions(ctx, s.db, sess.StoreID, pgx.TxOptions{AccessMode: pgx.ReadOnly, IsoLevel: pgx.RepeatableRead}, func(tx pgx.Tx) error {
		tables := []struct {
			key   string
			query string
		}{
			{"store", `SELECT to_jsonb(s) FROM stores s WHERE id = $1`},
			{"members", `SELECT COALESCE(jsonb_agg(jsonb_build_object('user_id', m.user_id, 'name', u.name, 'username', u.username, 'role', m.role, 'status', m.status, 'joined_at', m.joined_at)), '[]'::jsonb) FROM store_memberships m JOIN users u ON u.id = m.user_id WHERE m.store_id = $1`},
			{"products", `SELECT COALESCE(jsonb_agg(to_jsonb(t)), '[]'::jsonb) FROM products t WHERE t.store_id = $1`},
			{"variants", `SELECT COALESCE(jsonb_agg(to_jsonb(t)), '[]'::jsonb) FROM product_variants t WHERE t.store_id = $1`},
			{"batches", `SELECT COALESCE(jsonb_agg(to_jsonb(t)), '[]'::jsonb) FROM batches t WHERE t.store_id = $1`},
			{"customers", `SELECT COALESCE(jsonb_agg(to_jsonb(t)), '[]'::jsonb) FROM customers t WHERE t.store_id = $1`},
			{"suppliers", `SELECT COALESCE(jsonb_agg(to_jsonb(t)), '[]'::jsonb) FROM suppliers t WHERE t.store_id = $1`},
			{"sale_orders", `SELECT COALESCE(jsonb_agg(to_jsonb(t)), '[]'::jsonb) FROM sale_orders t WHERE t.store_id = $1`},
			{"expenses", `SELECT COALESCE(jsonb_agg(to_jsonb(t)), '[]'::jsonb) FROM expenses t WHERE t.store_id = $1`},
			{"register_shifts", `SELECT COALESCE(jsonb_agg(to_jsonb(t)), '[]'::jsonb) FROM register_shifts t WHERE t.store_id = $1`},
		}
		for _, t := range tables {
			var raw []byte
			if err := tx.QueryRow(ctx, t.query, sess.StoreID).Scan(&raw); err != nil {
				return err
			}
			var decoded any
			if len(raw) > 0 {
				if err := json.Unmarshal(raw, &decoded); err != nil {
					return err
				}
			}
			out[t.key] = decoded
		}
		out["exported_at"] = s.now()
		return nil
	})
	if err != nil {
		log.Printf("auth: export store failed: %v", err)
		return nil, errInternal
	}
	return out, nil
}

// CloseStore closes the store (Owner + password re-auth), ends all memberships,
// revokes all devices, and sets purge_after = now + 30 days.
func (s *Service) CloseStore(ctx context.Context, sess Session, in CloseStoreInput, ip string) error {
	if in.Password == "" {
		return newErr(http.StatusBadRequest, CodeBadRequest, "password is required")
	}
	if err := s.verifyOwnerPassword(ctx, sess.UserID, in.Password); err != nil {
		return err
	}
	return s.closeStoreInternal(ctx, sess.StoreID, &sess.UserID, &sess.DeviceID, sess.DeviceCode, ip)
}

func (s *Service) closeStoreInternal(ctx context.Context, storeID string, actorUserID, actorDeviceID *string, actorCode, ip string) error {
	now := s.now()
	purgeAfter := now.Add(30 * 24 * time.Hour)
	var revoked []deviceCodePair

	err := db.WithTenantTx(ctx, s.db, storeID, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `
			UPDATE stores SET status = 'CLOSED', closed_at = $1, purge_after = $2, updated_at = $1
			WHERE id = $3 AND status = 'ACTIVE'`, now, purgeAfter, storeID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return newErr(http.StatusNotFound, CodeNotFound, "active store not found")
		}

		// Collect active member user IDs so we can bump their token_version.
		var userIDs []string
		uRows, err := tx.Query(ctx, `
			UPDATE store_memberships
			SET status = 'LEFT', ended_at = $1, updated_at = $1
			WHERE store_id = $2 AND status = 'ACTIVE'
			RETURNING user_id`, now, storeID)
		if err != nil {
			return err
		}
		for uRows.Next() {
			var uid string
			if err := uRows.Scan(&uid); err == nil {
				userIDs = append(userIDs, uid)
			}
		}
		uRows.Close()

		if _, err := tx.Exec(ctx, `
			UPDATE staff_shift_sessions
			SET status = 'FORCE_CLOSED', punched_out_at = $1, updated_at = $1
			WHERE store_id = $2 AND status = 'ACTIVE'`, now, storeID); err != nil {
			return err
		}

		dRows, err := tx.Query(ctx, `
			UPDATE device_registrations
			SET status = CASE WHEN status = 'PENDING' THEN 'REJECTED' ELSE 'REVOKED' END,
			    is_active = FALSE,
			    revoked_at = CASE WHEN status = 'PENDING' THEN NULL::timestamptz ELSE $1::timestamptz END,
			    revocation_reason = 'store closed',
			    current_lease_id = NULL,
			    current_user_id = NULL,
			    updated_at = $1
			WHERE store_id = $2 AND status IN ('ACTIVE', 'PENDING')
			RETURNING id, COALESCE(device_code, '')`, now, storeID)
		if err != nil {
			return err
		}
		for dRows.Next() {
			var p deviceCodePair
			if err := dRows.Scan(&p.id, &p.code); err == nil {
				revoked = append(revoked, p)
			}
		}
		dRows.Close()

		if len(userIDs) > 0 {
			if _, err := tx.Exec(ctx, `
				UPDATE users SET token_version = token_version + 1, updated_at = $1
				WHERE id = ANY($2)`, now, userIDs); err != nil {
				return err
			}
		}

		return s.audit(ctx, tx, &storeID, "STORE_CLOSE", actorUserID, actorDeviceID, actorCode,
			map[string]any{"purge_after": purgeAfter}, ip)
	})
	if err != nil {
		var ae *Error
		if errors.As(err, &ae) {
			return ae
		}
		log.Printf("auth: close store failed: %v", err)
		return errInternal
	}
	if s.onDeviceRevoked != nil {
		for _, d := range revoked {
			s.onDeviceRevoked(storeID, d.id, d.code)
		}
	}
	return nil
}

// ---------------------------------------------------------------- Admin CLI Store Helpers

func (s *Service) AdminListStores(ctx context.Context) ([]StoreInfo, error) {
	rows, err := s.db.Query(ctx, `
		SELECT id, name, pan_number, phone, address, status, closed_at, created_at, updated_at
		FROM stores ORDER BY created_at DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []StoreInfo
	for rows.Next() {
		var st StoreInfo
		if err := rows.Scan(&st.ID, &st.Name, &st.PANNumber, &st.Phone, &st.Address, &st.Status, &st.ClosedAt, &st.CreatedAt, &st.UpdatedAt); err != nil {
			return nil, err
		}
		out = append(out, st)
	}
	return out, rows.Err()
}

func (s *Service) AdminCloseStore(ctx context.Context, storeID string) error {
	return s.closeStoreInternal(ctx, storeID, nil, nil, "admin", "127.0.0.1")
}

func (s *Service) AdminPurgeClosedStores(ctx context.Context) (int64, error) {
	tag, err := s.db.Exec(ctx, `DELETE FROM stores WHERE status = 'CLOSED' AND purge_after IS NOT NULL AND purge_after <= CURRENT_TIMESTAMP`)
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}

// ---------------------------------------------------------------- Helpers

func (s *Service) verifyOwnerPassword(ctx context.Context, userID, password string) error {
	var pwHash string
	err := s.db.QueryRow(ctx, `SELECT password_hash FROM users WHERE id = $1 AND deleted_at IS NULL`, userID).Scan(&pwHash)
	if errors.Is(err, pgx.ErrNoRows) {
		return newErr(http.StatusUnauthorized, CodeTokenInvalid, "user not found")
	}
	if err != nil {
		return errInternal
	}
	ok, err := VerifySecret(ctx, password, pwHash)
	if err != nil {
		return errInternal
	}
	if !ok {
		return newErr(http.StatusUnauthorized, CodeInvalidCredentials, "incorrect password")
	}
	return nil
}

func generateInviteCode() (raw, formatted string, hash []byte, err error) {
	var buf [10]byte
	if _, err = rand.Read(buf[:]); err != nil {
		return "", "", nil, err
	}
	chars := make([]byte, 10)
	for i, b := range buf {
		chars[i] = inviteCodeAlphabet[int(b)&31]
	}
	raw = string(chars)
	formatted = fmt.Sprintf("PSX-%s-%s", raw[:5], raw[5:])
	sum := sha256.Sum256([]byte(raw))
	return raw, formatted, sum[:], nil
}

func normalizeInviteCode(in string) string {
	s := strings.ToUpper(strings.TrimSpace(in))
	s = strings.TrimPrefix(s, "PSX-")
	s = strings.ReplaceAll(s, "-", "")
	s = strings.ReplaceAll(s, " ", "")
	return s
}

func trimOpt(s *string) *string {
	if s == nil {
		return nil
	}
	t := strings.TrimSpace(*s)
	if t == "" {
		return nil
	}
	return &t
}
