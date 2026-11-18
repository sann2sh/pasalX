-- ============================================================================
-- 000002_catalog_and_inventory.up.sql: Store-Scoped Products, Variants, Batches
-- ============================================================================

CREATE TABLE IF NOT EXISTS products (
    id VARCHAR(36) PRIMARY KEY,
    store_id VARCHAR(36) NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    brand VARCHAR(100) NOT NULL,
    category VARCHAR(50) NOT NULL,
    is_generic BOOLEAN NOT NULL DEFAULT FALSE,
    photo_url TEXT,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    client_updated_at TIMESTAMP WITH TIME ZONE,
    deleted_at TIMESTAMP WITH TIME ZONE,
    UNIQUE (store_id, id)
);
CREATE INDEX IF NOT EXISTS idx_products_store_category ON products(store_id, category);
CREATE INDEX IF NOT EXISTS idx_products_store_brand ON products(store_id, brand);
CREATE INDEX IF NOT EXISTS idx_products_store_updated ON products(store_id, updated_at);

CREATE TABLE IF NOT EXISTS product_variants (
    id VARCHAR(36) PRIMARY KEY,
    store_id VARCHAR(36) NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    product_id VARCHAR(36) NOT NULL,
    variant_name VARCHAR(150) NOT NULL,
    size_volume VARCHAR(50),
    color_hex VARCHAR(7),
    attributes JSONB NOT NULL DEFAULT '{}',
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    client_updated_at TIMESTAMP WITH TIME ZONE,
    deleted_at TIMESTAMP WITH TIME ZONE,
    UNIQUE (store_id, id),
    FOREIGN KEY (store_id, product_id) REFERENCES products(store_id, id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_variants_store_product ON product_variants(store_id, product_id);
CREATE INDEX IF NOT EXISTS idx_variants_store_updated ON product_variants(store_id, updated_at);

CREATE TABLE IF NOT EXISTS batches (
    id VARCHAR(36) PRIMARY KEY,
    store_id VARCHAR(36) NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    variant_id VARCHAR(36) NOT NULL,
    supplier_id VARCHAR(36),
    purchase_invoice_id VARCHAR(36),
    batch_code VARCHAR(100) NOT NULL,
    sticker_barcode VARCHAR(50) NOT NULL,
    cost_price DECIMAL(10,2) NOT NULL,
    selling_price DECIMAL(10,2) NOT NULL,
    stock_quantity INT NOT NULL DEFAULT 0,
    expiry_date DATE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    client_updated_at TIMESTAMP WITH TIME ZONE,
    deleted_at TIMESTAMP WITH TIME ZONE,
    UNIQUE (store_id, id),
    UNIQUE (store_id, sticker_barcode),
    FOREIGN KEY (store_id, variant_id) REFERENCES product_variants(store_id, id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_batches_store_barcode ON batches(store_id, sticker_barcode);
CREATE INDEX IF NOT EXISTS idx_batches_store_expiry ON batches(store_id, expiry_date);
CREATE INDEX IF NOT EXISTS idx_batches_store_variant ON batches(store_id, variant_id);
CREATE INDEX IF NOT EXISTS idx_batches_store_updated ON batches(store_id, updated_at);

CREATE TABLE IF NOT EXISTS stock_movements (
    id VARCHAR(36) PRIMARY KEY,
    store_id VARCHAR(36) NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    batch_id VARCHAR(36) NOT NULL,
    movement_type VARCHAR(30) NOT NULL,
    quantity INT NOT NULL,
    reference_id VARCHAR(100),
    reason TEXT,
    staff_name VARCHAR(100) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (store_id, id),
    FOREIGN KEY (store_id, batch_id) REFERENCES batches(store_id, id)
);
CREATE INDEX IF NOT EXISTS idx_movements_store_batch ON stock_movements(store_id, batch_id);
CREATE INDEX IF NOT EXISTS idx_movements_store_updated ON stock_movements(store_id, updated_at);

