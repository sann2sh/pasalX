-- ============================================================================
-- 000001_tenancy_and_identity.up.sql: Users, Stores, Memberships, Invites, Codes
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS citext;

-- 1. USERS (global identity; roles live strictly in store_memberships)
CREATE TABLE IF NOT EXISTS users (
    id VARCHAR(36) PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email CITEXT NOT NULL UNIQUE,
    email_verified_at TIMESTAMP WITH TIME ZONE,
    username VARCHAR(50) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    pin_hash VARCHAR(255),
    phone VARCHAR(50),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    token_version INT NOT NULL DEFAULT 1,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);
CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);
CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);

-- 2. STORES (tenant root; ownership lives strictly in store_memberships)
CREATE TABLE IF NOT EXISTS stores (
    id VARCHAR(36) PRIMARY KEY,
    name VARCHAR(150) NOT NULL,
    pan_number VARCHAR(50),
    phone VARCHAR(50),
    address TEXT,
    status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'CLOSED')),
    closed_at TIMESTAMP WITH TIME ZONE,
    purge_after TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_stores_status ON stores(status);
CREATE INDEX IF NOT EXISTS idx_stores_updated_at ON stores(updated_at);

-- 3. STORE MEMBERSHIPS (single source of truth for store <-> user & role)
CREATE TABLE IF NOT EXISTS store_memberships (
    id VARCHAR(36) PRIMARY KEY,
    store_id VARCHAR(36) NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    user_id VARCHAR(36) NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role VARCHAR(30) NOT NULL CHECK (role IN ('OWNER', 'MANAGER', 'STAFF')),
    status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'LEFT', 'REMOVED')),
    joined_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    ended_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (store_id, id)
);
-- 1 user = 1 active store (v1)
CREATE UNIQUE INDEX IF NOT EXISTS ux_one_active_store_per_user
    ON store_memberships(user_id) WHERE status = 'ACTIVE';
-- 1 active owner per store
CREATE UNIQUE INDEX IF NOT EXISTS ux_one_owner_per_store
    ON store_memberships(store_id) WHERE role = 'OWNER' AND status = 'ACTIVE';
CREATE INDEX IF NOT EXISTS idx_store_memberships_store_updated
    ON store_memberships(store_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_store_memberships_store_user
    ON store_memberships(store_id, user_id);

-- 4. STORE INVITATIONS (hashed single-use expiring codes)
CREATE TABLE IF NOT EXISTS store_invitations (
    id VARCHAR(36) PRIMARY KEY,
    store_id VARCHAR(36) NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    invited_by_user_id VARCHAR(36) NOT NULL REFERENCES users(id),
    role VARCHAR(30) NOT NULL CHECK (role IN ('MANAGER', 'STAFF')),
    code_hash BYTEA NOT NULL UNIQUE,
    invited_email CITEXT,
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'ACCEPTED', 'REVOKED', 'EXPIRED')),
    accepted_by_user_id VARCHAR(36) REFERENCES users(id),
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    accepted_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (store_id, id)
);
CREATE INDEX IF NOT EXISTS idx_store_invitations_store_status
    ON store_invitations(store_id, status);

-- 5. EMAIL VERIFICATION & PASSWORD RESET CODES (hashed, expiring, attempt-limited)
CREATE TABLE IF NOT EXISTS email_verification_codes (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    code_hash BYTEA NOT NULL,
    purpose VARCHAR(30) NOT NULL CHECK (purpose IN ('EMAIL_VERIFY', 'PASSWORD_RESET')),
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    attempts INT NOT NULL DEFAULT 0,
    consumed_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_email_codes_user_purpose
    ON email_verification_codes(user_id, purpose, created_at DESC);

