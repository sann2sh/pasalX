package sync

import (
	"encoding/json"
	"net/http"
	"time"
)

const (
	MaxPushBatchSize = 50
	MaxPushBodyBytes = 1 << 20 // 1 MiB
)

// Error is a machine-readable sync API error matching the auth error JSON format.
type Error struct {
	Status  int
	Code    string
	Message string
}

func (e *Error) Error() string { return e.Code + ": " + e.Message }

const (
	CodeBadRequest    = "BAD_REQUEST"
	CodeForbidden     = "FORBIDDEN"
	CodeConflict      = "CONFLICT"
	CodeUnprocessable = "UNPROCESSABLE_ENTITY"
	CodeTooManyConn   = "TOO_MANY_CONNECTIONS"
	CodeInternal      = "INTERNAL_ERROR"
)

func newErr(status int, code, msg string) *Error {
	return &Error{Status: status, Code: code, Message: msg}
}

var errInternal = newErr(http.StatusInternalServerError, CodeInternal, "internal server error")

// Table name constants matching SQL table names and mobile sync_outbox entries.
const (
	TableProducts              = "products"
	TableProductVariants       = "product_variants"
	TableBatches               = "batches"
	TableCustomers             = "customers"
	TableCustomerShadeProfiles = "customer_shade_profiles"
	TableCustomerTransactions  = "customer_transactions"
	TableSuppliers             = "suppliers"
	TablePurchaseInvoices      = "purchase_invoices"
	TablePurchaseInvoiceItems  = "purchase_invoice_items"
	TableSupplierPayments      = "supplier_payments"
	TableStockMovements        = "stock_movements"
	TableSaleOrders            = "sale_orders"
	TableSaleItems             = "sale_items"
	TableSalePayments          = "sale_payments"
	TableRegisterShifts        = "register_shifts"
	TableStaffShiftSessions    = "staff_shift_sessions"
	TableExpenses              = "expenses"
	TableInventorySyncAudit    = "inventory_sync_audit"
)

const (
	OpInsert = "INSERT"
	OpUpdate = "UPDATE"
	OpDelete = "DELETE"
)

// ---------------------------------------------------------------- Push DTOs

type PushRequest struct {
	Mutations []Mutation `json:"mutations"`
}

type Mutation struct {
	ID              string          `json:"id"`
	TableName       string          `json:"table_name"`
	RecordID        string          `json:"record_id"`
	Operation       string          `json:"operation"`
	ClientUpdatedAt *time.Time      `json:"client_updated_at,omitempty"`
	Payload         json.RawMessage `json:"payload"`
}

type MutationResult struct {
	ID        string `json:"id"`
	TableName string `json:"table_name"`
	RecordID  string `json:"record_id"`
	Status    string `json:"status"` // "APPLIED" | "ALREADY_APPLIED"
}

type DiscrepancyAlert struct {
	AuditID        string `json:"audit_id"`
	BatchID        string `json:"batch_id"`
	StockMovement  string `json:"stock_movement_id,omitempty"`
	DeviceCode     string `json:"device_code"`
	PreSyncQty     int    `json:"pre_sync_qty"`
	PostSyncQty    int    `json:"post_sync_qty"`
	QuantityChange int    `json:"quantity_change"`
	ReferenceID    string `json:"reference_id,omitempty"`
}

type PushResult struct {
	ServerTime     time.Time          `json:"server_time"`
	ProcessedCount int                `json:"processed_count"`
	AppliedCount   int                `json:"applied_count"`
	DuplicateCount int                `json:"duplicate_count"`
	Results        []MutationResult   `json:"results"`
	Discrepancies  []DiscrepancyAlert `json:"discrepancies"`
}

// ---------------------------------------------------------------- Shared / Pull Records

type ProductRecord struct {
	ID        string     `json:"id"`
	Name      string     `json:"name"`
	Brand     string     `json:"brand"`
	Category  string     `json:"category"`
	IsGeneric bool       `json:"is_generic"`
	PhotoURL  *string    `json:"photo_url,omitempty"`
	CreatedAt *time.Time `json:"created_at,omitempty"`
	UpdatedAt *time.Time `json:"updated_at,omitempty"`
	DeletedAt *time.Time `json:"deleted_at,omitempty"`
}

type ProductVariantRecord struct {
	ID          string          `json:"id"`
	ProductID   string          `json:"product_id"`
	VariantName string          `json:"variant_name"`
	SizeVolume  *string         `json:"size_volume,omitempty"`
	ColorHex    *string         `json:"color_hex,omitempty"`
	Attributes  json.RawMessage `json:"attributes,omitempty"`
	IsActive    *bool           `json:"is_active,omitempty"`
	CreatedAt   *time.Time      `json:"created_at,omitempty"`
	UpdatedAt   *time.Time      `json:"updated_at,omitempty"`
	DeletedAt   *time.Time      `json:"deleted_at,omitempty"`
}

type BatchRecord struct {
	ID                string     `json:"id"`
	VariantID         string     `json:"variant_id"`
	SupplierID        *string    `json:"supplier_id,omitempty"`
	PurchaseInvoiceID *string    `json:"purchase_invoice_id,omitempty"`
	BatchCode         string     `json:"batch_code"`
	StickerBarcode    string     `json:"sticker_barcode"`
	CostPrice         *Money     `json:"cost_price,omitempty"` // Masked (nil/omitted) for STAFF and MANAGER
	SellingPrice      Money      `json:"selling_price"`
	StockQuantity     int        `json:"stock_quantity"`
	ExpiryDate        string     `json:"expiry_date"` // YYYY-MM-DD
	CreatedAt         *time.Time `json:"created_at,omitempty"`
	UpdatedAt         *time.Time `json:"updated_at,omitempty"`
	DeletedAt         *time.Time `json:"deleted_at,omitempty"`
}

type CustomerRecord struct {
	ID                 string     `json:"id"`
	Name               string     `json:"name"`
	Phone              string     `json:"phone"`
	Address            *string    `json:"address,omitempty"`
	CreditLimit        *Money     `json:"credit_limit,omitempty"`
	CurrentBalanceDue  Money      `json:"current_balance_due"`
	FavoriteShadeNotes *string    `json:"favorite_shade_notes,omitempty"`
	CreatedAt          *time.Time `json:"created_at,omitempty"`
	UpdatedAt          *time.Time `json:"updated_at,omitempty"`
	DeletedAt          *time.Time `json:"deleted_at,omitempty"`
}

type CustomerShadeProfileRecord struct {
	ID           string     `json:"id"`
	CustomerID   string     `json:"customer_id"`
	ProductName  string     `json:"product_name"`
	Brand        string     `json:"brand"`
	ShadeVariant string     `json:"shade_variant"`
	Notes        *string    `json:"notes,omitempty"`
	CreatedAt    *time.Time `json:"created_at,omitempty"`
	UpdatedAt    *time.Time `json:"updated_at,omitempty"`
}

type CustomerTransactionRecord struct {
	ID              string     `json:"id"`
	CustomerID      string     `json:"customer_id"`
	Type            string     `json:"type"`
	Amount          Money      `json:"amount"`
	BalanceAfter    Money      `json:"balance_after"`
	ReferenceBillNo *string    `json:"reference_bill_no,omitempty"`
	PaymentMethod   *string    `json:"payment_method,omitempty"`
	Notes           *string    `json:"notes,omitempty"`
	CreatedByUserID *string    `json:"created_by_user_id,omitempty"`
	ShiftID         *string    `json:"shift_id,omitempty"` // optional push hint for CASH repayment drawer credit
	CreatedAt       *time.Time `json:"created_at,omitempty"`
	UpdatedAt       *time.Time `json:"updated_at,omitempty"`
}

type SupplierRecord struct {
	ID             string     `json:"id"`
	Name           string     `json:"name"`
	Phone          *string    `json:"phone,omitempty"`
	PanVAT         *string    `json:"pan_vat,omitempty"`
	Address        *string    `json:"address,omitempty"`
	TotalPurchased Money      `json:"total_purchased"`
	TotalPaid      Money      `json:"total_paid"`
	BalanceDue     Money      `json:"balance_due"`
	CreatedAt      *time.Time `json:"created_at,omitempty"`
	UpdatedAt      *time.Time `json:"updated_at,omitempty"`
	DeletedAt      *time.Time `json:"deleted_at,omitempty"`
}

type PurchaseInvoiceItemRecord struct {
	ID                string     `json:"id"`
	PurchaseInvoiceID string     `json:"purchase_invoice_id"`
	VariantID         string     `json:"variant_id"`
	BatchID           *string    `json:"batch_id,omitempty"`
	ProductName       string     `json:"product_name"`
	VariantName       string     `json:"variant_name"`
	QuantityReceived  int        `json:"quantity_received"`
	UnitCostPrice     *Money     `json:"unit_cost_price,omitempty"` // Masked for MANAGER; entire table hidden for STAFF
	UnitSellingPrice  Money      `json:"unit_selling_price"`
	TotalCost         *Money     `json:"total_cost,omitempty"` // Masked for MANAGER; entire table hidden for STAFF
	BatchCode         *string    `json:"batch_code,omitempty"`
	ExpiryDate        string     `json:"expiry_date"` // YYYY-MM-DD
	CreatedAt         *time.Time `json:"created_at,omitempty"`
	UpdatedAt         *time.Time `json:"updated_at,omitempty"`
}

type PurchaseInvoiceRecord struct {
	ID              string                      `json:"id"`
	SupplierID      string                      `json:"supplier_id"`
	InvoiceNo       string                      `json:"invoice_no"`
	InvoiceDate     string                      `json:"invoice_date"` // YYYY-MM-DD
	TotalAmount     Money                       `json:"total_amount"`
	PaidAmount      Money                       `json:"paid_amount"`
	DueAmount       Money                       `json:"due_amount"`
	Status          string                      `json:"status"`
	Notes           *string                     `json:"notes,omitempty"`
	CreatedByUserID *string                     `json:"created_by_user_id,omitempty"`
	CreatedAt       *time.Time                  `json:"created_at,omitempty"`
	UpdatedAt       *time.Time                  `json:"updated_at,omitempty"`
	Items           []PurchaseInvoiceItemRecord `json:"items,omitempty"` // optional embedded items on push
}

type SupplierPaymentRecord struct {
	ID                string     `json:"id"`
	SupplierID        string     `json:"supplier_id"`
	PurchaseInvoiceID *string    `json:"purchase_invoice_id,omitempty"`
	Amount            Money      `json:"amount"`
	PaymentMethod     string     `json:"payment_method"`
	ReferenceNo       *string    `json:"reference_no,omitempty"`
	CreatedByUserID   *string    `json:"created_by_user_id,omitempty"`
	CreatedAt         *time.Time `json:"created_at,omitempty"`
	UpdatedAt         *time.Time `json:"updated_at,omitempty"`
}

type StockMovementRecord struct {
	ID             string     `json:"id"`
	BatchID        string     `json:"batch_id"`
	MovementType   string     `json:"movement_type"`
	Quantity       *int       `json:"quantity,omitempty"`
	QuantityChange *int       `json:"quantity_change,omitempty"`
	ReferenceID    *string    `json:"reference_id,omitempty"`
	Reason         *string    `json:"reason,omitempty"`
	StaffName      string     `json:"staff_name"`
	CreatedAt      *time.Time `json:"created_at,omitempty"`
	UpdatedAt      *time.Time `json:"updated_at,omitempty"`
}

type SaleItemRecord struct {
	ID           string `json:"id"`
	SaleOrderID  string `json:"sale_order_id"`
	BatchID      string `json:"batch_id"`
	ProductName  string `json:"product_name"`
	VariantName  string `json:"variant_name"`
	Quantity     int    `json:"quantity"`
	CostPrice    *Money `json:"cost_price,omitempty"` // Masked for STAFF and MANAGER
	SellingPrice Money  `json:"selling_price"`
	TotalPrice   Money  `json:"total_price"`
}

type SalePaymentRecord struct {
	ID             string  `json:"id"`
	SaleOrderID    string  `json:"sale_order_id"`
	Method         string  `json:"method"`
	Amount         Money   `json:"amount"`
	TransactionRef *string `json:"transaction_ref,omitempty"`
}

type SaleOrderRecord struct {
	ID             string                `json:"id"`
	BillNo         string                `json:"bill_no"`
	CustomerID     *string               `json:"customer_id,omitempty"`
	CustomerName   *string               `json:"customer_name,omitempty"`
	CustomerPhone  *string               `json:"customer_phone,omitempty"`
	CashierUserID  string                `json:"cashier_user_id"`
	CashierName    string                `json:"cashier_name"`
	ShiftID        *string               `json:"shift_id,omitempty"`
	Subtotal       Money                 `json:"subtotal"`
	DiscountAmount Money                 `json:"discount_amount"`
	TotalAmount    Money                 `json:"total_amount"`
	CostTotal      *Money                `json:"cost_total,omitempty"` // Masked for STAFF and MANAGER
	NetProfit      *Money                `json:"net_profit,omitempty"` // Masked for STAFF and MANAGER
	PaymentMode    string                `json:"payment_mode"`
	SyncStatus     string                `json:"sync_status,omitempty"`
	CreatedAt      *time.Time            `json:"created_at,omitempty"`
	UpdatedAt      *time.Time            `json:"updated_at,omitempty"`
	Items          []SaleItemRecord      `json:"items,omitempty"`           // optional embedded bundle on push
	Payments       []SalePaymentRecord   `json:"payments,omitempty"`        // optional embedded bundle on push
	StockMovements []StockMovementRecord `json:"stock_movements,omitempty"` // optional embedded deltas on push
}

type RegisterShiftRecord struct {
	ID                   string     `json:"id"`
	OpenedByUserID       string     `json:"opened_by_user_id"`
	ClosedByUserID       *string    `json:"closed_by_user_id,omitempty"`
	OpenedAt             *time.Time `json:"opened_at,omitempty"`
	ClosedAt             *time.Time `json:"closed_at,omitempty"`
	OpeningFloat         Money      `json:"opening_float"`
	CashSales            Money      `json:"cash_sales"`
	DigitalSales         Money      `json:"digital_sales"`
	KhataCashRepayments  Money      `json:"khata_cash_repayments"`
	CashExpenses         Money      `json:"cash_expenses"`
	ExpectedCash         Money      `json:"expected_cash"`
	ActualCashCounted    *Money     `json:"actual_cash_counted,omitempty"`
	Discrepancy          *Money     `json:"discrepancy,omitempty"`
	CashWithdrawnDeposit Money      `json:"cash_withdrawn_deposit"`
	RetainedNextDayFloat Money      `json:"retained_next_day_float"`
	Status               string     `json:"status"`
	Notes                *string    `json:"notes,omitempty"`
	CreatedAt            *time.Time `json:"created_at,omitempty"`
	UpdatedAt            *time.Time `json:"updated_at,omitempty"`
}

type StaffShiftSessionRecord struct {
	ID                  string     `json:"id"`
	RegisterShiftID     string     `json:"register_shift_id"`
	UserID              string     `json:"user_id"`
	DeviceCode          string     `json:"device_code"`
	PunchedInAt         *time.Time `json:"punched_in_at,omitempty"`
	PunchedOutAt        *time.Time `json:"punched_out_at,omitempty"`
	LastSyncedAt        *time.Time `json:"last_synced_at,omitempty"`
	Status              string     `json:"status"`
	ForceClosedByUserID *string    `json:"force_closed_by_user_id,omitempty"`
	UpdatedAt           *time.Time `json:"updated_at,omitempty"`
}

type ExpenseRecord struct {
	ID              string     `json:"id"`
	Category        string     `json:"category"`
	Title           string     `json:"title"`
	Amount          Money      `json:"amount"`
	PaymentMethod   string     `json:"payment_method"`
	PaidTo          *string    `json:"paid_to,omitempty"`
	ShiftID         *string    `json:"shift_id,omitempty"`
	CreatedByUserID string     `json:"created_by_user_id"`
	CreatedAt       *time.Time `json:"created_at,omitempty"`
	UpdatedAt       *time.Time `json:"updated_at,omitempty"`
}

type InventorySyncAuditRecord struct {
	ID              string     `json:"id"`
	BatchID         string     `json:"batch_id"`
	DeviceCode      string     `json:"device_code"`
	Operation       string     `json:"operation"`
	QuantityChange  int        `json:"quantity_change"`
	PreSyncQty      *int       `json:"pre_sync_qty,omitempty"`
	PostSyncQty     *int       `json:"post_sync_qty,omitempty"`
	IsDiscrepancy   bool       `json:"is_discrepancy"`
	ReferenceID     *string    `json:"reference_id,omitempty"`
	StockMovementID *string    `json:"stock_movement_id,omitempty"`
	CreatedAt       *time.Time `json:"created_at,omitempty"`
	UpdatedAt       *time.Time `json:"updated_at,omitempty"`
}

type StoreProfileRecord struct {
	ID        string     `json:"id"`
	Name      string     `json:"name"`
	PanNumber *string    `json:"pan_number,omitempty"`
	Phone     *string    `json:"phone,omitempty"`
	Address   *string    `json:"address,omitempty"`
	Status    string     `json:"status"`
	UpdatedAt *time.Time `json:"updated_at,omitempty"`
}

type StoreMemberRecord struct {
	ID        string     `json:"id"`
	UserID    string     `json:"user_id"`
	Name      string     `json:"name"`
	Username  string     `json:"username"`
	Role      string     `json:"role"`
	Status    string     `json:"status"`
	UpdatedAt *time.Time `json:"updated_at,omitempty"`
}

// ---------------------------------------------------------------- Pull DTOs

type PullChanges struct {
	Stores                []StoreProfileRecord         `json:"stores"`
	StoreMembers          []StoreMemberRecord          `json:"store_members"`
	Products              []ProductRecord              `json:"products"`
	ProductVariants       []ProductVariantRecord       `json:"product_variants"`
	Batches               []BatchRecord                `json:"batches"`
	Customers             []CustomerRecord             `json:"customers"`
	CustomerShadeProfiles []CustomerShadeProfileRecord `json:"customer_shade_profiles"`
	CustomerTransactions  []CustomerTransactionRecord  `json:"customer_transactions"`
	Suppliers             []SupplierRecord             `json:"suppliers"`
	PurchaseInvoices      []PurchaseInvoiceRecord      `json:"purchase_invoices"`
	PurchaseInvoiceItems  []PurchaseInvoiceItemRecord  `json:"purchase_invoice_items"`
	SupplierPayments      []SupplierPaymentRecord      `json:"supplier_payments"`
	StockMovements        []StockMovementRecord        `json:"stock_movements"`
	SaleOrders            []SaleOrderRecord            `json:"sale_orders"`
	SaleItems             []SaleItemRecord             `json:"sale_items"`
	SalePayments          []SalePaymentRecord          `json:"sale_payments"`
	RegisterShifts        []RegisterShiftRecord        `json:"register_shifts"`
	StaffShiftSessions    []StaffShiftSessionRecord    `json:"staff_shift_sessions"`
	Expenses              []ExpenseRecord              `json:"expenses"`
	InventorySyncAudit    []InventorySyncAuditRecord   `json:"inventory_sync_audit"`
}

func newEmptyPullChanges() PullChanges {
	return PullChanges{
		Stores:                []StoreProfileRecord{},
		StoreMembers:          []StoreMemberRecord{},
		Products:              []ProductRecord{},
		ProductVariants:       []ProductVariantRecord{},
		Batches:               []BatchRecord{},
		Customers:             []CustomerRecord{},
		CustomerShadeProfiles: []CustomerShadeProfileRecord{},
		CustomerTransactions:  []CustomerTransactionRecord{},
		Suppliers:             []SupplierRecord{},
		PurchaseInvoices:      []PurchaseInvoiceRecord{},
		PurchaseInvoiceItems:  []PurchaseInvoiceItemRecord{},
		SupplierPayments:      []SupplierPaymentRecord{},
		StockMovements:        []StockMovementRecord{},
		SaleOrders:            []SaleOrderRecord{},
		SaleItems:             []SaleItemRecord{},
		SalePayments:          []SalePaymentRecord{},
		RegisterShifts:        []RegisterShiftRecord{},
		StaffShiftSessions:    []StaffShiftSessionRecord{},
		Expenses:              []ExpenseRecord{},
		InventorySyncAudit:    []InventorySyncAuditRecord{},
	}
}

type PullResponse struct {
	ServerTime time.Time   `json:"server_time"`
	Since      time.Time   `json:"since"`
	HasMore    bool        `json:"has_more"`
	Role       string      `json:"role"`
	Changes    PullChanges `json:"changes"`
}

