package sync

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/google/uuid"

	"pasalx/server/internal/auth"
)

func TestMoneyParsingFormattingAndOverflow(t *testing.T) {
	validCases := []struct {
		in   string
		want Money
		str  string
	}{
		{"0", 0, "0.00"},
		{"1350", 135000, "1350.00"},
		{"1350.5", 135050, "1350.50"},
		{"10.500", 1050, "10.50"},
		{".75", 75, "0.75"},
		{"-25.05", -2505, "-25.05"},
		{"+99999999.99", Money(maxMoney10_2), "99999999.99"},
	}
	for _, tc := range validCases {
		got, err := ParseMoney(tc.in)
		if err != nil {
			t.Fatalf("ParseMoney(%q) unexpected error: %v", tc.in, err)
		}
		if got != tc.want {
			t.Fatalf("ParseMoney(%q) = %d, want %d", tc.in, got, tc.want)
		}
		if got.String() != tc.str {
			t.Fatalf("Money(%d).String() = %q, want %q", got, got.String(), tc.str)
		}
	}

	invalidCases := []string{
		"",
		"-",
		"10.",
		"10.123",
		"1.2.3",
		"abc",
		"12.3a",
		"10000000000.00", // > DECIMAL(12,2)
	}
	for _, raw := range invalidCases {
		if _, err := ParseMoney(raw); err == nil {
			t.Fatalf("ParseMoney(%q) expected error, got nil", raw)
		}
	}

	// JSON round-trip accepts numbers & strings and outputs exact 2-decimal JSON numbers.
	type dto struct {
		A Money  `json:"a"`
		B Money  `json:"b"`
		C *Money `json:"c,omitempty"`
	}
	var parsed dto
	if err := json.Unmarshal([]byte(`{"a": 1350.5, "b": "450.25", "c": 10}`), &parsed); err != nil {
		t.Fatalf("UnmarshalJSON failed: %v", err)
	}
	if parsed.A != 135050 || parsed.B != 45025 || parsed.C == nil || *parsed.C != 1000 {
		t.Fatalf("unexpected unmarshaled values: %+v", parsed)
	}
	encoded, err := json.Marshal(parsed)
	if err != nil {
		t.Fatalf("MarshalJSON failed: %v", err)
	}
	wantJSON := `{"a":1350.50,"b":450.25,"c":10.00}`
	if string(encoded) != wantJSON {
		t.Fatalf("MarshalJSON = %s, want %s", encoded, wantJSON)
	}

	// Bounds & checked arithmetic
	if !Money(maxMoney10_2).FitsDecimal10_2() || Money(maxMoney10_2+1).FitsDecimal10_2() {
		t.Fatalf("FitsDecimal10_2 boundary check failed")
	}
	if !Money(maxMoney12_2).FitsDecimal12_2() || Money(maxMoney12_2+1).FitsDecimal12_2() {
		t.Fatalf("FitsDecimal12_2 boundary check failed")
	}
	if p, ok := Money(15000).MulChecked(3); !ok || p != 45000 {
		t.Fatalf("MulChecked(15000, 3) = (%d, %v), want (45000, true)", p, ok)
	}
	if _, ok := Money(maxMoney12_2).MulChecked(2); ok {
		t.Fatalf("MulChecked overflow beyond DECIMAL(12,2) succeeded unexpectedly")
	}
	if _, ok := Money(maxMoney12_2).AddChecked(1); ok {
		t.Fatalf("AddChecked overflow beyond DECIMAL(12,2) succeeded unexpectedly")
	}
}

func TestSyncClockConcurrentCutoff(t *testing.T) {
	base := time.Date(2026, 11, 15, 10, 0, 0, 0, time.UTC)
	c := newSyncClock()
	c.now = func() time.Time { return base }

	ts1, rel1 := c.beginPush()
	ts2, rel2 := c.beginPush()
	if !ts2.After(ts1) {
		t.Fatalf("expected strictly monotonic push timestamps: ts1=%v ts2=%v", ts1, ts2)
	}

	// Both pushes in-flight -> pull cutoff must hold strictly before ts1.
	cut1 := c.acquirePullCutoff()
	if !cut1.Before(ts1) {
		t.Fatalf("cutoff %v must be strictly before earliest in-flight push %v", cut1, ts1)
	}

	// Releasing ts1 while ts2 stays open allows cutoff to include ts1 but stay < ts2.
	rel1()
	cut2 := c.acquirePullCutoff()
	if cut2.Before(ts1) || !cut2.Before(ts2) {
		t.Fatalf("cutoff %v expected in [%v, %v)", cut2, ts1, ts2)
	}

	// Releasing ts2 lets cutoff advance cleanly past all committed writes, and
	// the next push is assigned strictly after the pull cutoff.
	rel2()
	cut3 := c.acquirePullCutoff()
	if cut3.Before(ts2) {
		t.Fatalf("cutoff %v must be >= ts2 (%v) once all pushes complete", cut3, ts2)
	}
	ts3, rel3 := c.beginPush()
	defer rel3()
	if !ts3.After(cut3) {
		t.Fatalf("subsequent push %v must be strictly after pull cutoff %v", ts3, cut3)
	}
}

func TestHubFanoutCoalescingAndLimits(t *testing.T) {
	hub := NewHub()
	defer hub.Shutdown()

	sub1, ok := hub.Subscribe("dev-id-1", "01")
	if !ok {
		t.Fatalf("Subscribe dev 01 failed")
	}
	sub2, ok := hub.Subscribe("dev-id-2", "02")
	if !ok {
		t.Fatalf("Subscribe dev 02 failed")
	}

	// Device 01 pushes -> Device 02 gets ping; Device 01 does not.
	t1 := time.Date(2026, 11, 15, 10, 1, 0, 0, time.UTC)
	t2 := t1.Add(200 * time.Millisecond)
	sent := hub.BroadcastDataChanged(BroadcastEvent{OriginDeviceCode: "01", ServerTime: t1, HasDiscrepancy: true})
	if sent != 1 {
		t.Fatalf("BroadcastDataChanged target count = %d, want 1", sent)
	}

	select {
	case <-sub1.Notify():
		t.Fatalf("origin device 01 received its own broadcast")
	default:
	}

	// Second queued event coalesces before consumer drains, keeping max ServerTime & HasDiscrepancy=true.
	hub.BroadcastDataChanged(BroadcastEvent{OriginDeviceCode: "03", ServerTime: t2, HasDiscrepancy: false})
	select {
	case <-sub2.Notify():
	case <-time.After(time.Second):
		t.Fatalf("dev 02 did not receive Notify signal")
	}
	ev, hasEv := sub2.TakePending()
	if !hasEv || !ev.HasDiscrepancy || !ev.ServerTime.Equal(t2) || ev.OriginDeviceCode != "03" {
		t.Fatalf("unexpected coalesced event: %+v (hasEv=%v)", ev, hasEv)
	}

	// maxPerDevice stale connection eviction for dev-id-2 (already has sub2 -> 1).
	var extras []*Subscriber
	for i := 0; i < defaultMaxPerDevice; i++ {
		s, ok := hub.Subscribe("dev-id-2", "02")
		if !ok {
			t.Fatalf("Subscribe extra %d failed", i)
		}
		extras = append(extras, s)
	}
	select {
	case <-sub2.Replaced():
	default:
		t.Fatalf("expected oldest stream sub2 to be marked Replaced after > maxPerDevice connects")
	}

	// RevokeDevice closes all active streams for dev-id-2 without affecting dev-id-1.
	hub.RevokeDevice("dev-id-2")
	for i, s := range extras {
		select {
		case <-s.Revoked():
		default:
			t.Fatalf("stream %d for revoked device not notified", i)
		}
	}
	select {
	case <-sub1.Revoked():
		t.Fatalf("unrelated device 01 marked revoked")
	default:
	}

	// Capacity limit check on isolated tiny hub.
	smallHub := NewHub()
	smallHub.maxSubscribers = 2
	if _, ok := smallHub.Subscribe("a", "01"); !ok {
		t.Fatalf("first subscribe on smallHub failed")
	}
	if _, ok := smallHub.Subscribe("b", "02"); !ok {
		t.Fatalf("second subscribe on smallHub failed")
	}
	if _, ok := smallHub.Subscribe("c", "03"); ok {
		t.Fatalf("third subscribe succeeded beyond maxSubscribers=2")
	}
	smallHub.Shutdown()
	if _, ok := smallHub.Subscribe("d", "04"); ok {
		t.Fatalf("subscribe succeeded after Shutdown")
	}
}

func assertSyncErrCode(t *testing.T, err error, wantStatus int, wantCode string) {
	t.Helper()
	if err == nil {
		t.Fatalf("expected error (%d %s), got nil", wantStatus, wantCode)
	}
	var se *Error
	if !errors.As(err, &se) {
		t.Fatalf("expected *sync.Error, got %T (%v)", err, err)
	}
	if se.Status != wantStatus || se.Code != wantCode {
		t.Fatalf("got Error(%d, %s: %s), want (%d, %s)", se.Status, se.Code, se.Message, wantStatus, wantCode)
	}
}

func TestPrepareMutationsRBACAndValidation(t *testing.T) {
	staff := auth.Session{
		UserID:     uuid.NewString(),
		Role:       auth.RoleStaff,
		DeviceID:   uuid.NewString(),
		DeviceCode: "02",
	}
	owner := auth.Session{
		UserID:     uuid.NewString(),
		Role:       auth.RoleOwner,
		DeviceID:   uuid.NewString(),
		DeviceCode: "01",
	}

	// Empty batch
	_, err := prepareMutations(owner, PushRequest{})
	assertSyncErrCode(t, err, http.StatusBadRequest, CodeBadRequest)

	// > MaxPushBatchSize (51 items)
	bigBatch := make([]Mutation, MaxPushBatchSize+1)
	for i := range bigBatch {
		id := uuid.NewString()
		bigBatch[i] = Mutation{
			ID:        uuid.NewString(),
			TableName: TableCustomers,
			RecordID:  id,
			Operation: OpInsert,
			Payload:   json.RawMessage(fmt.Sprintf(`{"id":%q,"name":"C%d","phone":"98000000%02d"}`, id, i, i)),
		}
	}
	_, err = prepareMutations(staff, PushRequest{Mutations: bigBatch})
	assertSyncErrCode(t, err, http.StatusBadRequest, CodeBadRequest)

	// Unknown JSON payload field rejected
	custID := uuid.NewString()
	_, err = prepareMutations(staff, PushRequest{Mutations: []Mutation{{
		ID:        uuid.NewString(),
		TableName: TableCustomers,
		RecordID:  custID,
		Operation: OpInsert,
		Payload:   json.RawMessage(fmt.Sprintf(`{"id":%q,"name":"Sita","phone":"9841","rogue":1}`, custID)),
	}}})
	assertSyncErrCode(t, err, http.StatusBadRequest, CodeBadRequest)

	// RecordID vs payload.id mismatch rejected
	_, err = prepareMutations(staff, PushRequest{Mutations: []Mutation{{
		ID:        uuid.NewString(),
		TableName: TableCustomers,
		RecordID:  custID,
		Operation: OpInsert,
		Payload:   json.RawMessage(fmt.Sprintf(`{"id":%q,"name":"Sita","phone":"9841"}`, uuid.NewString())),
	}}})
	assertSyncErrCode(t, err, http.StatusBadRequest, CodeBadRequest)

	// STAFF blocked on restricted tables & operations
	prodID := uuid.NewString()
	_, err = prepareMutations(staff, PushRequest{Mutations: []Mutation{{
		ID:        uuid.NewString(),
		TableName: TableProducts,
		RecordID:  prodID,
		Operation: OpInsert,
		Payload:   json.RawMessage(fmt.Sprintf(`{"id":%q,"name":"Lipstick","brand":"MAC","category":"Lips"}`, prodID)),
	}}})
	assertSyncErrCode(t, err, http.StatusForbidden, CodeForbidden)

	supID := uuid.NewString()
	_, err = prepareMutations(staff, PushRequest{Mutations: []Mutation{{
		ID:        uuid.NewString(),
		TableName: TableSuppliers,
		RecordID:  supID,
		Operation: OpInsert,
		Payload:   json.RawMessage(fmt.Sprintf(`{"id":%q,"name":"Valley Distributors"}`, supID)),
	}}})
	assertSyncErrCode(t, err, http.StatusForbidden, CodeForbidden)

	shiftID := uuid.NewString()
	_, err = prepareMutations(staff, PushRequest{Mutations: []Mutation{{
		ID:        uuid.NewString(),
		TableName: TableRegisterShifts,
		RecordID:  shiftID,
		Operation: OpUpdate,
		Payload:   json.RawMessage(fmt.Sprintf(`{"id":%q,"status":"CLOSED","actual_cash_counted":5000}`, shiftID)),
	}}})
	assertSyncErrCode(t, err, http.StatusForbidden, CodeForbidden)

	sessID := uuid.NewString()
	_, err = prepareMutations(staff, PushRequest{Mutations: []Mutation{{
		ID:        uuid.NewString(),
		TableName: TableStaffShiftSessions,
		RecordID:  sessID,
		Operation: OpUpdate,
		Payload:   json.RawMessage(fmt.Sprintf(`{"id":%q,"status":"FORCE_CLOSED"}`, sessID)),
	}}})
	assertSyncErrCode(t, err, http.StatusForbidden, CodeForbidden)

	// STAFF cannot push non-SALE stock movements
	movID := uuid.NewString()
	batchID := uuid.NewString()
	_, err = prepareMutations(staff, PushRequest{Mutations: []Mutation{{
		ID:        uuid.NewString(),
		TableName: TableStockMovements,
		RecordID:  movID,
		Operation: OpInsert,
		Payload:   json.RawMessage(fmt.Sprintf(`{"id":%q,"batch_id":%q,"movement_type":"PURCHASE_INTAKE","quantity_change":10,"staff_name":"Ram"}`, movID, batchID)),
	}}})
	assertSyncErrCode(t, err, http.StatusForbidden, CodeForbidden)

	// Wrong delta sign & zero delta checks (even for OWNER)
	_, err = prepareMutations(owner, PushRequest{Mutations: []Mutation{{
		ID:        uuid.NewString(),
		TableName: TableStockMovements,
		RecordID:  movID,
		Operation: OpInsert,
		Payload:   json.RawMessage(fmt.Sprintf(`{"id":%q,"batch_id":%q,"movement_type":"SALE","quantity_change":2,"staff_name":"Owner"}`, movID, batchID)),
	}}})
	assertSyncErrCode(t, err, http.StatusBadRequest, CodeBadRequest)

	_, err = prepareMutations(owner, PushRequest{Mutations: []Mutation{{
		ID:        uuid.NewString(),
		TableName: TableStockMovements,
		RecordID:  movID,
		Operation: OpInsert,
		Payload:   json.RawMessage(fmt.Sprintf(`{"id":%q,"batch_id":%q,"movement_type":"COUNT_CORRECTION","quantity_change":0,"staff_name":"Owner"}`, movID, batchID)),
	}}})
	assertSyncErrCode(t, err, http.StatusBadRequest, CodeBadRequest)

	// Append-only table rejects UPDATE
	_, err = prepareMutations(owner, PushRequest{Mutations: []Mutation{{
		ID:        uuid.NewString(),
		TableName: TableSaleOrders,
		RecordID:  uuid.NewString(),
		Operation: OpUpdate,
		Payload:   json.RawMessage(`{}`),
	}}})
	assertSyncErrCode(t, err, http.StatusBadRequest, CodeBadRequest)

	// STAFF spoofing cashier_user_id / created_by_user_id / opened_by_user_id / device_code rejected (403 FORBIDDEN)
	saleRecID := uuid.NewString()
	_, err = prepareMutations(staff, PushRequest{Mutations: []Mutation{{
		ID:        uuid.NewString(),
		TableName: TableSaleOrders,
		RecordID:  saleRecID,
		Operation: OpInsert,
		Payload:   json.RawMessage(fmt.Sprintf(`{"id":%q,"bill_no":"02-99","cashier_user_id":%q,"cashier_name":"Maya","subtotal":100,"discount_amount":0,"total_amount":100,"payment_mode":"CASH"}`, saleRecID, owner.UserID)),
	}}})
	assertSyncErrCode(t, err, http.StatusForbidden, CodeForbidden)

	txRecID := uuid.NewString()
	_, err = prepareMutations(staff, PushRequest{Mutations: []Mutation{{
		ID:        uuid.NewString(),
		TableName: TableCustomerTransactions,
		RecordID:  txRecID,
		Operation: OpInsert,
		Payload:   json.RawMessage(fmt.Sprintf(`{"id":%q,"customer_id":%q,"type":"DEBIT_PURCHASE","amount":100,"created_by_user_id":%q}`, txRecID, custID, owner.UserID)),
	}}})
	assertSyncErrCode(t, err, http.StatusForbidden, CodeForbidden)

	expRecID := uuid.NewString()
	_, err = prepareMutations(staff, PushRequest{Mutations: []Mutation{{
		ID:        uuid.NewString(),
		TableName: TableExpenses,
		RecordID:  expRecID,
		Operation: OpInsert,
		Payload:   json.RawMessage(fmt.Sprintf(`{"id":%q,"category":"TEA","title":"Chiya","amount":50,"payment_method":"CASH","created_by_user_id":%q}`, expRecID, owner.UserID)),
	}}})
	assertSyncErrCode(t, err, http.StatusForbidden, CodeForbidden)

	_, err = prepareMutations(staff, PushRequest{Mutations: []Mutation{{
		ID:        uuid.NewString(),
		TableName: TableRegisterShifts,
		RecordID:  shiftID,
		Operation: OpInsert,
		Payload:   json.RawMessage(fmt.Sprintf(`{"id":%q,"opened_by_user_id":%q,"opening_float":500,"status":"OPEN"}`, shiftID, owner.UserID)),
	}}})
	assertSyncErrCode(t, err, http.StatusForbidden, CodeForbidden)

	_, err = prepareMutations(staff, PushRequest{Mutations: []Mutation{{
		ID:        uuid.NewString(),
		TableName: TableStaffShiftSessions,
		RecordID:  sessID,
		Operation: OpInsert,
		Payload:   json.RawMessage(fmt.Sprintf(`{"id":%q,"register_shift_id":%q,"user_id":%q,"device_code":"01","status":"ACTIVE"}`, sessID, shiftID, staff.UserID)),
	}}})
	assertSyncErrCode(t, err, http.StatusForbidden, CodeForbidden)

	// register_shifts INSERT with status CLOSED rejected even for OWNER (400 BAD_REQUEST)
	_, err = prepareMutations(owner, PushRequest{Mutations: []Mutation{{
		ID:        uuid.NewString(),
		TableName: TableRegisterShifts,
		RecordID:  shiftID,
		Operation: OpInsert,
		Payload:   json.RawMessage(fmt.Sprintf(`{"id":%q,"opened_by_user_id":%q,"opening_float":500,"status":"CLOSED"}`, shiftID, owner.UserID)),
	}}})
	assertSyncErrCode(t, err, http.StatusBadRequest, CodeBadRequest)

	// Negative sale_order amounts, subtotal-discount mismatch, and duplicate embedded child IDs rejected
	_, err = prepareMutations(owner, PushRequest{Mutations: []Mutation{{
		ID:        uuid.NewString(),
		TableName: TableSaleOrders,
		RecordID:  saleRecID,
		Operation: OpInsert,
		Payload:   json.RawMessage(fmt.Sprintf(`{"id":%q,"bill_no":"01-99","cashier_name":"Owner","subtotal":100,"discount_amount":20,"total_amount":90,"payment_mode":"CASH"}`, saleRecID)),
	}}})
	assertSyncErrCode(t, err, http.StatusBadRequest, CodeBadRequest)

	dupItemID := uuid.NewString()
	_, err = prepareMutations(owner, PushRequest{Mutations: []Mutation{{
		ID:        uuid.NewString(),
		TableName: TableSaleOrders,
		RecordID:  saleRecID,
		Operation: OpInsert,
		Payload: json.RawMessage(fmt.Sprintf(`{"id":%q,"bill_no":"01-99","cashier_name":"Owner","subtotal":200,"discount_amount":0,"total_amount":200,"payment_mode":"CASH","items":[{"id":%q,"batch_id":%q,"product_name":"P","variant_name":"V","quantity":1,"selling_price":100,"total_price":100},{"id":%q,"batch_id":%q,"product_name":"P","variant_name":"V","quantity":1,"selling_price":100,"total_price":100}]}`,
			saleRecID, dupItemID, batchID, dupItemID, batchID)),
	}}})
	assertSyncErrCode(t, err, http.StatusBadRequest, CodeBadRequest)

	// Purchase invoice where paid_amount + due_amount != total_amount rejected
	invRecID := uuid.NewString()
	_, err = prepareMutations(owner, PushRequest{Mutations: []Mutation{{
		ID:        uuid.NewString(),
		TableName: TablePurchaseInvoices,
		RecordID:  invRecID,
		Operation: OpInsert,
		Payload:   json.RawMessage(fmt.Sprintf(`{"id":%q,"supplier_id":%q,"invoice_no":"INV-BAD","invoice_date":"2026-11-15","total_amount":1000,"paid_amount":400,"due_amount":500}`, invRecID, supID)),
	}}})
	assertSyncErrCode(t, err, http.StatusBadRequest, CodeBadRequest)
}
