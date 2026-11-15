-- ============================================================================
-- 000001_create_core_tables.up.sql: Core Catalog, Customers, Suppliers & Sales
-- ============================================================================

-- 1. USERS
CREATE TABLE IF NOT EXISTS users (
    id VARCHAR(36) PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    username VARCHAR(50) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    pin_hash VARCHAR(255),
    phone VARCHAR(50),
    role VARCHAR(30) NOT NULL CHECK (role IN ('OWNER', 'MANAGER', 'STAFF')),
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);
CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);

-- 2. CUSTOMERS & KHATA
CREATE TABLE IF NOT EXISTS customers (
    id VARCHAR(36) PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    phone VARCHAR(50) UNIQUE NOT NULL,
    address TEXT,
    credit_limit DECIMAL(10,2) DEFAULT 10000.00,
    current_balance_due DECIMAL(10,2) DEFAULT 0.00,
    favorite_shade_notes TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);
CREATE INDEX IF NOT EXISTS idx_customers_phone ON customers(phone);

CREATE TABLE IF NOT EXISTS customer_shade_profiles (
    id VARCHAR(36) PRIMARY KEY,
    customer_id VARCHAR(36) NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
    product_name VARCHAR(255) NOT NULL,
    brand VARCHAR(100) NOT NULL,
    shade_variant VARCHAR(150) NOT NULL,
    notes TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_customer_shades_cust ON customer_shade_profiles(customer_id);

CREATE TABLE IF NOT EXISTS customer_transactions (
    id VARCHAR(36) PRIMARY KEY,
    customer_id VARCHAR(36) NOT NULL REFERENCES customers(id) ON DELETE RESTRICT,
    type VARCHAR(30) NOT NULL CHECK (type IN ('DEBIT_PURCHASE', 'CREDIT_REPAYMENT')),
    amount DECIMAL(10,2) NOT NULL,
    balance_after DECIMAL(10,2) NOT NULL,
    reference_bill_no VARCHAR(50),
    payment_method VARCHAR(30) CHECK (payment_method IN ('CASH', 'FONEPAY_QR', 'BANK_TRANSFER')),
    notes TEXT,
    created_by_user_id VARCHAR(36) REFERENCES users(id),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_customer_tx_cust ON customer_transactions(customer_id);

-- 3. SUPPLIERS & PROCUREMENT
CREATE TABLE IF NOT EXISTS suppliers (
    id VARCHAR(36) PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    phone VARCHAR(50),
    pan_vat VARCHAR(50),
    address TEXT,
    total_purchased DECIMAL(12,2) DEFAULT 0.00,
    total_paid DECIMAL(12,2) DEFAULT 0.00,
    balance_due DECIMAL(12,2) DEFAULT 0.00,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

CREATE TABLE IF NOT EXISTS purchase_invoices (
    id VARCHAR(36) PRIMARY KEY,
    supplier_id VARCHAR(36) NOT NULL REFERENCES suppliers(id) ON DELETE RESTRICT,
    invoice_no VARCHAR(100) NOT NULL,
    invoice_date DATE NOT NULL,
    total_amount DECIMAL(10,2) NOT NULL,
    paid_amount DECIMAL(10,2) DEFAULT 0.00,
    due_amount DECIMAL(10,2) NOT NULL,
    status VARCHAR(20) DEFAULT 'UNPAID' CHECK (status IN ('PAID', 'PARTIAL', 'UNPAID')),
    notes TEXT,
    created_by_user_id VARCHAR(36) REFERENCES users(id),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_purchase_invoices_supplier ON purchase_invoices(supplier_id);

-- 4. PRODUCT CATALOG & 3-TIER INVENTORY
CREATE TABLE IF NOT EXISTS products (
    id VARCHAR(36) PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    brand VARCHAR(100) NOT NULL,
    category VARCHAR(50) NOT NULL,
    is_generic BOOLEAN DEFAULT FALSE,
    photo_url TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);
CREATE INDEX IF NOT EXISTS idx_products_category ON products(category);
CREATE INDEX IF NOT EXISTS idx_products_brand ON products(brand);

CREATE TABLE IF NOT EXISTS product_variants (
    id VARCHAR(36) PRIMARY KEY,
    product_id VARCHAR(36) NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    variant_name VARCHAR(150) NOT NULL,
    size_volume VARCHAR(50),
    color_hex VARCHAR(7),
    attributes JSONB DEFAULT '{}',
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);
CREATE INDEX IF NOT EXISTS idx_variants_product ON product_variants(product_id);

CREATE TABLE IF NOT EXISTS batches (
    id VARCHAR(36) PRIMARY KEY,
    variant_id VARCHAR(36) NOT NULL REFERENCES product_variants(id) ON DELETE CASCADE,
    supplier_id VARCHAR(36) REFERENCES suppliers(id),
    purchase_invoice_id VARCHAR(36) REFERENCES purchase_invoices(id),
    batch_code VARCHAR(100) NOT NULL,
    sticker_barcode VARCHAR(50) UNIQUE NOT NULL,
    cost_price DECIMAL(10,2) NOT NULL,
    selling_price DECIMAL(10,2) NOT NULL,
    stock_quantity INT NOT NULL DEFAULT 0,
    expiry_date DATE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);
CREATE INDEX IF NOT EXISTS idx_batches_barcode ON batches(sticker_barcode);
CREATE INDEX IF NOT EXISTS idx_batches_expiry ON batches(expiry_date);
CREATE INDEX IF NOT EXISTS idx_batches_variant ON batches(variant_id);

CREATE TABLE IF NOT EXISTS purchase_invoice_items (
    id VARCHAR(36) PRIMARY KEY,
    purchase_invoice_id VARCHAR(36) NOT NULL REFERENCES purchase_invoices(id) ON DELETE CASCADE,
    variant_id VARCHAR(36) NOT NULL REFERENCES product_variants(id),
    batch_id VARCHAR(36) REFERENCES batches(id),
    product_name VARCHAR(255) NOT NULL,
    variant_name VARCHAR(150) NOT NULL,
    quantity_received INT NOT NULL,
    unit_cost_price DECIMAL(10,2) NOT NULL,
    unit_selling_price DECIMAL(10,2) NOT NULL,
    total_cost DECIMAL(10,2) NOT NULL,
    batch_code VARCHAR(100),
    expiry_date DATE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS supplier_payments (
    id VARCHAR(36) PRIMARY KEY,
    supplier_id VARCHAR(36) NOT NULL REFERENCES suppliers(id),
    purchase_invoice_id VARCHAR(36) REFERENCES purchase_invoices(id),
    amount DECIMAL(10,2) NOT NULL,
    payment_method VARCHAR(30) NOT NULL CHECK (payment_method IN ('BANK_TRANSFER', 'CASH', 'CHEQUE', 'FONEPAY')),
    reference_no VARCHAR(100),
    created_by_user_id VARCHAR(36) REFERENCES users(id),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS stock_movements (
    id VARCHAR(36) PRIMARY KEY,
    batch_id VARCHAR(36) NOT NULL REFERENCES batches(id),
    movement_type VARCHAR(30) NOT NULL,
    quantity INT NOT NULL,
    reference_id VARCHAR(100),
    reason TEXT,
    staff_name VARCHAR(100) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_movements_batch ON stock_movements(batch_id);

-- 5. SALES, LINE ITEMS & PAYMENTS
CREATE TABLE IF NOT EXISTS sale_orders (
    id VARCHAR(36) PRIMARY KEY,
    bill_no VARCHAR(50) UNIQUE NOT NULL,
    customer_id VARCHAR(36) REFERENCES customers(id),
    customer_name VARCHAR(100),
    customer_phone VARCHAR(50),
    cashier_user_id VARCHAR(36) NOT NULL REFERENCES users(id),
    cashier_name VARCHAR(100) NOT NULL,
    shift_id VARCHAR(36),
    subtotal DECIMAL(10,2) NOT NULL,
    discount_amount DECIMAL(10,2) DEFAULT 0.00,
    total_amount DECIMAL(10,2) NOT NULL,
    cost_total DECIMAL(10,2) NOT NULL,
    net_profit DECIMAL(10,2) NOT NULL,
    payment_mode VARCHAR(30) NOT NULL,
    sync_status VARCHAR(20) DEFAULT 'PENDING',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_sales_date ON sale_orders(created_at);
CREATE INDEX IF NOT EXISTS idx_sales_sync ON sale_orders(sync_status);
CREATE INDEX IF NOT EXISTS idx_sales_bill_no ON sale_orders(bill_no);

CREATE TABLE IF NOT EXISTS sale_items (
    id VARCHAR(36) PRIMARY KEY,
    sale_order_id VARCHAR(36) NOT NULL REFERENCES sale_orders(id) ON DELETE CASCADE,
    batch_id VARCHAR(36) NOT NULL REFERENCES batches(id),
    product_name VARCHAR(255) NOT NULL,
    variant_name VARCHAR(150) NOT NULL,
    quantity INT NOT NULL,
    cost_price DECIMAL(10,2) NOT NULL,
    selling_price DECIMAL(10,2) NOT NULL,
    total_price DECIMAL(10,2) NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_sale_items_order ON sale_items(sale_order_id);

CREATE TABLE IF NOT EXISTS sale_payments (
    id VARCHAR(36) PRIMARY KEY,
    sale_order_id VARCHAR(36) NOT NULL REFERENCES sale_orders(id) ON DELETE CASCADE,
    method VARCHAR(30) NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    transaction_ref VARCHAR(100)
);
CREATE INDEX IF NOT EXISTS idx_sale_payments_order ON sale_payments(sale_order_id);

