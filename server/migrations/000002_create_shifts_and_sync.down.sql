-- ============================================================================
-- 000002_create_shifts_and_sync.down.sql: Rollback Shifts, Devices & Sync Audits
-- ============================================================================

DROP INDEX IF EXISTS idx_shift_sessions_updated_at;
DROP INDEX IF EXISTS idx_register_shifts_updated_at;
DROP INDEX IF EXISTS idx_sales_updated_at;
DROP INDEX IF EXISTS idx_suppliers_updated_at;
DROP INDEX IF EXISTS idx_customers_updated_at;
DROP INDEX IF EXISTS idx_batches_updated_at;
DROP INDEX IF EXISTS idx_variants_updated_at;
DROP INDEX IF EXISTS idx_products_updated_at;

ALTER TABLE IF EXISTS sale_orders
    DROP CONSTRAINT IF EXISTS fk_sale_orders_shift;

DROP TABLE IF EXISTS app_audit_logs CASCADE;
DROP TABLE IF EXISTS inventory_sync_audit CASCADE;
DROP TABLE IF EXISTS device_registrations CASCADE;
DROP TABLE IF EXISTS expenses CASCADE;
DROP TABLE IF EXISTS staff_shift_sessions CASCADE;
DROP TABLE IF EXISTS register_shifts CASCADE;
