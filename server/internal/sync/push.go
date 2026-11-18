package sync

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"pasalx/server/internal/auth"
	"pasalx/server/internal/db"
)

// Service executes idempotent batch push, cursor-based role-masked pull,
// and coordinates real-time SSE broadcasts after Postgres commits.
type Service struct {
	db    *pgxpool.Pool
	hub   *Hub
	clock *syncClock
}

// NewService creates a sync Service backed by pool and broadcasting via hub.
func NewService(pool *pgxpool.Pool, hub *Hub) *Service {
	if hub == nil {
		hub = NewHub()
	}
	return &Service{
		db:    pool,
		hub:   hub,
		clock: newSyncClock(),
	}
}

// Hub returns the underlying SSE hub.
func (s *Service) Hub() *Hub { return s.hub }

type preparedMutation struct {
	raw        Mutation
	clientTS   *time.Time
	product    *ProductRecord
	variant    *ProductVariantRecord
	batch      *BatchRecord
	customer   *CustomerRecord
	shadeProf  *CustomerShadeProfileRecord
	customerTx *CustomerTransactionRecord
	supplier   *SupplierRecord
	invoice    *PurchaseInvoiceRecord
	invItem    *PurchaseInvoiceItemRecord
	supPayment *SupplierPaymentRecord
	movement   *StockMovementRecord
	saleOrder  *SaleOrderRecord
	saleItem   *SaleItemRecord
	salePay    *SalePaymentRecord
	regShift   *RegisterShiftRecord
	staffSess  *StaffShiftSessionRecord
	expense    *ExpenseRecord
}

var (
	allowedMovementTypes = map[string]int{
		"PURCHASE_INTAKE":  1,  // strictly positive
		"CUSTOMER_RETURN":  1,  // strictly positive
		"SALE":             -1, // strictly negative
		"TESTER_CONVERSION": -1,
		"DAMAGED_WRITEOFF":  -1,
		"EXPIRED_WRITEOFF":  -1,
		"COUNT_CORRECTION":  0, // any non-zero delta
	}
	allowedCustTxTypes      = map[string]bool{"DEBIT_PURCHASE": true, "CREDIT_REPAYMENT": true}
	allowedCustPayMethods   = map[string]bool{"CASH": true, "FONEPAY_QR": true, "BANK_TRANSFER": true}
	allowedSupPayMethods    = map[string]bool{"BANK_TRANSFER": true, "CASH": true, "CHEQUE": true, "FONEPAY": true}
	allowedExpenseMethods   = map[string]bool{"CASH": true, "FONEPAY": true, "BANK": true}
	allowedShiftStatuses    = map[string]bool{"OPEN": true, "CLOSED": true}
	allowedSessionStatuses  = map[string]bool{"ACTIVE": true, "PUNCHED_OUT": true, "FORCE_CLOSED": true}
	allowedInvoiceStatuses  = map[string]bool{"PAID": true, "PARTIAL": true, "UNPAID": true}
)

// Push ingests a batch of up to 50 client outbox mutations in a single ACID
// PostgreSQL transaction using ON CONFLICT DO NOTHING idempotency, atomic stock
// deltas, negative stock discrepancy audits, and post-commit SSE wakeup pings.
func (s *Service) Push(ctx context.Context, sess auth.Session, req PushRequest) (*PushResult, error) {
	items, err := prepareMutations(sess, req)
	if err != nil {
		return nil, err
	}

	const maxTxAttempts = 3
	var (
		res       *PushResult
		hasChange bool
		hasDisc   bool
	)

	for attempt := 0; attempt < maxTxAttempts; attempt++ {
		ts, releaseTS := s.clock.beginPush()
		attemptRes, changed, disc, txErr := s.execPushTx(ctx, sess, ts, items)
		releaseTS()
		if txErr == nil {
			res = attemptRes
			hasChange = changed
			hasDisc = disc
			break
		}
		if isRetryablePgErr(txErr) && attempt < maxTxAttempts-1 {
			select {
			case <-ctx.Done():
				return nil, newErr(http.StatusRequestTimeout, CodeBadRequest, "request cancelled")
			case <-time.After(time.Duration(10*(attempt+1)) * time.Millisecond):
			}
			continue
		}
		return nil, mapPgError(txErr)
	}

	if hasChange {
		s.hub.BroadcastDataChanged(BroadcastEvent{
			StoreID:          sess.StoreID,
			OriginDeviceID:   sess.DeviceID,
			OriginDeviceCode: sess.DeviceCode,
			ServerTime:       res.ServerTime,
			HasDiscrepancy:   hasDisc,
		})
	}
	return res, nil
}

func (s *Service) execPushTx(ctx context.Context, sess auth.Session, ts time.Time, items []preparedMutation) (*PushResult, bool, bool, error) {
	out := &PushResult{
		ServerTime:    ts,
		Results:       make([]MutationResult, 0, len(items)),
		Discrepancies: []DiscrepancyAlert{},
	}
	recomputeOrders := make(map[string]struct{})

	err := db.WithTenantTxOptions(ctx, s.db, sess.StoreID, pgx.TxOptions{IsoLevel: pgx.ReadCommitted}, func(tx pgx.Tx) error {
		for _, pm := range items {
			tag, err := tx.Exec(ctx, `
				INSERT INTO sync_processed_mutations (store_id, id, device_id, device_code, table_name, record_id, operation, processed_at)
				VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
				ON CONFLICT (store_id, id) DO NOTHING`,
				sess.StoreID, pm.raw.ID, sess.DeviceID, sess.DeviceCode, pm.raw.TableName, pm.raw.RecordID, pm.raw.Operation, ts)
			if err != nil {
				return err
			}
			if tag.RowsAffected() == 0 {
				out.DuplicateCount++
				out.ProcessedCount++
				out.Results = append(out.Results, MutationResult{
					ID:        pm.raw.ID,
					TableName: pm.raw.TableName,
					RecordID:  pm.raw.RecordID,
					Status:    "ALREADY_APPLIED",
				})
				continue
			}

			disc, err := applyPreparedMutation(ctx, tx, sess, ts, pm, recomputeOrders)
			if err != nil {
				return err
			}
			out.AppliedCount++
			out.ProcessedCount++
			out.Results = append(out.Results, MutationResult{
				ID:        pm.raw.ID,
				TableName: pm.raw.TableName,
				RecordID:  pm.raw.RecordID,
				Status:    "APPLIED",
			})
			if len(disc) > 0 {
				out.Discrepancies = append(out.Discrepancies, disc...)
			}
		}

		for orderID := range recomputeOrders {
			if _, err := tx.Exec(ctx, `
				UPDATE sale_orders o
				SET cost_total = COALESCE((SELECT SUM(si.quantity * si.cost_price) FROM sale_items si WHERE si.sale_order_id = o.id AND si.store_id = o.store_id), 0.00),
				    net_profit = o.total_amount - COALESCE((SELECT SUM(si.quantity * si.cost_price) FROM sale_items si WHERE si.sale_order_id = o.id AND si.store_id = o.store_id), 0.00),
				    updated_at = GREATEST(COALESCE(o.updated_at, $2), $2)
				WHERE o.id = $1 AND o.store_id = $3 AND EXISTS (SELECT 1 FROM sale_items si WHERE si.sale_order_id = o.id AND si.store_id = o.store_id)`,
				orderID, ts, sess.StoreID); err != nil {
				return err
			}
		}

		if out.AppliedCount > 0 {
			if _, err := tx.Exec(ctx, `
				UPDATE staff_shift_sessions
				SET last_synced_at = $4, updated_at = GREATEST(COALESCE(updated_at, $4), $4)
				WHERE store_id = $1 AND device_id = $2 AND user_id = $3 AND status = 'ACTIVE'`,
				sess.StoreID, sess.DeviceID, sess.UserID, ts); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return nil, false, false, err
	}
	return out, out.AppliedCount > 0, len(out.Discrepancies) > 0, nil
}

// ---------------------------------------------------------------- Pre-Tx Validation

func prepareMutations(sess auth.Session, req PushRequest) ([]preparedMutation, error) {
	if len(req.Mutations) == 0 {
		return nil, newErr(http.StatusBadRequest, CodeBadRequest, "mutations array must not be empty")
	}
	if len(req.Mutations) > MaxPushBatchSize {
		return nil, newErr(http.StatusBadRequest, CodeBadRequest,
			fmt.Sprintf("batch size %d exceeds maximum %d", len(req.Mutations), MaxPushBatchSize))
	}

	isManagerOrOwner := sess.Role == auth.RoleOwner || sess.Role == auth.RoleManager
	out := make([]preparedMutation, len(req.Mutations))

	for i, m := range req.Mutations {
		m.ID = strings.TrimSpace(m.ID)
		m.RecordID = strings.TrimSpace(m.RecordID)
		m.TableName = strings.ToLower(strings.TrimSpace(m.TableName))
		m.Operation = strings.ToUpper(strings.TrimSpace(m.Operation))
		if !isUUID(m.ID) {
			return nil, newErr(http.StatusBadRequest, CodeBadRequest, fmt.Sprintf("mutations[%d].id must be a valid UUID", i))
		}
		if !isUUID(m.RecordID) {
			return nil, newErr(http.StatusBadRequest, CodeBadRequest, fmt.Sprintf("mutations[%d].record_id must be a valid UUID", i))
		}
		if m.Operation != OpInsert && m.Operation != OpUpdate && m.Operation != OpDelete {
			return nil, newErr(http.StatusBadRequest, CodeBadRequest, fmt.Sprintf("mutations[%d].operation invalid: %q", i, m.Operation))
		}

		pm := preparedMutation{raw: m, clientTS: m.ClientUpdatedAt}
		switch m.TableName {
		case TableProducts:
			if !isManagerOrOwner {
				return nil, newErr(http.StatusForbidden, CodeForbidden, "STAFF cannot modify products catalog")
			}
			var r ProductRecord
			if err := decodeStrictPayload(m.Payload, &r); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if err := alignRecordID(&r.ID, m.RecordID); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if m.Operation != OpDelete {
				if strings.TrimSpace(r.Name) == "" || strings.TrimSpace(r.Brand) == "" || strings.TrimSpace(r.Category) == "" {
					return nil, badPayloadErr(i, errors.New("name, brand, and category are required"))
				}
			}
			pm.product = &r

		case TableProductVariants:
			if !isManagerOrOwner {
				return nil, newErr(http.StatusForbidden, CodeForbidden, "STAFF cannot modify product variants")
			}
			var r ProductVariantRecord
			if err := decodeStrictPayload(m.Payload, &r); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if err := alignRecordID(&r.ID, m.RecordID); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if m.Operation != OpDelete {
				if !isUUID(r.ProductID) || strings.TrimSpace(r.VariantName) == "" {
					return nil, badPayloadErr(i, errors.New("valid product_id and variant_name are required"))
				}
				if len(r.Attributes) == 0 {
					r.Attributes = json.RawMessage(`{}`)
				} else if !json.Valid(r.Attributes) {
					return nil, badPayloadErr(i, errors.New("attributes must be valid JSON"))
				}
			}
			pm.variant = &r

		case TableBatches:
			if !isManagerOrOwner {
				return nil, newErr(http.StatusForbidden, CodeForbidden, "STAFF cannot create or edit batches directly; use stock_movements SALE")
			}
			var r BatchRecord
			if err := decodeStrictPayload(m.Payload, &r); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if err := alignRecordID(&r.ID, m.RecordID); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if m.Operation != OpDelete {
				if !isUUID(r.VariantID) || strings.TrimSpace(r.BatchCode) == "" || strings.TrimSpace(r.StickerBarcode) == "" {
					return nil, badPayloadErr(i, errors.New("variant_id, batch_code, and sticker_barcode are required"))
				}
				if !r.SellingPrice.FitsDecimal10_2() || r.SellingPrice < 0 {
					return nil, badPayloadErr(i, errors.New("selling_price must be non-negative DECIMAL(10,2)"))
				}
				if r.CostPrice != nil && (!r.CostPrice.FitsDecimal10_2() || *r.CostPrice < 0) {
					return nil, badPayloadErr(i, errors.New("cost_price must be non-negative DECIMAL(10,2)"))
				}
				exp, err := normalizeDate(r.ExpiryDate)
				if err != nil {
					return nil, badPayloadErr(i, fmt.Errorf("expiry_date: %w", err))
				}
				r.ExpiryDate = exp
				if err := cleanOptionalUUID(&r.SupplierID, "supplier_id"); err != nil {
					return nil, badPayloadErr(i, err)
				}
				if err := cleanOptionalUUID(&r.PurchaseInvoiceID, "purchase_invoice_id"); err != nil {
					return nil, badPayloadErr(i, err)
				}
			}
			pm.batch = &r

		case TableCustomers:
			var r CustomerRecord
			if err := decodeStrictPayload(m.Payload, &r); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if err := alignRecordID(&r.ID, m.RecordID); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if m.Operation != OpDelete {
				if strings.TrimSpace(r.Name) == "" || strings.TrimSpace(r.Phone) == "" {
					return nil, badPayloadErr(i, errors.New("name and phone are required"))
				}
				if r.CreditLimit != nil && (!r.CreditLimit.FitsDecimal10_2() || *r.CreditLimit < 0) {
					return nil, badPayloadErr(i, errors.New("credit_limit must be non-negative DECIMAL(10,2)"))
				}
			}
			pm.customer = &r

		case TableCustomerShadeProfiles:
			if m.Operation == OpDelete {
				return nil, badPayloadErr(i, errors.New("customer_shade_profiles does not support DELETE"))
			}
			var r CustomerShadeProfileRecord
			if err := decodeStrictPayload(m.Payload, &r); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if err := alignRecordID(&r.ID, m.RecordID); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if !isUUID(r.CustomerID) || strings.TrimSpace(r.ProductName) == "" || strings.TrimSpace(r.Brand) == "" || strings.TrimSpace(r.ShadeVariant) == "" {
				return nil, badPayloadErr(i, errors.New("customer_id, product_name, brand, and shade_variant are required"))
			}
			pm.shadeProf = &r

		case TableCustomerTransactions:
			if m.Operation != OpInsert {
				return nil, badPayloadErr(i, errors.New("customer_transactions is append-only (INSERT only)"))
			}
			var r CustomerTransactionRecord
			if err := decodeStrictPayload(m.Payload, &r); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if err := alignRecordID(&r.ID, m.RecordID); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if !isUUID(r.CustomerID) || !allowedCustTxTypes[r.Type] {
				return nil, badPayloadErr(i, errors.New("valid customer_id and type (DEBIT_PURCHASE|CREDIT_REPAYMENT) are required"))
			}
			if !r.Amount.FitsDecimal10_2() || r.Amount <= 0 {
				return nil, badPayloadErr(i, errors.New("amount must be > 0 and fit DECIMAL(10,2)"))
			}
			if r.PaymentMethod != nil {
				pmethod := strings.TrimSpace(*r.PaymentMethod)
				if pmethod == "" {
					r.PaymentMethod = nil
				} else {
					r.PaymentMethod = &pmethod
					if !allowedCustPayMethods[pmethod] {
						return nil, badPayloadErr(i, fmt.Errorf("invalid payment_method %q", pmethod))
					}
				}
			}
			if err := cleanOptionalUUID(&r.ShiftID, "shift_id"); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if r.CreatedByUserID == nil || strings.TrimSpace(*r.CreatedByUserID) == "" {
				u := sess.UserID
				r.CreatedByUserID = &u
			} else if err := cleanOptionalUUID(&r.CreatedByUserID, "created_by_user_id"); err != nil {
				return nil, badPayloadErr(i, err)
			} else if !isManagerOrOwner && *r.CreatedByUserID != sess.UserID {
				return nil, newErr(http.StatusForbidden, CodeForbidden, "STAFF cannot attribute customer_transactions to another user")
			}
			pm.customerTx = &r

		case TableSuppliers:
			if !isManagerOrOwner {
				return nil, newErr(http.StatusForbidden, CodeForbidden, "STAFF cannot modify suppliers")
			}
			var r SupplierRecord
			if err := decodeStrictPayload(m.Payload, &r); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if err := alignRecordID(&r.ID, m.RecordID); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if m.Operation != OpDelete && strings.TrimSpace(r.Name) == "" {
				return nil, badPayloadErr(i, errors.New("supplier name is required"))
			}
			pm.supplier = &r

		case TablePurchaseInvoices:
			if !isManagerOrOwner {
				return nil, newErr(http.StatusForbidden, CodeForbidden, "STAFF cannot push purchase_invoices")
			}
			if m.Operation != OpInsert {
				return nil, badPayloadErr(i, errors.New("purchase_invoices only supports INSERT via sync"))
			}
			var r PurchaseInvoiceRecord
			if err := decodeStrictPayload(m.Payload, &r); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if err := alignRecordID(&r.ID, m.RecordID); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if !isUUID(r.SupplierID) || strings.TrimSpace(r.InvoiceNo) == "" {
				return nil, badPayloadErr(i, errors.New("supplier_id and invoice_no are required"))
			}
			invDate, err := normalizeDate(r.InvoiceDate)
			if err != nil {
				return nil, badPayloadErr(i, fmt.Errorf("invoice_date: %w", err))
			}
			r.InvoiceDate = invDate
			if !r.TotalAmount.FitsDecimal10_2() || !r.PaidAmount.FitsDecimal10_2() || !r.DueAmount.FitsDecimal10_2() ||
				r.TotalAmount < 0 || r.PaidAmount < 0 || r.DueAmount < 0 {
				return nil, badPayloadErr(i, errors.New("invoice amounts must be non-negative DECIMAL(10,2)"))
			}
			invSum, ok := r.PaidAmount.AddChecked(r.DueAmount)
			if !ok || invSum != r.TotalAmount {
				return nil, badPayloadErr(i, errors.New("paid_amount + due_amount must equal total_amount"))
			}
			if r.Status == "" {
				r.Status = "UNPAID"
			}
			if !allowedInvoiceStatuses[r.Status] {
				return nil, badPayloadErr(i, fmt.Errorf("invalid invoice status %q", r.Status))
			}
			if r.CreatedByUserID == nil || strings.TrimSpace(*r.CreatedByUserID) == "" {
				u := sess.UserID
				r.CreatedByUserID = &u
			} else if err := cleanOptionalUUID(&r.CreatedByUserID, "created_by_user_id"); err != nil {
				return nil, badPayloadErr(i, err)
			}
			seenInvItems := make(map[string]bool, len(r.Items))
			for j := range r.Items {
				if err := validatePurchaseItem(&r.Items[j], r.ID); err != nil {
					return nil, badPayloadErr(i, fmt.Errorf("items[%d]: %w", j, err))
				}
				if seenInvItems[r.Items[j].ID] {
					return nil, badPayloadErr(i, fmt.Errorf("duplicate purchase_invoice_item id %q", r.Items[j].ID))
				}
				seenInvItems[r.Items[j].ID] = true
			}
			pm.invoice = &r

		case TablePurchaseInvoiceItems:
			if !isManagerOrOwner {
				return nil, newErr(http.StatusForbidden, CodeForbidden, "STAFF cannot push purchase_invoice_items")
			}
			if m.Operation != OpInsert {
				return nil, badPayloadErr(i, errors.New("purchase_invoice_items is append-only (INSERT only)"))
			}
			var r PurchaseInvoiceItemRecord
			if err := decodeStrictPayload(m.Payload, &r); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if err := alignRecordID(&r.ID, m.RecordID); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if err := validatePurchaseItem(&r, ""); err != nil {
				return nil, badPayloadErr(i, err)
			}
			pm.invItem = &r

		case TableSupplierPayments:
			if !isManagerOrOwner {
				return nil, newErr(http.StatusForbidden, CodeForbidden, "STAFF cannot push supplier_payments")
			}
			if m.Operation != OpInsert {
				return nil, badPayloadErr(i, errors.New("supplier_payments is append-only (INSERT only)"))
			}
			var r SupplierPaymentRecord
			if err := decodeStrictPayload(m.Payload, &r); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if err := alignRecordID(&r.ID, m.RecordID); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if !isUUID(r.SupplierID) || !r.Amount.FitsDecimal10_2() || r.Amount <= 0 || !allowedSupPayMethods[r.PaymentMethod] {
				return nil, badPayloadErr(i, errors.New("valid supplier_id, amount > 0, and payment_method required"))
			}
			if err := cleanOptionalUUID(&r.PurchaseInvoiceID, "purchase_invoice_id"); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if r.CreatedByUserID == nil || strings.TrimSpace(*r.CreatedByUserID) == "" {
				u := sess.UserID
				r.CreatedByUserID = &u
			} else if err := cleanOptionalUUID(&r.CreatedByUserID, "created_by_user_id"); err != nil {
				return nil, badPayloadErr(i, err)
			}
			pm.supPayment = &r

		case TableStockMovements:
			if m.Operation != OpInsert {
				return nil, badPayloadErr(i, errors.New("stock_movements is append-only (INSERT only)"))
			}
			var r StockMovementRecord
			if err := decodeStrictPayload(m.Payload, &r); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if err := alignRecordID(&r.ID, m.RecordID); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if err := validateStockMovement(sess, &r); err != nil {
				return nil, err
			}
			pm.movement = &r

		case TableSaleOrders:
			if m.Operation != OpInsert {
				return nil, badPayloadErr(i, errors.New("sale_orders is append-only (INSERT only)"))
			}
			var r SaleOrderRecord
			if err := decodeStrictPayload(m.Payload, &r); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if err := alignRecordID(&r.ID, m.RecordID); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if err := validateSaleOrder(sess, &r); err != nil {
				return nil, err
			}
			pm.saleOrder = &r

		case TableSaleItems:
			if m.Operation != OpInsert {
				return nil, badPayloadErr(i, errors.New("sale_items is append-only (INSERT only)"))
			}
			var r SaleItemRecord
			if err := decodeStrictPayload(m.Payload, &r); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if err := alignRecordID(&r.ID, m.RecordID); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if err := validateSaleItem(&r, ""); err != nil {
				return nil, badPayloadErr(i, err)
			}
			pm.saleItem = &r

		case TableSalePayments:
			if m.Operation != OpInsert {
				return nil, badPayloadErr(i, errors.New("sale_payments is append-only (INSERT only)"))
			}
			var r SalePaymentRecord
			if err := decodeStrictPayload(m.Payload, &r); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if err := alignRecordID(&r.ID, m.RecordID); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if err := validateSalePayment(&r, ""); err != nil {
				return nil, badPayloadErr(i, err)
			}
			pm.salePay = &r

		case TableRegisterShifts:
			if m.Operation == OpDelete {
				return nil, badPayloadErr(i, errors.New("register_shifts cannot be deleted"))
			}
			var r RegisterShiftRecord
			if err := decodeStrictPayload(m.Payload, &r); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if err := alignRecordID(&r.ID, m.RecordID); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if r.Status == "" {
				if m.Operation == OpInsert {
					r.Status = "OPEN"
				} else {
					r.Status = "CLOSED"
				}
			}
			if !allowedShiftStatuses[r.Status] {
				return nil, badPayloadErr(i, fmt.Errorf("invalid shift status %q", r.Status))
			}
			if m.Operation == OpUpdate || r.Status == "CLOSED" {
				if !isManagerOrOwner {
					return nil, newErr(http.StatusForbidden, CodeForbidden, "STAFF cannot settle or close register_shifts (Z-Report)")
				}
			}
			if m.Operation == OpInsert {
				if r.Status != "OPEN" {
					return nil, badPayloadErr(i, errors.New("register_shifts INSERT must have status OPEN"))
				}
				if strings.TrimSpace(r.OpenedByUserID) == "" {
					r.OpenedByUserID = sess.UserID
				} else if !isUUID(r.OpenedByUserID) {
					return nil, badPayloadErr(i, errors.New("opened_by_user_id must be a UUID"))
				} else if !isManagerOrOwner && r.OpenedByUserID != sess.UserID {
					return nil, newErr(http.StatusForbidden, CodeForbidden, "STAFF cannot open a register shift for another user")
				}
				if !r.OpeningFloat.FitsDecimal10_2() || r.OpeningFloat < 0 {
					return nil, badPayloadErr(i, errors.New("opening_float must be non-negative DECIMAL(10,2)"))
				}
			} else {
				if r.ClosedByUserID == nil || strings.TrimSpace(*r.ClosedByUserID) == "" {
					u := sess.UserID
					r.ClosedByUserID = &u
				} else if err := cleanOptionalUUID(&r.ClosedByUserID, "closed_by_user_id"); err != nil {
					return nil, badPayloadErr(i, err)
				}
				if r.ActualCashCounted != nil && (!r.ActualCashCounted.FitsDecimal10_2() || *r.ActualCashCounted < 0) {
					return nil, badPayloadErr(i, errors.New("actual_cash_counted must be non-negative DECIMAL(10,2)"))
				}
				if !r.CashWithdrawnDeposit.FitsDecimal10_2() || r.CashWithdrawnDeposit < 0 ||
					!r.RetainedNextDayFloat.FitsDecimal10_2() || r.RetainedNextDayFloat < 0 {
					return nil, badPayloadErr(i, errors.New("deposit/float amounts must be non-negative DECIMAL(10,2)"))
				}
			}
			pm.regShift = &r

		case TableStaffShiftSessions:
			if m.Operation == OpDelete {
				return nil, badPayloadErr(i, errors.New("staff_shift_sessions cannot be deleted"))
			}
			var r StaffShiftSessionRecord
			if err := decodeStrictPayload(m.Payload, &r); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if err := alignRecordID(&r.ID, m.RecordID); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if r.Status == "" {
				r.Status = "ACTIVE"
			}
			if !allowedSessionStatuses[r.Status] {
				return nil, badPayloadErr(i, fmt.Errorf("invalid shift session status %q", r.Status))
			}
			if r.Status == "FORCE_CLOSED" && !isManagerOrOwner {
				return nil, newErr(http.StatusForbidden, CodeForbidden, "only OWNER or MANAGER can force-close a staff session")
			}
			if m.Operation == OpInsert {
				if !isUUID(r.RegisterShiftID) {
					return nil, badPayloadErr(i, errors.New("register_shift_id must be a UUID"))
				}
				if strings.TrimSpace(r.UserID) == "" {
					r.UserID = sess.UserID
				} else if !isUUID(r.UserID) {
					return nil, badPayloadErr(i, errors.New("user_id must be a UUID"))
				}
				if !isManagerOrOwner && r.UserID != sess.UserID {
					return nil, newErr(http.StatusForbidden, CodeForbidden, "STAFF cannot punch in for another user")
				}
				if strings.TrimSpace(r.DeviceCode) == "" {
					r.DeviceCode = sess.DeviceCode
				} else if !isManagerOrOwner && r.DeviceCode != sess.DeviceCode {
					return nil, newErr(http.StatusForbidden, CodeForbidden, "STAFF cannot punch in with another device_code")
				}
			} else {
				if r.UserID != "" {
					if !isUUID(r.UserID) {
						return nil, badPayloadErr(i, errors.New("user_id must be a UUID"))
					}
					if !isManagerOrOwner && r.UserID != sess.UserID {
						return nil, newErr(http.StatusForbidden, CodeForbidden, "STAFF cannot modify another user's shift session")
					}
				}
				if r.Status == "FORCE_CLOSED" && (r.ForceClosedByUserID == nil || strings.TrimSpace(*r.ForceClosedByUserID) == "") {
					u := sess.UserID
					r.ForceClosedByUserID = &u
				} else if err := cleanOptionalUUID(&r.ForceClosedByUserID, "force_closed_by_user_id"); err != nil {
					return nil, badPayloadErr(i, err)
				}
			}
			pm.staffSess = &r

		case TableExpenses:
			if m.Operation != OpInsert {
				return nil, badPayloadErr(i, errors.New("expenses is append-only (INSERT only)"))
			}
			var r ExpenseRecord
			if err := decodeStrictPayload(m.Payload, &r); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if err := alignRecordID(&r.ID, m.RecordID); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if strings.TrimSpace(r.Category) == "" || strings.TrimSpace(r.Title) == "" ||
				!r.Amount.FitsDecimal10_2() || r.Amount <= 0 || !allowedExpenseMethods[r.PaymentMethod] {
				return nil, badPayloadErr(i, errors.New("valid category, title, amount > 0, and payment_method (CASH|FONEPAY|BANK) required"))
			}
			if err := cleanOptionalUUID(&r.ShiftID, "shift_id"); err != nil {
				return nil, badPayloadErr(i, err)
			}
			if strings.TrimSpace(r.CreatedByUserID) == "" {
				r.CreatedByUserID = sess.UserID
			} else if !isUUID(r.CreatedByUserID) {
				return nil, badPayloadErr(i, errors.New("created_by_user_id must be a UUID"))
			} else if !isManagerOrOwner && r.CreatedByUserID != sess.UserID {
				return nil, newErr(http.StatusForbidden, CodeForbidden, "STAFF cannot record expenses under another user")
			}
			pm.expense = &r

		default:
			return nil, newErr(http.StatusBadRequest, CodeBadRequest, fmt.Sprintf("mutations[%d]: unsupported table %q", i, m.TableName))
		}
		out[i] = pm
	}
	return out, nil
}

func validatePurchaseItem(it *PurchaseInvoiceItemRecord, parentID string) error {
	if parentID != "" && it.PurchaseInvoiceID == "" {
		it.PurchaseInvoiceID = parentID
	}
	if !isUUID(it.ID) || !isUUID(it.PurchaseInvoiceID) || !isUUID(it.VariantID) {
		return errors.New("id, purchase_invoice_id, and variant_id must be UUIDs")
	}
	if parentID != "" && it.PurchaseInvoiceID != parentID {
		return errors.New("purchase_invoice_id mismatch with parent")
	}
	if err := cleanOptionalUUID(&it.BatchID, "batch_id"); err != nil {
		return err
	}
	if strings.TrimSpace(it.ProductName) == "" || strings.TrimSpace(it.VariantName) == "" || it.QuantityReceived <= 0 {
		return errors.New("product_name, variant_name, and quantity_received > 0 required")
	}
	if !it.UnitSellingPrice.FitsDecimal10_2() || it.UnitSellingPrice < 0 {
		return errors.New("unit_selling_price invalid")
	}
	if it.UnitCostPrice != nil && (!it.UnitCostPrice.FitsDecimal10_2() || *it.UnitCostPrice < 0) {
		return errors.New("unit_cost_price invalid")
	}
	if it.TotalCost != nil && (!it.TotalCost.FitsDecimal10_2() || *it.TotalCost < 0) {
		return errors.New("total_cost invalid")
	}
	exp, err := normalizeDate(it.ExpiryDate)
	if err != nil {
		return fmt.Errorf("expiry_date: %w", err)
	}
	it.ExpiryDate = exp
	return nil
}

func validateStockMovement(sess auth.Session, r *StockMovementRecord) error {
	sign, ok := allowedMovementTypes[r.MovementType]
	if !ok {
		return newErr(http.StatusBadRequest, CodeBadRequest, fmt.Sprintf("invalid movement_type %q", r.MovementType))
	}
	if sess.Role == auth.RoleStaff && r.MovementType != "SALE" {
		return newErr(http.StatusForbidden, CodeForbidden, fmt.Sprintf("STAFF cannot push stock_movements of type %q", r.MovementType))
	}
	if !isUUID(r.BatchID) || strings.TrimSpace(r.StaffName) == "" {
		return newErr(http.StatusBadRequest, CodeBadRequest, "batch_id and staff_name are required")
	}
	var delta int
	switch {
	case r.QuantityChange != nil && r.Quantity != nil && *r.QuantityChange != *r.Quantity:
		return newErr(http.StatusBadRequest, CodeBadRequest, "quantity_change and quantity must match when both are provided")
	case r.QuantityChange != nil:
		delta = *r.QuantityChange
	case r.Quantity != nil:
		delta = *r.Quantity
	default:
		return newErr(http.StatusBadRequest, CodeBadRequest, "quantity_change (or quantity) is required")
	}
	if delta == 0 {
		return newErr(http.StatusBadRequest, CodeBadRequest, "quantity_change cannot be 0")
	}
	if sign < 0 && delta >= 0 {
		return newErr(http.StatusBadRequest, CodeBadRequest, fmt.Sprintf("%s movement requires negative quantity_change", r.MovementType))
	}
	if sign > 0 && delta <= 0 {
		return newErr(http.StatusBadRequest, CodeBadRequest, fmt.Sprintf("%s movement requires positive quantity_change", r.MovementType))
	}
	r.Quantity = &delta
	r.QuantityChange = &delta
	return nil
}

func validateSaleOrder(sess auth.Session, r *SaleOrderRecord) error {
	if strings.TrimSpace(r.BillNo) == "" || strings.TrimSpace(r.CashierName) == "" || strings.TrimSpace(r.PaymentMode) == "" {
		return newErr(http.StatusBadRequest, CodeBadRequest, "bill_no, cashier_name, and payment_mode are required")
	}
	if strings.TrimSpace(r.CashierUserID) == "" {
		r.CashierUserID = sess.UserID
	} else if !isUUID(r.CashierUserID) {
		return newErr(http.StatusBadRequest, CodeBadRequest, "cashier_user_id must be a UUID")
	} else if sess.Role == auth.RoleStaff && r.CashierUserID != sess.UserID {
		return newErr(http.StatusForbidden, CodeForbidden, "STAFF cannot record sales under another cashier_user_id")
	}
	if err := cleanOptionalUUID(&r.CustomerID, "customer_id"); err != nil {
		return newErr(http.StatusBadRequest, CodeBadRequest, err.Error())
	}
	if err := cleanOptionalUUID(&r.ShiftID, "shift_id"); err != nil {
		return newErr(http.StatusBadRequest, CodeBadRequest, err.Error())
	}
	if !r.Subtotal.FitsDecimal10_2() || !r.DiscountAmount.FitsDecimal10_2() || !r.TotalAmount.FitsDecimal10_2() ||
		r.Subtotal < 0 || r.DiscountAmount < 0 || r.TotalAmount < 0 {
		return newErr(http.StatusBadRequest, CodeBadRequest, "sale order monetary fields must be non-negative DECIMAL(10,2)")
	}
	if r.Subtotal-r.DiscountAmount != r.TotalAmount {
		return newErr(http.StatusBadRequest, CodeBadRequest, "subtotal - discount_amount must equal total_amount")
	}
	if r.CostTotal != nil && (!r.CostTotal.FitsDecimal10_2() || *r.CostTotal < 0) {
		return newErr(http.StatusBadRequest, CodeBadRequest, "cost_total must be non-negative DECIMAL(10,2)")
	}
	if r.NetProfit != nil && !r.NetProfit.FitsDecimal10_2() {
		return newErr(http.StatusBadRequest, CodeBadRequest, "net_profit exceeds DECIMAL(10,2)")
	}
	seenItems := make(map[string]bool, len(r.Items))
	for i := range r.Items {
		if err := validateSaleItem(&r.Items[i], r.ID); err != nil {
			return newErr(http.StatusBadRequest, CodeBadRequest, fmt.Sprintf("sale item[%d]: %v", i, err))
		}
		if seenItems[r.Items[i].ID] {
			return newErr(http.StatusBadRequest, CodeBadRequest, fmt.Sprintf("duplicate sale_item id %q", r.Items[i].ID))
		}
		seenItems[r.Items[i].ID] = true
	}
	seenPayments := make(map[string]bool, len(r.Payments))
	for i := range r.Payments {
		if err := validateSalePayment(&r.Payments[i], r.ID); err != nil {
			return newErr(http.StatusBadRequest, CodeBadRequest, fmt.Sprintf("sale payment[%d]: %v", i, err))
		}
		if seenPayments[r.Payments[i].ID] {
			return newErr(http.StatusBadRequest, CodeBadRequest, fmt.Sprintf("duplicate sale_payment id %q", r.Payments[i].ID))
		}
		seenPayments[r.Payments[i].ID] = true
	}
	seenMovs := make(map[string]bool, len(r.StockMovements))
	for i := range r.StockMovements {
		if !isUUID(r.StockMovements[i].ID) {
			return newErr(http.StatusBadRequest, CodeBadRequest, fmt.Sprintf("sale stock_movements[%d].id must be a UUID", i))
		}
		if err := validateStockMovement(sess, &r.StockMovements[i]); err != nil {
			return err
		}
		if seenMovs[r.StockMovements[i].ID] {
			return newErr(http.StatusBadRequest, CodeBadRequest, fmt.Sprintf("duplicate stock_movement id %q", r.StockMovements[i].ID))
		}
		seenMovs[r.StockMovements[i].ID] = true
	}
	return nil
}

func validateSaleItem(it *SaleItemRecord, parentID string) error {
	if parentID != "" && it.SaleOrderID == "" {
		it.SaleOrderID = parentID
	}
	if !isUUID(it.ID) || !isUUID(it.SaleOrderID) || !isUUID(it.BatchID) {
		return errors.New("id, sale_order_id, and batch_id must be UUIDs")
	}
	if parentID != "" && it.SaleOrderID != parentID {
		return errors.New("sale_order_id mismatch with parent")
	}
	if strings.TrimSpace(it.ProductName) == "" || strings.TrimSpace(it.VariantName) == "" || it.Quantity <= 0 {
		return errors.New("product_name, variant_name, and quantity > 0 required")
	}
	if !it.SellingPrice.FitsDecimal10_2() || !it.TotalPrice.FitsDecimal10_2() || it.SellingPrice < 0 || it.TotalPrice < 0 {
		return errors.New("price fields must be non-negative DECIMAL(10,2)")
	}
	if it.CostPrice != nil && (!it.CostPrice.FitsDecimal10_2() || *it.CostPrice < 0) {
		return errors.New("cost_price must be non-negative DECIMAL(10,2)")
	}
	return nil
}

func validateSalePayment(p *SalePaymentRecord, parentID string) error {
	if parentID != "" && p.SaleOrderID == "" {
		p.SaleOrderID = parentID
	}
	if !isUUID(p.ID) || !isUUID(p.SaleOrderID) || strings.TrimSpace(p.Method) == "" {
		return errors.New("id, sale_order_id, and method are required")
	}
	if parentID != "" && p.SaleOrderID != parentID {
		return errors.New("sale_order_id mismatch with parent")
	}
	if !p.Amount.FitsDecimal10_2() || p.Amount <= 0 {
		return errors.New("amount must be > 0 and fit DECIMAL(10,2)")
	}
	return nil
}

// ---------------------------------------------------------------- Tx Application

func resolveClientLWW(serverTS time.Time, pm preparedMutation) time.Time {
	cand := pm.clientTS
	if cand == nil {
		switch {
		case pm.product != nil:
			cand = pm.product.UpdatedAt
		case pm.variant != nil:
			cand = pm.variant.UpdatedAt
		case pm.batch != nil:
			cand = pm.batch.UpdatedAt
		case pm.customer != nil:
			cand = pm.customer.UpdatedAt
		case pm.shadeProf != nil:
			cand = pm.shadeProf.UpdatedAt
		case pm.supplier != nil:
			cand = pm.supplier.UpdatedAt
		}
	}
	return effectiveClientTS(serverTS, cand)
}

func applyPreparedMutation(ctx context.Context, tx pgx.Tx, sess auth.Session, ts time.Time, pm preparedMutation, recomputeOrders map[string]struct{}) ([]DiscrepancyAlert, error) {
	lwwTS := resolveClientLWW(ts, pm)
	switch pm.raw.TableName {
	case TableProducts:
		return nil, applyProduct(ctx, tx, sess, ts, lwwTS, pm.raw.Operation, pm.product)
	case TableProductVariants:
		return nil, applyProductVariant(ctx, tx, sess, ts, lwwTS, pm.raw.Operation, pm.variant)
	case TableBatches:
		return nil, applyBatch(ctx, tx, sess, ts, lwwTS, pm.raw.Operation, pm.batch)
	case TableCustomers:
		return nil, applyCustomer(ctx, tx, sess, ts, lwwTS, pm.raw.Operation, pm.customer)
	case TableCustomerShadeProfiles:
		return nil, applyCustomerShadeProfile(ctx, tx, sess, ts, lwwTS, pm.shadeProf)
	case TableCustomerTransactions:
		return nil, applyCustomerTransaction(ctx, tx, sess, ts, pm.customerTx)
	case TableSuppliers:
		return nil, applySupplier(ctx, tx, sess, ts, lwwTS, pm.raw.Operation, pm.supplier)
	case TablePurchaseInvoices:
		return nil, applyPurchaseInvoice(ctx, tx, sess, ts, pm.invoice)
	case TablePurchaseInvoiceItems:
		return nil, applyPurchaseInvoiceItem(ctx, tx, sess, ts, pm.invItem)
	case TableSupplierPayments:
		return nil, applySupplierPayment(ctx, tx, sess, ts, pm.supPayment)
	case TableStockMovements:
		disc, err := applyStockMovement(ctx, tx, sess, ts, pm.movement)
		if err != nil {
			return nil, err
		}
		if disc != nil {
			return []DiscrepancyAlert{*disc}, nil
		}
		return nil, nil
	case TableSaleOrders:
		return applySaleOrder(ctx, tx, sess, ts, pm.saleOrder, recomputeOrders)
	case TableSaleItems:
		return nil, applySaleItem(ctx, tx, sess, ts, pm.saleItem, recomputeOrders)
	case TableSalePayments:
		return nil, applySalePayment(ctx, tx, sess, ts, pm.salePay)
	case TableRegisterShifts:
		return nil, applyRegisterShift(ctx, tx, sess, ts, pm.raw.Operation, pm.regShift)
	case TableStaffShiftSessions:
		return nil, applyStaffShiftSession(ctx, tx, sess, ts, pm.raw.Operation, pm.staffSess)
	case TableExpenses:
		return nil, applyExpense(ctx, tx, sess, ts, pm.expense)
	default:
		return nil, newErr(http.StatusBadRequest, CodeBadRequest, "unsupported table")
	}
}

func ensureRowExists(ctx context.Context, tx pgx.Tx, table, id string) error {
	var exists bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM `+table+` WHERE id = $1)`, id).Scan(&exists); err != nil {
		return err
	}
	if !exists {
		return newErr(http.StatusUnprocessableEntity, CodeUnprocessable, table+" record not found for DELETE")
	}
	return nil
}

// checkSameStoreOrForbidden is called when an INSERT ... ON CONFLICT (id) returns 0 rows.
// Inside WithTenantTx(sess.StoreID), RLS hides rows owned by other stores:
// - exists == true  => row belongs to this store (LWW skipped or idempotent retry) -> nil
// - exists == false => primary key id belongs to another store -> 403 FORBIDDEN + audit log
func checkSameStoreOrForbidden(ctx context.Context, tx pgx.Tx, sess auth.Session, table, id string) error {
	var exists bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM `+table+` WHERE id = $1 AND store_id = $2)`, id, sess.StoreID).Scan(&exists); err != nil {
		return err
	}
	if exists {
		return nil
	}
	metaJSON, _ := json.Marshal(map[string]any{"table": table, "record_id": id})
	_, _ = tx.Exec(ctx, `
		INSERT INTO app_audit_logs (id, store_id, event_type, user_id, device_id, device_code, metadata)
		VALUES ($1, $2, 'CROSS_TENANT_ATTEMPT', $3, $4, $5, $6)`,
		uuid.NewString(), sess.StoreID, sess.UserID, sess.DeviceID, sess.DeviceCode, metaJSON)
	return newErr(http.StatusForbidden, CodeForbidden, "record id belongs to another store")
}

func requireStoreMember(ctx context.Context, tx pgx.Tx, storeID string, userIDs ...*string) error {
	for _, uid := range userIDs {
		if uid == nil || *uid == "" {
			continue
		}
		var ok bool
		if err := tx.QueryRow(ctx, `
			SELECT EXISTS (SELECT 1 FROM store_memberships WHERE store_id = $1 AND user_id = $2)`,
			storeID, *uid).Scan(&ok); err != nil {
			return err
		}
		if !ok {
			return newErr(http.StatusForbidden, CodeForbidden, "referenced user does not belong to this store")
		}
	}
	return nil
}

func applyProduct(ctx context.Context, tx pgx.Tx, sess auth.Session, ts, lwwTS time.Time, op string, r *ProductRecord) error {
	if op == OpDelete {
		delAt := ts
		if r.DeletedAt != nil {
			delAt = *r.DeletedAt
		}
		tag, err := tx.Exec(ctx, `
			UPDATE products
			SET deleted_at = COALESCE(deleted_at, $2), client_updated_at = $3, updated_at = GREATEST(COALESCE(updated_at, $4), $4)
			WHERE id = $1 AND store_id = $5 AND COALESCE(client_updated_at, created_at) <= $3`,
			r.ID, delAt, lwwTS, ts, sess.StoreID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ensureRowExists(ctx, tx, "products", r.ID)
		}
		return nil
	}
	createdAt := derefTimeOr(r.CreatedAt, ts)
	tag, err := tx.Exec(ctx, `
		INSERT INTO products (id, store_id, name, brand, category, is_generic, photo_url, created_at, updated_at, deleted_at, client_updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
		ON CONFLICT (id) DO UPDATE SET
			name = EXCLUDED.name,
			brand = EXCLUDED.brand,
			category = EXCLUDED.category,
			is_generic = EXCLUDED.is_generic,
			photo_url = EXCLUDED.photo_url,
			deleted_at = COALESCE(products.deleted_at, EXCLUDED.deleted_at),
			client_updated_at = EXCLUDED.client_updated_at,
			updated_at = GREATEST(COALESCE(products.updated_at, EXCLUDED.updated_at), EXCLUDED.updated_at)
		WHERE products.store_id = EXCLUDED.store_id
		  AND COALESCE(products.client_updated_at, products.created_at) <= EXCLUDED.client_updated_at`,
		r.ID, sess.StoreID, r.Name, r.Brand, r.Category, r.IsGeneric, r.PhotoURL, createdAt, ts, r.DeletedAt, lwwTS)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return checkSameStoreOrForbidden(ctx, tx, sess, "products", r.ID)
	}
	return nil
}

func applyProductVariant(ctx context.Context, tx pgx.Tx, sess auth.Session, ts, lwwTS time.Time, op string, r *ProductVariantRecord) error {
	if op == OpDelete {
		delAt := ts
		if r.DeletedAt != nil {
			delAt = *r.DeletedAt
		}
		tag, err := tx.Exec(ctx, `
			UPDATE product_variants
			SET deleted_at = COALESCE(deleted_at, $2), is_active = FALSE, client_updated_at = $3, updated_at = GREATEST(COALESCE(updated_at, $4), $4)
			WHERE id = $1 AND store_id = $5 AND COALESCE(client_updated_at, created_at) <= $3`,
			r.ID, delAt, lwwTS, ts, sess.StoreID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ensureRowExists(ctx, tx, "product_variants", r.ID)
		}
		return nil
	}
	isActive := true
	if r.IsActive != nil {
		isActive = *r.IsActive
	}
	createdAt := derefTimeOr(r.CreatedAt, ts)
	tag, err := tx.Exec(ctx, `
		INSERT INTO product_variants (id, store_id, product_id, variant_name, size_volume, color_hex, attributes, is_active, created_at, updated_at, deleted_at, client_updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb, $8, $9, $10, $11, $12)
		ON CONFLICT (id) DO UPDATE SET
			product_id = EXCLUDED.product_id,
			variant_name = EXCLUDED.variant_name,
			size_volume = EXCLUDED.size_volume,
			color_hex = EXCLUDED.color_hex,
			attributes = EXCLUDED.attributes,
			is_active = CASE WHEN COALESCE(product_variants.deleted_at, EXCLUDED.deleted_at) IS NOT NULL THEN FALSE ELSE EXCLUDED.is_active END,
			deleted_at = COALESCE(product_variants.deleted_at, EXCLUDED.deleted_at),
			client_updated_at = EXCLUDED.client_updated_at,
			updated_at = GREATEST(COALESCE(product_variants.updated_at, EXCLUDED.updated_at), EXCLUDED.updated_at)
		WHERE product_variants.store_id = EXCLUDED.store_id
		  AND COALESCE(product_variants.client_updated_at, product_variants.created_at) <= EXCLUDED.client_updated_at`,
		r.ID, sess.StoreID, r.ProductID, r.VariantName, r.SizeVolume, r.ColorHex, string(r.Attributes), isActive, createdAt, ts, r.DeletedAt, lwwTS)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return checkSameStoreOrForbidden(ctx, tx, sess, "product_variants", r.ID)
	}
	return nil
}

func applyBatch(ctx context.Context, tx pgx.Tx, sess auth.Session, ts, lwwTS time.Time, op string, r *BatchRecord) error {
	if op == OpDelete {
		delAt := ts
		if r.DeletedAt != nil {
			delAt = *r.DeletedAt
		}
		tag, err := tx.Exec(ctx, `
			UPDATE batches
			SET deleted_at = COALESCE(deleted_at, $2), client_updated_at = $3, updated_at = GREATEST(COALESCE(updated_at, $4), $4)
			WHERE id = $1 AND store_id = $5 AND COALESCE(client_updated_at, created_at) <= $3`,
			r.ID, delAt, lwwTS, ts, sess.StoreID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ensureRowExists(ctx, tx, "batches", r.ID)
		}
		return nil
	}
	costStr := "0.00"
	hasOwnerCost := sess.Role == auth.RoleOwner && r.CostPrice != nil
	if hasOwnerCost {
		costStr = r.CostPrice.String()
	}
	createdAt := derefTimeOr(r.CreatedAt, ts)
	// stock_quantity ALWAYS starts at 0 on insert and is NEVER overwritten on update:
	// stock changes exclusively arrive as atomic deltas via stock_movements.
	tag, err := tx.Exec(ctx, `
		INSERT INTO batches
			(id, store_id, variant_id, supplier_id, purchase_invoice_id, batch_code, sticker_barcode,
			 cost_price, selling_price, stock_quantity, expiry_date, created_at, updated_at, deleted_at, client_updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 0, $10::date, $11, $12, $13, $14)
		ON CONFLICT (id) DO UPDATE SET
			variant_id = EXCLUDED.variant_id,
			supplier_id = COALESCE(EXCLUDED.supplier_id, batches.supplier_id),
			purchase_invoice_id = COALESCE(EXCLUDED.purchase_invoice_id, batches.purchase_invoice_id),
			batch_code = EXCLUDED.batch_code,
			sticker_barcode = EXCLUDED.sticker_barcode,
			cost_price = CASE WHEN $15 THEN EXCLUDED.cost_price ELSE batches.cost_price END,
			selling_price = EXCLUDED.selling_price,
			expiry_date = EXCLUDED.expiry_date,
			deleted_at = COALESCE(batches.deleted_at, EXCLUDED.deleted_at),
			client_updated_at = EXCLUDED.client_updated_at,
			updated_at = GREATEST(COALESCE(batches.updated_at, EXCLUDED.updated_at), EXCLUDED.updated_at)
		WHERE batches.store_id = EXCLUDED.store_id
		  AND COALESCE(batches.client_updated_at, batches.created_at) <= EXCLUDED.client_updated_at`,
		r.ID, sess.StoreID, r.VariantID, r.SupplierID, r.PurchaseInvoiceID, r.BatchCode, r.StickerBarcode,
		costStr, r.SellingPrice.String(), r.ExpiryDate, createdAt, ts, r.DeletedAt, lwwTS, hasOwnerCost)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return checkSameStoreOrForbidden(ctx, tx, sess, "batches", r.ID)
	}
	return nil
}

func applyCustomer(ctx context.Context, tx pgx.Tx, sess auth.Session, ts, lwwTS time.Time, op string, r *CustomerRecord) error {
	if op == OpDelete {
		delAt := ts
		if r.DeletedAt != nil {
			delAt = *r.DeletedAt
		}
		tag, err := tx.Exec(ctx, `
			UPDATE customers
			SET deleted_at = COALESCE(deleted_at, $2), client_updated_at = $3, updated_at = GREATEST(COALESCE(updated_at, $4), $4)
			WHERE id = $1 AND store_id = $5 AND COALESCE(client_updated_at, created_at) <= $3`,
			r.ID, delAt, lwwTS, ts, sess.StoreID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ensureRowExists(ctx, tx, "customers", r.ID)
		}
		return nil
	}
	creditLimit := "10000.00"
	hasCreditLimit := r.CreditLimit != nil
	if hasCreditLimit {
		creditLimit = r.CreditLimit.String()
	}
	canUpdateCreditLimit := (sess.Role == auth.RoleOwner || sess.Role == auth.RoleManager) && hasCreditLimit
	createdAt := derefTimeOr(r.CreatedAt, ts)
	// current_balance_due initializes to 0.00 and only changes atomically via customer_transactions.
	tag, err := tx.Exec(ctx, `
		INSERT INTO customers
			(id, store_id, name, phone, address, credit_limit, current_balance_due, favorite_shade_notes, created_at, updated_at, deleted_at, client_updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, 0.00, $7, $8, $9, $10, $11)
		ON CONFLICT (id) DO UPDATE SET
			name = EXCLUDED.name,
			phone = EXCLUDED.phone,
			address = EXCLUDED.address,
			credit_limit = CASE WHEN $12 THEN EXCLUDED.credit_limit ELSE customers.credit_limit END,
			favorite_shade_notes = EXCLUDED.favorite_shade_notes,
			deleted_at = COALESCE(customers.deleted_at, EXCLUDED.deleted_at),
			client_updated_at = EXCLUDED.client_updated_at,
			updated_at = GREATEST(COALESCE(customers.updated_at, EXCLUDED.updated_at), EXCLUDED.updated_at)
		WHERE customers.store_id = EXCLUDED.store_id
		  AND COALESCE(customers.client_updated_at, customers.created_at) <= EXCLUDED.client_updated_at`,
		r.ID, sess.StoreID, r.Name, r.Phone, r.Address, creditLimit, r.FavoriteShadeNotes, createdAt, ts, r.DeletedAt, lwwTS, canUpdateCreditLimit)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return checkSameStoreOrForbidden(ctx, tx, sess, "customers", r.ID)
	}
	return nil
}

func applyCustomerShadeProfile(ctx context.Context, tx pgx.Tx, sess auth.Session, ts, lwwTS time.Time, r *CustomerShadeProfileRecord) error {
	createdAt := derefTimeOr(r.CreatedAt, ts)
	tag, err := tx.Exec(ctx, `
		INSERT INTO customer_shade_profiles (id, store_id, customer_id, product_name, brand, shade_variant, notes, created_at, updated_at, client_updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
		ON CONFLICT (id) DO UPDATE SET
			customer_id = EXCLUDED.customer_id,
			product_name = EXCLUDED.product_name,
			brand = EXCLUDED.brand,
			shade_variant = EXCLUDED.shade_variant,
			notes = EXCLUDED.notes,
			client_updated_at = EXCLUDED.client_updated_at,
			updated_at = GREATEST(COALESCE(customer_shade_profiles.updated_at, EXCLUDED.updated_at), EXCLUDED.updated_at)
		WHERE customer_shade_profiles.store_id = EXCLUDED.store_id
		  AND COALESCE(customer_shade_profiles.client_updated_at, customer_shade_profiles.created_at) <= EXCLUDED.client_updated_at`,
		r.ID, sess.StoreID, r.CustomerID, r.ProductName, r.Brand, r.ShadeVariant, r.Notes, createdAt, ts, lwwTS)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return checkSameStoreOrForbidden(ctx, tx, sess, "customer_shade_profiles", r.ID)
	}
	return nil
}

func applyCustomerTransaction(ctx context.Context, tx pgx.Tx, sess auth.Session, ts time.Time, r *CustomerTransactionRecord) error {
	if err := requireStoreMember(ctx, tx, sess.StoreID, r.CreatedByUserID); err != nil {
		return err
	}
	var curBalStr string
	err := tx.QueryRow(ctx, `SELECT current_balance_due::text FROM customers WHERE id = $1 AND store_id = $2 FOR UPDATE`, r.CustomerID, sess.StoreID).Scan(&curBalStr)
	if errors.Is(err, pgx.ErrNoRows) {
		return newErr(http.StatusUnprocessableEntity, CodeUnprocessable, "customer_id not found")
	}
	if err != nil {
		return err
	}
	curBal, err := ParseMoney(curBalStr)
	if err != nil {
		return err
	}
	delta := r.Amount
	if r.Type == "CREDIT_REPAYMENT" {
		delta = -delta
	}
	newBal, ok := curBal.AddChecked(delta)
	if !ok || !newBal.FitsDecimal10_2() {
		return newErr(http.StatusBadRequest, CodeBadRequest, "customer balance exceeds DECIMAL(10,2) bounds")
	}

	createdAt := derefTimeOr(r.CreatedAt, ts)
	tag, err := tx.Exec(ctx, `
		INSERT INTO customer_transactions
			(id, store_id, customer_id, type, amount, balance_after, reference_bill_no, payment_method, notes, created_by_user_id, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
		ON CONFLICT (id) DO NOTHING`,
		r.ID, sess.StoreID, r.CustomerID, r.Type, r.Amount.String(), newBal.String(), r.ReferenceBillNo, r.PaymentMethod, r.Notes, r.CreatedByUserID, createdAt, ts)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return checkSameStoreOrForbidden(ctx, tx, sess, "customer_transactions", r.ID)
	}

	if _, err := tx.Exec(ctx, `
		UPDATE customers SET current_balance_due = $2, updated_at = GREATEST(COALESCE(updated_at, $3), $3) WHERE id = $1 AND store_id = $4`,
		r.CustomerID, newBal.String(), ts, sess.StoreID); err != nil {
		return err
	}

	if r.Type == "CREDIT_REPAYMENT" && r.PaymentMethod != nil && *r.PaymentMethod == "CASH" && r.ShiftID != nil {
		shiftTag, err := tx.Exec(ctx, `
			UPDATE register_shifts
			SET khata_cash_repayments = khata_cash_repayments + $2,
			    expected_cash = expected_cash + $2,
			    updated_at = GREATEST(COALESCE(updated_at, $3), $3)
			WHERE id = $1 AND store_id = $4`,
			*r.ShiftID, r.Amount.String(), ts, sess.StoreID)
		if err != nil {
			return err
		}
		if shiftTag.RowsAffected() == 0 {
			return newErr(http.StatusUnprocessableEntity, CodeUnprocessable, "shift_id not found for cash repayment")
		}
	}
	return nil
}

func applySupplier(ctx context.Context, tx pgx.Tx, sess auth.Session, ts, lwwTS time.Time, op string, r *SupplierRecord) error {
	if op == OpDelete {
		delAt := ts
		if r.DeletedAt != nil {
			delAt = *r.DeletedAt
		}
		tag, err := tx.Exec(ctx, `
			UPDATE suppliers
			SET deleted_at = COALESCE(deleted_at, $2), client_updated_at = $3, updated_at = GREATEST(COALESCE(updated_at, $4), $4)
			WHERE id = $1 AND store_id = $5 AND COALESCE(client_updated_at, created_at) <= $3`,
			r.ID, delAt, lwwTS, ts, sess.StoreID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ensureRowExists(ctx, tx, "suppliers", r.ID)
		}
		return nil
	}
	createdAt := derefTimeOr(r.CreatedAt, ts)
	// Supplier financial ledgers (total_purchased/total_paid/balance_due) only change
	// via purchase_invoices & supplier_payments.
	tag, err := tx.Exec(ctx, `
		INSERT INTO suppliers (id, store_id, name, phone, pan_vat, address, total_purchased, total_paid, balance_due, created_at, updated_at, deleted_at, client_updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, 0.00, 0.00, 0.00, $7, $8, $9, $10)
		ON CONFLICT (id) DO UPDATE SET
			name = EXCLUDED.name,
			phone = EXCLUDED.phone,
			pan_vat = EXCLUDED.pan_vat,
			address = EXCLUDED.address,
			deleted_at = COALESCE(suppliers.deleted_at, EXCLUDED.deleted_at),
			client_updated_at = EXCLUDED.client_updated_at,
			updated_at = GREATEST(COALESCE(suppliers.updated_at, EXCLUDED.updated_at), EXCLUDED.updated_at)
		WHERE suppliers.store_id = EXCLUDED.store_id
		  AND COALESCE(suppliers.client_updated_at, suppliers.created_at) <= EXCLUDED.client_updated_at`,
		r.ID, sess.StoreID, r.Name, r.Phone, r.PanVAT, r.Address, createdAt, ts, r.DeletedAt, lwwTS)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return checkSameStoreOrForbidden(ctx, tx, sess, "suppliers", r.ID)
	}
	return nil
}

func applyPurchaseInvoice(ctx context.Context, tx pgx.Tx, sess auth.Session, ts time.Time, r *PurchaseInvoiceRecord) error {
	if err := requireStoreMember(ctx, tx, sess.StoreID, r.CreatedByUserID); err != nil {
		return err
	}
	createdAt := derefTimeOr(r.CreatedAt, ts)
	tag, err := tx.Exec(ctx, `
		INSERT INTO purchase_invoices
			(id, store_id, supplier_id, invoice_no, invoice_date, total_amount, paid_amount, due_amount, status, notes, created_by_user_id, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5::date, $6, $7, $8, $9, $10, $11, $12, $13)
		ON CONFLICT (id) DO NOTHING`,
		r.ID, sess.StoreID, r.SupplierID, r.InvoiceNo, r.InvoiceDate, r.TotalAmount.String(), r.PaidAmount.String(), r.DueAmount.String(),
		r.Status, r.Notes, r.CreatedByUserID, createdAt, ts)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return checkSameStoreOrForbidden(ctx, tx, sess, "purchase_invoices", r.ID)
	}
	updTag, err := tx.Exec(ctx, `
		UPDATE suppliers
		SET total_purchased = total_purchased + $2,
		    total_paid = total_paid + $3,
		    balance_due = balance_due + $4,
		    updated_at = GREATEST(COALESCE(updated_at, $5), $5)
		WHERE id = $1 AND store_id = $6`,
		r.SupplierID, r.TotalAmount.String(), r.PaidAmount.String(), r.DueAmount.String(), ts, sess.StoreID)
	if err != nil {
		return err
	}
	if updTag.RowsAffected() == 0 {
		return newErr(http.StatusUnprocessableEntity, CodeUnprocessable, "supplier_id not found")
	}
	for i := range r.Items {
		if err := applyPurchaseInvoiceItem(ctx, tx, sess, ts, &r.Items[i]); err != nil {
			return err
		}
	}
	return nil
}

func applyPurchaseInvoiceItem(ctx context.Context, tx pgx.Tx, sess auth.Session, ts time.Time, r *PurchaseInvoiceItemRecord) error {
	unitCost := "0.00"
	if r.UnitCostPrice != nil {
		unitCost = r.UnitCostPrice.String()
	}
	totalCost := "0.00"
	if r.TotalCost != nil {
		totalCost = r.TotalCost.String()
	}
	createdAt := derefTimeOr(r.CreatedAt, ts)
	tag, err := tx.Exec(ctx, `
		INSERT INTO purchase_invoice_items
			(id, store_id, purchase_invoice_id, variant_id, batch_id, product_name, variant_name,
			 quantity_received, unit_cost_price, unit_selling_price, total_cost, batch_code, expiry_date, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13::date, $14, $15)
		ON CONFLICT (id) DO NOTHING`,
		r.ID, sess.StoreID, r.PurchaseInvoiceID, r.VariantID, r.BatchID, r.ProductName, r.VariantName,
		r.QuantityReceived, unitCost, r.UnitSellingPrice.String(), totalCost, r.BatchCode, r.ExpiryDate, createdAt, ts)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return checkSameStoreOrForbidden(ctx, tx, sess, "purchase_invoice_items", r.ID)
	}
	return nil
}

func applySupplierPayment(ctx context.Context, tx pgx.Tx, sess auth.Session, ts time.Time, r *SupplierPaymentRecord) error {
	if err := requireStoreMember(ctx, tx, sess.StoreID, r.CreatedByUserID); err != nil {
		return err
	}
	createdAt := derefTimeOr(r.CreatedAt, ts)
	tag, err := tx.Exec(ctx, `
		INSERT INTO supplier_payments
			(id, store_id, supplier_id, purchase_invoice_id, amount, payment_method, reference_no, created_by_user_id, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
		ON CONFLICT (id) DO NOTHING`,
		r.ID, sess.StoreID, r.SupplierID, r.PurchaseInvoiceID, r.Amount.String(), r.PaymentMethod, r.ReferenceNo, r.CreatedByUserID, createdAt, ts)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return checkSameStoreOrForbidden(ctx, tx, sess, "supplier_payments", r.ID)
	}
	if r.PurchaseInvoiceID != nil {
		var invSupplierID, invDueStr string
		err := tx.QueryRow(ctx, `SELECT supplier_id, due_amount::text FROM purchase_invoices WHERE id = $1 AND store_id = $2 FOR UPDATE`, *r.PurchaseInvoiceID, sess.StoreID).Scan(&invSupplierID, &invDueStr)
		if errors.Is(err, pgx.ErrNoRows) {
			return newErr(http.StatusUnprocessableEntity, CodeUnprocessable, "purchase_invoice_id not found")
		}
		if err != nil {
			return err
		}
		if invSupplierID != r.SupplierID {
			return newErr(http.StatusUnprocessableEntity, CodeUnprocessable, "purchase_invoice_id does not belong to supplier_id")
		}
		invDue, err := ParseMoney(invDueStr)
		if err != nil {
			return err
		}
		if r.Amount > invDue {
			return newErr(http.StatusBadRequest, CodeBadRequest, "supplier payment amount exceeds invoice due_amount")
		}
		if _, err := tx.Exec(ctx, `
			UPDATE purchase_invoices
			SET paid_amount = paid_amount + $2,
			    due_amount = due_amount - $2,
			    status = CASE WHEN due_amount - $2 <= 0.00 THEN 'PAID' ELSE 'PARTIAL' END,
			    updated_at = GREATEST(COALESCE(updated_at, $3), $3)
			WHERE id = $1 AND store_id = $5 AND supplier_id = $4`, *r.PurchaseInvoiceID, r.Amount.String(), ts, r.SupplierID, sess.StoreID); err != nil {
			return err
		}
	}
	supTag, err := tx.Exec(ctx, `
		UPDATE suppliers
		SET total_paid = total_paid + $2,
		    balance_due = balance_due - $2,
		    updated_at = GREATEST(COALESCE(updated_at, $3), $3)
		WHERE id = $1 AND store_id = $4`, r.SupplierID, r.Amount.String(), ts, sess.StoreID)
	if err != nil {
		return err
	}
	if supTag.RowsAffected() == 0 {
		return newErr(http.StatusUnprocessableEntity, CodeUnprocessable, "supplier_id not found")
	}
	return nil
}

func applyStockMovement(ctx context.Context, tx pgx.Tx, sess auth.Session, ts time.Time, r *StockMovementRecord) (*DiscrepancyAlert, error) {
	delta := *r.QuantityChange
	createdAt := derefTimeOr(r.CreatedAt, ts)
	tag, err := tx.Exec(ctx, `
		INSERT INTO stock_movements (id, store_id, batch_id, movement_type, quantity, reference_id, reason, staff_name, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
		ON CONFLICT (id) DO NOTHING`,
		r.ID, sess.StoreID, r.BatchID, r.MovementType, delta, r.ReferenceID, r.Reason, r.StaffName, createdAt, ts)
	if err != nil {
		return nil, err
	}
	if tag.RowsAffected() == 0 {
		if err := checkSameStoreOrForbidden(ctx, tx, sess, "stock_movements", r.ID); err != nil {
			return nil, err
		}
		// Duplicate stock_movement UUID in same store: zero double-deduction.
		return nil, nil
	}

	var postQty int
	err = tx.QueryRow(ctx, `
		UPDATE batches
		SET stock_quantity = stock_quantity + $2,
		    updated_at = GREATEST(COALESCE(updated_at, $3), $3)
		WHERE id = $1 AND store_id = $4
		RETURNING stock_quantity`,
		r.BatchID, delta, ts, sess.StoreID).Scan(&postQty)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, newErr(http.StatusUnprocessableEntity, CodeUnprocessable, "batch_id not found")
	}
	if err != nil {
		return nil, err
	}

	preQty := postQty - delta
	isDisc := postQty < 0
	auditOp := mapAuditOp(r.MovementType)
	auditID := uuid.NewString()

	if _, err := tx.Exec(ctx, `
		INSERT INTO inventory_sync_audit
			(id, store_id, batch_id, device_id, device_code, operation, quantity_change, pre_sync_qty, post_sync_qty, is_discrepancy, reference_id, stock_movement_id, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $13)
		ON CONFLICT (store_id, stock_movement_id) DO NOTHING`,
		auditID, sess.StoreID, r.BatchID, sess.DeviceID, sess.DeviceCode, auditOp, delta, preQty, postQty, isDisc, r.ReferenceID, r.ID, ts); err != nil {
		return nil, err
	}

	if !isDisc {
		return nil, nil
	}
	var ref string
	if r.ReferenceID != nil {
		ref = *r.ReferenceID
	}
	return &DiscrepancyAlert{
		AuditID:        auditID,
		BatchID:        r.BatchID,
		StockMovement:  r.ID,
		DeviceCode:     sess.DeviceCode,
		PreSyncQty:     preQty,
		PostSyncQty:    postQty,
		QuantityChange: delta,
		ReferenceID:    ref,
	}, nil
}

func mapAuditOp(movementType string) string {
	switch movementType {
	case "SALE":
		return "PUSH_SALE"
	case "PURCHASE_INTAKE":
		return "PUSH_INTAKE"
	default:
		return "CORRECTION"
	}
}

func applySaleOrder(ctx context.Context, tx pgx.Tx, sess auth.Session, ts time.Time, r *SaleOrderRecord, recomputeOrders map[string]struct{}) ([]DiscrepancyAlert, error) {
	if err := requireStoreMember(ctx, tx, sess.StoreID, &r.CashierUserID); err != nil {
		return nil, err
	}
	createdAt := derefTimeOr(r.CreatedAt, ts)
	costTotal := Money(0)
	netProfit := r.TotalAmount
	needRecompute := false
	if sess.Role == auth.RoleOwner && r.CostTotal != nil {
		costTotal = *r.CostTotal
		if r.NetProfit != nil {
			netProfit = *r.NetProfit
		} else {
			netProfit = r.TotalAmount - costTotal
		}
	} else {
		needRecompute = true
	}

	tag, err := tx.Exec(ctx, `
		INSERT INTO sale_orders
			(id, store_id, bill_no, customer_id, customer_name, customer_phone, cashier_user_id, cashier_name, shift_id,
			 subtotal, discount_amount, total_amount, cost_total, net_profit, payment_mode, sync_status, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, 'SYNCED', $16, $17)
		ON CONFLICT (id) DO NOTHING`,
		r.ID, sess.StoreID, r.BillNo, r.CustomerID, r.CustomerName, r.CustomerPhone, r.CashierUserID, r.CashierName, r.ShiftID,
		r.Subtotal.String(), r.DiscountAmount.String(), r.TotalAmount.String(), costTotal.String(), netProfit.String(),
		r.PaymentMode, createdAt, ts)
	if err != nil {
		return nil, err
	}
	if tag.RowsAffected() == 0 {
		return nil, checkSameStoreOrForbidden(ctx, tx, sess, "sale_orders", r.ID)
	}
	if needRecompute || len(r.Items) > 0 {
		// Recompute from authoritative sale_items cost_price at the end of the push tx.
		recomputeOrders[r.ID] = struct{}{}
	}

	for i := range r.Items {
		if err := applySaleItem(ctx, tx, sess, ts, &r.Items[i], recomputeOrders); err != nil {
			return nil, err
		}
	}
	for i := range r.Payments {
		if err := applySalePayment(ctx, tx, sess, ts, &r.Payments[i]); err != nil {
			return nil, err
		}
	}
	var alerts []DiscrepancyAlert
	for i := range r.StockMovements {
		disc, err := applyStockMovement(ctx, tx, sess, ts, &r.StockMovements[i])
		if err != nil {
			return nil, err
		}
		if disc != nil {
			alerts = append(alerts, *disc)
		}
	}
	return alerts, nil
}

func applySaleItem(ctx context.Context, tx pgx.Tx, sess auth.Session, ts time.Time, r *SaleItemRecord, recomputeOrders map[string]struct{}) error {
	var costPrice Money
	if sess.Role == auth.RoleOwner && r.CostPrice != nil {
		costPrice = *r.CostPrice
	} else {
		var costStr string
		err := tx.QueryRow(ctx, `SELECT cost_price::text FROM batches WHERE id = $1 AND store_id = $2`, r.BatchID, sess.StoreID).Scan(&costStr)
		if errors.Is(err, pgx.ErrNoRows) {
			return newErr(http.StatusUnprocessableEntity, CodeUnprocessable, "batch_id not found for sale item")
		}
		if err != nil {
			return err
		}
		costPrice, err = ParseMoney(costStr)
		if err != nil {
			return err
		}
	}

	tag, err := tx.Exec(ctx, `
		INSERT INTO sale_items
			(id, store_id, sale_order_id, batch_id, product_name, variant_name, quantity, cost_price, selling_price, total_price)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
		ON CONFLICT (id) DO NOTHING`,
		r.ID, sess.StoreID, r.SaleOrderID, r.BatchID, r.ProductName, r.VariantName, r.Quantity,
		costPrice.String(), r.SellingPrice.String(), r.TotalPrice.String())
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return checkSameStoreOrForbidden(ctx, tx, sess, "sale_items", r.ID)
	}
	recomputeOrders[r.SaleOrderID] = struct{}{}
	return nil
}

func applySalePayment(ctx context.Context, tx pgx.Tx, sess auth.Session, ts time.Time, r *SalePaymentRecord) error {
	tag, err := tx.Exec(ctx, `
		INSERT INTO sale_payments (id, store_id, sale_order_id, method, amount, transaction_ref)
		VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (id) DO NOTHING`,
		r.ID, sess.StoreID, r.SaleOrderID, r.Method, r.Amount.String(), r.TransactionRef)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return checkSameStoreOrForbidden(ctx, tx, sess, "sale_payments", r.ID)
	}

	var shiftID *string
	err = tx.QueryRow(ctx, `UPDATE sale_orders SET updated_at = GREATEST(COALESCE(updated_at, $2), $2) WHERE id = $1 AND store_id = $3 RETURNING shift_id`, r.SaleOrderID, ts, sess.StoreID).Scan(&shiftID)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return err
	}
	if shiftID == nil {
		return nil
	}

	var shiftTag pgconn.CommandTag
	switch r.Method {
	case "CASH":
		shiftTag, err = tx.Exec(ctx, `
			UPDATE register_shifts
			SET cash_sales = cash_sales + $2, expected_cash = expected_cash + $2, updated_at = GREATEST(COALESCE(updated_at, $3), $3)
			WHERE id = $1 AND store_id = $4`, *shiftID, r.Amount.String(), ts, sess.StoreID)
	case "FONEPAY_QR", "CARD":
		shiftTag, err = tx.Exec(ctx, `
			UPDATE register_shifts
			SET digital_sales = digital_sales + $2, updated_at = GREATEST(COALESCE(updated_at, $3), $3)
			WHERE id = $1 AND store_id = $4`, *shiftID, r.Amount.String(), ts, sess.StoreID)
	default:
		return nil
	}
	if err != nil {
		return err
	}
	if shiftTag.RowsAffected() == 0 {
		return newErr(http.StatusUnprocessableEntity, CodeUnprocessable, "shift_id not found for sale payment")
	}
	return nil
}

func applyRegisterShift(ctx context.Context, tx pgx.Tx, sess auth.Session, ts time.Time, op string, r *RegisterShiftRecord) error {
	if err := requireStoreMember(ctx, tx, sess.StoreID, &r.OpenedByUserID, r.ClosedByUserID); err != nil {
		return err
	}
	if op == OpInsert && r.Status == "OPEN" {
		openedAt := derefTimeOr(r.OpenedAt, ts)
		createdAt := derefTimeOr(r.CreatedAt, ts)
		tag, err := tx.Exec(ctx, `
			INSERT INTO register_shifts
				(id, store_id, opened_by_user_id, opened_at, opening_float, cash_sales, digital_sales,
				 khata_cash_repayments, cash_expenses, expected_cash, status, notes, created_at, updated_at)
			VALUES ($1, $2, $3, $4, $5, 0.00, 0.00, 0.00, 0.00, $5, 'OPEN', $6, $7, $8)
			ON CONFLICT (id) DO NOTHING`,
			r.ID, sess.StoreID, r.OpenedByUserID, openedAt, r.OpeningFloat.String(), r.Notes, createdAt, ts)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return checkSameStoreOrForbidden(ctx, tx, sess, "register_shifts", r.ID)
		}
		return nil
	}

	var curStatus, expStr string
	err := tx.QueryRow(ctx, `SELECT status, expected_cash::text FROM register_shifts WHERE id = $1 AND store_id = $2 FOR UPDATE`, r.ID, sess.StoreID).Scan(&curStatus, &expStr)
	if errors.Is(err, pgx.ErrNoRows) {
		return newErr(http.StatusUnprocessableEntity, CodeUnprocessable, "register_shift not found")
	}
	if err != nil {
		return err
	}
	if curStatus == "CLOSED" {
		return nil
	}
	expectedCash, err := ParseMoney(expStr)
	if err != nil {
		return err
	}

	var discStr *string
	if r.ActualCashCounted != nil {
		disc := *r.ActualCashCounted - expectedCash
		if !disc.FitsDecimal10_2() {
			return newErr(http.StatusBadRequest, CodeBadRequest, "discrepancy exceeds DECIMAL(10,2)")
		}
		s := disc.String()
		discStr = &s
	}
	var actualStr *string
	if r.ActualCashCounted != nil {
		s := r.ActualCashCounted.String()
		actualStr = &s
	}
	closedAt := r.ClosedAt
	if r.Status == "CLOSED" && closedAt == nil {
		closedAt = &ts
	}

	if _, err := tx.Exec(ctx, `
		UPDATE register_shifts
		SET closed_by_user_id = COALESCE($2, closed_by_user_id),
		    closed_at = COALESCE($3, closed_at),
		    actual_cash_counted = COALESCE($4::numeric, actual_cash_counted),
		    discrepancy = COALESCE($5::numeric, discrepancy),
		    cash_withdrawn_deposit = $6,
		    retained_next_day_float = $7,
		    status = $8,
		    notes = COALESCE($9, notes),
		    updated_at = GREATEST(COALESCE(updated_at, $10), $10)
		WHERE id = $1 AND store_id = $11`,
		r.ID, r.ClosedByUserID, closedAt, actualStr, discStr,
		r.CashWithdrawnDeposit.String(), r.RetainedNextDayFloat.String(), r.Status, r.Notes, ts, sess.StoreID); err != nil {
		return err
	}
	if r.Status == "CLOSED" {
		metaJSON, _ := json.Marshal(map[string]any{"shift_id": r.ID, "expected_cash": expectedCash.String()})
		_, err = tx.Exec(ctx, `
			INSERT INTO app_audit_logs (id, store_id, event_type, user_id, device_id, device_code, metadata)
			VALUES ($1, $2, 'ZREPORT_CLOSED', $3, $4, $5, $6)`,
			uuid.NewString(), sess.StoreID, sess.UserID, sess.DeviceID, sess.DeviceCode, metaJSON)
		return err
	}
	return nil
}

func applyStaffShiftSession(ctx context.Context, tx pgx.Tx, sess auth.Session, ts time.Time, op string, r *StaffShiftSessionRecord) error {
	if err := requireStoreMember(ctx, tx, sess.StoreID, &r.UserID, r.ForceClosedByUserID); err != nil {
		return err
	}
	if op == OpInsert {
		punchedIn := derefTimeOr(r.PunchedInAt, ts)
		tag, err := tx.Exec(ctx, `
			INSERT INTO staff_shift_sessions
				(id, store_id, register_shift_id, user_id, device_id, device_code, punched_in_at, punched_out_at, last_synced_at, status, force_closed_by_user_id, updated_at)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $9)
			ON CONFLICT (id) DO NOTHING`,
			r.ID, sess.StoreID, r.RegisterShiftID, r.UserID, sess.DeviceID, sess.DeviceCode, punchedIn, r.PunchedOutAt, ts, r.Status, r.ForceClosedByUserID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return checkSameStoreOrForbidden(ctx, tx, sess, "staff_shift_sessions", r.ID)
		}
		return nil
	}

	var existingUserID string
	err := tx.QueryRow(ctx, `SELECT user_id FROM staff_shift_sessions WHERE id = $1 AND store_id = $2 FOR UPDATE`, r.ID, sess.StoreID).Scan(&existingUserID)
	if errors.Is(err, pgx.ErrNoRows) {
		return newErr(http.StatusUnprocessableEntity, CodeUnprocessable, "staff_shift_session not found")
	}
	if err != nil {
		return err
	}
	if sess.Role == auth.RoleStaff && existingUserID != sess.UserID {
		return newErr(http.StatusForbidden, CodeForbidden, "STAFF cannot modify another user's shift session")
	}

	punchedOutAt := r.PunchedOutAt
	if (r.Status == "PUNCHED_OUT" || r.Status == "FORCE_CLOSED") && punchedOutAt == nil {
		punchedOutAt = &ts
	}
	if _, err := tx.Exec(ctx, `
		UPDATE staff_shift_sessions
		SET punched_out_at = COALESCE($2, punched_out_at),
		    last_synced_at = $3,
		    status = $4,
		    force_closed_by_user_id = COALESCE($5, force_closed_by_user_id),
		    updated_at = GREATEST(COALESCE(updated_at, $3), $3)
		WHERE id = $1 AND store_id = $6`,
		r.ID, punchedOutAt, ts, r.Status, r.ForceClosedByUserID, sess.StoreID); err != nil {
		return err
	}
	if r.Status == "FORCE_CLOSED" {
		metaJSON, _ := json.Marshal(map[string]any{"session_id": r.ID, "target_user_id": existingUserID})
		_, err = tx.Exec(ctx, `
			INSERT INTO app_audit_logs (id, store_id, event_type, user_id, device_id, device_code, metadata)
			VALUES ($1, $2, 'FORCE_PUNCHOUT', $3, $4, $5, $6)`,
			uuid.NewString(), sess.StoreID, sess.UserID, sess.DeviceID, sess.DeviceCode, metaJSON)
		return err
	}
	return nil
}

func applyExpense(ctx context.Context, tx pgx.Tx, sess auth.Session, ts time.Time, r *ExpenseRecord) error {
	if err := requireStoreMember(ctx, tx, sess.StoreID, &r.CreatedByUserID); err != nil {
		return err
	}
	createdAt := derefTimeOr(r.CreatedAt, ts)
	tag, err := tx.Exec(ctx, `
		INSERT INTO expenses
			(id, store_id, category, title, amount, payment_method, paid_to, shift_id, created_by_user_id, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
		ON CONFLICT (id) DO NOTHING`,
		r.ID, sess.StoreID, r.Category, r.Title, r.Amount.String(), r.PaymentMethod, r.PaidTo, r.ShiftID, r.CreatedByUserID, createdAt, ts)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return checkSameStoreOrForbidden(ctx, tx, sess, "expenses", r.ID)
	}
	if r.PaymentMethod == "CASH" && r.ShiftID != nil {
		shiftTag, err := tx.Exec(ctx, `
			UPDATE register_shifts
			SET cash_expenses = cash_expenses + $2,
			    expected_cash = expected_cash - $2,
			    updated_at = GREATEST(COALESCE(updated_at, $3), $3)
			WHERE id = $1 AND store_id = $4`, *r.ShiftID, r.Amount.String(), ts, sess.StoreID)
		if err != nil {
			return err
		}
		if shiftTag.RowsAffected() == 0 {
			return newErr(http.StatusUnprocessableEntity, CodeUnprocessable, "shift_id not found for cash expense")
		}
	}
	return nil
}

// ---------------------------------------------------------------- Helpers

func decodeStrictPayload(raw json.RawMessage, dst any) error {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		return errors.New("payload object is required")
	}
	dec := json.NewDecoder(bytes.NewReader(trimmed))
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		return err
	}
	if err := dec.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return errors.New("payload must be a single JSON object")
	}
	return nil
}

func alignRecordID(target *string, recordID string) error {
	*target = strings.TrimSpace(*target)
	if *target == "" {
		*target = recordID
		return nil
	}
	if *target != recordID {
		return errors.New("payload.id does not match mutation.record_id")
	}
	return nil
}

func isUUID(s string) bool {
	if s == "" {
		return false
	}
	_, err := uuid.Parse(s)
	return err == nil
}

func cleanOptionalUUID(pp **string, field string) error {
	if pp == nil || *pp == nil {
		return nil
	}
	v := strings.TrimSpace(**pp)
	if v == "" {
		*pp = nil
		return nil
	}
	if !isUUID(v) {
		return fmt.Errorf("%s must be a valid UUID", field)
	}
	*pp = &v
	return nil
}

func normalizeDate(raw string) (string, error) {
	s := strings.TrimSpace(raw)
	if s == "" {
		return "", errors.New("date is required")
	}
	if t, err := time.Parse("2006-01-02", s); err == nil {
		return t.Format("2006-01-02"), nil
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t.UTC().Format("2006-01-02"), nil
	}
	return "", fmt.Errorf("invalid date %q (expected YYYY-MM-DD)", raw)
}

func derefTimeOr(p *time.Time, fallback time.Time) time.Time {
	if p == nil || p.IsZero() {
		return fallback
	}
	return p.UTC()
}

func effectiveClientTS(serverTS time.Time, clientTS *time.Time) time.Time {
	if clientTS == nil || clientTS.IsZero() {
		return serverTS
	}
	t := clientTS.UTC()
	// Guard against badly misconfigured device clocks far in the future so they
	// do not win LWW over subsequent accurate-clock edits.
	if t.After(serverTS.Add(30 * time.Second)) {
		return serverTS
	}
	return t
}

func badPayloadErr(idx int, err error) *Error {
	return newErr(http.StatusBadRequest, CodeBadRequest, fmt.Sprintf("mutations[%d] invalid payload: %v", idx, err))
}

func isRetryablePgErr(err error) bool {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		return pgErr.Code == "40001" || pgErr.Code == "40P01"
	}
	return false
}

func mapPgError(err error) error {
	var se *Error
	if errors.As(err, &se) {
		return se
	}
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		switch pgErr.Code {
		case "42501":
			return newErr(http.StatusForbidden, CodeForbidden, "cross-tenant operation rejected")
		case "23505":
			return newErr(http.StatusConflict, CodeConflict, "conflicting unique constraint violation (e.g. duplicate bill_no or sticker_barcode)")
		case "23503":
			return newErr(http.StatusUnprocessableEntity, CodeUnprocessable, "referenced parent record does not exist")
		case "23514", "22P02", "22003", "22007", "22008", "23502":
			return newErr(http.StatusBadRequest, CodeBadRequest, "database constraint validation failed")
		}
	}
	log.Printf("sync: push failed: %v", err)
	return errInternal
}
