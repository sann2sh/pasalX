-- ============================================================================
-- 000002_create_shifts_and_sync.up.sql: Shifts, Sessions, Devices & Sync Audits
-- ============================================================================

-- 1. CASH REGISTER SHIFTS (Z-REPORTS)
CREATE TABLE IF NOT EXISTS register_shifts (
    id VARCHAR(36) PRIMARY KEY,
    opened_by_user_id VARCHAR(36) NOT NULL REFERENCES users(id),
    closed_by_user_id VARCHAR(36) REFERENCES users(id),
    opened_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    closed_at TIMESTAMP WITH TIME ZONE,
    
    opening_float DECIMAL(10,2) NOT NULL,
    cash_sales DECIMAL(10,2) DEFAULT 0.00,
    digital_sales DECIMAL(10,2) DEFAULT 0.00,
    khata_cash_repayments DECIMAL(10,2) DEFAULT 0.00,
    cash_expenses DECIMAL(10,2) DEFAULT 0.00,
    expected_cash DECIMAL(10,2) NOT NULL,
    actual_cash_counted DECIMAL(10,2),
    discrepancy DECIMAL(10,2),
    
    cash_withdrawn_deposit DECIMAL(10,2) DEFAULT 0.00,
    retained_next_day_float DECIMAL(10,2) DEFAULT 0.00,
    status VARCHAR(20) DEFAULT 'OPEN' CHECK (status IN ('OPEN', 'CLOSED')),
    notes TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_register_shifts_status ON register_shifts(status);

-- Link sale_orders.shift_id to register_shifts now that register_shifts exists
ALTER TABLE sale_orders
    DROP CONSTRAINT IF EXISTS fk_sale_orders_shift;
ALTER TABLE sale_orders
    ADD CONSTRAINT fk_sale_orders_shift
    FOREIGN KEY (shift_id) REFERENCES register_shifts(id);

-- 2. STAFF SHIFT SESSIONS (Phone-level punch-in against register shift)
CREATE TABLE IF NOT EXISTS staff_shift_sessions (
    id VARCHAR(36) PRIMARY KEY,
    register_shift_id VARCHAR(36) NOT NULL REFERENCES register_shifts(id),
    user_id VARCHAR(36) NOT NULL REFERENCES users(id),
    device_code VARCHAR(10) NOT NULL,
    punched_in_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    punched_out_at TIMESTAMP WITH TIME ZONE,
    last_synced_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    status VARCHAR(30) DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'PUNCHED_OUT', 'FORCE_CLOSED')),
    force_closed_by_user_id VARCHAR(36) REFERENCES users(id),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_shift_sessions_shift ON staff_shift_sessions(register_shift_id);
CREATE INDEX IF NOT EXISTS idx_shift_sessions_user ON staff_shift_sessions(user_id);
CREATE INDEX IF NOT EXISTS idx_shift_sessions_status ON staff_shift_sessions(status);

-- 3. EXPENSES & PETTY CASH
CREATE TABLE IF NOT EXISTS expenses (
    id VARCHAR(36) PRIMARY KEY,
    category VARCHAR(50) NOT NULL,
    title VARCHAR(255) NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    payment_method VARCHAR(30) NOT NULL CHECK (payment_method IN ('CASH', 'FONEPAY', 'BANK')),
    paid_to VARCHAR(150),
    shift_id VARCHAR(36) REFERENCES register_shifts(id),
    created_by_user_id VARCHAR(36) NOT NULL REFERENCES users(id),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_expenses_shift ON expenses(shift_id);

-- 4. DEVICE REGISTRATIONS & KILL SWITCH LEASES
CREATE TABLE IF NOT EXISTS device_registrations (
    id VARCHAR(36) PRIMARY KEY,
    device_code VARCHAR(10) UNIQUE NOT NULL,      -- '01', '02', '03'
    device_name VARCHAR(100) NOT NULL,           -- e.g. "Counter Redmi 12"
    platform VARCHAR(20) NOT NULL,               -- 'ANDROID', 'LINUX', 'IOS'
    fcm_push_token TEXT,
    is_active BOOLEAN DEFAULT TRUE,
    status VARCHAR(30) DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'REVOKED', 'PENDING')),
    last_kek_lease_issued_at TIMESTAMP WITH TIME ZONE,
    last_kek_lease_expires_at TIMESTAMP WITH TIME ZONE,
    revoked_at TIMESTAMP WITH TIME ZONE,
    revoked_by_user_id VARCHAR(36) REFERENCES users(id),
    revocation_reason TEXT,
    registered_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_devices_code ON device_registrations(device_code);
CREATE INDEX IF NOT EXISTS idx_devices_status ON device_registrations(status);

-- 5. INVENTORY SYNC AUDIT & CONFLICT TRACKING
CREATE TABLE IF NOT EXISTS inventory_sync_audit (
    id VARCHAR(36) PRIMARY KEY,
    batch_id VARCHAR(36) NOT NULL REFERENCES batches(id),
    device_code VARCHAR(10) NOT NULL,
    operation VARCHAR(30) NOT NULL,              -- 'PUSH_SALE', 'PUSH_INTAKE', 'CORRECTION'
    quantity_change INT NOT NULL,                -- -1, +24, etc.
    pre_sync_qty INT,
    post_sync_qty INT,
    is_discrepancy BOOLEAN DEFAULT FALSE,        -- True if post_sync_qty < 0
    reference_id VARCHAR(100),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_sync_audit_batch ON inventory_sync_audit(batch_id);
CREATE INDEX IF NOT EXISTS idx_sync_audit_discrepancy ON inventory_sync_audit(is_discrepancy);

-- 6. APP SECURITY AUDIT LOGS
CREATE TABLE IF NOT EXISTS app_audit_logs (
    id VARCHAR(36) PRIMARY KEY,
    event_type VARCHAR(50) NOT NULL,             -- 'LOGIN', 'LOGOUT', 'REVOKE_DEVICE', 'FORCE_PUNCHOUT', 'DISCOUNT_APPLIED'
    user_id VARCHAR(36) REFERENCES users(id),
    device_code VARCHAR(10),
    metadata JSONB DEFAULT '{}',
    ip_address VARCHAR(50),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_audit_logs_event ON app_audit_logs(event_type);
CREATE INDEX IF NOT EXISTS idx_audit_logs_user ON app_audit_logs(user_id);

-- 7. DELTA PULL INDEXES (for GET /api/sync/pull?since=...)
CREATE INDEX IF NOT EXISTS idx_products_updated_at ON products(updated_at);
CREATE INDEX IF NOT EXISTS idx_variants_updated_at ON product_variants(updated_at);
CREATE INDEX IF NOT EXISTS idx_batches_updated_at ON batches(updated_at);
CREATE INDEX IF NOT EXISTS idx_customers_updated_at ON customers(updated_at);
CREATE INDEX IF NOT EXISTS idx_suppliers_updated_at ON suppliers(updated_at);
CREATE INDEX IF NOT EXISTS idx_sales_updated_at ON sale_orders(updated_at);
CREATE INDEX IF NOT EXISTS idx_register_shifts_updated_at ON register_shifts(updated_at);
CREATE INDEX IF NOT EXISTS idx_shift_sessions_updated_at ON staff_shift_sessions(updated_at);
