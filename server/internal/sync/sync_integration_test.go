package sync_test

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"pasalx/server/internal/auth"
	"pasalx/server/internal/db"
	psync "pasalx/server/internal/sync"
)

var testPool *pgxpool.Pool

func TestMain(m *testing.M) {
	if os.Getenv("PASALX_SKIP_DB_TESTS") == "1" {
		os.Exit(m.Run())
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	admin, err := db.ConnectPool(ctx)
	if err != nil {
		fmt.Fprintf(os.Stderr, "integration DB unavailable (set PASALX_SKIP_DB_TESTS=1 to skip): %v\n", err)
		os.Exit(1)
	}
	name := fmt.Sprintf("pasalx_synctest_%d", time.Now().UnixNano())
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+name); err != nil {
		fmt.Fprintf(os.Stderr, "create test db: %v\n", err)
		os.Exit(1)
	}
	cfg := admin.Config().ConnConfig
	url := fmt.Sprintf("postgres://%s:%s@%s:%d/%s?sslmode=disable", cfg.User, cfg.Password, cfg.Host, cfg.Port, name)
	testPool, err = pgxpool.New(ctx, url)
	if err == nil {
		err = applyMigrations(ctx, testPool)
	}
	cancel()

	code := 1
	if err != nil {
		fmt.Fprintf(os.Stderr, "test db setup: %v\n", err)
	} else {
		code = m.Run()
	}

	if testPool != nil {
		testPool.Close()
	}
	dropCtx, dropCancel := context.WithTimeout(context.Background(), 10*time.Second)
	if _, err := admin.Exec(dropCtx, "DROP DATABASE IF EXISTS "+name+" WITH (FORCE)"); err != nil {
		fmt.Fprintf(os.Stderr, "drop test db: %v\n", err)
	}
	dropCancel()
	admin.Close()
	os.Exit(code)
}

func applyMigrations(ctx context.Context, pool *pgxpool.Pool) error {
	files, err := filepath.Glob(filepath.Join("..", "..", "migrations", "*.up.sql"))
	if err != nil || len(files) < 4 {
		return fmt.Errorf("expected >=4 up migrations, found %d (%v)", len(files), err)
	}
	sort.Strings(files)
	for _, f := range files {
		sqlBytes, err := os.ReadFile(f)
		if err != nil {
			return err
		}
		if _, err := pool.Exec(ctx, string(sqlBytes)); err != nil {
			return fmt.Errorf("%s: %w", filepath.Base(f), err)
		}
	}
	return nil
}

type testEnv struct {
	t           *testing.T
	srv         *httptest.Server
	hub         *psync.Hub
	authSvc     *auth.Service
	syncSvc     *psync.Service
	ownerUser   auth.UserInfo
	managerUser auth.UserInfo
	staffUser   auth.UserInfo
	ownerSess   auth.LoginResult
	staffSess   auth.LoginResult
	managerSess auth.LoginResult
}

func newTestEnv(t *testing.T) *testEnv {
	t.Helper()
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
		t.Fatalf("truncate tables: %v", err)
	}

	keys, err := auth.NewKeys(bytes.Repeat([]byte{42}, 32))
	if err != nil {
		t.Fatalf("NewKeys: %v", err)
	}
	authSvc := auth.NewService(testPool, keys)
	hub := psync.NewHub()
	authSvc.SetOnDeviceRevoked(func(storeID, deviceID, _ string) {
		hub.RevokeDevice(storeID, deviceID)
	})
	syncSvc := psync.NewService(testPool, hub)

	mux := http.NewServeMux()
	authHandler := auth.NewHandler(authSvc, false)
	authHandler.Routes(mux)
	psync.NewHandler(syncSvc).Routes(mux, authHandler.RequireAuth)

	srv := httptest.NewServer(mux)
	t.Cleanup(func() {
		hub.Shutdown()
		srv.Close()
	})

	ownerU, err := authSvc.CreateUser(ctx, "OwnerDidi", "owner@test.local", "owner", "OwnerPass!2026", "111111")
	if err != nil {
		t.Fatalf("create owner: %v", err)
	}
	storeID, err := authSvc.CreateStoreWithOwner(ctx, ownerU.ID, "Test Store")
	if err != nil {
		t.Fatalf("create store: %v", err)
	}
	mgrU, err := authSvc.CreateUser(ctx, "ManagerDai", "manager@test.local", "manager", "ManagerPass!2026", "222222")
	if err != nil {
		t.Fatalf("create manager: %v", err)
	}
	if err := authSvc.AddStoreMember(ctx, storeID, mgrU.ID, auth.RoleManager); err != nil {
		t.Fatalf("add manager member: %v", err)
	}
	staffU, err := authSvc.CreateUser(ctx, "StaffMaya", "maya@test.local", "maya", "StaffPass!2026", "333333")
	if err != nil {
		t.Fatalf("create staff: %v", err)
	}
	if err := authSvc.AddStoreMember(ctx, storeID, staffU.ID, auth.RoleStaff); err != nil {
		t.Fatalf("add staff member: %v", err)
	}

	dev01, err := authSvc.RegisterDevice(ctx, auth.RegisterDeviceInput{
		OwnerUsername: "owner", OwnerPassword: "OwnerPass!2026", DeviceName: "OwnerPhone", Platform: "ANDROID",
	}, "127.0.0.1")
	if err != nil {
		t.Fatalf("register dev01: %v", err)
	}
	dev02, err := authSvc.RegisterDevice(ctx, auth.RegisterDeviceInput{
		OwnerUsername: "owner", OwnerPassword: "OwnerPass!2026", DeviceName: "CounterPhone", Platform: "ANDROID",
	}, "127.0.0.1")
	if err != nil {
		t.Fatalf("register dev02: %v", err)
	}
	dev03, err := authSvc.RegisterDevice(ctx, auth.RegisterDeviceInput{
		OwnerUsername: "owner", OwnerPassword: "OwnerPass!2026", DeviceName: "MgrPhone", Platform: "ANDROID",
	}, "127.0.0.1")
	if err != nil {
		t.Fatalf("register dev03: %v", err)
	}

	ownLogin, err := authSvc.Login(ctx, auth.LoginInput{Username: "owner", Password: "OwnerPass!2026", DeviceID: dev01.ID}, "127.0.0.1")
	if err != nil {
		t.Fatalf("owner login: %v", err)
	}
	staffLogin, err := authSvc.Login(ctx, auth.LoginInput{Username: "maya", PIN: "333333", DeviceID: dev02.ID}, "127.0.0.1")
	if err != nil {
		t.Fatalf("staff login: %v", err)
	}
	mgrLogin, err := authSvc.Login(ctx, auth.LoginInput{Username: "manager", PIN: "222222", DeviceID: dev03.ID}, "127.0.0.1")
	if err != nil {
		t.Fatalf("manager login: %v", err)
	}

	return &testEnv{
		t:           t,
		srv:         srv,
		hub:         hub,
		authSvc:     authSvc,
		syncSvc:     syncSvc,
		ownerUser:   ownerU,
		managerUser: mgrU,
		staffUser:   staffU,
		ownerSess:   *ownLogin,
		staffSess:   *staffLogin,
		managerSess: *mgrLogin,
	}
}

func (e *testEnv) pushHTTP(token string, req psync.PushRequest) (int, []byte) {
	e.t.Helper()
	body, err := json.Marshal(req)
	if err != nil {
		e.t.Fatalf("marshal push: %v", err)
	}
	httpReq, err := http.NewRequest(http.MethodPost, e.srv.URL+"/api/sync/push", bytes.NewReader(body))
	if err != nil {
		e.t.Fatalf("new req: %v", err)
	}
	httpReq.Header.Set("Authorization", "Bearer "+token)
	httpReq.Header.Set("Content-Type", "application/json")
	resp, err := e.srv.Client().Do(httpReq)
	if err != nil {
		e.t.Fatalf("POST /api/sync/push failed: %v", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, raw
}

func (e *testEnv) mustPush(token string, mutations ...psync.Mutation) psync.PushResult {
	e.t.Helper()
	code, raw := e.pushHTTP(token, psync.PushRequest{Mutations: mutations})
	if code != http.StatusOK {
		e.t.Fatalf("POST /api/sync/push returned HTTP %d: %s", code, raw)
	}
	var res psync.PushResult
	if err := json.Unmarshal(raw, &res); err != nil {
		e.t.Fatalf("decode PushResult: %v (%s)", err, raw)
	}
	return res
}

func (e *testEnv) pullRaw(token, since string) (int, []byte, psync.PullResponse) {
	e.t.Helper()
	u := e.srv.URL + "/api/sync/pull"
	if since != "" {
		u += "?since=" + since
	}
	req, err := http.NewRequest(http.MethodGet, u, nil)
	if err != nil {
		e.t.Fatalf("new pull req: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := e.srv.Client().Do(req)
	if err != nil {
		e.t.Fatalf("GET /api/sync/pull failed: %v", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var parsed psync.PullResponse
	if resp.StatusCode == http.StatusOK {
		if err := json.Unmarshal(raw, &parsed); err != nil {
			e.t.Fatalf("decode PullResponse: %v (%s)", err, raw)
		}
	}
	return resp.StatusCode, raw, parsed
}

func makeMut(table, recordID, op string, clientTS *time.Time, payload any) psync.Mutation {
	raw, err := json.Marshal(payload)
	if err != nil {
		panic(err)
	}
	return psync.Mutation{
		ID:              uuid.NewString(),
		TableName:       table,
		RecordID:        recordID,
		Operation:       op,
		ClientUpdatedAt: clientTS,
		Payload:         raw,
	}
}

func intPtr(v int) *int       { return &v }
func strPtr(v string) *string { return &v }

func TestEndToEndCatalogIntakeLWWAndServerProfitMasking(t *testing.T) {
	env := newTestEnv(t)

	supID := uuid.NewString()
	prodID := uuid.NewString()
	varID := uuid.NewString()
	invID := uuid.NewString()
	invItemID := uuid.NewString()
	batchID := uuid.NewString()
	intakeMovID := uuid.NewString()

	tBase := time.Now().UTC().Add(-2 * time.Hour)
	env.mustPush(env.ownerSess.AccessToken,
		makeMut(psync.TableSuppliers, supID, psync.OpInsert, &tBase, psync.SupplierRecord{
			ID: supID, Name: "Kathmandu Beauty Supply", Phone: strPtr("9801112233"),
		}),
		makeMut(psync.TableProducts, prodID, psync.OpInsert, &tBase, psync.ProductRecord{
			ID: prodID, Name: "Matte Lipstick", Brand: "MAC", Category: "Lips",
		}),
		makeMut(psync.TableProductVariants, varID, psync.OpInsert, &tBase, psync.ProductVariantRecord{
			ID: varID, ProductID: prodID, VariantName: "Ruby Woo",
		}),
		makeMut(psync.TablePurchaseInvoices, invID, psync.OpInsert, &tBase, psync.PurchaseInvoiceRecord{
			ID: invID, SupplierID: supID, InvoiceNo: "INV-001", InvoiceDate: "2026-11-15",
			TotalAmount: 1920000, PaidAmount: 1000000, DueAmount: 920000, Status: "PARTIAL",
		}),
		makeMut(psync.TableBatches, batchID, psync.OpInsert, &tBase, psync.BatchRecord{
			ID: batchID, VariantID: varID, SupplierID: &supID, PurchaseInvoiceID: &invID,
			BatchCode: "LOT-R1", StickerBarcode: "100001",
			CostPrice: psync.MoneyPtr(80000), SellingPrice: 135000,
			StockQuantity: 999, // server must ignore and initialize to 0!
			ExpiryDate:    "2028-06-30",
		}),
		makeMut(psync.TablePurchaseInvoiceItems, invItemID, psync.OpInsert, &tBase, psync.PurchaseInvoiceItemRecord{
			ID: invItemID, PurchaseInvoiceID: invID, VariantID: varID, BatchID: &batchID,
			ProductName: "Matte Lipstick", VariantName: "Ruby Woo",
			QuantityReceived: 24, UnitCostPrice: psync.MoneyPtr(80000),
			UnitSellingPrice: 135000, TotalCost: psync.MoneyPtr(1920000),
			BatchCode: strPtr("LOT-R1"), ExpiryDate: "2028-06-30",
		}),
		makeMut(psync.TableStockMovements, intakeMovID, psync.OpInsert, &tBase, psync.StockMovementRecord{
			ID: intakeMovID, BatchID: batchID, MovementType: "PURCHASE_INTAKE",
			QuantityChange: intPtr(24), ReferenceID: &invID, StaffName: "OwnerDidi",
		}),
	)

	// Verify stock started at 0 and became 24 ONLY via PURCHASE_INTAKE.
	_, _, ownPull1 := env.pullRaw(env.ownerSess.AccessToken, "")
	if len(ownPull1.Changes.Batches) != 1 || ownPull1.Changes.Batches[0].StockQuantity != 24 {
		t.Fatalf("expected stock_quantity=24, got %+v", ownPull1.Changes.Batches)
	}

	// LWW test: newer MANAGER update succeeds (and preserves OWNER's cost_price=800.00);
	// stale older update afterwards is dropped cleanly; extreme future timestamp is clamped so future updates still work.
	tFuture := time.Now().UTC().Add(48 * time.Hour)
	env.mustPush(env.managerSess.AccessToken, makeMut(psync.TableBatches, batchID, psync.OpUpdate, &tFuture, psync.BatchRecord{
		ID: batchID, VariantID: varID, BatchCode: "LOT-R1", StickerBarcode: "100001",
		CostPrice: psync.MoneyPtr(100), // MANAGER cost_price ignored
		SellingPrice: 140000, ExpiryDate: "2028-06-30",
	}))

	tStale := tBase.Add(-30 * time.Minute)
	env.mustPush(env.ownerSess.AccessToken, makeMut(psync.TableBatches, batchID, psync.OpUpdate, &tStale, psync.BatchRecord{
		ID: batchID, VariantID: varID, BatchCode: "LOT-R1", StickerBarcode: "100001",
		CostPrice: psync.MoneyPtr(80000), SellingPrice: 111100, ExpiryDate: "2028-06-30",
	}))

	// Valid update right after clamped future edit should STILL succeed (not frozen for 48h).
	tNow := time.Now().UTC().Add(2 * time.Second)
	env.mustPush(env.ownerSess.AccessToken, makeMut(psync.TableBatches, batchID, psync.OpUpdate, &tNow, psync.BatchRecord{
		ID: batchID, VariantID: varID, BatchCode: "LOT-R1", StickerBarcode: "100001",
		CostPrice: psync.MoneyPtr(80000), SellingPrice: 145000, ExpiryDate: "2028-06-30",
	}))

	// STAFF cannot push restricted products table over HTTP (403 FORBIDDEN).
	forbCode, _ := env.pushHTTP(env.staffSess.AccessToken, psync.PushRequest{
		Mutations: []psync.Mutation{makeMut(psync.TableProducts, uuid.NewString(), psync.OpInsert, nil, psync.ProductRecord{
			ID: uuid.NewString(), Name: "Illegal", Brand: "X", Category: "Y",
		})},
	})
	if forbCode != http.StatusForbidden {
		t.Fatalf("expected HTTP 403 for STAFF product push, got %d", forbCode)
	}

	// STAFF pushes a SaleOrder for qty=2 at 1450.00 (Total 2900.00) without cost_price / profit.
	saleID := uuid.NewString()
	saleItemID := uuid.NewString()
	salePayID := uuid.NewString()
	saleMovID := uuid.NewString()
	env.mustPush(env.staffSess.AccessToken, makeMut(psync.TableSaleOrders, saleID, psync.OpInsert, nil, psync.SaleOrderRecord{
		ID: saleID, BillNo: "02-1001", CashierUserID: env.staffUser.ID, CashierName: env.staffUser.Name,
		Subtotal: 290000, DiscountAmount: 0, TotalAmount: 290000, PaymentMode: "CASH",
		Items: []psync.SaleItemRecord{{
			ID: saleItemID, SaleOrderID: saleID, BatchID: batchID,
			ProductName: "Matte Lipstick", VariantName: "Ruby Woo",
			Quantity: 2, SellingPrice: 145000, TotalPrice: 290000,
		}},
		Payments: []psync.SalePaymentRecord{{
			ID: salePayID, SaleOrderID: saleID, Method: "CASH", Amount: 290000,
		}},
		StockMovements: []psync.StockMovementRecord{{
			ID: saleMovID, BatchID: batchID, MovementType: "SALE",
			QuantityChange: intPtr(-2), ReferenceID: &saleID, StaffName: env.staffUser.Name,
		}},
	}))

	// Verify OWNER pull: sees cost_price=800.00, cost_total=1600.00, net_profit=1300.00, selling_price=1450.00, stock=22, suppliers & invoices.
	code, ownRaw, ownPull2 := env.pullRaw(env.ownerSess.AccessToken, "")
	if code != http.StatusOK {
		t.Fatalf("owner pull status %d: %s", code, ownRaw)
	}
	if len(ownPull2.Changes.Batches) != 1 {
		t.Fatalf("expected 1 batch, got %d", len(ownPull2.Changes.Batches))
	}
	b := ownPull2.Changes.Batches[0]
	if b.StockQuantity != 22 || b.SellingPrice != 145000 || b.CostPrice == nil || *b.CostPrice != 80000 {
		t.Fatalf("unexpected OWNER batch: %+v", b)
	}
	if len(ownPull2.Changes.SaleOrders) != 1 {
		t.Fatalf("expected 1 sale_order, got %d", len(ownPull2.Changes.SaleOrders))
	}
	so := ownPull2.Changes.SaleOrders[0]
	if so.CostTotal == nil || *so.CostTotal != 160000 || so.NetProfit == nil || *so.NetProfit != 130000 {
		t.Fatalf("expected authoritative cost_total=1600.00 & net_profit=1300.00, got cost=%v profit=%v", so.CostTotal, so.NetProfit)
	}
	if len(ownPull2.Changes.Suppliers) != 1 || len(ownPull2.Changes.PurchaseInvoices) != 1 || len(ownPull2.Changes.InventorySyncAudit) == 0 {
		t.Fatalf("OWNER missing supplier/invoice/audit tables")
	}

	// Verify STAFF strict JSON masking (§7.5): zero cost/profit/supplier/audit leak!
	code, staffRaw, staffPull := env.pullRaw(env.staffSess.AccessToken, "")
	if code != http.StatusOK {
		t.Fatalf("staff pull status %d", code)
	}
	for _, secretKey := range []string{`"cost_price"`, `"cost_total"`, `"net_profit"`, `"unit_cost_price"`, `"total_cost"`} {
		if strings.Contains(string(staffRaw), secretKey) {
			t.Fatalf("STAFF pull leaked sensitive JSON field %s in body: %s", secretKey, staffRaw)
		}
	}
	if len(staffPull.Changes.Suppliers) != 0 || len(staffPull.Changes.PurchaseInvoices) != 0 ||
		len(staffPull.Changes.PurchaseInvoiceItems) != 0 || len(staffPull.Changes.SupplierPayments) != 0 ||
		len(staffPull.Changes.InventorySyncAudit) != 0 {
		t.Fatalf("STAFF pull must return empty supplier/audit arrays")
	}

	// Verify MANAGER masking (§7.5): sees suppliers & audit, NEVER sees cost_price/profit fields.
	code, mgrRaw, mgrPull := env.pullRaw(env.managerSess.AccessToken, "")
	if code != http.StatusOK {
		t.Fatalf("manager pull status %d", code)
	}
	for _, secretKey := range []string{`"cost_price"`, `"cost_total"`, `"net_profit"`, `"unit_cost_price"`, `"total_cost"`} {
		if strings.Contains(string(mgrRaw), secretKey) {
			t.Fatalf("MANAGER pull leaked sensitive JSON field %s", secretKey)
		}
	}
	if len(mgrPull.Changes.Suppliers) != 1 || len(mgrPull.Changes.InventorySyncAudit) == 0 {
		t.Fatalf("MANAGER should see suppliers and discrepancy audits")
	}
}

func TestReviewGate2TwoPhoneConcurrentPushAndNegativeStockAudit(t *testing.T) {
	env := newTestEnv(t)

	prodID := uuid.NewString()
	varID := uuid.NewString()
	batchID := uuid.NewString()
	initMovID := uuid.NewString()
	shiftID := uuid.NewString()

	// Seed batch with exactly 1 unit in stock + 1 OPEN register shift (float 1000.00).
	env.mustPush(env.ownerSess.AccessToken,
		makeMut(psync.TableProducts, prodID, psync.OpInsert, nil, psync.ProductRecord{
			ID: prodID, Name: "Sunscreen", Brand: "Cetaphil", Category: "Skincare",
		}),
		makeMut(psync.TableProductVariants, varID, psync.OpInsert, nil, psync.ProductVariantRecord{
			ID: varID, ProductID: prodID, VariantName: "50ml",
		}),
		makeMut(psync.TableBatches, batchID, psync.OpInsert, nil, psync.BatchRecord{
			ID: batchID, VariantID: varID, BatchCode: "SPF-01", StickerBarcode: "200001",
			CostPrice: psync.MoneyPtr(50000), SellingPrice: 80000, ExpiryDate: "2028-01-01",
		}),
		makeMut(psync.TableStockMovements, initMovID, psync.OpInsert, nil, psync.StockMovementRecord{
			ID: initMovID, BatchID: batchID, MovementType: "PURCHASE_INTAKE",
			QuantityChange: intPtr(1), StaffName: env.ownerUser.Name,
		}),
		makeMut(psync.TableRegisterShifts, shiftID, psync.OpInsert, nil, psync.RegisterShiftRecord{
			ID: shiftID, OpenedByUserID: env.ownerUser.ID, OpeningFloat: 100000, Status: "OPEN",
		}),
	)

	// Two phones go offline and BOTH sell the last 1 unit concurrently.
	buildSaleMut := func(billNo string, cashier auth.UserInfo, token string) (string, psync.Mutation) {
		saleID := uuid.NewString()
		return token, makeMut(psync.TableSaleOrders, saleID, psync.OpInsert, nil, psync.SaleOrderRecord{
			ID: saleID, BillNo: billNo, CashierUserID: cashier.ID, CashierName: cashier.Name,
			ShiftID: &shiftID, Subtotal: 80000, DiscountAmount: 0, TotalAmount: 80000, PaymentMode: "CASH",
			Items: []psync.SaleItemRecord{{
				ID: uuid.NewString(), SaleOrderID: saleID, BatchID: batchID,
				ProductName: "Sunscreen", VariantName: "50ml",
				Quantity: 1, SellingPrice: 80000, TotalPrice: 80000,
			}},
			Payments: []psync.SalePaymentRecord{{
				ID: uuid.NewString(), SaleOrderID: saleID, Method: "CASH", Amount: 80000,
			}},
			StockMovements: []psync.StockMovementRecord{{
				ID: uuid.NewString(), BatchID: batchID, MovementType: "SALE",
				QuantityChange: intPtr(-1), ReferenceID: &saleID, StaffName: cashier.Name,
			}},
		})
	}

	tok1, mut1 := buildSaleMut("01-1001", env.ownerUser, env.ownerSess.AccessToken)
	tok2, mut2 := buildSaleMut("02-1001", env.staffUser, env.staffSess.AccessToken)

	start := make(chan struct{})
	var wg sync.WaitGroup
	results := make([]psync.PushResult, 2)

	wg.Add(2)
	go func() {
		defer wg.Done()
		<-start
		results[0] = env.mustPush(tok1, mut1)
	}()
	go func() {
		defer wg.Done()
		<-start
		results[1] = env.mustPush(tok2, mut2)
	}()
	close(start)
	wg.Wait()

	// Exactly one of the two concurrent pushes caused stock to drop 0 -> -1 and raised DiscrepancyAlert.
	discCount := len(results[0].Discrepancies) + len(results[1].Discrepancies)
	if discCount != 1 {
		t.Fatalf("expected exactly 1 negative-stock DiscrepancyAlert across 2 phones, got %d (r0=%+v r1=%+v)",
			discCount, results[0].Discrepancies, results[1].Discrepancies)
	}
	var alert psync.DiscrepancyAlert
	if len(results[0].Discrepancies) == 1 {
		alert = results[0].Discrepancies[0]
	} else {
		alert = results[1].Discrepancies[0]
	}
	if alert.PreSyncQty != 0 || alert.PostSyncQty != -1 || alert.QuantityChange != -1 {
		t.Fatalf("unexpected discrepancy alert: %+v", alert)
	}

	// Verify 8 more simultaneous pushes contending on the same batch & shift converge cleanly.
	start8 := make(chan struct{})
	var wg8 sync.WaitGroup
	for i := 0; i < 8; i++ {
		i := i
		tok, mut := buildSaleMut(fmt.Sprintf("02-%04d", 2000+i), env.staffUser, env.staffSess.AccessToken)
		wg8.Add(1)
		go func() {
			defer wg8.Done()
			<-start8
			env.mustPush(tok, mut)
		}()
	}
	close(start8)
	wg8.Wait()

	// Final stock: 1 - 2 - 8 = -9; shift cash_sales = 10 * 800.00 = 8000.00; expected_cash = 9000.00.
	_, _, ownPull := env.pullRaw(env.ownerSess.AccessToken, "")
	if len(ownPull.Changes.Batches) != 1 || ownPull.Changes.Batches[0].StockQuantity != -9 {
		t.Fatalf("expected final stock_quantity=-9, got %+v", ownPull.Changes.Batches)
	}
	if len(ownPull.Changes.RegisterShifts) != 1 {
		t.Fatalf("expected 1 shift, got %d", len(ownPull.Changes.RegisterShifts))
	}
	sh := ownPull.Changes.RegisterShifts[0]
	if sh.CashSales != 800000 || sh.ExpectedCash != 900000 {
		t.Fatalf("expected cash_sales=8000.00 expected_cash=9000.00, got cash_sales=%d expected_cash=%d", sh.CashSales, sh.ExpectedCash)
	}

	var discDBCount int
	if err := testPool.QueryRow(context.Background(), `SELECT COUNT(*) FROM inventory_sync_audit WHERE batch_id = $1 AND is_discrepancy = TRUE`, batchID).Scan(&discDBCount); err != nil {
		t.Fatalf("query audit discrepancy count: %v", err)
	}
	if discDBCount != 9 {
		t.Fatalf("expected 9 discrepancy rows in inventory_sync_audit, got %d", discDBCount)
	}
}

func TestDuplicateUUIDRetryIdempotency(t *testing.T) {
	env := newTestEnv(t)

	supID := uuid.NewString()
	custID := uuid.NewString()
	prodID := uuid.NewString()
	varID := uuid.NewString()
	batchID := uuid.NewString()
	intakeMovID := uuid.NewString()
	pInvID := uuid.NewString()
	shiftID := uuid.NewString()

	env.mustPush(env.ownerSess.AccessToken,
		makeMut(psync.TableSuppliers, supID, psync.OpInsert, nil, psync.SupplierRecord{ID: supID, Name: "SupA"}),
		makeMut(psync.TableCustomers, custID, psync.OpInsert, nil, psync.CustomerRecord{ID: custID, Name: "Sita", Phone: "9841000001"}),
		makeMut(psync.TableProducts, prodID, psync.OpInsert, nil, psync.ProductRecord{ID: prodID, Name: "Serum", Brand: "Ordinary", Category: "Skincare"}),
		makeMut(psync.TableProductVariants, varID, psync.OpInsert, nil, psync.ProductVariantRecord{ID: varID, ProductID: prodID, VariantName: "Niacinamide"}),
		makeMut(psync.TableBatches, batchID, psync.OpInsert, nil, psync.BatchRecord{
			ID: batchID, VariantID: varID, SupplierID: &supID, BatchCode: "S1", StickerBarcode: "300001",
			CostPrice: psync.MoneyPtr(70000), SellingPrice: 120000, ExpiryDate: "2028-05-01",
		}),
		makeMut(psync.TableStockMovements, intakeMovID, psync.OpInsert, nil, psync.StockMovementRecord{
			ID: intakeMovID, BatchID: batchID, MovementType: "PURCHASE_INTAKE", QuantityChange: intPtr(10), StaffName: "Owner",
		}),
		makeMut(psync.TablePurchaseInvoices, pInvID, psync.OpInsert, nil, psync.PurchaseInvoiceRecord{
			ID: pInvID, SupplierID: supID, InvoiceNo: "INV-S1", InvoiceDate: "2026-11-15",
			TotalAmount: 100000, PaidAmount: 0, DueAmount: 100000, Status: "UNPAID",
		}),
		makeMut(psync.TableRegisterShifts, shiftID, psync.OpInsert, nil, psync.RegisterShiftRecord{
			ID: shiftID, OpenedByUserID: env.ownerUser.ID, OpeningFloat: 50000, Status: "OPEN",
		}),
	)

	// Duplicate retry payload (sale -3, khata debit +500, supplier payment +300, cash expense -200).
	saleID := uuid.NewString()
	movID := uuid.NewString()
	custTxID := uuid.NewString()
	supPayID := uuid.NewString()
	expID := uuid.NewString()

	retryReq := psync.PushRequest{
		Mutations: []psync.Mutation{
			makeMut(psync.TableSaleOrders, saleID, psync.OpInsert, nil, psync.SaleOrderRecord{
				ID: saleID, BillNo: "01-5555", CashierUserID: env.ownerUser.ID, CashierName: env.ownerUser.Name,
				ShiftID: &shiftID, Subtotal: 360000, DiscountAmount: 0, TotalAmount: 360000, PaymentMode: "CASH",
				Items: []psync.SaleItemRecord{{
					ID: uuid.NewString(), SaleOrderID: saleID, BatchID: batchID, ProductName: "Serum", VariantName: "Niacinamide",
					Quantity: 3, CostPrice: psync.MoneyPtr(70000), SellingPrice: 120000, TotalPrice: 360000,
				}},
				Payments: []psync.SalePaymentRecord{{
					ID: uuid.NewString(), SaleOrderID: saleID, Method: "CASH", Amount: 360000,
				}},
				StockMovements: []psync.StockMovementRecord{{
					ID: movID, BatchID: batchID, MovementType: "SALE", QuantityChange: intPtr(-3), ReferenceID: &saleID, StaffName: "Owner",
				}},
			}),
			makeMut(psync.TableCustomerTransactions, custTxID, psync.OpInsert, nil, psync.CustomerTransactionRecord{
				ID: custTxID, CustomerID: custID, Type: "DEBIT_PURCHASE", Amount: 50000,
			}),
			makeMut(psync.TableSupplierPayments, supPayID, psync.OpInsert, nil, psync.SupplierPaymentRecord{
				ID: supPayID, SupplierID: supID, Amount: 30000, PaymentMethod: "CASH",
			}),
			makeMut(psync.TableExpenses, expID, psync.OpInsert, nil, psync.ExpenseRecord{
				ID: expID, Category: "SUPPLIES", Title: "Tea", Amount: 20000, PaymentMethod: "CASH",
				ShiftID: &shiftID, CreatedByUserID: env.ownerUser.ID,
			}),
		},
	}

	first := env.mustPush(env.ownerSess.AccessToken, retryReq.Mutations...)
	if first.AppliedCount != 4 || first.DuplicateCount != 0 {
		t.Fatalf("first push expected 4 applied, got %+v", first)
	}

	// Retry exact same batch 3 more times.
	for attempt := 0; attempt < 3; attempt++ {
		code, raw := env.pushHTTP(env.ownerSess.AccessToken, retryReq)
		if code != http.StatusOK {
			t.Fatalf("retry #%d HTTP %d: %s", attempt+1, code, raw)
		}
		var dupRes psync.PushResult
		if err := json.Unmarshal(raw, &dupRes); err != nil {
			t.Fatalf("decode retry #%d: %v", attempt+1, err)
		}
		if dupRes.AppliedCount != 0 || dupRes.DuplicateCount != 4 {
			t.Fatalf("retry #%d expected 0 applied / 4 duplicates, got %+v", attempt+1, dupRes)
		}
		for _, mr := range dupRes.Results {
			if mr.Status != "ALREADY_APPLIED" {
				t.Fatalf("retry #%d status=%s want ALREADY_APPLIED", attempt+1, mr.Status)
			}
		}
	}

	_, _, pull := env.pullRaw(env.ownerSess.AccessToken, "")
	if pull.Changes.Batches[0].StockQuantity != 7 {
		t.Fatalf("expected stock=7 after 3 retries, got %d", pull.Changes.Batches[0].StockQuantity)
	}
	if pull.Changes.Customers[0].CurrentBalanceDue != 50000 {
		t.Fatalf("expected customer balance=500.00, got %d", pull.Changes.Customers[0].CurrentBalanceDue)
	}
	if pull.Changes.Suppliers[0].BalanceDue != 70000 {
		t.Fatalf("expected supplier balance=700.00, got %d", pull.Changes.Suppliers[0].BalanceDue)
	}
	// expected_cash = 500.00 (float) + 3600.00 (cash sale) - 200.00 (cash expense) = 3900.00
	if pull.Changes.RegisterShifts[0].ExpectedCash != 390000 {
		t.Fatalf("expected register expected_cash=3900.00, got %d", pull.Changes.RegisterShifts[0].ExpectedCash)
	}
}

func TestDeltaCursorKhataAndZReportEODFlow(t *testing.T) {
	env := newTestEnv(t)

	custID := uuid.NewString()
	prodID := uuid.NewString()
	shiftID := uuid.NewString()
	staffShiftID := uuid.NewString()

	env.mustPush(env.ownerSess.AccessToken,
		makeMut(psync.TableProducts, prodID, psync.OpInsert, nil, psync.ProductRecord{
			ID: prodID, Name: "Foundation", Brand: "Loreal", Category: "Face",
		}),
		makeMut(psync.TableCustomers, custID, psync.OpInsert, nil, psync.CustomerRecord{
			ID: custID, Name: "Gita", Phone: "9841223344",
		}),
		makeMut(psync.TableRegisterShifts, shiftID, psync.OpInsert, nil, psync.RegisterShiftRecord{
			ID: shiftID, OpenedByUserID: env.managerUser.ID, OpeningFloat: 100000, Status: "OPEN",
		}),
	)

	// Record baseline Khata debt (+1200.00) and staff punch-in.
	debitTxID := uuid.NewString()
	env.mustPush(env.staffSess.AccessToken,
		makeMut(psync.TableCustomerTransactions, debitTxID, psync.OpInsert, nil, psync.CustomerTransactionRecord{
			ID: debitTxID, CustomerID: custID, Type: "DEBIT_PURCHASE", Amount: 120000,
		}),
		makeMut(psync.TableStaffShiftSessions, staffShiftID, psync.OpInsert, nil, psync.StaffShiftSessionRecord{
			ID: staffShiftID, RegisterShiftID: shiftID, UserID: env.staffUser.ID, DeviceCode: "02", Status: "ACTIVE",
		}),
	)

	_, _, p1 := env.pullRaw(env.ownerSess.AccessToken, "")
	sinceCursor := p1.ServerTime.UTC().Format(time.RFC3339Nano)

	// Subsequent mutations: Khata CASH repayment (+500.00), CASH expense (-150.00), force punchout, Z-Report close.
	// Expected cash: 1000.00 + 500.00 - 150.00 = 1350.00. Actual counted = 1300.00 -> Discrepancy = -50.00.
	repayID := uuid.NewString()
	expID := uuid.NewString()
	env.mustPush(env.managerSess.AccessToken,
		makeMut(psync.TableCustomerTransactions, repayID, psync.OpInsert, nil, psync.CustomerTransactionRecord{
			ID: repayID, CustomerID: custID, Type: "CREDIT_REPAYMENT", Amount: 50000,
			PaymentMethod: strPtr("CASH"), ShiftID: &shiftID,
		}),
		makeMut(psync.TableExpenses, expID, psync.OpInsert, nil, psync.ExpenseRecord{
			ID: expID, Category: "UTILITY", Title: "Water Jar", Amount: 15000,
			PaymentMethod: "CASH", ShiftID: &shiftID, CreatedByUserID: env.managerUser.ID,
		}),
		makeMut(psync.TableStaffShiftSessions, staffShiftID, psync.OpUpdate, nil, psync.StaffShiftSessionRecord{
			ID: staffShiftID, RegisterShiftID: shiftID, UserID: env.staffUser.ID, DeviceCode: "02", Status: "FORCE_CLOSED",
		}),
		makeMut(psync.TableRegisterShifts, shiftID, psync.OpUpdate, nil, psync.RegisterShiftRecord{
			ID: shiftID, Status: "CLOSED", ActualCashCounted: psync.MoneyPtr(130000),
			CashWithdrawnDeposit: 30000, RetainedNextDayFloat: 100000,
		}),
	)

	// Delta pull since cursor returns ONLY post-cursor changes (no unchanged products).
	_, _, delta := env.pullRaw(env.ownerSess.AccessToken, sinceCursor)
	if len(delta.Changes.Products) != 0 {
		t.Fatalf("delta pull should exclude unchanged products, got %d", len(delta.Changes.Products))
	}
	if len(delta.Changes.Customers) != 1 || delta.Changes.Customers[0].CurrentBalanceDue != 70000 {
		t.Fatalf("expected updated customer balance=700.00, got %+v", delta.Changes.Customers)
	}
	if len(delta.Changes.RegisterShifts) != 1 {
		t.Fatalf("expected closed shift in delta pull, got %d", len(delta.Changes.RegisterShifts))
	}
	closed := delta.Changes.RegisterShifts[0]
	if closed.Status != "CLOSED" || closed.ExpectedCash != 135000 || closed.Discrepancy == nil || *closed.Discrepancy != -5000 {
		t.Fatalf("unexpected closed Z-Report shift: %+v", closed)
	}
}

func readSSEEvent(r *bufio.Reader, timeout time.Duration) (string, string, error) {
	type res struct {
		ev   string
		data string
		err  error
	}
	ch := make(chan res, 1)
	go func() {
		var ev, data string
		for {
			line, err := r.ReadString('\n')
			if err != nil {
				ch <- res{err: err}
				return
			}
			line = strings.TrimRight(line, "\r\n")
			if line == "" {
				if ev != "" || data != "" {
					ch <- res{ev: ev, data: data}
					return
				}
				continue
			}
			if strings.HasPrefix(line, ":") {
				continue
			}
			if strings.HasPrefix(line, "event:") {
				ev = strings.TrimSpace(strings.TrimPrefix(line, "event:"))
			} else if strings.HasPrefix(line, "data:") {
				data = strings.TrimSpace(strings.TrimPrefix(line, "data:"))
			}
		}
	}()
	select {
	case out := <-ch:
		return out.ev, out.data, out.err
	case <-time.After(timeout):
		return "", "", fmt.Errorf("timed out after %v waiting for SSE event", timeout)
	}
}

func openSSE(t *testing.T, url, token string) (*http.Response, *bufio.Reader, context.CancelFunc) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		cancel()
		t.Fatalf("new SSE req: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		cancel()
		t.Fatalf("connect SSE: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		raw, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		cancel()
		t.Fatalf("SSE returned HTTP %d: %s", resp.StatusCode, raw)
	}
	return resp, bufio.NewReader(resp.Body), cancel
}

func TestSSEEventsLatencyMemoryFootprintAndKillSwitch(t *testing.T) {
	env := newTestEnv(t)

	// 1) Connect Phone 01 (owner) and Phone 02 (staff) to /api/sync/events.
	resp1, r1, cancel1 := openSSE(t, env.srv.URL+"/api/sync/events", env.ownerSess.AccessToken)
	defer func() { cancel1(); resp1.Body.Close() }()
	ev, _, err := readSSEEvent(r1, time.Second)
	if err != nil || ev != "CONNECTED" {
		t.Fatalf("phone 01 initial SSE = (%q, %v), want CONNECTED", ev, err)
	}

	resp2, r2, cancel2 := openSSE(t, env.srv.URL+"/api/sync/events", env.staffSess.AccessToken)
	defer func() { cancel2(); resp2.Body.Close() }()
	ev, _, err = readSSEEvent(r2, time.Second)
	if err != nil || ev != "CONNECTED" {
		t.Fatalf("phone 02 initial SSE = (%q, %v), want CONNECTED", ev, err)
	}

	// Phone 01 pushes a new customer -> Phone 02 must receive DATA_CHANGED within < 1s.
	custID := uuid.NewString()
	pushStart := time.Now()
	env.mustPush(env.ownerSess.AccessToken, makeMut(psync.TableCustomers, custID, psync.OpInsert, nil, psync.CustomerRecord{
		ID: custID, Name: "Nisha", Phone: "9841999888",
	}))
	ev, data, err := readSSEEvent(r2, 800*time.Millisecond)
	if err != nil || ev != "DATA_CHANGED" {
		t.Fatalf("phone 02 did not receive DATA_CHANGED within 800ms: ev=%q err=%v", ev, err)
	}
	if time.Since(pushStart) >= time.Second {
		t.Fatalf("SSE delivery took >= 1s: %v", time.Since(pushStart))
	}
	if !strings.Contains(data, `"origin_device_code":"01"`) {
		t.Fatalf("unexpected DATA_CHANGED payload: %s", data)
	}

	// Confirm Phone 02 immediately pulls the new customer.
	_, _, pull := env.pullRaw(env.staffSess.AccessToken, "")
	if len(pull.Changes.Customers) != 1 || pull.Changes.Customers[0].ID != custID {
		t.Fatalf("phone 02 pull missing synced customer: %+v", pull.Changes.Customers)
	}

	// Confirm Phone 01 did NOT receive its own push broadcast (timeout expected quickly).
	if evSelf, _, errSelf := readSSEEvent(r1, 80*time.Millisecond); errSelf == nil {
		t.Fatalf("origin device 01 unexpectedly received %q", evSelf)
	}

	// 2) Live kill-switch over SSE & all sync endpoints: OWNER revokes Phone 02.
	revBody, _ := json.Marshal(auth.RevokeInput{DeviceID: env.staffSess.Device.ID, Reason: "stolen"})
	revReq, _ := http.NewRequest(http.MethodPost, env.srv.URL+"/api/auth/revoke", bytes.NewReader(revBody))
	revReq.Header.Set("Authorization", "Bearer "+env.ownerSess.AccessToken)
	revReq.Header.Set("Content-Type", "application/json")
	revResp, err := env.srv.Client().Do(revReq)
	if err != nil || revResp.StatusCode != http.StatusOK {
		t.Fatalf("revoke failed: status=%v err=%v", revResp, err)
	}
	revResp.Body.Close()

	evRev, revData, errRev := readSSEEvent(r2, time.Second)
	if errRev != nil || evRev != "DEVICE_REVOKED" || !strings.Contains(revData, auth.CodeDeviceRevoked) {
		t.Fatalf("revoked phone SSE expected DEVICE_REVOKED, got (%q, %q, %v)", evRev, revData, errRev)
	}
	// Next HTTP push/pull/events calls from revoked Phone 02 must return 401 DEVICE_REVOKED.
	pushCode, pushRaw := env.pushHTTP(env.staffSess.AccessToken, psync.PushRequest{
		Mutations: []psync.Mutation{makeMut(psync.TableCustomers, uuid.NewString(), psync.OpInsert, nil, psync.CustomerRecord{
			ID: uuid.NewString(), Name: "Late", Phone: "9800",
		})},
	})
	if pushCode != http.StatusUnauthorized || !strings.Contains(string(pushRaw), auth.CodeDeviceRevoked) {
		t.Fatalf("expected 401 DEVICE_REVOKED on push, got %d: %s", pushCode, pushRaw)
	}
	pullCode, pullBody, _ := env.pullRaw(env.staffSess.AccessToken, "")
	if pullCode != http.StatusUnauthorized || !strings.Contains(string(pullBody), auth.CodeDeviceRevoked) {
		t.Fatalf("expected 401 DEVICE_REVOKED on pull, got %d: %s", pullCode, pullBody)
	}

	// 3) Memory budget check: 50 concurrent hub subscriptions must stay < 1 MiB heap delta.
	cancel1()
	resp1.Body.Close()
	cancel2()
	resp2.Body.Close()
	time.Sleep(30 * time.Millisecond)

	hub := psync.NewHub()
	defer hub.Shutdown()
	runtime.GC()
	runtime.GC()
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)

	subs := make([]*psync.Subscriber, 50)
	for i := 0; i < 50; i++ {
		s, ok := hub.Subscribe(fmt.Sprintf("store-%d", i/10), fmt.Sprintf("dev-%02d", i), fmt.Sprintf("%02d", i+10))
		if !ok {
			t.Fatalf("Subscribe %d failed", i)
		}
		subs[i] = s
	}
	hub.BroadcastDataChanged(psync.BroadcastEvent{
		StoreID:          "store-0",
		OriginDeviceID:   "dev-00",
		OriginDeviceCode: "01",
		ServerTime:       time.Now().UTC(),
	})

	runtime.GC()
	runtime.ReadMemStats(&after)
	var delta uint64
	if after.HeapAlloc > before.HeapAlloc {
		delta = after.HeapAlloc - before.HeapAlloc
	}
	t.Logf("50 SSE hub subscribers heap delta: %d bytes (limit: 1048576)", delta)
	if delta >= 1<<20 {
		t.Fatalf("50 SSE subscribers consumed >= 1 MiB (%d bytes)", delta)
	}
	for _, s := range subs {
		hub.Unsubscribe(s)
	}
	if hub.ActiveCount() != 0 {
		t.Fatalf("expected 0 active subscribers after Unsubscribe, got %d", hub.ActiveCount())
	}
}

func TestPostReviewSecurityAndIntegrityHardening(t *testing.T) {
	env := newTestEnv(t)

	supA := uuid.NewString()
	supB := uuid.NewString()
	invA := uuid.NewString()
	prodID := uuid.NewString()
	varID := uuid.NewString()
	batchID := uuid.NewString()
	custID := uuid.NewString()
	shiftID := uuid.NewString()
	initMovID := uuid.NewString()

	env.mustPush(env.ownerSess.AccessToken,
		makeMut(psync.TableSuppliers, supA, psync.OpInsert, nil, psync.SupplierRecord{ID: supA, Name: "Supplier A"}),
		makeMut(psync.TableSuppliers, supB, psync.OpInsert, nil, psync.SupplierRecord{ID: supB, Name: "Supplier B"}),
		makeMut(psync.TablePurchaseInvoices, invA, psync.OpInsert, nil, psync.PurchaseInvoiceRecord{
			ID: invA, SupplierID: supA, InvoiceNo: "INV-A1", InvoiceDate: "2026-11-15",
			TotalAmount: 100000, PaidAmount: 20000, DueAmount: 80000, Status: "PARTIAL",
		}),
		makeMut(psync.TableProducts, prodID, psync.OpInsert, nil, psync.ProductRecord{ID: prodID, Name: "Toner", Brand: "Klairs", Category: "Skincare"}),
		makeMut(psync.TableProductVariants, varID, psync.OpInsert, nil, psync.ProductVariantRecord{ID: varID, ProductID: prodID, VariantName: "180ml"}),
		makeMut(psync.TableBatches, batchID, psync.OpInsert, nil, psync.BatchRecord{
			ID: batchID, VariantID: varID, SupplierID: &supA, BatchCode: "T-01", StickerBarcode: "400001",
			CostPrice: psync.MoneyPtr(60000), SellingPrice: 100000, ExpiryDate: "2028-09-01",
		}),
		makeMut(psync.TableStockMovements, initMovID, psync.OpInsert, nil, psync.StockMovementRecord{
			ID: initMovID, BatchID: batchID, MovementType: "PURCHASE_INTAKE", QuantityChange: intPtr(10), StaffName: "Owner",
		}),
		makeMut(psync.TableCustomers, custID, psync.OpInsert, nil, psync.CustomerRecord{ID: custID, Name: "Rama", Phone: "9841777666"}),
		makeMut(psync.TableRegisterShifts, shiftID, psync.OpInsert, nil, psync.RegisterShiftRecord{
			ID: shiftID, OpenedByUserID: env.ownerUser.ID, OpeningFloat: 50000, Status: "OPEN",
		}),
	)

	// 1) Duplicate parent sale_orders with a new mutation.id and new child UUIDs must NOT double-deduct stock or double-credit shift.
	saleID := uuid.NewString()
	env.mustPush(env.staffSess.AccessToken, makeMut(psync.TableSaleOrders, saleID, psync.OpInsert, nil, psync.SaleOrderRecord{
		ID: saleID, BillNo: "02-7001", CashierUserID: env.staffUser.ID, CashierName: env.staffUser.Name,
		ShiftID: &shiftID, Subtotal: 100000, DiscountAmount: 0, TotalAmount: 100000, PaymentMode: "CASH",
		Items: []psync.SaleItemRecord{{
			ID: uuid.NewString(), SaleOrderID: saleID, BatchID: batchID, ProductName: "Toner", VariantName: "180ml",
			Quantity: 1, SellingPrice: 100000, TotalPrice: 100000,
		}},
		Payments: []psync.SalePaymentRecord{{
			ID: uuid.NewString(), SaleOrderID: saleID, Method: "CASH", Amount: 100000,
		}},
		StockMovements: []psync.StockMovementRecord{{
			ID: uuid.NewString(), BatchID: batchID, MovementType: "SALE", QuantityChange: intPtr(-1), ReferenceID: &saleID, StaffName: env.staffUser.Name,
		}},
	}))
	// Second push with same saleID but brand-new mutation ID & brand-new embedded child IDs:
	env.mustPush(env.staffSess.AccessToken, makeMut(psync.TableSaleOrders, saleID, psync.OpInsert, nil, psync.SaleOrderRecord{
		ID: saleID, BillNo: "02-7001", CashierUserID: env.staffUser.ID, CashierName: env.staffUser.Name,
		ShiftID: &shiftID, Subtotal: 100000, DiscountAmount: 0, TotalAmount: 100000, PaymentMode: "CASH",
		Items: []psync.SaleItemRecord{{
			ID: uuid.NewString(), SaleOrderID: saleID, BatchID: batchID, ProductName: "Toner", VariantName: "180ml",
			Quantity: 1, SellingPrice: 100000, TotalPrice: 100000,
		}},
		Payments: []psync.SalePaymentRecord{{
			ID: uuid.NewString(), SaleOrderID: saleID, Method: "CASH", Amount: 100000,
		}},
		StockMovements: []psync.StockMovementRecord{{
			ID: uuid.NewString(), BatchID: batchID, MovementType: "SALE", QuantityChange: intPtr(-1), ReferenceID: &saleID, StaffName: env.staffUser.Name,
		}},
	}))

	// 2) Standalone OWNER sale_orders + standalone sale_items recomputes cost_total & net_profit accurately.
	ownSaleID := uuid.NewString()
	ownItemID := uuid.NewString()
	env.mustPush(env.ownerSess.AccessToken,
		makeMut(psync.TableSaleOrders, ownSaleID, psync.OpInsert, nil, psync.SaleOrderRecord{
			ID: ownSaleID, BillNo: "01-7002", CashierUserID: env.ownerUser.ID, CashierName: env.ownerUser.Name,
			Subtotal: 200000, DiscountAmount: 10000, TotalAmount: 190000, PaymentMode: "CASH",
		}),
		makeMut(psync.TableSaleItems, ownItemID, psync.OpInsert, nil, psync.SaleItemRecord{
			ID: ownItemID, SaleOrderID: ownSaleID, BatchID: batchID, ProductName: "Toner", VariantName: "180ml",
			Quantity: 2, CostPrice: psync.MoneyPtr(60000), SellingPrice: 100000, TotalPrice: 200000,
		}),
	)

	// 3) Khata CASH repayment referencing a non-existent shift_id must fail with 422 (no silent drawer loss).
	badShiftID := uuid.NewString()
	repayID := uuid.NewString()
	code, _ := env.pushHTTP(env.staffSess.AccessToken, psync.PushRequest{
		Mutations: []psync.Mutation{makeMut(psync.TableCustomerTransactions, repayID, psync.OpInsert, nil, psync.CustomerTransactionRecord{
			ID: repayID, CustomerID: custID, Type: "CREDIT_REPAYMENT", Amount: 10000,
			PaymentMethod: strPtr("CASH"), ShiftID: &badShiftID,
		})},
	})
	if code != http.StatusUnprocessableEntity {
		t.Fatalf("expected 422 for non-existent shift_id on cash repayment, got %d", code)
	}

	// 4) Cross-supplier invoice payment mismatch (422) & invoice overpayment (400) rejected.
	crossPayID := uuid.NewString()
	code, _ = env.pushHTTP(env.ownerSess.AccessToken, psync.PushRequest{
		Mutations: []psync.Mutation{makeMut(psync.TableSupplierPayments, crossPayID, psync.OpInsert, nil, psync.SupplierPaymentRecord{
			ID: crossPayID, SupplierID: supB, PurchaseInvoiceID: &invA, Amount: 10000, PaymentMethod: "CASH",
		})},
	})
	if code != http.StatusUnprocessableEntity {
		t.Fatalf("expected 422 for cross-supplier invoice payment, got %d", code)
	}

	overPayID := uuid.NewString()
	code, _ = env.pushHTTP(env.ownerSess.AccessToken, psync.PushRequest{
		Mutations: []psync.Mutation{makeMut(psync.TableSupplierPayments, overPayID, psync.OpInsert, nil, psync.SupplierPaymentRecord{
			ID: overPayID, SupplierID: supA, PurchaseInvoiceID: &invA, Amount: 90000, PaymentMethod: "CASH",
		})},
	})
	if code != http.StatusBadRequest {
		t.Fatalf("expected 400 for invoice overpayment > due_amount, got %d", code)
	}

	// 5) Soft-delete tombstone protection: DELETE on non-existent product -> 422;
	// DELETE on existing product followed by newer UPDATE with deleted_at=nil stays deleted.
	missingProdID := uuid.NewString()
	code, _ = env.pushHTTP(env.ownerSess.AccessToken, psync.PushRequest{
		Mutations: []psync.Mutation{makeMut(psync.TableProducts, missingProdID, psync.OpDelete, nil, psync.ProductRecord{ID: missingProdID})},
	})
	if code != http.StatusUnprocessableEntity {
		t.Fatalf("expected 422 for DELETE on non-existent product, got %d", code)
	}

	tDel := time.Now().UTC().Add(time.Second)
	tAfterDel := tDel.Add(5 * time.Second)
	env.mustPush(env.ownerSess.AccessToken,
		makeMut(psync.TableProducts, prodID, psync.OpDelete, &tDel, psync.ProductRecord{ID: prodID}),
		makeMut(psync.TableProducts, prodID, psync.OpUpdate, &tAfterDel, psync.ProductRecord{
			ID: prodID, Name: "Toner Renamed", Brand: "Klairs", Category: "Skincare", DeletedAt: nil,
		}),
	)

	// 6) Re-closing an already CLOSED shift does not overwrite the original Z-Report settlement.
	env.mustPush(env.managerSess.AccessToken, makeMut(psync.TableRegisterShifts, shiftID, psync.OpUpdate, nil, psync.RegisterShiftRecord{
		ID: shiftID, Status: "CLOSED", ActualCashCounted: psync.MoneyPtr(150000),
		CashWithdrawnDeposit: 50000, RetainedNextDayFloat: 100000,
	}))
	env.mustPush(env.ownerSess.AccessToken, makeMut(psync.TableRegisterShifts, shiftID, psync.OpUpdate, nil, psync.RegisterShiftRecord{
		ID: shiftID, Status: "CLOSED", ActualCashCounted: psync.MoneyPtr(999900),
		CashWithdrawnDeposit: 888800, RetainedNextDayFloat: 111100,
	}))

	_, _, checkPull := env.pullRaw(env.ownerSess.AccessToken, "")
	if checkPull.Changes.Batches[0].StockQuantity != 9 {
		t.Fatalf("expected stock=9 (no double deduction from duplicate saleID), got %d", checkPull.Changes.Batches[0].StockQuantity)
	}
	if checkPull.Changes.Products[0].DeletedAt == nil {
		t.Fatalf("soft-deleted product was resurrected by subsequent update")
	}
	if checkPull.Changes.RegisterShifts[0].ActualCashCounted == nil || *checkPull.Changes.RegisterShifts[0].ActualCashCounted != 150000 {
		t.Fatalf("expected closed shift actual_cash_counted=1500.00 preserved, got %+v", checkPull.Changes.RegisterShifts[0].ActualCashCounted)
	}
	var foundOwnSale bool
	for _, so := range checkPull.Changes.SaleOrders {
		if so.ID == ownSaleID {
			foundOwnSale = true
			if so.CostTotal == nil || *so.CostTotal != 120000 || so.NetProfit == nil || *so.NetProfit != 70000 {
				t.Fatalf("standalone OWNER sale_items failed to recompute cost_total/net_profit: %+v", so)
			}
		}
	}
	if !foundOwnSale {
		t.Fatalf("standalone OWNER sale order missing from pull")
	}

	// 7) Same-microsecond cursor pagination guard: 120 products sharing 1 microsecond + 5 later products with limit=100.
	tSame := checkPull.ServerTime.UTC().Add(10 * time.Microsecond).Truncate(time.Microsecond)
	tLater := tSame.Add(10 * time.Microsecond)
	for i := 0; i < 120; i++ {
		if _, err := testPool.Exec(context.Background(), `
			INSERT INTO products (id, store_id, name, brand, category, is_generic, created_at, updated_at)
			VALUES ($1, $2, $3, 'BulkBrand', 'Lips', FALSE, $4, $4)`,
			uuid.NewString(), env.ownerSess.Device.StoreID, fmt.Sprintf("Bulk-%03d", i), tSame); err != nil {
			t.Fatalf("seed same-microsecond product %d: %v", i, err)
		}
	}
	for i := 0; i < 5; i++ {
		if _, err := testPool.Exec(context.Background(), `
			INSERT INTO products (id, store_id, name, brand, category, is_generic, created_at, updated_at)
			VALUES ($1, $2, $3, 'LaterBrand', 'Lips', FALSE, $4, $4)`,
			uuid.NewString(), env.ownerSess.Device.StoreID, fmt.Sprintf("Later-%03d", i), tLater); err != nil {
			t.Fatalf("seed later product %d: %v", i, err)
		}
	}
	time.Sleep(2 * time.Millisecond)

	sinceBeforeBulk := tSame.Add(-time.Microsecond).UTC().Format(time.RFC3339Nano)
	req1, _ := http.NewRequest(http.MethodGet, env.srv.URL+"/api/sync/pull?limit=100&since="+sinceBeforeBulk, nil)
	req1.Header.Set("Authorization", "Bearer "+env.ownerSess.AccessToken)
	resp1, err := env.srv.Client().Do(req1)
	if err != nil || resp1.StatusCode != http.StatusOK {
		t.Fatalf("page 1 pull failed: %v", err)
	}
	var page1 psync.PullResponse
	_ = json.NewDecoder(resp1.Body).Decode(&page1)
	resp1.Body.Close()

	if len(page1.Changes.Products) != 120 || !page1.HasMore {
		t.Fatalf("page 1 expected all 120 same-microsecond products with HasMore=true, got len=%d hasMore=%v",
			len(page1.Changes.Products), page1.HasMore)
	}
	_, _, page2 := env.pullRaw(env.ownerSess.AccessToken, page1.ServerTime.UTC().Format(time.RFC3339Nano))
	if len(page2.Changes.Products) != 5 || page2.HasMore {
		t.Fatalf("page 2 expected 5 remaining products with HasMore=false, got len=%d hasMore=%v",
			len(page2.Changes.Products), page2.HasMore)
	}
}
