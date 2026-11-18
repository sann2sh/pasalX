-- ============================================================================
-- 000005_row_level_security.up.sql: Strict RLS on all tenant tables
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
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON %I', t);
        EXECUTE format(
            'CREATE POLICY tenant_isolation ON %I
             USING (store_id = NULLIF(current_setting(''app.store_id'', true), ''''))
             WITH CHECK (store_id = NULLIF(current_setting(''app.store_id'', true), ''''))',
            t
        );
    END LOOP;
END $$;

-- Narrow SECURITY DEFINER functions for pre-tenant / cross-store lookups
-- (e.g., authenticating an incoming device_id before app.store_id is set).
CREATE OR REPLACE FUNCTION lookup_device_auth(p_device_id VARCHAR)
RETURNS TABLE (
    id VARCHAR,
    store_id VARCHAR,
    device_code VARCHAR,
    device_name VARCHAR,
    platform VARCHAR,
    status VARCHAR,
    is_active BOOLEAN,
    revoked_at TIMESTAMP WITH TIME ZONE,
    dek_sealed BYTEA,
    current_lease_id VARCHAR,
    current_user_id VARCHAR,
    store_status VARCHAR
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT d.id, d.store_id, d.device_code, d.device_name, d.platform,
           d.status, d.is_active, d.revoked_at, d.dek_sealed,
           d.current_lease_id, d.current_user_id, s.status
    FROM public.device_registrations d
    JOIN public.stores s ON s.id = d.store_id
    WHERE d.id = p_device_id;
$$;

CREATE OR REPLACE FUNCTION lookup_user_active_membership(p_user_id VARCHAR)
RETURNS TABLE (
    membership_id VARCHAR,
    store_id VARCHAR,
    role VARCHAR,
    store_name VARCHAR,
    store_status VARCHAR
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT m.id, m.store_id, m.role, s.name, s.status
    FROM public.store_memberships m
    JOIN public.stores s ON s.id = m.store_id
    WHERE m.user_id = p_user_id AND m.status = 'ACTIVE';
$$;

CREATE OR REPLACE FUNCTION lookup_invitation_by_hash(p_code_hash BYTEA)
RETURNS TABLE (
    id VARCHAR,
    store_id VARCHAR,
    role VARCHAR,
    invited_email CITEXT,
    status VARCHAR,
    expires_at TIMESTAMP WITH TIME ZONE
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT i.id, i.store_id, i.role, i.invited_email, i.status, i.expires_at
    FROM public.store_invitations i
    WHERE i.code_hash = p_code_hash;
$$;

