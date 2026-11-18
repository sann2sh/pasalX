package db

import (
	"context"
	"errors"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

var rlsTenantTables = []string{
	"store_memberships",
	"store_invitations",
	"products",
	"product_variants",
	"batches",
	"stock_movements",
	"customers",
	"customer_shade_profiles",
	"customer_transactions",
	"suppliers",
	"purchase_invoices",
	"purchase_invoice_items",
	"supplier_payments",
	"sale_orders",
	"sale_items",
	"sale_payments",
	"register_shifts",
	"staff_shift_sessions",
	"expenses",
	"device_registrations",
	"inventory_sync_audit",
	"sync_processed_mutations",
}

func TestMigrationsCycleAndRLSIsolation(t *testing.T) {
	if os.Getenv("PASALX_SKIP_DB_TESTS") == "1" {
		t.Skip("PASALX_SKIP_DB_TESTS=1")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	admin, err := ConnectPool(ctx)
	if err != nil {
		t.Fatalf("ConnectPool: %v", err)
	}
	defer admin.Close()

	dbName := fmt.Sprintf("pasalx_rlstest_%d", time.Now().UnixNano())
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+dbName); err != nil {
		t.Fatalf("create test db: %v", err)
	}
	defer func() {
		dctx, dcancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer dcancel()
		_, _ = admin.Exec(dctx, "DROP DATABASE IF EXISTS "+dbName+" WITH (FORCE)")
	}()

	cfg := admin.Config().ConnConfig
	dbURL := fmt.Sprintf("postgres://%s:%s@%s:%d/%s?sslmode=disable", cfg.User, cfg.Password, cfg.Host, cfg.Port, dbName)

	expectedVer, err := ExpectedMigrationVersion()
	if err != nil {
		t.Fatalf("ExpectedMigrationVersion: %v", err)
	}

	// 1. Test full up -> down -> up migration cycle
	v, changed, err := MigrateUp(dbURL)
	if err != nil || !changed || v != expectedVer {
		t.Fatalf("first MigrateUp: v=%d changed=%v err=%v", v, changed, err)
	}
	if _, _, err := MigrateDown(dbURL, int(expectedVer)); err != nil {
		t.Fatalf("MigrateDown(%d): %v", expectedVer, err)
	}
	v, changed, err = MigrateUp(dbURL)
	if err != nil || !changed || v != expectedVer {
		t.Fatalf("second MigrateUp: v=%d changed=%v err=%v", v, changed, err)
	}

	pool, err := pgxpool.New(ctx, dbURL)
	if err != nil {
		t.Fatalf("pgxpool.New: %v", err)
	}
	defer pool.Close()

	// 2. Create a non-superuser, NOBYPASSRLS role to verify real RLS enforcement
	roleName := fmt.Sprintf("pasalx_rls_app_%d", time.Now().UnixNano())
	if _, err := pool.Exec(ctx, fmt.Sprintf(`
		CREATE ROLE %s NOSUPERUSER NOBYPASSRLS NOLOGIN;
		GRANT USAGE ON SCHEMA public TO %s;
		GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO %s;
		GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO %s;
	`, roleName, roleName, roleName, roleName)); err != nil {
		t.Fatalf("create rls test role: %v", err)
	}
	defer func() {
		_, _ = admin.Exec(context.Background(), "DROP ROLE IF EXISTS "+roleName)
	}()

	// 3. Seed two stores and a product in each (as owner)
	if _, err := pool.Exec(ctx, `
		INSERT INTO stores (id, name) VALUES ('store-a', 'Store A'), ('store-b', 'Store B');
		INSERT INTO products (id, store_id, name, brand, category) VALUES
			('prod-a', 'store-a', 'Lipstick A', 'BrandA', 'COSMETICS'),
			('prod-b', 'store-b', 'Lipstick B', 'BrandB', 'COSMETICS');
	`); err != nil {
		t.Fatalf("seed stores/products: %v", err)
	}

	// 4. As non-owner app role WITHOUT app.store_id, every tenant table returns 0 rows
	err = WithTenantTx(ctx, pool, "store-a", func(tx pgx.Tx) error { return nil })
	if err != nil {
		t.Fatalf("WithTenantTx smoke: %v", err)
	}

	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatalf("begin: %v", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if _, err := tx.Exec(ctx, "SET LOCAL ROLE "+roleName); err != nil {
		t.Fatalf("set local role: %v", err)
	}
	// Unset app.store_id => fail-closed: 0 rows on every tenant table
	for _, tbl := range rlsTenantTables {
		var cnt int
		if err := tx.QueryRow(ctx, fmt.Sprintf("SELECT count(*) FROM %s", tbl)).Scan(&cnt); err != nil {
			t.Fatalf("select %s without store_id: %v", tbl, err)
		}
		if cnt != 0 {
			t.Fatalf("expected 0 rows from %s without app.store_id, got %d", tbl, cnt)
		}
	}

	// Attempting to insert into products without app.store_id must fail with 42501
	_, err = tx.Exec(ctx, `INSERT INTO products (id, store_id, name, brand, category) VALUES ('prod-x', 'store-a', 'X', 'B', 'C')`)
	assertPgCode(t, err, "42501", "insert without app.store_id")
	_ = tx.Rollback(ctx)

	// 5. With app.store_id = 'store-a', Store A is visible, Store B is invisible & unmodifiable
	tx2, err := pool.Begin(ctx)
	if err != nil {
		t.Fatalf("begin tx2: %v", err)
	}
	defer func() { _ = tx2.Rollback(ctx) }()

	if _, err := tx2.Exec(ctx, "SET LOCAL ROLE "+roleName); err != nil {
		t.Fatalf("set local role tx2: %v", err)
	}
	if _, err := tx2.Exec(ctx, `SELECT set_config('app.store_id', 'store-a', true)`); err != nil {
		t.Fatalf("set app.store_id: %v", err)
	}
	var cnt int
	if err := tx2.QueryRow(ctx, `SELECT count(*) FROM products`).Scan(&cnt); err != nil {
		t.Fatalf("select products in store-a: %v", err)
	}
	if cnt != 1 {
		t.Fatalf("expected 1 product in store-a, got %d", cnt)
	}
	var seenID string
	if err := tx2.QueryRow(ctx, `SELECT id FROM products`).Scan(&seenID); err != nil || seenID != "prod-a" {
		t.Fatalf("expected prod-a, got %q err=%v", seenID, err)
	}

	// Updating Store B's row must affect 0 rows
	tag, err := tx2.Exec(ctx, `UPDATE products SET name = 'HACKED' WHERE id = 'prod-b'`)
	if err != nil {
		t.Fatalf("update prod-b: %v", err)
	}
	if tag.RowsAffected() != 0 {
		t.Fatalf("expected 0 rows affected on prod-b from store-a, got %d", tag.RowsAffected())
	}

	// Inserting a row with store_id = 'store-b' while app.store_id = 'store-a' must fail with 42501
	_, err = tx2.Exec(ctx, `INSERT INTO products (id, store_id, name, brand, category) VALUES ('prod-evil', 'store-b', 'Evil', 'B', 'C')`)
	assertPgCode(t, err, "42501", "insert store-b from store-a context")
}

func assertPgCode(t *testing.T, err error, code, desc string) {
	t.Helper()
	if err == nil {
		t.Fatalf("%s: expected pg error %s, got nil", desc, code)
	}
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != code {
		t.Fatalf("%s: expected pg error %s, got %v", desc, code, err)
	}
}
