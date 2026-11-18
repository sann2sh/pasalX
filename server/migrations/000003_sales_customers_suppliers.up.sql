-- ============================================================================
-- 000003_sales_customers_suppliers.up.sql: Customers, Suppliers, Sales
-- ============================================================================

CREATE TABLE IF NOT EXISTS customers (
    id VARCHAR(36) PRIMARY KEY,
    store_id VARCHAR(36) NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    phone VARCHAR(50) NOT NULL,
    address TEXT,
    credit_limit DECIMAL(10,2) NOT NULL DEFAULT 10000.00,
    current_balance_due DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    favorite_shade_notes TEXT,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    client_updated_at TIMESTAMP WITH TIME ZONE,
    deleted_at TIMESTAMP WITH TIME ZONE,
    UNIQUE (store_id, id),
    UNIQUE (store_id, phone)
);
CREATE INDEX IF NOT EXISTS idx_customers_store_phone ON customers(store_id, phone);
CREATE INDEX IF NOT EXISTS idx_customers_store_updated ON customers(store_id, updated_at);

CREATE TABLE IF NOT EXISTS customer_shade_profiles (
    id VARCHAR(36) PRIMARY KEY,
    store_id VARCHAR(36) NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    customer_id VARCHAR(36) NOT NULL,
    product_name VARCHAR(255) NOT NULL,
    brand VARCHAR(100) NOT NULL,
    shade_variant VARCHAR(150) NOT NULL,
    notes TEXT,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    client_updated_at TIMESTAMP WITH TIME ZONE,
    UNIQUE (store_id, id),
    FOREIGN KEY (store_id, customer_id) REFERENCES customers(store_id, id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_customer_shades_store_cust ON customer_shade_profiles(store_id, customer_id);
CREATE INDEX IF NOT EXISTS idx_customer_shades_store_updated ON customer_shade_profiles(store_id, updated_at);

CREATE TABLE IF NOT EXISTS customer_transactions (
    id VARCHAR(36) PRIMARY KEY,
    store_id VARCHAR(36) NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    customer_id VARCHAR(36) NOT NULL,
    type VARCHAR(30) NOT NULL CHECK (type IN ('DEBIT_PURCHASE', 'CREDIT_REPAYMENT')),
    amount DECIMAL(10,2) NOT NULL,
    balance_after DECIMAL(10,2) NOT NULL,
    reference_bill_no VARCHAR(50),
    payment_method VARCHAR(30) CHECK (payment_method IN ('CASH', 'FONEPAY_QR', 'BANK_TRANSFER')),
    notes TEXT,
    created_by_user_id VARCHAR(36) REFERENCES users(id),
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (store_id, id),
    FOREIGN KEY (store_id, customer_id) REFERENCES customers(store_id, id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS idx_customer_tx_store_cust ON customer_transactions(store_id, customer_id);
CREATE INDEX IF NOT EXISTS idx_customer_tx_store_updated ON customer_transactions(store_id, updated_at);

CREATE TABLE IF NOT EXISTS suppliers (
    id VARCHAR(36) PRIMARY KEY,
    store_id VARCHAR(36) NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    phone VARCHAR(50),
    pan_vat VARCHAR(50),
    address TEXT,
    total_purchased DECIMAL(12,2) NOT NULL DEFAULT 0.00,
    total_paid DECIMAL(12,2) NOT NULL DEFAULT 0.00,
    balance_due DECIMAL(12,2) NOT NULL DEFAULT 0.00,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    client_updated_at TIMESTAMP WITH TIME ZONE,
    deleted_at TIMESTAMP WITH TIME ZONE,
    UNIQUE (store_id, id)
);
CREATE INDEX IF NOT EXISTS idx_suppliers_store_updated ON suppliers(store_id, updated_at);

CREATE TABLE IF NOT EXISTS purchase_invoices (
    id VARCHAR(36) PRIMARY KEY,
    store_id VARCHAR(36) NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    supplier_id VARCHAR(36) NOT NULL,
    invoice_no VARCHAR(100) NOT NULL,
    invoice_date DATE NOT NULL,
    total_amount DECIMAL(10,2) NOT NULL,
    paid_amount DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    due_amount DECIMAL(10,2) NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'UNPAID' CHECK (status IN ('PAID', 'PARTIAL', 'UNPAID')),
    notes TEXT,
    created_by_user_id VARCHAR(36) REFERENCES users(id),
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (store_id, id),
    UNIQUE (store_id, supplier_id, invoice_no),
    FOREIGN KEY (store_id, supplier_id) REFERENCES suppliers(store_id, id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS idx_purchase_invoices_store_supplier ON purchase_invoices(store_id, supplier_id);
CREATE INDEX IF NOT EXISTS idx_purchase_invoices_store_updated ON purchase_invoices(store_id, updated_at);

-- Link batches to suppliers and purchase_invoices with composite store-scoped FKs
ALTER TABLE batches
    ADD CONSTRAINT fk_batches_supplier
        FOREIGN KEY (store_id, supplier_id) REFERENCES suppliers(store_id, id),
    ADD CONSTRAINT fk_batches_purchase_invoice
        FOREIGN KEY (store_id, purchase_invoice_id) REFERENCES purchase_invoices(store_id, id);

CREATE TABLE IF NOT EXISTS purchase_invoice_items (
    id VARCHAR(36) PRIMARY KEY,
    store_id VARCHAR(36) NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    purchase_invoice_id VARCHAR(36) NOT NULL,
    variant_id VARCHAR(36) NOT NULL,
    batch_id VARCHAR(36),
    product_name VARCHAR(255) NOT NULL,
    variant_name VARCHAR(150) NOT NULL,
    quantity_received INT NOT NULL,
    unit_cost_price DECIMAL(10,2) NOT NULL,
    unit_selling_price DECIMAL(10,2) NOT NULL,
    total_cost DECIMAL(10,2) NOT NULL,
    batch_code VARCHAR(100),
    expiry_date DATE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (store_id, id),
    FOREIGN KEY (store_id, purchase_invoice_id) REFERENCES purchase_invoices(store_id, id) ON DELETE CASCADE,
    FOREIGN KEY (store_id, variant_id) REFERENCES product_variants(store_id, id),
    FOREIGN KEY (store_id, batch_id) REFERENCES batches(store_id, id)
);
CREATE INDEX IF NOT EXISTS idx_purchase_items_store_updated ON purchase_invoice_items(store_id, updated_at);

CREATE TABLE IF NOT EXISTS supplier_payments (
    id VARCHAR(36) PRIMARY KEY,
    store_id VARCHAR(36) NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    supplier_id VARCHAR(36) NOT NULL,
    purchase_invoice_id VARCHAR(36),
    amount DECIMAL(10,2) NOT NULL,
    payment_method VARCHAR(30) NOT NULL CHECK (payment_method IN ('BANK_TRANSFER', 'CASH', 'CHEQUE', 'FONEPAY')),
    reference_no VARCHAR(100),
    created_by_user_id VARCHAR(36) REFERENCES users(id),
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (store_id, id),
    FOREIGN KEY (store_id, supplier_id) REFERENCES suppliers(store_id, id),
    FOREIGN KEY (store_id, purchase_invoice_id) REFERENCES purchase_invoices(store_id, id)
);
CREATE INDEX IF NOT EXISTS idx_supplier_payments_store_updated ON supplier_payments(store_id, updated_at);

CREATE TABLE IF NOT EXISTS sale_orders (
    id VARCHAR(36) PRIMARY KEY,
    store_id VARCHAR(36) NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    bill_no VARCHAR(50) NOT NULL,
    customer_id VARCHAR(36),
    customer_name VARCHAR(100),
    customer_phone VARCHAR(50),
    cashier_user_id VARCHAR(36) NOT NULL REFERENCES users(id),
    cashier_name VARCHAR(100) NOT NULL,
    shift_id VARCHAR(36),
    subtotal DECIMAL(10,2) NOT NULL,
    discount_amount DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    total_amount DECIMAL(10,2) NOT NULL,
    cost_total DECIMAL(10,2) NOT NULL,
    net_profit DECIMAL(10,2) NOT NULL,
    payment_mode VARCHAR(30) NOT NULL,
    sync_status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (store_id, id),
    UNIQUE (store_id, bill_no),
    FOREIGN KEY (store_id, customer_id) REFERENCES customers(store_id, id)
);
CREATE INDEX IF NOT EXISTS idx_sales_store_date ON sale_orders(store_id, created_at);
CREATE INDEX IF NOT EXISTS idx_sales_store_bill_no ON sale_orders(store_id, bill_no);
CREATE INDEX IF NOT EXISTS idx_sales_store_updated ON sale_orders(store_id, updated_at);

CREATE TABLE IF NOT EXISTS sale_items (
    id VARCHAR(36) PRIMARY KEY,
    store_id VARCHAR(36) NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    sale_order_id VARCHAR(36) NOT NULL,
    batch_id VARCHAR(36) NOT NULL,
    product_name VARCHAR(255) NOT NULL,
    variant_name VARCHAR(150) NOT NULL,
    quantity INT NOT NULL,
    cost_price DECIMAL(10,2) NOT NULL,
    selling_price DECIMAL(10,2) NOT NULL,
    total_price DECIMAL(10,2) NOT NULL,
    UNIQUE (store_id, id),
    FOREIGN KEY (store_id, sale_order_id) REFERENCES sale_orders(store_id, id) ON DELETE CASCADE,
    FOREIGN KEY (store_id, batch_id) REFERENCES batches(store_id, id)
);
CREATE INDEX IF NOT EXISTS idx_sale_items_store_order ON sale_items(store_id, sale_order_id);

CREATE TABLE IF NOT EXISTS sale_payments (
    id VARCHAR(36) PRIMARY KEY,
    store_id VARCHAR(36) NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
    sale_order_id VARCHAR(36) NOT NULL,
    method VARCHAR(30) NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    transaction_ref VARCHAR(100),
    UNIQUE (store_id, id),
    FOREIGN KEY (store_id, sale_order_id) REFERENCES sale_orders(store_id, id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_sale_payments_store_order ON sale_payments(store_id, sale_order_id);

