package sync

import (
	"context"
	"encoding/json"
	"log"
	"time"

	"github.com/jackc/pgx/v5"

	"pasalx/server/internal/auth"
)

const (
	defaultPullLimit        = 500
	minPullLimit            = 100
	maxPullLimit            = 2000
	maxSameMicrosecondLimit = 100_000
)

// Pull returns a consistent snapshot of all changes committed strictly after
// since up to a safe monotonic cutoff, applying strict RBAC field masking
// per TECHNICAL_SPEC.md §7.5 (STAFF cannot see wholesale cost_price, profit
// metrics, or supplier debt; MANAGER cannot see cost_price or P&L).
func (s *Service) Pull(ctx context.Context, sess auth.Session, since time.Time, limit int) (*PullResponse, error) {
	since = since.UTC().Truncate(time.Microsecond)
	if limit <= 0 {
		limit = defaultPullLimit
	} else if limit < minPullLimit {
		limit = minPullLimit
	} else if limit > maxPullLimit {
		limit = maxPullLimit
	}

	cutoff := s.clock.acquirePullCutoff()
	if !cutoff.After(since) {
		return &PullResponse{
			ServerTime: since,
			Since:      since,
			HasMore:    false,
			Role:       sess.Role,
			Changes:    newEmptyPullChanges(),
		}, nil
	}

	tx, err := s.db.BeginTx(ctx, pgx.TxOptions{
		IsoLevel:   pgx.RepeatableRead,
		AccessMode: pgx.ReadOnly,
	})
	if err != nil {
		log.Printf("sync: begin pull tx failed: %v", err)
		return nil, errInternal
	}
	defer func() { _ = tx.Rollback(ctx) }()

	changes := newEmptyPullChanges()
	hasMore := false
	nextCursor := cutoff
	updateCursor := func(tableEnd time.Time, truncated bool) {
		if truncated {
			hasMore = true
			if !tableEnd.IsZero() && tableEnd.Before(nextCursor) {
				nextCursor = tableEnd
			}
		}
	}

	var tEnd time.Time
	var trunc bool

	if changes.Products, tEnd, trunc, err = pullTable(cutoff, limit, func(c time.Time, l int) ([]ProductRecord, time.Time, bool, error) {
		return pullProducts(ctx, tx, since, c, l)
	}); err != nil {
		return nil, pullDBErr(err)
	}
	updateCursor(tEnd, trunc)

	if changes.ProductVariants, tEnd, trunc, err = pullTable(cutoff, limit, func(c time.Time, l int) ([]ProductVariantRecord, time.Time, bool, error) {
		return pullVariants(ctx, tx, since, c, l)
	}); err != nil {
		return nil, pullDBErr(err)
	}
	updateCursor(tEnd, trunc)

	if changes.Batches, tEnd, trunc, err = pullTable(cutoff, limit, func(c time.Time, l int) ([]BatchRecord, time.Time, bool, error) {
		return pullBatches(ctx, tx, sess.Role, since, c, l)
	}); err != nil {
		return nil, pullDBErr(err)
	}
	updateCursor(tEnd, trunc)

	if changes.Customers, tEnd, trunc, err = pullTable(cutoff, limit, func(c time.Time, l int) ([]CustomerRecord, time.Time, bool, error) {
		return pullCustomers(ctx, tx, since, c, l)
	}); err != nil {
		return nil, pullDBErr(err)
	}
	updateCursor(tEnd, trunc)

	if changes.CustomerShadeProfiles, tEnd, trunc, err = pullTable(cutoff, limit, func(c time.Time, l int) ([]CustomerShadeProfileRecord, time.Time, bool, error) {
		return pullCustomerShadeProfiles(ctx, tx, since, c, l)
	}); err != nil {
		return nil, pullDBErr(err)
	}
	updateCursor(tEnd, trunc)

	if changes.CustomerTransactions, tEnd, trunc, err = pullTable(cutoff, limit, func(c time.Time, l int) ([]CustomerTransactionRecord, time.Time, bool, error) {
		return pullCustomerTransactions(ctx, tx, since, c, l)
	}); err != nil {
		return nil, pullDBErr(err)
	}
	updateCursor(tEnd, trunc)

	// Supplier ledger & cost/audit visibility strictly follows RBAC (§7.5):
	// STAFF receives empty slices and zero DB queries are run for these tables.
	if sess.Role == auth.RoleOwner || sess.Role == auth.RoleManager {
		if changes.Suppliers, tEnd, trunc, err = pullTable(cutoff, limit, func(c time.Time, l int) ([]SupplierRecord, time.Time, bool, error) {
			return pullSuppliers(ctx, tx, since, c, l)
		}); err != nil {
			return nil, pullDBErr(err)
		}
		updateCursor(tEnd, trunc)

		if changes.PurchaseInvoices, tEnd, trunc, err = pullTable(cutoff, limit, func(c time.Time, l int) ([]PurchaseInvoiceRecord, time.Time, bool, error) {
			return pullPurchaseInvoices(ctx, tx, since, c, l)
		}); err != nil {
			return nil, pullDBErr(err)
		}
		updateCursor(tEnd, trunc)

		if changes.PurchaseInvoiceItems, tEnd, trunc, err = pullTable(cutoff, limit, func(c time.Time, l int) ([]PurchaseInvoiceItemRecord, time.Time, bool, error) {
			return pullPurchaseInvoiceItems(ctx, tx, sess.Role, since, c, l)
		}); err != nil {
			return nil, pullDBErr(err)
		}
		updateCursor(tEnd, trunc)

		if changes.SupplierPayments, tEnd, trunc, err = pullTable(cutoff, limit, func(c time.Time, l int) ([]SupplierPaymentRecord, time.Time, bool, error) {
			return pullSupplierPayments(ctx, tx, since, c, l)
		}); err != nil {
			return nil, pullDBErr(err)
		}
		updateCursor(tEnd, trunc)

		if changes.InventorySyncAudit, tEnd, trunc, err = pullTable(cutoff, limit, func(c time.Time, l int) ([]InventorySyncAuditRecord, time.Time, bool, error) {
			return pullInventorySyncAudit(ctx, tx, since, c, l)
		}); err != nil {
			return nil, pullDBErr(err)
		}
		updateCursor(tEnd, trunc)
	}

	if changes.StockMovements, tEnd, trunc, err = pullTable(cutoff, limit, func(c time.Time, l int) ([]StockMovementRecord, time.Time, bool, error) {
		return pullStockMovements(ctx, tx, since, c, l)
	}); err != nil {
		return nil, pullDBErr(err)
	}
	updateCursor(tEnd, trunc)

	if changes.SaleOrders, tEnd, trunc, err = pullTable(cutoff, limit, func(c time.Time, l int) ([]SaleOrderRecord, time.Time, bool, error) {
		return pullSaleOrders(ctx, tx, sess.Role, since, c, l)
	}); err != nil {
		return nil, pullDBErr(err)
	}
	updateCursor(tEnd, trunc)

	if len(changes.SaleOrders) > 0 {
		orderIDs := make([]string, len(changes.SaleOrders))
		for i, o := range changes.SaleOrders {
			orderIDs[i] = o.ID
		}
		if changes.SaleItems, err = pullSaleItems(ctx, tx, sess.Role, orderIDs); err != nil {
			return nil, pullDBErr(err)
		}
		if changes.SalePayments, err = pullSalePayments(ctx, tx, orderIDs); err != nil {
			return nil, pullDBErr(err)
		}
	}

	if changes.RegisterShifts, tEnd, trunc, err = pullTable(cutoff, limit, func(c time.Time, l int) ([]RegisterShiftRecord, time.Time, bool, error) {
		return pullRegisterShifts(ctx, tx, since, c, l)
	}); err != nil {
		return nil, pullDBErr(err)
	}
	updateCursor(tEnd, trunc)

	if changes.StaffShiftSessions, tEnd, trunc, err = pullTable(cutoff, limit, func(c time.Time, l int) ([]StaffShiftSessionRecord, time.Time, bool, error) {
		return pullStaffShiftSessions(ctx, tx, since, c, l)
	}); err != nil {
		return nil, pullDBErr(err)
	}
	updateCursor(tEnd, trunc)

	if changes.Expenses, tEnd, trunc, err = pullTable(cutoff, limit, func(c time.Time, l int) ([]ExpenseRecord, time.Time, bool, error) {
		return pullExpenses(ctx, tx, since, c, l)
	}); err != nil {
		return nil, pullDBErr(err)
	}
	updateCursor(tEnd, trunc)

	if err := tx.Commit(ctx); err != nil {
		return nil, pullDBErr(err)
	}
	if !nextCursor.After(since) {
		nextCursor = since
	}

	return &PullResponse{
		ServerTime: nextCursor,
		Since:      since,
		HasMore:    hasMore,
		Role:       sess.Role,
		Changes:    changes,
	}, nil
}

func pullDBErr(err error) error {
	log.Printf("sync: pull query failed: %v", err)
	return errInternal
}

func pullTable[T any](
	cutoff time.Time,
	limit int,
	fetch func(cutoff time.Time, lim int) ([]T, time.Time, bool, error),
) ([]T, time.Time, bool, error) {
	rows, end, trunc, err := fetch(cutoff, limit)
	if err != nil || !trunc || len(rows) < limit || limit >= maxSameMicrosecondLimit {
		return rows, end, trunc, err
	}
	// len(rows) == limit with trunc == true only occurs when all first `limit` rows
	// share the exact same microsecond `end`. Fetch the full microsecond cohort at
	// `end` so advancing `?since=end` never skips rows sharing that microsecond.
	allAtEnd, _, _, err := fetch(end, maxSameMicrosecondLimit)
	if err != nil {
		return nil, time.Time{}, false, err
	}
	return allAtEnd, end, true, nil
}

func trimByUpdatedAt[T any](rows []T, limit int, getTS func(T) time.Time) ([]T, time.Time, bool) {
	if len(rows) <= limit {
		return rows, time.Time{}, false
	}
	boundary := getTS(rows[limit-1])
	end := limit
	if getTS(rows[0]).Before(boundary) {
		end = limit - 1
		for end > 0 && !getTS(rows[end-1]).Before(boundary) {
			end--
		}
		return rows[:end], getTS(rows[end-1]), true
	}
	return rows[:limit], boundary, true
}

func pullProducts(ctx context.Context, tx pgx.Tx, since, cutoff time.Time, limit int) ([]ProductRecord, time.Time, bool, error) {
	rows, err := tx.Query(ctx, `
		SELECT id, name, brand, category, COALESCE(is_generic, FALSE), photo_url, created_at, updated_at, deleted_at
		FROM products
		WHERE updated_at > $1 AND updated_at <= $2
		ORDER BY updated_at ASC, id ASC
		LIMIT $3`, since, cutoff, limit+1)
	if err != nil {
		return nil, time.Time{}, false, err
	}
	defer rows.Close()

	out := make([]ProductRecord, 0, 16)
	for rows.Next() {
		var r ProductRecord
		if err := rows.Scan(&r.ID, &r.Name, &r.Brand, &r.Category, &r.IsGeneric, &r.PhotoURL, &r.CreatedAt, &r.UpdatedAt, &r.DeletedAt); err != nil {
			return nil, time.Time{}, false, err
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, time.Time{}, false, err
	}
	trimmed, end, trunc := trimByUpdatedAt(out, limit, func(r ProductRecord) time.Time { return *r.UpdatedAt })
	return trimmed, end, trunc, nil
}

func pullVariants(ctx context.Context, tx pgx.Tx, since, cutoff time.Time, limit int) ([]ProductVariantRecord, time.Time, bool, error) {
	rows, err := tx.Query(ctx, `
		SELECT id, product_id, variant_name, size_volume, color_hex, COALESCE(attributes, '{}'::jsonb)::text, is_active, created_at, updated_at, deleted_at
		FROM product_variants
		WHERE updated_at > $1 AND updated_at <= $2
		ORDER BY updated_at ASC, id ASC
		LIMIT $3`, since, cutoff, limit+1)
	if err != nil {
		return nil, time.Time{}, false, err
	}
	defer rows.Close()

	out := make([]ProductVariantRecord, 0, 16)
	for rows.Next() {
		var (
			r       ProductVariantRecord
			attrStr string
		)
		if err := rows.Scan(&r.ID, &r.ProductID, &r.VariantName, &r.SizeVolume, &r.ColorHex, &attrStr, &r.IsActive, &r.CreatedAt, &r.UpdatedAt, &r.DeletedAt); err != nil {
			return nil, time.Time{}, false, err
		}
		r.Attributes = json.RawMessage(attrStr)
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, time.Time{}, false, err
	}
	trimmed, end, trunc := trimByUpdatedAt(out, limit, func(r ProductVariantRecord) time.Time { return *r.UpdatedAt })
	return trimmed, end, trunc, nil
}

func pullBatches(ctx context.Context, tx pgx.Tx, role string, since, cutoff time.Time, limit int) ([]BatchRecord, time.Time, bool, error) {
	includeCost := role == auth.RoleOwner
	includeSupplier := role == auth.RoleOwner || role == auth.RoleManager

	rows, err := tx.Query(ctx, `
		SELECT id, variant_id,
		       CASE WHEN $4 THEN supplier_id ELSE NULL END,
		       CASE WHEN $4 THEN purchase_invoice_id ELSE NULL END,
		       batch_code, sticker_barcode,
		       CASE WHEN $5 THEN cost_price::text ELSE NULL END,
		       selling_price::text, stock_quantity, to_char(expiry_date, 'YYYY-MM-DD'),
		       created_at, updated_at, deleted_at
		FROM batches
		WHERE updated_at > $1 AND updated_at <= $2
		ORDER BY updated_at ASC, id ASC
		LIMIT $3`, since, cutoff, limit+1, includeSupplier, includeCost)
	if err != nil {
		return nil, time.Time{}, false, err
	}
	defer rows.Close()

	out := make([]BatchRecord, 0, 16)
	for rows.Next() {
		var (
			r          BatchRecord
			costStr    *string
			sellingStr string
		)
		if err := rows.Scan(&r.ID, &r.VariantID, &r.SupplierID, &r.PurchaseInvoiceID, &r.BatchCode, &r.StickerBarcode,
			&costStr, &sellingStr, &r.StockQuantity, &r.ExpiryDate, &r.CreatedAt, &r.UpdatedAt, &r.DeletedAt); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.CostPrice, err = ParseMoneyPtr(costStr); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.SellingPrice, err = ParseMoney(sellingStr); err != nil {
			return nil, time.Time{}, false, err
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, time.Time{}, false, err
	}
	trimmed, end, trunc := trimByUpdatedAt(out, limit, func(r BatchRecord) time.Time { return *r.UpdatedAt })
	return trimmed, end, trunc, nil
}

func pullCustomers(ctx context.Context, tx pgx.Tx, since, cutoff time.Time, limit int) ([]CustomerRecord, time.Time, bool, error) {
	rows, err := tx.Query(ctx, `
		SELECT id, name, phone, address, credit_limit::text, current_balance_due::text, favorite_shade_notes, created_at, updated_at, deleted_at
		FROM customers
		WHERE updated_at > $1 AND updated_at <= $2
		ORDER BY updated_at ASC, id ASC
		LIMIT $3`, since, cutoff, limit+1)
	if err != nil {
		return nil, time.Time{}, false, err
	}
	defer rows.Close()

	out := make([]CustomerRecord, 0, 16)
	for rows.Next() {
		var (
			r      CustomerRecord
			limStr *string
			balStr string
		)
		if err := rows.Scan(&r.ID, &r.Name, &r.Phone, &r.Address, &limStr, &balStr, &r.FavoriteShadeNotes, &r.CreatedAt, &r.UpdatedAt, &r.DeletedAt); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.CreditLimit, err = ParseMoneyPtr(limStr); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.CurrentBalanceDue, err = ParseMoney(balStr); err != nil {
			return nil, time.Time{}, false, err
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, time.Time{}, false, err
	}
	trimmed, end, trunc := trimByUpdatedAt(out, limit, func(r CustomerRecord) time.Time { return *r.UpdatedAt })
	return trimmed, end, trunc, nil
}

func pullCustomerShadeProfiles(ctx context.Context, tx pgx.Tx, since, cutoff time.Time, limit int) ([]CustomerShadeProfileRecord, time.Time, bool, error) {
	rows, err := tx.Query(ctx, `
		SELECT id, customer_id, product_name, brand, shade_variant, notes, created_at, updated_at
		FROM customer_shade_profiles
		WHERE updated_at > $1 AND updated_at <= $2
		ORDER BY updated_at ASC, id ASC
		LIMIT $3`, since, cutoff, limit+1)
	if err != nil {
		return nil, time.Time{}, false, err
	}
	defer rows.Close()

	out := make([]CustomerShadeProfileRecord, 0, 16)
	for rows.Next() {
		var r CustomerShadeProfileRecord
		if err := rows.Scan(&r.ID, &r.CustomerID, &r.ProductName, &r.Brand, &r.ShadeVariant, &r.Notes, &r.CreatedAt, &r.UpdatedAt); err != nil {
			return nil, time.Time{}, false, err
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, time.Time{}, false, err
	}
	trimmed, end, trunc := trimByUpdatedAt(out, limit, func(r CustomerShadeProfileRecord) time.Time { return *r.UpdatedAt })
	return trimmed, end, trunc, nil
}

func pullCustomerTransactions(ctx context.Context, tx pgx.Tx, since, cutoff time.Time, limit int) ([]CustomerTransactionRecord, time.Time, bool, error) {
	rows, err := tx.Query(ctx, `
		SELECT id, customer_id, type, amount::text, balance_after::text, reference_bill_no, payment_method, notes, created_by_user_id, created_at, updated_at
		FROM customer_transactions
		WHERE updated_at > $1 AND updated_at <= $2
		ORDER BY updated_at ASC, id ASC
		LIMIT $3`, since, cutoff, limit+1)
	if err != nil {
		return nil, time.Time{}, false, err
	}
	defer rows.Close()

	out := make([]CustomerTransactionRecord, 0, 16)
	for rows.Next() {
		var (
			r          CustomerTransactionRecord
			amtStr     string
			balAfterSt string
		)
		if err := rows.Scan(&r.ID, &r.CustomerID, &r.Type, &amtStr, &balAfterSt, &r.ReferenceBillNo, &r.PaymentMethod, &r.Notes, &r.CreatedByUserID, &r.CreatedAt, &r.UpdatedAt); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.Amount, err = ParseMoney(amtStr); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.BalanceAfter, err = ParseMoney(balAfterSt); err != nil {
			return nil, time.Time{}, false, err
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, time.Time{}, false, err
	}
	trimmed, end, trunc := trimByUpdatedAt(out, limit, func(r CustomerTransactionRecord) time.Time { return *r.UpdatedAt })
	return trimmed, end, trunc, nil
}

func pullSuppliers(ctx context.Context, tx pgx.Tx, since, cutoff time.Time, limit int) ([]SupplierRecord, time.Time, bool, error) {
	rows, err := tx.Query(ctx, `
		SELECT id, name, phone, pan_vat, address, total_purchased::text, total_paid::text, balance_due::text, created_at, updated_at, deleted_at
		FROM suppliers
		WHERE updated_at > $1 AND updated_at <= $2
		ORDER BY updated_at ASC, id ASC
		LIMIT $3`, since, cutoff, limit+1)
	if err != nil {
		return nil, time.Time{}, false, err
	}
	defer rows.Close()

	out := make([]SupplierRecord, 0, 8)
	for rows.Next() {
		var (
			r                    SupplierRecord
			totPurch, totPaid, b string
		)
		if err := rows.Scan(&r.ID, &r.Name, &r.Phone, &r.PanVAT, &r.Address, &totPurch, &totPaid, &b, &r.CreatedAt, &r.UpdatedAt, &r.DeletedAt); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.TotalPurchased, err = ParseMoney(totPurch); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.TotalPaid, err = ParseMoney(totPaid); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.BalanceDue, err = ParseMoney(b); err != nil {
			return nil, time.Time{}, false, err
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, time.Time{}, false, err
	}
	trimmed, end, trunc := trimByUpdatedAt(out, limit, func(r SupplierRecord) time.Time { return *r.UpdatedAt })
	return trimmed, end, trunc, nil
}

func pullPurchaseInvoices(ctx context.Context, tx pgx.Tx, since, cutoff time.Time, limit int) ([]PurchaseInvoiceRecord, time.Time, bool, error) {
	rows, err := tx.Query(ctx, `
		SELECT id, supplier_id, invoice_no, to_char(invoice_date, 'YYYY-MM-DD'), total_amount::text, paid_amount::text, due_amount::text, status, notes, created_by_user_id, created_at, updated_at
		FROM purchase_invoices
		WHERE updated_at > $1 AND updated_at <= $2
		ORDER BY updated_at ASC, id ASC
		LIMIT $3`, since, cutoff, limit+1)
	if err != nil {
		return nil, time.Time{}, false, err
	}
	defer rows.Close()

	out := make([]PurchaseInvoiceRecord, 0, 8)
	for rows.Next() {
		var (
			r               PurchaseInvoiceRecord
			tot, paid, due  string
		)
		if err := rows.Scan(&r.ID, &r.SupplierID, &r.InvoiceNo, &r.InvoiceDate, &tot, &paid, &due, &r.Status, &r.Notes, &r.CreatedByUserID, &r.CreatedAt, &r.UpdatedAt); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.TotalAmount, err = ParseMoney(tot); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.PaidAmount, err = ParseMoney(paid); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.DueAmount, err = ParseMoney(due); err != nil {
			return nil, time.Time{}, false, err
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, time.Time{}, false, err
	}
	trimmed, end, trunc := trimByUpdatedAt(out, limit, func(r PurchaseInvoiceRecord) time.Time { return *r.UpdatedAt })
	return trimmed, end, trunc, nil
}

func pullPurchaseInvoiceItems(ctx context.Context, tx pgx.Tx, role string, since, cutoff time.Time, limit int) ([]PurchaseInvoiceItemRecord, time.Time, bool, error) {
	includeCost := role == auth.RoleOwner
	rows, err := tx.Query(ctx, `
		SELECT id, purchase_invoice_id, variant_id, batch_id, product_name, variant_name,
		       quantity_received,
		       CASE WHEN $4 THEN unit_cost_price::text ELSE NULL END,
		       unit_selling_price::text,
		       CASE WHEN $4 THEN total_cost::text ELSE NULL END,
		       batch_code, to_char(expiry_date, 'YYYY-MM-DD'), created_at, updated_at
		FROM purchase_invoice_items
		WHERE updated_at > $1 AND updated_at <= $2
		ORDER BY updated_at ASC, id ASC
		LIMIT $3`, since, cutoff, limit+1, includeCost)
	if err != nil {
		return nil, time.Time{}, false, err
	}
	defer rows.Close()

	out := make([]PurchaseInvoiceItemRecord, 0, 8)
	for rows.Next() {
		var (
			r             PurchaseInvoiceItemRecord
			uCost, tCost  *string
			uSell         string
		)
		if err := rows.Scan(&r.ID, &r.PurchaseInvoiceID, &r.VariantID, &r.BatchID, &r.ProductName, &r.VariantName,
			&r.QuantityReceived, &uCost, &uSell, &tCost, &r.BatchCode, &r.ExpiryDate, &r.CreatedAt, &r.UpdatedAt); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.UnitCostPrice, err = ParseMoneyPtr(uCost); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.UnitSellingPrice, err = ParseMoney(uSell); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.TotalCost, err = ParseMoneyPtr(tCost); err != nil {
			return nil, time.Time{}, false, err
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, time.Time{}, false, err
	}
	trimmed, end, trunc := trimByUpdatedAt(out, limit, func(r PurchaseInvoiceItemRecord) time.Time { return *r.UpdatedAt })
	return trimmed, end, trunc, nil
}

func pullSupplierPayments(ctx context.Context, tx pgx.Tx, since, cutoff time.Time, limit int) ([]SupplierPaymentRecord, time.Time, bool, error) {
	rows, err := tx.Query(ctx, `
		SELECT id, supplier_id, purchase_invoice_id, amount::text, payment_method, reference_no, created_by_user_id, created_at, updated_at
		FROM supplier_payments
		WHERE updated_at > $1 AND updated_at <= $2
		ORDER BY updated_at ASC, id ASC
		LIMIT $3`, since, cutoff, limit+1)
	if err != nil {
		return nil, time.Time{}, false, err
	}
	defer rows.Close()

	out := make([]SupplierPaymentRecord, 0, 8)
	for rows.Next() {
		var (
			r      SupplierPaymentRecord
			amtStr string
		)
		if err := rows.Scan(&r.ID, &r.SupplierID, &r.PurchaseInvoiceID, &amtStr, &r.PaymentMethod, &r.ReferenceNo, &r.CreatedByUserID, &r.CreatedAt, &r.UpdatedAt); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.Amount, err = ParseMoney(amtStr); err != nil {
			return nil, time.Time{}, false, err
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, time.Time{}, false, err
	}
	trimmed, end, trunc := trimByUpdatedAt(out, limit, func(r SupplierPaymentRecord) time.Time { return *r.UpdatedAt })
	return trimmed, end, trunc, nil
}

func pullStockMovements(ctx context.Context, tx pgx.Tx, since, cutoff time.Time, limit int) ([]StockMovementRecord, time.Time, bool, error) {
	rows, err := tx.Query(ctx, `
		SELECT id, batch_id, movement_type, quantity, reference_id, reason, staff_name, created_at, updated_at
		FROM stock_movements
		WHERE updated_at > $1 AND updated_at <= $2
		ORDER BY updated_at ASC, id ASC
		LIMIT $3`, since, cutoff, limit+1)
	if err != nil {
		return nil, time.Time{}, false, err
	}
	defer rows.Close()

	out := make([]StockMovementRecord, 0, 16)
	for rows.Next() {
		var (
			r   StockMovementRecord
			qty int
		)
		if err := rows.Scan(&r.ID, &r.BatchID, &r.MovementType, &qty, &r.ReferenceID, &r.Reason, &r.StaffName, &r.CreatedAt, &r.UpdatedAt); err != nil {
			return nil, time.Time{}, false, err
		}
		q := qty
		qc := qty
		r.Quantity = &q
		r.QuantityChange = &qc
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, time.Time{}, false, err
	}
	trimmed, end, trunc := trimByUpdatedAt(out, limit, func(r StockMovementRecord) time.Time { return *r.UpdatedAt })
	return trimmed, end, trunc, nil
}

func pullSaleOrders(ctx context.Context, tx pgx.Tx, role string, since, cutoff time.Time, limit int) ([]SaleOrderRecord, time.Time, bool, error) {
	includeProfit := role == auth.RoleOwner
	rows, err := tx.Query(ctx, `
		SELECT id, bill_no, customer_id, customer_name, customer_phone, cashier_user_id, cashier_name, shift_id,
		       subtotal::text, discount_amount::text, total_amount::text,
		       CASE WHEN $4 THEN cost_total::text ELSE NULL END,
		       CASE WHEN $4 THEN net_profit::text ELSE NULL END,
		       payment_mode, sync_status, created_at, updated_at
		FROM sale_orders
		WHERE updated_at > $1 AND updated_at <= $2
		ORDER BY updated_at ASC, id ASC
		LIMIT $3`, since, cutoff, limit+1, includeProfit)
	if err != nil {
		return nil, time.Time{}, false, err
	}
	defer rows.Close()

	out := make([]SaleOrderRecord, 0, 16)
	for rows.Next() {
		var (
			r                 SaleOrderRecord
			subS, discS, totS string
			costS, profitS    *string
		)
		if err := rows.Scan(&r.ID, &r.BillNo, &r.CustomerID, &r.CustomerName, &r.CustomerPhone,
			&r.CashierUserID, &r.CashierName, &r.ShiftID, &subS, &discS, &totS, &costS, &profitS,
			&r.PaymentMode, &r.SyncStatus, &r.CreatedAt, &r.UpdatedAt); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.Subtotal, err = ParseMoney(subS); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.DiscountAmount, err = ParseMoney(discS); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.TotalAmount, err = ParseMoney(totS); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.CostTotal, err = ParseMoneyPtr(costS); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.NetProfit, err = ParseMoneyPtr(profitS); err != nil {
			return nil, time.Time{}, false, err
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, time.Time{}, false, err
	}
	trimmed, end, trunc := trimByUpdatedAt(out, limit, func(r SaleOrderRecord) time.Time { return *r.UpdatedAt })
	return trimmed, end, trunc, nil
}

func pullSaleItems(ctx context.Context, tx pgx.Tx, role string, orderIDs []string) ([]SaleItemRecord, error) {
	includeCost := role == auth.RoleOwner
	rows, err := tx.Query(ctx, `
		SELECT id, sale_order_id, batch_id, product_name, variant_name, quantity,
		       CASE WHEN $2 THEN cost_price::text ELSE NULL END,
		       selling_price::text, total_price::text
		FROM sale_items
		WHERE sale_order_id = ANY($1)
		ORDER BY sale_order_id ASC, id ASC`, orderIDs, includeCost)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]SaleItemRecord, 0, len(orderIDs)*2)
	for rows.Next() {
		var (
			r      SaleItemRecord
			costS  *string
			sellS  string
			totalS string
		)
		if err := rows.Scan(&r.ID, &r.SaleOrderID, &r.BatchID, &r.ProductName, &r.VariantName,
			&r.Quantity, &costS, &sellS, &totalS); err != nil {
			return nil, err
		}
		if r.CostPrice, err = ParseMoneyPtr(costS); err != nil {
			return nil, err
		}
		if r.SellingPrice, err = ParseMoney(sellS); err != nil {
			return nil, err
		}
		if r.TotalPrice, err = ParseMoney(totalS); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func pullSalePayments(ctx context.Context, tx pgx.Tx, orderIDs []string) ([]SalePaymentRecord, error) {
	rows, err := tx.Query(ctx, `
		SELECT id, sale_order_id, method, amount::text, transaction_ref
		FROM sale_payments
		WHERE sale_order_id = ANY($1)
		ORDER BY sale_order_id ASC, id ASC`, orderIDs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]SalePaymentRecord, 0, len(orderIDs))
	for rows.Next() {
		var (
			r    SalePaymentRecord
			amtS string
		)
		if err := rows.Scan(&r.ID, &r.SaleOrderID, &r.Method, &amtS, &r.TransactionRef); err != nil {
			return nil, err
		}
		if r.Amount, err = ParseMoney(amtS); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func pullRegisterShifts(ctx context.Context, tx pgx.Tx, since, cutoff time.Time, limit int) ([]RegisterShiftRecord, time.Time, bool, error) {
	rows, err := tx.Query(ctx, `
		SELECT id, opened_by_user_id, closed_by_user_id, opened_at, closed_at,
		       opening_float::text, cash_sales::text, digital_sales::text, khata_cash_repayments::text,
		       cash_expenses::text, expected_cash::text, actual_cash_counted::text, discrepancy::text,
		       cash_withdrawn_deposit::text, retained_next_day_float::text, status, notes, created_at, updated_at
		FROM register_shifts
		WHERE updated_at > $1 AND updated_at <= $2
		ORDER BY updated_at ASC, id ASC
		LIMIT $3`, since, cutoff, limit+1)
	if err != nil {
		return nil, time.Time{}, false, err
	}
	defer rows.Close()

	out := make([]RegisterShiftRecord, 0, 8)
	for rows.Next() {
		var (
			r                                        RegisterShiftRecord
			openS, cashS, digS, khataS, expS, expecS string
			actS, discS                              *string
			wdS, retS                                string
		)
		if err := rows.Scan(&r.ID, &r.OpenedByUserID, &r.ClosedByUserID, &r.OpenedAt, &r.ClosedAt,
			&openS, &cashS, &digS, &khataS, &expS, &expecS, &actS, &discS, &wdS, &retS,
			&r.Status, &r.Notes, &r.CreatedAt, &r.UpdatedAt); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.OpeningFloat, err = ParseMoney(openS); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.CashSales, err = ParseMoney(cashS); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.DigitalSales, err = ParseMoney(digS); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.KhataCashRepayments, err = ParseMoney(khataS); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.CashExpenses, err = ParseMoney(expS); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.ExpectedCash, err = ParseMoney(expecS); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.ActualCashCounted, err = ParseMoneyPtr(actS); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.Discrepancy, err = ParseMoneyPtr(discS); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.CashWithdrawnDeposit, err = ParseMoney(wdS); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.RetainedNextDayFloat, err = ParseMoney(retS); err != nil {
			return nil, time.Time{}, false, err
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, time.Time{}, false, err
	}
	trimmed, end, trunc := trimByUpdatedAt(out, limit, func(r RegisterShiftRecord) time.Time { return *r.UpdatedAt })
	return trimmed, end, trunc, nil
}

func pullStaffShiftSessions(ctx context.Context, tx pgx.Tx, since, cutoff time.Time, limit int) ([]StaffShiftSessionRecord, time.Time, bool, error) {
	rows, err := tx.Query(ctx, `
		SELECT id, register_shift_id, user_id, device_code, punched_in_at, punched_out_at, last_synced_at, status, force_closed_by_user_id, updated_at
		FROM staff_shift_sessions
		WHERE updated_at > $1 AND updated_at <= $2
		ORDER BY updated_at ASC, id ASC
		LIMIT $3`, since, cutoff, limit+1)
	if err != nil {
		return nil, time.Time{}, false, err
	}
	defer rows.Close()

	out := make([]StaffShiftSessionRecord, 0, 8)
	for rows.Next() {
		var r StaffShiftSessionRecord
		if err := rows.Scan(&r.ID, &r.RegisterShiftID, &r.UserID, &r.DeviceCode, &r.PunchedInAt, &r.PunchedOutAt,
			&r.LastSyncedAt, &r.Status, &r.ForceClosedByUserID, &r.UpdatedAt); err != nil {
			return nil, time.Time{}, false, err
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, time.Time{}, false, err
	}
	trimmed, end, trunc := trimByUpdatedAt(out, limit, func(r StaffShiftSessionRecord) time.Time { return *r.UpdatedAt })
	return trimmed, end, trunc, nil
}

func pullExpenses(ctx context.Context, tx pgx.Tx, since, cutoff time.Time, limit int) ([]ExpenseRecord, time.Time, bool, error) {
	rows, err := tx.Query(ctx, `
		SELECT id, category, title, amount::text, payment_method, paid_to, shift_id, created_by_user_id, created_at, updated_at
		FROM expenses
		WHERE updated_at > $1 AND updated_at <= $2
		ORDER BY updated_at ASC, id ASC
		LIMIT $3`, since, cutoff, limit+1)
	if err != nil {
		return nil, time.Time{}, false, err
	}
	defer rows.Close()

	out := make([]ExpenseRecord, 0, 8)
	for rows.Next() {
		var (
			r    ExpenseRecord
			amtS string
		)
		if err := rows.Scan(&r.ID, &r.Category, &r.Title, &amtS, &r.PaymentMethod, &r.PaidTo, &r.ShiftID, &r.CreatedByUserID, &r.CreatedAt, &r.UpdatedAt); err != nil {
			return nil, time.Time{}, false, err
		}
		if r.Amount, err = ParseMoney(amtS); err != nil {
			return nil, time.Time{}, false, err
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, time.Time{}, false, err
	}
	trimmed, end, trunc := trimByUpdatedAt(out, limit, func(r ExpenseRecord) time.Time { return *r.UpdatedAt })
	return trimmed, end, trunc, nil
}

func pullInventorySyncAudit(ctx context.Context, tx pgx.Tx, since, cutoff time.Time, limit int) ([]InventorySyncAuditRecord, time.Time, bool, error) {
	rows, err := tx.Query(ctx, `
		SELECT id, batch_id, device_code, operation, quantity_change, pre_sync_qty, post_sync_qty, is_discrepancy, reference_id, stock_movement_id, created_at, updated_at
		FROM inventory_sync_audit
		WHERE updated_at > $1 AND updated_at <= $2
		ORDER BY updated_at ASC, id ASC
		LIMIT $3`, since, cutoff, limit+1)
	if err != nil {
		return nil, time.Time{}, false, err
	}
	defer rows.Close()

	out := make([]InventorySyncAuditRecord, 0, 8)
	for rows.Next() {
		var r InventorySyncAuditRecord
		if err := rows.Scan(&r.ID, &r.BatchID, &r.DeviceCode, &r.Operation, &r.QuantityChange,
			&r.PreSyncQty, &r.PostSyncQty, &r.IsDiscrepancy, &r.ReferenceID, &r.StockMovementID, &r.CreatedAt, &r.UpdatedAt); err != nil {
			return nil, time.Time{}, false, err
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, time.Time{}, false, err
	}
	trimmed, end, trunc := trimByUpdatedAt(out, limit, func(r InventorySyncAuditRecord) time.Time { return *r.UpdatedAt })
	return trimmed, end, trunc, nil
}

