package main

import (
	"crypto/sha256"
	"fmt"
	"math"
	"strings"
)

// The fields of hist/v1/transactions this program reads. Amounts and costs are in the account's currency (the
// "requester's" currency when querying by AccountKeys); ConversionRate goes from the instrument's currency to it
type Transaction struct {
	TransactionType   string
	Event             string
	Date              string
	AccountId         string
	TradeId           string
	CorporateActionId string
	IsIntradayData    bool
	IsReversal        bool
	OriginalTradeId   jsonString
	Currency          string
	DividendCurrency  string
	BookedAmount      float64
	TotalCost         float64
	ConversionRate    float64
	Instrument        Instrument
	Bookings          []Booking
	Trades            []Trade
}

type Instrument struct {
	Uic         int64
	AssetType   string
	Symbol      string
	Description string
	Currency    string
	ISINCode    string
}

type Booking struct {
	BookingId      string
	AmountType     string
	BookedAmount   float64
	ConversionRate float64
	CostClass      string
}

type Trade struct {
	TradeId            string
	TradedQuantity     float64
	Price              float64
	TradeExecutionTime string
	Instrument         *Instrument
}

// OriginalTradeId comes as the number 0 when unset and as a string otherwise
type jsonString string

func (s *jsonString) UnmarshalJSON(b []byte) error {
	*s = jsonString(strings.Trim(string(b), `"`))
	if *s == "0" || *s == "null" {
		*s = ""
	}
	return nil
}

// Activity is Ghostfolio's CreateOrderDto (3.100.0)
type Activity struct {
	AccountID  string  `json:"accountId"`
	Comment    string  `json:"comment"`
	Currency   string  `json:"currency"`
	DataSource string  `json:"dataSource"`
	Date       string  `json:"date"`
	Fee        float64 `json:"fee"`
	Quantity   float64 `json:"quantity"`
	Symbol     string  `json:"symbol"`
	Type       string  `json:"type"`
	UnitPrice  float64 `json:"unitPrice"`
}

// AssetProfile is the part of Ghostfolio's CreateAssetProfileDto a MANUAL profile needs. The import reuses the user's
// custom profile of the same name, so the symbol only matters for a new one
type AssetProfile struct {
	Currency   string `json:"currency"`
	DataSource string `json:"dataSource"`
	Name       string `json:"name"`
	Symbol     string `json:"symbol"`
}

type Target struct {
	Symbol     string `json:"symbol"`
	DataSource string `json:"dataSource"`
}

type Mapper struct {
	// ISIN → Ghostfolio symbol, for instruments Ghostfolio already holds under a symbol of its own. Others go to the
	// import as the ISIN, which Ghostfolio resolves through its data provider
	Symbols   map[string]Target
	AccountID string
	Profiles  map[string]AssetProfile
}

// Result of one transaction: activities, a trade to delete (reversals), or a problem that stops the import
type Result struct {
	Activities []Activity
	Reverses   string
	Problem    string
}

func round(x float64) float64 { return math.Round(x*1e6) / 1e6 }

func (m *Mapper) target(i Instrument) (Target, error) {
	if i.ISINCode == "" {
		return Target{}, fmt.Errorf("%s %s (%s, Uic %d) has no ISIN", i.AssetType, i.Symbol, i.Description, i.Uic)
	}
	if t, ok := m.Symbols[i.ISINCode]; ok {
		if t.DataSource == "" {
			t.DataSource = "YAHOO"
		}
		return t, nil
	}
	return Target{Symbol: i.ISINCode, DataSource: "YAHOO"}, nil
}

// toInstrument converts an amount in the account's currency to the instrument's
func toInstrument(amount, rate float64) float64 {
	if rate == 0 {
		return amount
	}
	return amount / rate
}

// profile is the MANUAL asset profile for fees and interest of one kind, named after Saxo's booking type
func (m *Mapper) profile(name, currency string) string {
	if p, ok := m.Profiles[name]; ok {
		return p.Symbol
	}
	h := sha256.Sum256([]byte("saxo-sync:" + name))
	h[6] = h[6]&0x0f | 0x50 // a name-based UUID, the same on every run
	h[8] = h[8]&0x3f | 0x80
	sym := fmt.Sprintf("%x-%x-%x-%x-%x", h[0:4], h[4:6], h[6:8], h[8:10], h[10:16])
	m.Profiles[name] = AssetProfile{Currency: currency, DataSource: "MANUAL", Name: name, Symbol: sym}
	return sym
}

func (m *Mapper) Map(tx Transaction) Result {
	switch tx.TransactionType {
	case "Trade":
		return m.trade(tx)
	case "CorporateAction":
		return m.corporateAction(tx)
	case "CashAmount":
		return m.cashAmount(tx)
	case "CashTransfer":
		// Deposits and withdrawals: the account's cash comes from its balance
		return Result{}
	}
	return Result{Problem: fmt.Sprintf("transaction type %s (%s) on %s", tx.TransactionType, tx.Event, tx.Date)}
}

func (m *Mapper) trade(tx Transaction) Result {
	if tx.IsReversal {
		if tx.OriginalTradeId == "" {
			return Result{Problem: fmt.Sprintf("reversal %s without an original trade", tx.TradeId)}
		}
		return Result{Reverses: "saxo:trade:" + string(tx.OriginalTradeId)}
	}
	if tx.Instrument.AssetType != "Stock" && tx.Instrument.AssetType != "Etf" {
		return Result{Problem: fmt.Sprintf("trade %s: %s %s (%s)", tx.TradeId, tx.Instrument.AssetType, tx.Instrument.Symbol, tx.Event)}
	}
	if len(tx.Trades) != 1 {
		return Result{Problem: fmt.Sprintf("trade %s has %d fills", tx.TradeId, len(tx.Trades))}
	}
	t, err := m.target(tx.Instrument)
	if err != nil {
		return Result{Problem: fmt.Sprintf("trade %s: %v", tx.TradeId, err)}
	}
	fill := tx.Trades[0]
	typ := "BUY"
	if fill.TradedQuantity < 0 {
		typ = "SELL"
	}
	date := fill.TradeExecutionTime
	if date == "" {
		date = tx.Date + "T00:00:00Z"
	}
	// TotalCost is every cost of the trade, commission, taxes and the currency conversion included
	return Result{Activities: []Activity{{
		AccountID:  m.AccountID,
		Comment:    "saxo:trade:" + tx.TradeId,
		Currency:   tx.Instrument.Currency,
		DataSource: t.DataSource,
		Date:       date,
		Fee:        round(math.Abs(toInstrument(tx.TotalCost, tx.ConversionRate))),
		Quantity:   math.Abs(fill.TradedQuantity),
		Symbol:     t.Symbol,
		Type:       typ,
		UnitPrice:  fill.Price,
	}}}
}

func (m *Mapper) corporateAction(tx Transaction) Result {
	id := "saxo:ca:" + tx.CorporateActionId
	switch tx.Event {
	case "Cash Dividend", "Shares Premium Dividend":
		if len(tx.Trades) > 0 {
			break
		}
		t, err := m.target(tx.Instrument)
		if err != nil {
			return Result{Problem: fmt.Sprintf("corporate action %s: %v", tx.CorporateActionId, err)}
		}
		// The dividend in its own currency, gross, with the withholding tax as its fee
		var gross, tax float64
		for _, b := range tx.Bookings {
			rate := b.ConversionRate
			if rate == 0 {
				rate = tx.ConversionRate
			}
			if a := toInstrument(b.BookedAmount, rate); a > 0 {
				gross += a
			} else {
				tax -= a
			}
		}
		currency := tx.DividendCurrency
		if currency == "" {
			currency = tx.Instrument.Currency
		}
		return Result{Activities: []Activity{{
			AccountID:  m.AccountID,
			Comment:    id,
			Currency:   currency,
			DataSource: t.DataSource,
			Date:       tx.Date + "T00:00:00Z",
			Fee:        round(tax),
			Quantity:   1,
			Symbol:     t.Symbol,
			Type:       "DIVIDEND",
			UnitPrice:  round(gross),
		}}}
	case "Spin-Off":
		// The new shares arrive at a price of 0: Saxo books no cost for them and Ghostfolio has no spin-off
		var out []Activity
		for _, fill := range tx.Trades {
			if fill.Instrument == nil || fill.TradedQuantity <= 0 || len(tx.Bookings) > 0 {
				return Result{Problem: fmt.Sprintf("spin-off %s needs review", tx.CorporateActionId)}
			}
			t, err := m.target(*fill.Instrument)
			if err != nil {
				return Result{Problem: fmt.Sprintf("spin-off %s: %v", tx.CorporateActionId, err)}
			}
			out = append(out, Activity{
				AccountID:  m.AccountID,
				Comment:    id + ":" + fill.Instrument.ISINCode,
				Currency:   fill.Instrument.Currency,
				DataSource: t.DataSource,
				Date:       tx.Date + "T00:00:00Z",
				Quantity:   fill.TradedQuantity,
				Symbol:     t.Symbol,
				Type:       "BUY",
			})
		}
		return Result{Activities: out}
	}
	return Result{Problem: fmt.Sprintf("corporate action %s (%s, %s) on %s", tx.CorporateActionId, tx.Event, tx.Instrument.Symbol, tx.Date)}
}

func (m *Mapper) cashAmount(tx Transaction) Result {
	var out []Activity
	for _, b := range tx.Bookings {
		if b.BookedAmount == 0 {
			continue
		}
		a := Activity{
			AccountID:  m.AccountID,
			Comment:    "saxo:booking:" + b.BookingId,
			Currency:   tx.Currency,
			DataSource: "MANUAL",
			Date:       tx.Date + "T00:00:00Z",
		}
		if b.AmountType == "Interest" && b.BookedAmount > 0 {
			// Ghostfolio's own form: quantity 1, the amount as the unit price
			a.Type, a.Quantity, a.UnitPrice = "INTEREST", 1, b.BookedAmount
			a.Symbol = m.profile("Interest", tx.Currency)
		} else {
			// Ghostfolio's own form: quantity and unit price 0, the amount as the fee
			name := b.AmountType
			if name == "Interest" {
				name = "Interest fee"
			}
			a.Type, a.Fee = "FEE", math.Abs(b.BookedAmount)
			a.Symbol = m.profile(name, tx.Currency)
		}
		out = append(out, a)
	}
	return Result{Activities: out}
}
