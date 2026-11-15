-- PasalX Migration 000004 rollback

DROP INDEX IF EXISTS idx_purchase_invoices_updated_at;
DROP INDEX IF EXISTS idx_customer_tx_updated_at;
DROP INDEX IF EXISTS idx_customer_shades_updated_at;
DROP INDEX IF EXISTS idx_sync_audit_updated_at;
DROP INDEX IF EXISTS idx_supplier_payments_updated_at;
DROP INDEX IF EXISTS idx_purchase_items_updated_at;
DROP INDEX IF EXISTS idx_expenses_updated_at;
DROP INDEX IF EXISTS idx_movements_updated_at;

ALTER TABLE inventory_sync_audit
    DROP COLUMN IF EXISTS stock_movement_id,
    DROP COLUMN IF EXISTS updated_at;
ALTER TABLE supplier_payments DROP COLUMN IF EXISTS updated_at;
ALTER TABLE purchase_invoice_items DROP COLUMN IF EXISTS updated_at;
ALTER TABLE expenses DROP COLUMN IF EXISTS updated_at;
ALTER TABLE stock_movements DROP COLUMN IF EXISTS updated_at;

ALTER TABLE suppliers DROP COLUMN IF EXISTS client_updated_at;
ALTER TABLE customer_shade_profiles DROP COLUMN IF EXISTS client_updated_at;
ALTER TABLE customers DROP COLUMN IF EXISTS client_updated_at;
ALTER TABLE batches DROP COLUMN IF EXISTS client_updated_at;
ALTER TABLE product_variants DROP COLUMN IF EXISTS client_updated_at;
ALTER TABLE products DROP COLUMN IF EXISTS client_updated_at;

DROP INDEX IF EXISTS idx_sync_processed_record;
DROP INDEX IF EXISTS idx_sync_processed_at;
DROP TABLE IF EXISTS sync_processed_mutations;

