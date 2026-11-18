package sync_test

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"pasalx/server/internal/auth"
	psync "pasalx/server/internal/sync"
)

func TestGateA_AdversarialCrossTenantIsolation(t *testing.T) {
	if testPool == nil {
		t.Skip("DB tests skipped")
	}
	ctx := context.Background()

	_, err := testPool.Exec(ctx, `
		TRUNCATE sync_processed_mutations, inventory_sync_audit, stock_movements,
			sale_payments, sale_items, sale_orders, expenses,
			staff_shift_sessions, register_shifts,
			supplier_payments, purchase_invoice_items, purchase_invoices, suppliers,
			customer_transactions, customer_shade_profiles, customers,
			batches, product_variants, products,
			app_audit_logs, device_registrations, store_invitations, store_memberships, stores, users RESTART IDENTITY CASCADE`)
	if err != nil {
		t.Fatalf("truncate: %v", err)
	}

	// Create a non-superuser, NOBYPASSRLS role to mirror production pasalx_app.
	appRole := fmt.Sprintf("pasalx_app_gatea_%d", time.Now().UnixNano())
	appPass := "GateA_AppPass_2026"
	if _, err := testPool.Exec(ctx, fmt.Sprintf(`
		CREATE ROLE %s NOSUPERUSER NOBYPASSRLS LOGIN PASSWORD '%s';
		GRANT USAGE ON SCHEMA public TO %s;
		GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO %s;
		GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO %s;
	`, appRole, appPass, appRole, appRole, appRole)); err != nil {
		t.Fatalf("create app role: %v", err)
	}
	defer func() {
		_, _ = testPool.Exec(context.Background(), fmt.Sprintf(`
			REVOKE ALL ON ALL TABLES IN SCHEMA public FROM %s;
			REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM %s;
			REVOKE USAGE ON SCHEMA public FROM %s;
			DROP ROLE IF EXISTS %s;`, appRole, appRole, appRole, appRole))
	}()

	cfg := testPool.Config().ConnConfig
	appURL := fmt.Sprintf("postgres://%s:%s@%s:%d/%s?sslmode=disable",
		appRole, appPass, cfg.Host, cfg.Port, cfg.Database)
	appPool, err := pgxpool.New(ctx, appURL)
	if err != nil {
		t.Fatalf("connect appPool: %v", err)
	}
	defer appPool.Close()

	masterKey := bytes.Repeat([]byte{77}, 32)
	keys, err := auth.NewKeys(masterKey)
	if err != nil {
		t.Fatalf("NewKeys: %v", err)
	}
	authSvc := auth.NewService(appPool, keys)
	hub := psync.NewHub()
	authSvc.SetOnDeviceRevoked(func(storeID, deviceID, _ string) {
		hub.RevokeDevice(storeID, deviceID)
	})
	syncSvc := psync.NewService(appPool, hub)

	mux := http.NewServeMux()
	authHandler := auth.NewHandler(authSvc, false)
	authHandler.Routes(mux)
	psync.NewHandler(syncSvc).Routes(mux, authHandler.RequireAuth)

	srv := httptest.NewServer(mux)
	defer func() {
		hub.Shutdown()
		srv.Close()
	}()

	// Seed Store A & Store B
	ownerA, err := authSvc.CreateUser(ctx, "Owner A", "ownera@test.local", "ownera", "OwnerAPass!2026", "112233")
	if err != nil {
		t.Fatalf("create ownerA: %v", err)
	}
	storeA, err := authSvc.CreateStoreWithOwner(ctx, ownerA.ID, "Store Alpha")
	if err != nil {
		t.Fatalf("create storeA: %v", err)
	}

	ownerB, err := authSvc.CreateUser(ctx, "Owner B", "ownerb@test.local", "ownerb", "OwnerBPass!2026", "445566")
	if err != nil {
		t.Fatalf("create ownerB: %v", err)
	}
	storeB, err := authSvc.CreateStoreWithOwner(ctx, ownerB.ID, "Store Beta")
	if err != nil {
		t.Fatalf("create storeB: %v", err)
	}

	devA, err := authSvc.RegisterDevice(ctx, auth.RegisterDeviceInput{
		OwnerUsername: "ownera", OwnerPassword: "OwnerAPass!2026", DeviceName: "Phone A", Platform: "ANDROID",
	}, "127.0.0.1")
	if err != nil {
		t.Fatalf("register devA: %v", err)
	}
	devB, err := authSvc.RegisterDevice(ctx, auth.RegisterDeviceInput{
		OwnerUsername: "ownerb", OwnerPassword: "OwnerBPass!2026", DeviceName: "Phone B", Platform: "ANDROID",
	}, "127.0.0.1")
	if err != nil {
		t.Fatalf("register devB: %v", err)
	}
	if devA.Code != "01" || devB.Code != "01" {
		t.Fatalf("expected per-store device code 01 in both stores, got A=%q B=%q", devA.Code, devB.Code)
	}

	sessA, err := authSvc.Login(ctx, auth.LoginInput{Username: "ownera", PIN: "112233", DeviceID: devA.ID}, "127.0.0.1")
	if err != nil {
		t.Fatalf("login A: %v", err)
	}
	sessB, err := authSvc.Login(ctx, auth.LoginInput{Username: "ownerb", PIN: "445566", DeviceID: devB.ID}, "127.0.0.1")
	if err != nil {
		t.Fatalf("login B: %v", err)
	}

	push := func(token string, body psync.PushRequest) (int, []byte) {
		t.Helper()
		b, _ := json.Marshal(body)
		req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/sync/push", bytes.NewReader(b))
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("Content-Type", "application/json")
		resp, err := srv.Client().Do(req)
		if err != nil {
			t.Fatalf("push req: %v", err)
		}
		defer resp.Body.Close()
		var raw bytes.Buffer
		_, _ = raw.ReadFrom(resp.Body)
		return resp.StatusCode, raw.Bytes()
	}

	pull := func(token, since string) (int, psync.PullResponse, []byte) {
		t.Helper()
		u := srv.URL + "/api/sync/pull"
		if since != "" {
			u += "?since=" + since
		}
		req, _ := http.NewRequest(http.MethodGet, u, nil)
		req.Header.Set("Authorization", "Bearer "+token)
		resp, err := srv.Client().Do(req)
		if err != nil {
			t.Fatalf("pull req: %v", err)
		}
		defer resp.Body.Close()
		var raw bytes.Buffer
		_, _ = raw.ReadFrom(resp.Body)
		var pr psync.PullResponse
		_ = json.Unmarshal(raw.Bytes(), &pr)
		return resp.StatusCode, pr, raw.Bytes()
	}

	// Store A seeds product, variant, batch, customer, supplier, shift, and a sale with bill_no "01-0001".
	prodAID := uuid.NewString()
	varAID := uuid.NewString()
	batchAID := uuid.NewString()
	custAID := uuid.NewString()
	supAID := uuid.NewString()
	shiftAID := uuid.NewString()
	saleAID := uuid.NewString()
	mutProductAID := uuid.NewString()

	code, raw := push(sessA.AccessToken, psync.PushRequest{
		Mutations: []psync.Mutation{
			{ID: mutProductAID, TableName: psync.TableProducts, RecordID: prodAID, Operation: psync.OpInsert,
				Payload: mustRaw(map[string]any{"id": prodAID, "name": "Alpha Lipstick", "brand": "Alpha", "category": "Lips"})},
			{ID: uuid.NewString(), TableName: psync.TableProductVariants, RecordID: varAID, Operation: psync.OpInsert,
				Payload: mustRaw(map[string]any{"id": varAID, "product_id": prodAID, "variant_name": "Ruby"})},
			{ID: uuid.NewString(), TableName: psync.TableSuppliers, RecordID: supAID, Operation: psync.OpInsert,
				Payload: mustRaw(map[string]any{"id": supAID, "name": "Alpha Supplier"})},
			{ID: uuid.NewString(), TableName: psync.TableBatches, RecordID: batchAID, Operation: psync.OpInsert,
				Payload: mustRaw(map[string]any{"id": batchAID, "variant_id": varAID, "supplier_id": supAID, "batch_code": "BA1", "sticker_barcode": "SHARED-BARCODE-001", "cost_price": "100.00", "selling_price": "200.00", "expiry_date": "2028-01-01"})},
			{ID: uuid.NewString(), TableName: psync.TableStockMovements, RecordID: uuid.NewString(), Operation: psync.OpInsert,
				Payload: mustRaw(map[string]any{"batch_id": batchAID, "movement_type": "PURCHASE_INTAKE", "quantity_change": 10, "staff_name": "Owner A"})},
			{ID: uuid.NewString(), TableName: psync.TableCustomers, RecordID: custAID, Operation: psync.OpInsert,
				Payload: mustRaw(map[string]any{"id": custAID, "name": "Customer A", "phone": "9800000001"})},
			{ID: uuid.NewString(), TableName: psync.TableRegisterShifts, RecordID: shiftAID, Operation: psync.OpInsert,
				Payload: mustRaw(map[string]any{"id": shiftAID, "opened_by_user_id": ownerA.ID, "opening_float": "1000.00", "status": "OPEN"})},
			{ID: uuid.NewString(), TableName: psync.TableSaleOrders, RecordID: saleAID, Operation: psync.OpInsert,
				Payload: mustRaw(map[string]any{"id": saleAID, "bill_no": "01-0001", "cashier_user_id": ownerA.ID, "cashier_name": "Owner A", "shift_id": shiftAID, "subtotal": "200.00", "discount_amount": "0.00", "total_amount": "200.00", "payment_mode": "CASH"})},
		},
	})
	if code != http.StatusOK {
		t.Fatalf("Store A seed failed: %d %s", code, raw)
	}

	// Snapshot Store A pull before attacks
	stCode, beforePull, beforeRaw := pull(sessA.AccessToken, "")
	if stCode != http.StatusOK {
		t.Fatalf("Store A pull before failed: %d %s", stCode, beforeRaw)
	}
	if len(beforePull.Changes.Stores) != 1 || beforePull.Changes.Stores[0].ID != storeA {
		t.Fatalf("Store A pull expected own store only, got %+v", beforePull.Changes.Stores)
	}
	if len(beforePull.Changes.StoreMembers) != 1 || beforePull.Changes.StoreMembers[0].UserID != ownerA.ID {
		t.Fatalf("Store A pull expected own member only, got %+v", beforePull.Changes.StoreMembers)
	}
	if bytes.Contains(beforeRaw, []byte("ownera@test.local")) || bytes.Contains(beforeRaw, []byte("password_hash")) {
		t.Fatalf("Store A pull leaked email or hash: %s", beforeRaw)
	}

	// Open SSE stream on Store B BEFORE Store A triggers a change -> Store B must receive ZERO Store A events.
	sseReq, _ := http.NewRequest(http.MethodGet, srv.URL+"/api/sync/events", nil)
	sseReq.Header.Set("Authorization", "Bearer "+sessB.AccessToken)
	sseCtx, sseCancel := context.WithTimeout(ctx, 2*time.Second)
	defer sseCancel()
	sseResp, err := srv.Client().Do(sseReq.WithContext(sseCtx))
	if err != nil || sseResp.StatusCode != http.StatusOK {
		t.Fatalf("Store B SSE connect failed: %v", err)
	}
	defer sseResp.Body.Close()

	// Trigger a legitimate change in Store A
	code, raw = push(sessA.AccessToken, psync.PushRequest{
		Mutations: []psync.Mutation{
			{ID: uuid.NewString(), TableName: psync.TableProducts, RecordID: uuid.NewString(), Operation: psync.OpInsert,
				Payload: mustRaw(map[string]any{"name": "Alpha Serum", "brand": "Alpha", "category": "Skin"})},
		},
	})
	if code != http.StatusOK {
		t.Fatalf("Store A second push failed: %d %s", code, raw)
	}
	// Read SSE lines on Store B for 250ms: only "event: CONNECTED" may appear, never "DATA_CHANGED"
	sseLines := make(chan string, 16)
	go func() {
		sc := bufio.NewScanner(sseResp.Body)
		for sc.Scan() {
			sseLines <- sc.Text()
		}
	}()
	timer := time.NewTimer(250 * time.Millisecond)
	defer timer.Stop()
sseLoop:
	for {
		select {
		case line := <-sseLines:
			if strings.Contains(line, "DATA_CHANGED") {
				t.Fatalf("Store B SSE received Store A DATA_CHANGED event!")
			}
		case <-timer.C:
			break sseLoop
		}
	}
	sseCancel()

	// Update Store A snapshot after legitimate second push
	_, beforePull, _ = pull(sessA.AccessToken, "")
	beforeChangesJSON := mustRaw(beforePull.Changes)

	// --- Adversarial Attacks from Store B ---
	// 1a. Upsert Store A product ID (update path via ON CONFLICT (id))
	code, raw = push(sessB.AccessToken, psync.PushRequest{
		Mutations: []psync.Mutation{
			{ID: uuid.NewString(), TableName: psync.TableProducts, RecordID: prodAID, Operation: psync.OpUpdate,
				Payload: mustRaw(map[string]any{"id": prodAID, "name": "HACKED", "brand": "Hacked", "category": "Lips"})},
		},
	})
	if code != http.StatusForbidden {
		t.Fatalf("Attack 1a (upsert Store A product) expected 403, got %d %s", code, raw)
	}

	// 1b. Upsert Store A customer ID
	code, raw = push(sessB.AccessToken, psync.PushRequest{
		Mutations: []psync.Mutation{
			{ID: uuid.NewString(), TableName: psync.TableCustomers, RecordID: custAID, Operation: psync.OpUpdate,
				Payload: mustRaw(map[string]any{"id": custAID, "name": "HACKED", "phone": "9899999999"})},
		},
	})
	if code != http.StatusForbidden {
		t.Fatalf("Attack 1b (upsert Store A customer) expected 403, got %d %s", code, raw)
	}

	// 1c. Upsert Store A supplier ID
	code, raw = push(sessB.AccessToken, psync.PushRequest{
		Mutations: []psync.Mutation{
			{ID: uuid.NewString(), TableName: psync.TableSuppliers, RecordID: supAID, Operation: psync.OpUpdate,
				Payload: mustRaw(map[string]any{"id": supAID, "name": "HACKED"})},
		},
	})
	if code != http.StatusForbidden {
		t.Fatalf("Attack 1c (upsert Store A supplier) expected 403, got %d %s", code, raw)
	}

	// 2. Insert sale_items referencing Store A batch_id
	saleBID := uuid.NewString()
	code, raw = push(sessB.AccessToken, psync.PushRequest{
		Mutations: []psync.Mutation{
			{ID: uuid.NewString(), TableName: psync.TableSaleOrders, RecordID: saleBID, Operation: psync.OpInsert,
				Payload: mustRaw(map[string]any{"id": saleBID, "bill_no": "01-9999", "cashier_user_id": ownerB.ID, "cashier_name": "Owner B", "subtotal": "200.00", "discount_amount": "0.00", "total_amount": "200.00", "payment_mode": "CASH"})},
			{ID: uuid.NewString(), TableName: psync.TableSaleItems, RecordID: uuid.NewString(), Operation: psync.OpInsert,
				Payload: mustRaw(map[string]any{"sale_order_id": saleBID, "batch_id": batchAID, "product_name": "X", "variant_name": "Y", "quantity": 1, "selling_price": "200.00", "total_price": "200.00"})},
		},
	})
	if code != http.StatusUnprocessableEntity && code != http.StatusForbidden {
		t.Fatalf("Attack 2 (sale_item referencing Store A batch_id) expected 422/403, got %d %s", code, raw)
	}

	// 3. Repay Store A customer
	code, raw = push(sessB.AccessToken, psync.PushRequest{
		Mutations: []psync.Mutation{
			{ID: uuid.NewString(), TableName: psync.TableCustomerTransactions, RecordID: uuid.NewString(), Operation: psync.OpInsert,
				Payload: mustRaw(map[string]any{"customer_id": custAID, "type": "CREDIT_REPAYMENT", "amount": "50.00", "payment_method": "CASH"})},
		},
	})
	if code != http.StatusUnprocessableEntity && code != http.StatusForbidden {
		t.Fatalf("Attack 3 (repay Store A customer) expected 422/403, got %d %s", code, raw)
	}

	// 4. Close Store A shift
	code, raw = push(sessB.AccessToken, psync.PushRequest{
		Mutations: []psync.Mutation{
			{ID: uuid.NewString(), TableName: psync.TableRegisterShifts, RecordID: shiftAID, Operation: psync.OpUpdate,
				Payload: mustRaw(map[string]any{"id": shiftAID, "opened_by_user_id": ownerB.ID, "opening_float": "1000.00", "status": "CLOSED", "actual_cash_counted": "0.00"})},
		},
	})
	if code != http.StatusUnprocessableEntity && code != http.StatusForbidden {
		t.Fatalf("Attack 4 (close Store A shift) expected 422/403, got %d %s", code, raw)
	}

	// 5. Replay Store A mutation UUID in Store B -> must NOT return ALREADY_APPLIED; must fail on Store A record ID (403)
	code, raw = push(sessB.AccessToken, psync.PushRequest{
		Mutations: []psync.Mutation{
			{ID: mutProductAID, TableName: psync.TableProducts, RecordID: prodAID, Operation: psync.OpInsert,
				Payload: mustRaw(map[string]any{"id": prodAID, "name": "Replay", "brand": "B", "category": "C"})},
		},
	})
	if code != http.StatusForbidden {
		t.Fatalf("Attack 5 (replay Store A mutation UUID + record ID) expected 403, got %d %s", code, raw)
	}

	// 6. Revoke Store A device from Store B
	revBody, _ := json.Marshal(map[string]string{"device_id": devA.ID, "reason": "cross-store attack"})
	revReq, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/auth/revoke", bytes.NewReader(revBody))
	revReq.Header.Set("Authorization", "Bearer "+sessB.AccessToken)
	revReq.Header.Set("Content-Type", "application/json")
	revResp, err := srv.Client().Do(revReq)
	if err != nil {
		t.Fatalf("revoke req: %v", err)
	}
	revResp.Body.Close()
	if revResp.StatusCode != http.StatusNotFound && revResp.StatusCode != http.StatusForbidden {
		t.Fatalf("Attack 6 (revoke Store A device) expected 404/403, got %d", revResp.StatusCode)
	}

	// 7. Pull from Store B with epoch cursor -> must see 0 Store A records, only Store B's own store & member
	stCode, pullB, pullBRaw := pull(sessB.AccessToken, "1970-01-01T00:00:00Z")
	if stCode != http.StatusOK {
		t.Fatalf("Store B pull failed: %d %s", stCode, pullBRaw)
	}
	if len(pullB.Changes.Products) != 0 || len(pullB.Changes.Customers) != 0 || len(pullB.Changes.SaleOrders) != 0 ||
		len(pullB.Changes.Stores) != 1 || pullB.Changes.Stores[0].ID != storeB {
		t.Fatalf("Attack 7 (Store B pull leaked Store A data): %s", pullBRaw)
	}

	// 8. Forged JWT with Store B user/device but sid=storeA -> rejected (401/403)
	forgedClaims := auth.Claims{
		StoreID:      storeA,
		Role:         auth.RoleOwner,
		DeviceID:     devB.ID,
		DeviceCode:   devB.Code,
		LeaseID:      sessB.Lease.LeaseID,
		TokenVersion: 1,
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    "pasalx-server",
			Subject:   ownerB.ID,
			Audience:  jwt.ClaimStrings{"pasalx-device"},
			IssuedAt:  jwt.NewNumericDate(time.Now().UTC()),
			ExpiresAt: jwt.NewNumericDate(time.Now().UTC().Add(time.Hour)),
		},
	}
	// Even if signed with wrong or leaked key, Authenticate checks device belongs to sid
	forgedTok, _ := jwt.NewWithClaims(jwt.SigningMethodHS256, forgedClaims).SignedString(bytes.Repeat([]byte{99}, 32))
	stCode, _, _ = pull(forgedTok, "")
	if stCode != http.StatusUnauthorized {
		t.Fatalf("Attack 8 (forged JWT sid) expected 401, got %d", stCode)
	}

	// Verify Store A data is byte-identical before & after all attacks
	stCode, afterPull, _ := pull(sessA.AccessToken, "")
	afterChangesJSON := mustRaw(afterPull.Changes)
	if stCode != http.StatusOK || !bytes.Equal(beforeChangesJSON, afterChangesJSON) {
		t.Fatalf("Store A pull changed after attacks!\nbefore=%s\nafter=%s", beforeChangesJSON, afterChangesJSON)
	}

	// 9. Duplicate bill_no "01-0001" and sticker_barcode "SHARED-BARCODE-001" succeed independently in Store B!
	prodBID := uuid.NewString()
	varBID := uuid.NewString()
	batchBID := uuid.NewString()
	code, raw = push(sessB.AccessToken, psync.PushRequest{
		Mutations: []psync.Mutation{
			{ID: uuid.NewString(), TableName: psync.TableProducts, RecordID: prodBID, Operation: psync.OpInsert,
				Payload: mustRaw(map[string]any{"id": prodBID, "name": "Beta Cream", "brand": "Beta", "category": "Skin"})},
			{ID: uuid.NewString(), TableName: psync.TableProductVariants, RecordID: varBID, Operation: psync.OpInsert,
				Payload: mustRaw(map[string]any{"id": varBID, "product_id": prodBID, "variant_name": "50ml"})},
			{ID: uuid.NewString(), TableName: psync.TableBatches, RecordID: batchBID, Operation: psync.OpInsert,
				Payload: mustRaw(map[string]any{"id": batchBID, "variant_id": varBID, "batch_code": "BB1", "sticker_barcode": "SHARED-BARCODE-001", "cost_price": "50.00", "selling_price": "100.00", "expiry_date": "2028-01-01"})},
			{ID: uuid.NewString(), TableName: psync.TableSaleOrders, RecordID: uuid.NewString(), Operation: psync.OpInsert,
				Payload: mustRaw(map[string]any{"bill_no": "01-0001", "cashier_user_id": ownerB.ID, "cashier_name": "Owner B", "subtotal": "100.00", "discount_amount": "0.00", "total_amount": "100.00", "payment_mode": "CASH"})},
		},
	})
	if code != http.StatusOK {
		t.Fatalf("Duplicate bill_no & sticker_barcode in Store B failed: %d %s", code, raw)
	}
}

func mustRaw(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}
