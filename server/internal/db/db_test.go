package db

import (
	"context"
	"testing"
	"time"
)

func TestConnectPool(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	pool, err := ConnectPool(ctx)
	if err != nil {
		t.Fatalf("ConnectPool failed: %v", err)
	}
	defer pool.Close()

	var one int
	if err := pool.QueryRow(ctx, "SELECT 1").Scan(&one); err != nil || one != 1 {
		t.Fatalf("SELECT 1 failed: one=%d err=%v", one, err)
	}

	var tableCount int
	err = pool.QueryRow(ctx, "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'").Scan(&tableCount)
	if err != nil {
		t.Fatalf("Table count query failed: %v", err)
	}
	if tableCount != 21 {
		t.Errorf("Expected 21 tables in public schema, got %d", tableCount)
	}

	// Verify sync-critical columns & constraints added in Phase 2 review cleanup
	var hasUpdatedAt bool
	err = pool.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM information_schema.columns
			WHERE table_schema = 'public' AND table_name = 'staff_shift_sessions' AND column_name = 'updated_at'
		)
	`).Scan(&hasUpdatedAt)
	if err != nil || !hasUpdatedAt {
		t.Errorf("Expected staff_shift_sessions.updated_at to exist (exists=%v, err=%v)", hasUpdatedAt, err)
	}

	var hasShiftFK bool
	err = pool.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM information_schema.table_constraints
			WHERE table_schema = 'public' AND table_name = 'sale_orders' AND constraint_name = 'fk_sale_orders_shift'
		)
	`).Scan(&hasShiftFK)
	if err != nil || !hasShiftFK {
		t.Errorf("Expected sale_orders fk_sale_orders_shift constraint to exist (exists=%v, err=%v)", hasShiftFK, err)
	}
}
