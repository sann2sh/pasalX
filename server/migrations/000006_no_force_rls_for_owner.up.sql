-- ============================================================================
-- 000006_no_force_rls_for_owner.up.sql:
-- Keep ENABLE ROW LEVEL SECURITY for non-owner runtime role (pasalx_app),
-- but remove FORCE ROW LEVEL SECURITY so table owner (pasalx_owner) and
-- SECURITY DEFINER lookup_* functions owned by pasalx_owner can read rows
-- before app.store_id is set (e.g., lookup_device_auth, lookup_invitation_by_hash,
-- lookup_user_active_membership, and pasalx-admin purge-closed-stores).
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
        EXECUTE format('ALTER TABLE %I NO FORCE ROW LEVEL SECURITY', t);
    END LOOP;
END $$;

