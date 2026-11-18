DROP TABLE IF EXISTS app_audit_logs CASCADE;
DROP TABLE IF EXISTS sync_processed_mutations CASCADE;
DROP TABLE IF EXISTS inventory_sync_audit CASCADE;
DROP TABLE IF EXISTS expenses CASCADE;
DROP TABLE IF EXISTS staff_shift_sessions CASCADE;
DROP TABLE IF EXISTS device_registrations CASCADE;
ALTER TABLE sale_orders DROP CONSTRAINT IF EXISTS fk_sale_orders_shift;
DROP TABLE IF EXISTS register_shifts CASCADE;

