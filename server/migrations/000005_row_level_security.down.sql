DROP FUNCTION IF EXISTS lookup_invitation_by_hash(BYTEA);
DROP FUNCTION IF EXISTS lookup_user_active_membership(VARCHAR);
DROP FUNCTION IF EXISTS lookup_device_auth(VARCHAR);

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
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON %I', t);
        EXECUTE format('ALTER TABLE %I NO FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE %I DISABLE ROW LEVEL SECURITY', t);
    END LOOP;
END $$;

