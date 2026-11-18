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
}
