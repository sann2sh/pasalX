-- PasalX Migration 000003 rollback
DROP INDEX IF EXISTS idx_devices_updated_at;

ALTER TABLE device_registrations
    DROP CONSTRAINT IF EXISTS chk_device_revocation_consistency;

ALTER TABLE device_registrations
    DROP COLUMN IF EXISTS current_user_id,
    DROP COLUMN IF EXISTS current_lease_id,
    DROP COLUMN IF EXISTS registered_by_user_id,
    DROP COLUMN IF EXISTS dek_sealed;

