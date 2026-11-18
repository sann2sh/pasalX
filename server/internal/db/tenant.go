package db

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// WithTenantTx executes fn inside a transaction with app.store_id set locally
// for PostgreSQL Row-Level Security.
func WithTenantTx(ctx context.Context, pool *pgxpool.Pool, storeID string, fn func(pgx.Tx) error) error {
	return WithTenantTxOptions(ctx, pool, storeID, pgx.TxOptions{}, fn)
}

// WithTenantTxOptions executes fn inside a transaction with explicit pgx.TxOptions
// and app.store_id set locally for PostgreSQL Row-Level Security.
func WithTenantTxOptions(ctx context.Context, pool *pgxpool.Pool, storeID string, opts pgx.TxOptions, fn func(pgx.Tx) error) error {
	if storeID == "" {
		return fmt.Errorf("storeID is required for tenant transaction")
	}
	tx, err := pool.BeginTx(ctx, opts)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if _, err := tx.Exec(ctx, `SELECT set_config('app.store_id', $1, true)`, storeID); err != nil {
		return fmt.Errorf("set app.store_id: %w", err)
	}
	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

