-- PasalX Migration 000004: Idempotent Sync Engine, LWW Client Clock Isolation & Pull Indexes (Step 4)

-- 1. Processed client outbox mutation log for exact-once retry idempotency across
--    atomic deltas, ledger append-only inserts, and LWW metadata updates.
CREATE TABLE IF NOT EXISTS sync_processed_mutations (
    id VARCHAR(36) PRIMARY KEY,
    device_code VARCHAR(10) NOT NULL,
    table_name VARCHAR(50) NOT NULL,
    record_id VARCHAR(36) NOT NULL,
    operation VARCHAR(20) NOT NULL,
    processed_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_sync_processed_at ON sync_processed_mutations(processed_at);
CREATE INDEX IF NOT EXISTS idx_sync_processed_record ON sync_processed_mutations(table_name, record_id);

-- 2. Isolate client edit timestamps (for offline LWW conflict resolution) from the
--    server's monotonic updated_at cursor clock used by GET /api/sync/pull.
ALTER TABLE products
    ADD COLUMN IF NOT EXISTS client_updated_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE product_variants
    ADD COLUMN IF NOT EXISTS client_updated_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE batches
    ADD COLUMN IF NOT EXISTS client_updated_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE customers
    ADD COLUMN IF NOT EXISTS client_updated_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE customer_shade_profiles
    ADD COLUMN IF NOT EXISTS client_updated_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE suppliers
    ADD COLUMN IF NOT EXISTS client_updated_at TIMESTAMP WITH TIME ZONE;

-- 3. Add updated_at pull-cursor columns & B-tree indexes to append-only / ledger
--    tables created without updated_at in 000001/000002.
ALTER TABLE stock_movements
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE expenses
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE purchase_invoice_items
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE supplier_payments
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE inventory_sync_audit
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    ADD COLUMN IF NOT EXISTS stock_movement_id VARCHAR(36) UNIQUE REFERENCES stock_movements(id);

UPDATE stock_movements SET updated_at = COALESCE(updated_at, created_at, CURRENT_TIMESTAMP);
UPDATE expenses SET updated_at = COALESCE(updated_at, created_at, CURRENT_TIMESTAMP);
UPDATE purchase_invoice_items SET updated_at = COALESCE(updated_at, created_at, CURRENT_TIMESTAMP);
UPDATE supplier_payments SET updated_at = COALESCE(updated_at, created_at, CURRENT_TIMESTAMP);
UPDATE inventory_sync_audit SET updated_at = COALESCE(updated_at, created_at, CURRENT_TIMESTAMP);

CREATE INDEX IF NOT EXISTS idx_movements_updated_at ON stock_movements(updated_at);
CREATE INDEX IF NOT EXISTS idx_expenses_updated_at ON expenses(updated_at);
CREATE INDEX IF NOT EXISTS idx_purchase_items_updated_at ON purchase_invoice_items(updated_at);
CREATE INDEX IF NOT EXISTS idx_supplier_payments_updated_at ON supplier_payments(updated_at);
CREATE INDEX IF NOT EXISTS idx_sync_audit_updated_at ON inventory_sync_audit(updated_at);
CREATE INDEX IF NOT EXISTS idx_customer_shades_updated_at ON customer_shade_profiles(updated_at);
CREATE INDEX IF NOT EXISTS idx_customer_tx_updated_at ON customer_transactions(updated_at);
CREATE INDEX IF NOT EXISTS idx_purchase_invoices_updated_at ON purchase_invoices(updated_at);

