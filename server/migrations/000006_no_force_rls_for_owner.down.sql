-- ============================================================================
-- 000006_no_force_rls_for_owner.down.sql: Re-enable FORCE ROW LEVEL SECURITY
-- ============================================================================

DO $$
DECLARE
    t TEXT;
    tenant_tables TEXT[] := ARRAY[
        'store_memberships',
        'store_invitations',
        'products',
        'product_variants',
        'batches',
        'stock_movements',
        'customers',
        'customer_shade_profiles',
        'customer_transactions',
        'suppliers',
        'purchase_invoices',
        'purchase_invoice_items',
        'supplier_payments',
        'sale_orders',
        'sale_items',
        'sale_payments',
        'register_shifts',
        'staff_shift_sessions',
        'expenses',
        'device_registrations',
        'inventory_sync_audit',
        'sync_processed_mutations'
    ];
BEGIN
    FOREACH t IN ARRAY tenant_tables LOOP
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    END LOOP;
END $$;

