package auth

import (
	"context"
	"net/http"
)

type acctCtxKey struct{}

// AccountSessionFrom returns the authenticated account session attached by RequireAccountAuth.
func AccountSessionFrom(ctx context.Context) (AccountSession, bool) {
	s, ok := ctx.Value(acctCtxKey{}).(AccountSession)
	return s, ok
}

// RequireAccountAuth verifies an Account JWT (aud=pasalx-account, signed with
// k.accountJWT). Device JWTs are rejected at this gate and vice versa.
func (h *Handler) RequireAccountAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, ok := extractBearer(r.Header.Get("Authorization"))
		if !ok {
			writeError(w, newErr(http.StatusUnauthorized, CodeTokenMissing, "missing bearer token"))
			return
		}
		acct, err := h.svc.AuthenticateAccount(r.Context(), raw)
		if err != nil {
			writeError(w, err)
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), acctCtxKey{}, acct)))
	})
}

func (h *Handler) registerPhase2Routes(mux *http.ServeMux) {
	// Public account onboarding & password reset
	mux.HandleFunc("POST /api/auth/signup", h.signup)
	mux.HandleFunc("POST /api/auth/verify-email", h.verifyEmail)
	mux.HandleFunc("POST /api/auth/resend-verification", h.resendVerification)
	mux.HandleFunc("POST /api/auth/account-login", h.accountLogin)
	mux.HandleFunc("POST /api/auth/forgot-password", h.forgotPassword)
	mux.HandleFunc("POST /api/auth/reset-password", h.resetPassword)

	// Account-JWT protected routes (pre-device or account-wide)
	mux.Handle("POST /api/stores", h.RequireAccountAuth(http.HandlerFunc(h.createStore)))
	mux.Handle("POST /api/invitations/accept", h.RequireAccountAuth(http.HandlerFunc(h.acceptInvitation)))
	mux.Handle("POST /api/devices/enroll", h.RequireAccountAuth(http.HandlerFunc(h.enrollDevice)))
	mux.Handle("GET /api/devices/me/status", h.RequireAccountAuth(http.HandlerFunc(h.getMyDeviceStatus)))
	mux.Handle("DELETE /api/account", h.RequireAccountAuth(http.HandlerFunc(h.deleteAccount)))

	// Device-JWT protected store & team routes
	mux.Handle("GET /api/stores/current", h.RequireAuth(http.HandlerFunc(h.getCurrentStore)))
	mux.Handle("PATCH /api/stores/current", h.RequireAuth(RequireRole(RoleOwner, RoleManager)(http.HandlerFunc(h.updateCurrentStore))))
	mux.Handle("GET /api/stores/current/export", h.RequireAuth(RequireRole(RoleOwner)(http.HandlerFunc(h.exportStore))))
	mux.Handle("POST /api/stores/current/close", h.RequireAuth(RequireRole(RoleOwner)(http.HandlerFunc(h.closeStore))))
	mux.Handle("POST /api/stores/current/leave", h.RequireAuth(http.HandlerFunc(h.leaveStore)))
	mux.Handle("POST /api/stores/current/transfer-ownership", h.RequireAuth(RequireRole(RoleOwner)(http.HandlerFunc(h.transferOwnership))))

	// Invitations
	mux.Handle("POST /api/stores/current/invitations", h.RequireAuth(RequireRole(RoleOwner)(http.HandlerFunc(h.createInvitation))))
	mux.Handle("GET /api/stores/current/invitations", h.RequireAuth(RequireRole(RoleOwner)(http.HandlerFunc(h.listInvitations))))
	mux.Handle("DELETE /api/stores/current/invitations/{id}", h.RequireAuth(RequireRole(RoleOwner)(http.HandlerFunc(h.revokeInvitation))))

	// Devices & Approvals
	mux.Handle("GET /api/stores/current/devices", h.RequireAuth(RequireRole(RoleOwner)(http.HandlerFunc(h.listStoreDevices))))
	mux.Handle("POST /api/stores/current/devices/{id}/approve", h.RequireAuth(RequireRole(RoleOwner)(http.HandlerFunc(h.approveDevice))))
	mux.Handle("POST /api/stores/current/devices/{id}/reject", h.RequireAuth(RequireRole(RoleOwner)(http.HandlerFunc(h.rejectDevice))))

	// Members
	mux.Handle("GET /api/stores/current/members", h.RequireAuth(http.HandlerFunc(h.listMembers)))
	mux.Handle("PATCH /api/stores/current/members/{userId}", h.RequireAuth(RequireRole(RoleOwner)(http.HandlerFunc(h.updateMemberRole))))
	mux.Handle("DELETE /api/stores/current/members/{userId}", h.RequireAuth(RequireRole(RoleOwner)(http.HandlerFunc(h.removeMember))))
	mux.Handle("POST /api/stores/current/members/{userId}/reset-pin", h.RequireAuth(RequireRole(RoleOwner)(http.HandlerFunc(h.resetMemberPIN))))

	// Google Play account deletion public info page
	mux.HandleFunc("GET /delete-account", h.deleteAccountPage)
}

// ---------------------------------------------------------------- Account Handlers

func (h *Handler) signup(w http.ResponseWriter, r *http.Request) {
	var in SignupInput
	if !decodeJSON(w, r, &in) {
		return
	}
	res, err := h.svc.Signup(r.Context(), in, h.clientIP(r))
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, res)
}

func (h *Handler) verifyEmail(w http.ResponseWriter, r *http.Request) {
	var in VerifyEmailInput
	if !decodeJSON(w, r, &in) {
		return
	}
	if err := h.svc.VerifyEmail(r.Context(), in, h.clientIP(r)); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"verified": true})
}

func (h *Handler) resendVerification(w http.ResponseWriter, r *http.Request) {
	var in EmailInput
	if !decodeJSON(w, r, &in) {
		return
	}
	if err := h.svc.ResendVerification(r.Context(), in.Email, h.clientIP(r)); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]any{
		"status":  "ACCEPTED",
		"message": "If an unverified account exists for that email, a new verification code has been sent.",
	})
}

func (h *Handler) accountLogin(w http.ResponseWriter, r *http.Request) {
	var in AccountLoginInput
	if !decodeJSON(w, r, &in) {
		return
	}
	res, err := h.svc.AccountLogin(r.Context(), in, h.clientIP(r))
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (h *Handler) forgotPassword(w http.ResponseWriter, r *http.Request) {
	var in EmailInput
	if !decodeJSON(w, r, &in) {
		return
	}
	if err := h.svc.ForgotPassword(r.Context(), in.Email, h.clientIP(r)); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]any{
		"status":  "ACCEPTED",
		"message": "If that email is registered, a password reset code has been sent.",
	})
}

func (h *Handler) resetPassword(w http.ResponseWriter, r *http.Request) {
	var in ResetPasswordInput
	if !decodeJSON(w, r, &in) {
		return
	}
	if err := h.svc.ResetPassword(r.Context(), in, h.clientIP(r)); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "PASSWORD_RESET"})
}

func (h *Handler) deleteAccount(w http.ResponseWriter, r *http.Request) {
	acct, _ := AccountSessionFrom(r.Context())
	var in DeleteAccountInput
	if !decodeJSON(w, r, &in) {
		return
	}
	if err := h.svc.DeleteAccount(r.Context(), acct, in, h.clientIP(r)); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ACCOUNT_DELETED"})
}

// ---------------------------------------------------------------- Store & Team Handlers

func (h *Handler) createStore(w http.ResponseWriter, r *http.Request) {
	acct, _ := AccountSessionFrom(r.Context())
	var in CreateStoreInput
	if !decodeJSON(w, r, &in) {
		return
	}
	res, err := h.svc.CreateStore(r.Context(), acct, in, h.clientIP(r))
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, res)
}

func (h *Handler) getCurrentStore(w http.ResponseWriter, r *http.Request) {
	sess, _ := SessionFrom(r.Context())
	st, err := h.svc.GetCurrentStore(r.Context(), sess)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"store": st})
}

func (h *Handler) updateCurrentStore(w http.ResponseWriter, r *http.Request) {
	sess, _ := SessionFrom(r.Context())
	var in UpdateStoreInput
	if !decodeJSON(w, r, &in) {
		return
	}
	st, err := h.svc.UpdateCurrentStore(r.Context(), sess, in, h.clientIP(r))
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"store": st})
}

func (h *Handler) createInvitation(w http.ResponseWriter, r *http.Request) {
	sess, _ := SessionFrom(r.Context())
	var in CreateInvitationInput
	if !decodeJSON(w, r, &in) {
		return
	}
	inv, err := h.svc.CreateInvitation(r.Context(), sess, in, h.clientIP(r))
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"invitation": inv})
}

func (h *Handler) listInvitations(w http.ResponseWriter, r *http.Request) {
	sess, _ := SessionFrom(r.Context())
	list, err := h.svc.ListInvitations(r.Context(), sess)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"invitations": list})
}

func (h *Handler) revokeInvitation(w http.ResponseWriter, r *http.Request) {
	sess, _ := SessionFrom(r.Context())
	if err := h.svc.RevokeInvitation(r.Context(), sess, r.PathValue("id"), h.clientIP(r)); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "REVOKED"})
}

func (h *Handler) acceptInvitation(w http.ResponseWriter, r *http.Request) {
	acct, _ := AccountSessionFrom(r.Context())
	var in AcceptInvitationInput
	if !decodeJSON(w, r, &in) {
		return
	}
	res, err := h.svc.AcceptInvitation(r.Context(), acct, in, h.clientIP(r))
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, res)
}

func (h *Handler) enrollDevice(w http.ResponseWriter, r *http.Request) {
	acct, _ := AccountSessionFrom(r.Context())
	var in EnrollDeviceInput
	if !decodeJSON(w, r, &in) {
		return
	}
	res, err := h.svc.EnrollDevice(r.Context(), acct, in, h.clientIP(r))
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, res)
}

func (h *Handler) getMyDeviceStatus(w http.ResponseWriter, r *http.Request) {
	acct, _ := AccountSessionFrom(r.Context())
	res, err := h.svc.GetMyDeviceStatus(r.Context(), acct, r.URL.Query().Get("device_id"))
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (h *Handler) listStoreDevices(w http.ResponseWriter, r *http.Request) {
	sess, _ := SessionFrom(r.Context())
	devices, err := h.svc.ListStoreDevices(r.Context(), sess, r.URL.Query().Get("status"))
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": devices})
}

func (h *Handler) approveDevice(w http.ResponseWriter, r *http.Request) {
	sess, _ := SessionFrom(r.Context())
	dev, err := h.svc.ApproveDevice(r.Context(), sess, r.PathValue("id"), h.clientIP(r))
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"device": dev})
}

func (h *Handler) rejectDevice(w http.ResponseWriter, r *http.Request) {
	sess, _ := SessionFrom(r.Context())
	var in RejectDeviceInput
	if r.ContentLength > 0 {
		if !decodeJSON(w, r, &in) {
			return
		}
	}
	if err := h.svc.RejectDevice(r.Context(), sess, r.PathValue("id"), in, h.clientIP(r)); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "REJECTED"})
}

func (h *Handler) listMembers(w http.ResponseWriter, r *http.Request) {
	sess, _ := SessionFrom(r.Context())
	members, err := h.svc.ListMembers(r.Context(), sess)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"members": members})
}

func (h *Handler) updateMemberRole(w http.ResponseWriter, r *http.Request) {
	sess, _ := SessionFrom(r.Context())
	var in UpdateMemberRoleInput
	if !decodeJSON(w, r, &in) {
		return
	}
	if err := h.svc.UpdateMemberRole(r.Context(), sess, r.PathValue("userId"), in, h.clientIP(r)); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "UPDATED"})
}

func (h *Handler) removeMember(w http.ResponseWriter, r *http.Request) {
	sess, _ := SessionFrom(r.Context())
	if err := h.svc.RemoveMember(r.Context(), sess, r.PathValue("userId"), h.clientIP(r)); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "REMOVED"})
}

func (h *Handler) resetMemberPIN(w http.ResponseWriter, r *http.Request) {
	sess, _ := SessionFrom(r.Context())
	var in ResetMemberPINInput
	if !decodeJSON(w, r, &in) {
		return
	}
	if err := h.svc.ResetMemberPIN(r.Context(), sess, r.PathValue("userId"), in, h.clientIP(r)); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "PIN_RESET"})
}

func (h *Handler) leaveStore(w http.ResponseWriter, r *http.Request) {
	sess, _ := SessionFrom(r.Context())
	var in LeaveStoreInput
	if !decodeJSON(w, r, &in) {
		return
	}
	if err := h.svc.LeaveStore(r.Context(), sess, in, h.clientIP(r)); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "LEFT"})
}

func (h *Handler) transferOwnership(w http.ResponseWriter, r *http.Request) {
	sess, _ := SessionFrom(r.Context())
	var in TransferOwnershipInput
	if !decodeJSON(w, r, &in) {
		return
	}
	if err := h.svc.TransferOwnership(r.Context(), sess, in, h.clientIP(r)); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "TRANSFERRED"})
}

func (h *Handler) exportStore(w http.ResponseWriter, r *http.Request) {
	sess, _ := SessionFrom(r.Context())
	data, err := h.svc.ExportStore(r.Context(), sess)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, data)
}

func (h *Handler) closeStore(w http.ResponseWriter, r *http.Request) {
	sess, _ := SessionFrom(r.Context())
	var in CloseStoreInput
	if !decodeJSON(w, r, &in) {
		return
	}
	if err := h.svc.CloseStore(r.Context(), sess, in, h.clientIP(r)); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "CLOSED"})
}

func (h *Handler) deleteAccountPage(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(`<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>PasalX — Account Deletion</title>
<style>body{font-family:system-ui,sans-serif;max-width:640px;margin:48px auto;padding:0 20px;line-height:1.6;color:#111827}
h1{color:#0f766e}code{background:#f3f4f6;padding:2px 6px;border-radius:4px}</style>
</head>
<body>
<h1>Delete Your PasalX Account</h1>
<p>You can permanently delete your PasalX account directly from the PasalX mobile app:</p>
<ol>
  <li>Open <strong>PasalX</strong> and go to <strong>Settings &rarr; Account &rarr; Delete Account</strong>.</li>
  <li>If you are a store <strong>Owner</strong>, first transfer ownership to another team member or close your store under <strong>Settings &rarr; Team &rarr; Danger Zone</strong>.</li>
  <li>Enter your password to confirm deletion.</li>
</ol>
<p><strong>What is deleted:</strong> Your name, email address, username, phone number, password hash, and PIN hash are permanently anonymized and all active device sessions are revoked.</p>
<p><strong>What is retained:</strong> Store sales, tax invoices, and accounting ledger entries remain with the store for statutory bookkeeping until the store itself is closed and purged (30 days after store closure).</p>
</body></html>`))
}

