package sync

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"
)

const (
	// maxMoney10_2 is the maximum magnitude representable in DECIMAL(10,2) in paisa/cents.
	maxMoney10_2 int64 = 99_999_999_99
	// maxMoney12_2 is the maximum magnitude representable in DECIMAL(12,2) in paisa/cents.
	maxMoney12_2 int64 = 9_999_999_999_99
)

// Money stores monetary values as exact integer paisa/cents (10^-2 units),
// avoiding IEEE-754 floating-point drift on retail totals and Z-Reports.
type Money int64

// MoneyPtr allocates a heap pointer for optional/masked response fields.
func MoneyPtr(m Money) *Money { return &m }

// String formats Money with two fixed decimal places (e.g. "1350.00", "-25.50").
func (m Money) String() string {
	v := int64(m)
	sign := ""
	if v < 0 {
		sign = "-"
		if v == math.MinInt64 {
			return "-92233720368547758.08"
		}
		v = -v
	}
	return fmt.Sprintf("%s%d.%02d", sign, v/100, v%100)
}

// FitsDecimal10_2 reports whether m fits inside SQL DECIMAL(10,2).
func (m Money) FitsDecimal10_2() bool {
	v := int64(m)
	return v >= -maxMoney10_2 && v <= maxMoney10_2
}

// FitsDecimal12_2 reports whether m fits inside SQL DECIMAL(12,2).
func (m Money) FitsDecimal12_2() bool {
	v := int64(m)
	return v >= -maxMoney12_2 && v <= maxMoney12_2
}

// MarshalJSON writes exact 2-decimal RFC 8259 numeric literals (e.g. 1350.00).
func (m Money) MarshalJSON() ([]byte, error) {
	return []byte(m.String()), nil
}

// UnmarshalJSON accepts both JSON numeric literals (1350.5, 1350) and quoted
// decimal strings ("1350.50") while preserving exact fixed-point precision.
func (m *Money) UnmarshalJSON(data []byte) error {
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		return errors.New("money value cannot be null")
	}
	if trimmed[0] == '"' {
		var s string
		if err := json.Unmarshal(trimmed, &s); err != nil {
			return err
		}
		trimmed = []byte(strings.TrimSpace(s))
	}
	parsed, err := ParseMoney(string(trimmed))
	if err != nil {
		return err
	}
	*m = parsed
	return nil
}

// ParseMoney converts a decimal string into exact integer paisa/cents.
func ParseMoney(s string) (Money, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, errors.New("empty money string")
	}
	neg := false
	switch s[0] {
	case '-':
		neg = true
		s = s[1:]
	case '+':
		s = s[1:]
	}
	if s == "" {
		return 0, errors.New("invalid money format")
	}
	wholePart := s
	fracPart := ""
	if dot := strings.IndexByte(s, '.'); dot >= 0 {
		if strings.IndexByte(s[dot+1:], '.') >= 0 {
			return 0, errors.New("multiple decimal points in money")
		}
		wholePart = s[:dot]
		fracPart = s[dot+1:]
		if fracPart == "" {
			return 0, errors.New("trailing decimal point in money")
		}
	}
	if wholePart == "" {
		wholePart = "0"
	}
	for i := 0; i < len(wholePart); i++ {
		if wholePart[i] < '0' || wholePart[i] > '9' {
			return 0, fmt.Errorf("invalid digit in money integer part %q", wholePart)
		}
	}
	for i := 0; i < len(fracPart); i++ {
		if fracPart[i] < '0' || fracPart[i] > '9' {
			return 0, fmt.Errorf("invalid digit in money fractional part %q", fracPart)
		}
	}
	if len(fracPart) > 2 {
		// Allow trailing zeros (e.g. "10.500"), reject non-zero sub-paisa precision.
		for i := 2; i < len(fracPart); i++ {
			if fracPart[i] != '0' {
				return 0, errors.New("money supports at most 2 decimal places")
			}
		}
		fracPart = fracPart[:2]
	} else if len(fracPart) == 1 {
		fracPart += "0"
	} else if len(fracPart) == 0 {
		fracPart = "00"
	}

	whole, err := strconv.ParseInt(wholePart, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("money integer overflow: %w", err)
	}
	frac, err := strconv.ParseInt(fracPart, 10, 64)
	if err != nil {
		return 0, err
	}
	if whole > maxMoney12_2/100 {
		return 0, errors.New("money exceeds DECIMAL(12,2) range")
	}
	total := whole*100 + frac
	if neg {
		total = -total
	}
	if !Money(total).FitsDecimal12_2() {
		return 0, errors.New("money exceeds DECIMAL(12,2) range")
	}
	return Money(total), nil
}

// ParseMoneyPtr converts an optional string representation from Postgres into *Money.
func ParseMoneyPtr(s *string) (*Money, error) {
	if s == nil {
		return nil, nil
	}
	m, err := ParseMoney(*s)
	if err != nil {
		return nil, err
	}
	return &m, nil
}

// MulChecked multiplies a Money value by an integer quantity while guarding against overflow.
func (m Money) MulChecked(qty int64) (Money, bool) {
	if qty == 0 || m == 0 {
		return 0, true
	}
	v := int64(m)
	if qty < -maxMoney12_2 || qty > maxMoney12_2 {
		return 0, false
	}
	prod := v * qty
	if prod/qty != v {
		return 0, false
	}
	res := Money(prod)
	if !res.FitsDecimal12_2() {
		return 0, false
	}
	return res, true
}

// AddChecked adds two Money values while checking overflow beyond DECIMAL(12,2).
func (m Money) AddChecked(other Money) (Money, bool) {
	a, b := int64(m), int64(other)
	if (b > 0 && a > math.MaxInt64-b) || (b < 0 && a < math.MinInt64-b) {
		return 0, false
	}
	res := Money(a + b)
	if !res.FitsDecimal12_2() {
		return 0, false
	}
	return res, true
}
