-- ============================================================================
-- 000004_shifts_devices_sync.up.sql: Shifts, Devices, Expenses, Sync & Audits
-- ============================================================================

CREATE TABLE IF NOT EXISTS register_shifts (
    id VARCHAR(36) PRIMARY KEY,
    store_id VARCHAR(36) NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    opened_by_user_id VARCHAR(36) NOT NULL REFERENCES users(id),
    closed_by_user_id VARCHAR(36) REFERENCES users(id),
    opened_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    closed_at TIMESTAMP WITH TIME ZONE,

    opening_float DECIMAL(10,2) NOT NULL,
    cash_sales DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    digital_sales DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    khata_cash_repayments DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    cash_expenses DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    expected_cash DECIMAL(10,2) NOT NULL,
    actual_cash_counted DECIMAL(10,2),
    discrepancy DECIMAL(10,2),

    cash_withdrawn_deposit DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    retained_next_day_float DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    status VARCHAR(20) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN', 'CLOSED')),
    notes TEXT,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (store_id, id)
);
CREATE INDEX IF NOT EXISTS idx_register_shifts_store_status ON register_shifts(store_id, status);
CREATE INDEX IF NOT EXISTS idx_register_shifts_store_updated ON register_shifts(store_id, updated_at);

ALTER TABLE sale_orders
    ADD CONSTRAINT fk_sale_orders_shift
    FOREIGN KEY (store_id, shift_id) REFERENCES register_shifts(store_id, id);

CREATE TABLE IF NOT EXISTS device_registrations (
    id VARCHAR(36) PRIMARY KEY,
    store_id VARCHAR(36) NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    device_code VARCHAR(10),
    device_name VARCHAR(100) NOT NULL,
    platform VARCHAR(20) NOT NULL,
    fcm_push_token TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    status VARCHAR(30) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('ACTIVE', 'REVOKED', 'PENDING', 'REJECTED')),
    dek_sealed BYTEA,
    requested_by_user_id VARCHAR(36) REFERENCES users(id),
    registered_by_user_id VARCHAR(36) REFERENCES users(id),
    current_lease_id VARCHAR(36),
    current_user_id VARCHAR(36) REFERENCES users(id),
    last_kek_lease_issued_at TIMESTAMP WITH TIME ZONE,
    last_kek_lease_expires_at TIMESTAMP WITH TIME ZONE,
    revoked_at TIMESTAMP WITH TIME ZONE,
    revoked_by_user_id VARCHAR(36) REFERENCES users(id),
    revocation_reason TEXT,
    registered_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (store_id, id),
    UNIQUE (store_id, device_code),
    CONSTRAINT chk_device_active_has_code CHECK (status <> 'ACTIVE' OR device_code IS NOT NULL),
    CONSTRAINT chk_device_revocation_consistency CHECK (status <> 'REVOKED' OR (revoked_at IS NOT NULL AND is_active = FALSE))
);
CREATE INDEX IF NOT EXISTS idx_devices_store_status ON device_registrations(store_id, status);
CREATE INDEX IF NOT EXISTS idx_devices_store_updated ON device_registrations(store_id, updated_at);

CREATE TABLE IF NOT EXISTS staff_shift_sessions (
    id VARCHAR(36) PRIMARY KEY,
    store_id VARCHAR(36) NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    register_shift_id VARCHAR(36) NOT NULL,
    user_id VARCHAR(36) NOT NULL REFERENCES users(id),
    device_id VARCHAR(36) NOT NULL,
    device_code VARCHAR(10) NOT NULL,
    punched_in_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    punched_out_at TIMESTAMP WITH TIME ZONE,
    last_synced_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    status VARCHAR(30) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'PUNCHED_OUT', 'FORCE_CLOSED')),
    force_closed_by_user_id VARCHAR(36) REFERENCES users(id),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (store_id, id),
    FOREIGN KEY (store_id, register_shift_id) REFERENCES register_shifts(store_id, id),
    FOREIGN KEY (store_id, device_id) REFERENCES device_registrations(store_id, id)
);
CREATE INDEX IF NOT EXISTS idx_shift_sessions_store_shift ON staff_shift_sessions(store_id, register_shift_id);
CREATE INDEX IF NOT EXISTS idx_shift_sessions_store_user ON staff_shift_sessions(store_id, user_id);
CREATE INDEX IF NOT EXISTS idx_shift_sessions_store_status ON staff_shift_sessions(store_id, status);
CREATE INDEX IF NOT EXISTS idx_shift_sessions_store_updated ON staff_shift_sessions(store_id, updated_at);

CREATE TABLE IF NOT EXISTS expenses (
    id VARCHAR(36) PRIMARY KEY,
    store_id VARCHAR(36) NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    category VARCHAR(50) NOT NULL,
    title VARCHAR(255) NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    payment_method VARCHAR(30) NOT NULL CHECK (payment_method IN ('CASH', 'FONEPAY', 'BANK')),
    paid_to VARCHAR(150),
    shift_id VARCHAR(36),
    created_by_user_id VARCHAR(36) NOT NULL REFERENCES users(id),
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (store_id, id),
    FOREIGN KEY (store_id, shift_id) REFERENCES register_shifts(store_id, id)
);
CREATE INDEX IF NOT EXISTS idx_expenses_store_shift ON expenses(store_id, shift_id);
CREATE INDEX IF NOT EXISTS idx_expenses_store_updated ON expenses(store_id, updated_at);

CREATE TABLE IF NOT EXISTS inventory_sync_audit (
    id VARCHAR(36) PRIMARY KEY,
    store_id VARCHAR(36) NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    batch_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    device_code VARCHAR(10) NOT NULL,
    operation VARCHAR(30) NOT NULL,
    quantity_change INT NOT NULL,
    pre_sync_qty INT,
    post_sync_qty INT,
    is_discrepancy BOOLEAN NOT NULL DEFAULT FALSE,
    reference_id VARCHAR(100),
    stock_movement_id VARCHAR(36),
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (store_id, id),
    UNIQUE (store_id, stock_movement_id),
    FOREIGN KEY (store_id, batch_id) REFERENCES batches(store_id, id),
    FOREIGN KEY (store_id, stock_movement_id) REFERENCES stock_movements(store_id, id),
    FOREIGN KEY (store_id, device_id) REFERENCES device_registrations(store_id, id)
);
CREATE INDEX IF NOT EXISTS idx_sync_audit_store_batch ON inventory_sync_audit(store_id, batch_id);
CREATE INDEX IF NOT EXISTS idx_sync_audit_store_discrepancy ON inventory_sync_audit(store_id, is_discrepancy);
CREATE INDEX IF NOT EXISTS idx_sync_audit_store_updated ON inventory_sync_audit(store_id, updated_at);

CREATE TABLE IF NOT EXISTS sync_processed_mutations (
    store_id VARCHAR(36) NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    device_code VARCHAR(10) NOT NULL,
    table_name VARCHAR(50) NOT NULL,
    record_id VARCHAR(36) NOT NULL,
    operation VARCHAR(20) NOT NULL,
    processed_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (store_id, id),
    FOREIGN KEY (store_id, device_id) REFERENCES device_registrations(store_id, id)
);
CREATE INDEX IF NOT EXISTS idx_sync_processed_store_at ON sync_processed_mutations(store_id, processed_at);
CREATE INDEX IF NOT EXISTS idx_sync_processed_store_record ON sync_processed_mutations(store_id, table_name, record_id);

-- Global + optional store-scoped security audit logs
CREATE TABLE IF NOT EXISTS app_audit_logs (
    id VARCHAR(36) PRIMARY KEY,
    store_id VARCHAR(36) REFERENCES stores(id) ON DELETE SET NULL,
    event_type VARCHAR(50) NOT NULL,
    user_id VARCHAR(36) REFERENCES users(id),
    device_id VARCHAR(36),
    device_code VARCHAR(10),
    metadata JSONB NOT NULL DEFAULT '{}',
    ip_address VARCHAR(50),
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_audit_logs_store ON app_audit_logs(store_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_logs_event ON app_audit_logs(event_type);
CREATE INDEX IF NOT EXISTS idx_audit_logs_user ON app_audit_logs(user_id);

