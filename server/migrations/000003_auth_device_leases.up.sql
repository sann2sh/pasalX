-- PasalX Migration 000003: Auth, per-device DEK custody & 12h lease session binding (Step 3)
-- Additive only: extends device_registrations created in 000002.

-- Per-device 256-bit SQLite DEK, stored ONLY as AES-256-GCM ciphertext sealed under the
-- server master key (HKDF subkey "pasalx/dek-at-rest/v1"). Layout: nonce(12) || ct(32) || tag(16) = 60 bytes.
ALTER TABLE device_registrations
    ADD COLUMN IF NOT EXISTS dek_sealed BYTEA,
    -- Owner who authorised the phone during on-site setup
    ADD COLUMN IF NOT EXISTS registered_by_user_id VARCHAR(36) REFERENCES users(id),
    -- Single active 12h lease per device. JWTs carrying a different lease id are rejected
    -- (SESSION_ENDED). NULL = logged out / no active session.
    ADD COLUMN IF NOT EXISTS current_lease_id VARCHAR(36),
    ADD COLUMN IF NOT EXISTS current_user_id VARCHAR(36) REFERENCES users(id);

-- Revoked/active devices must keep exactly one consistent state
ALTER TABLE device_registrations
    DROP CONSTRAINT IF EXISTS chk_device_revocation_consistency;
ALTER TABLE device_registrations
    ADD CONSTRAINT chk_device_revocation_consistency
    CHECK (status <> 'REVOKED' OR (revoked_at IS NOT NULL AND is_active = FALSE));

CREATE INDEX IF NOT EXISTS idx_devices_updated_at ON device_registrations(updated_at);

