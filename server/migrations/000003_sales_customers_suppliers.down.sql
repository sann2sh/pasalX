DROP TABLE IF EXISTS sale_payments CASCADE;
DROP TABLE IF EXISTS sale_items CASCADE;
DROP TABLE IF EXISTS sale_orders CASCADE;
DROP TABLE IF EXISTS supplier_payments CASCADE;
DROP TABLE IF EXISTS purchase_invoice_items CASCADE;
ALTER TABLE batches
    DROP CONSTRAINT IF EXISTS fk_batches_purchase_invoice,
    DROP CONSTRAINT IF EXISTS fk_batches_supplier;
DROP TABLE IF EXISTS purchase_invoices CASCADE;
DROP TABLE IF EXISTS suppliers CASCADE;
DROP TABLE IF EXISTS customer_transactions CASCADE;
DROP TABLE IF EXISTS customer_shade_profiles CASCADE;
DROP TABLE IF EXISTS customers CASCADE;

