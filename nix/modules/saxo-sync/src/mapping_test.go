package main

import (
	"encoding/json"
	"math"
	"strings"
	"testing"
)

// Shaped like LIVE hist/v1/transactions answers, with made-up values
func parse(t *testing.T, s string) Transaction {
	t.Helper()
	var tx Transaction
	if err := json.Unmarshal([]byte(s), &tx); err != nil {
		t.Fatal(err)
	}
	return tx
}

func mapper() *Mapper {
	return &Mapper{
		Symbols:   map[string]Target{"SE0000000001": {Symbol: "ACME.ST"}},
		AccountID: "acc",
		Profiles:  map[string]AssetProfile{"Holding Fee": {Symbol: "11111111-1111-1111-1111-111111111111"}},
	}
}

func near(a, b float64) bool { return math.Abs(a-b) < 1e-6 }

func TestTradeInForeignCurrency(t *testing.T) {
	// A sale in SEK on an EUR account: the costs (commission and conversion) come in EUR and go to the fee in SEK
	r := mapper().Map(parse(t, `{
		"TransactionType": "Trade", "Event": "Sell", "Date": "2025-01-02", "TradeId": "77", "OriginalTradeId": 0,
		"Currency": "EUR", "TotalCost": -3, "ConversionRate": 0.1,
		"Instrument": {"AssetType": "Stock", "Currency": "SEK", "ISINCode": "SE0000000001", "Uic": 1, "Symbol": "ACME:xome"},
		"Bookings": [{"AmountType": "Commission", "BookedAmount": -1, "CostClass": "TransactionCosts"},
		             {"AmountType": "Share Amount", "BookedAmount": 100, "CostClass": "NotAssigned"}],
		"Trades": [{"TradeId": "77", "TradedQuantity": -10, "Price": 100, "TradeExecutionTime": "2025-01-02T08:00:01.483000Z"}]
	}`))
	if r.Problem != "" || len(r.Activities) != 1 {
		t.Fatalf("%+v", r)
	}
	a := r.Activities[0]
	if a.Type != "SELL" || a.Symbol != "ACME.ST" || a.DataSource != "YAHOO" || a.Quantity != 10 || a.UnitPrice != 100 ||
		a.Currency != "SEK" || !near(a.Fee, 30) || a.Comment != "saxo:trade:77" || a.Date != "2025-01-02T08:00:01.483000Z" {
		t.Fatalf("%+v", a)
	}
}

func TestTradeUnmappedGoesAsISIN(t *testing.T) {
	r := mapper().Map(parse(t, `{
		"TransactionType": "Trade", "TradeId": "1", "Currency": "EUR", "TotalCost": -2, "ConversionRate": 1,
		"Instrument": {"AssetType": "Etf", "Currency": "EUR", "ISINCode": "LU0000000002"},
		"Trades": [{"TradedQuantity": 5, "Price": 20}]
	}`))
	if a := r.Activities[0]; a.Symbol != "LU0000000002" || a.Type != "BUY" || a.Fee != 2 {
		t.Fatalf("%+v", a)
	}
}

func TestOptionIsAProblem(t *testing.T) {
	r := mapper().Map(parse(t, `{"TransactionType": "Trade", "TradeId": "2", "Instrument": {"AssetType": "StockOption", "Symbol": "X/17F20C15:xcbf"}, "Trades": [{}]}`))
	if !strings.Contains(r.Problem, "StockOption") {
		t.Fatalf("%+v", r)
	}
}

func TestReversal(t *testing.T) {
	r := mapper().Map(parse(t, `{"TransactionType": "Trade", "TradeId": "9", "IsReversal": true, "OriginalTradeId": "8"}`))
	if r.Reverses != "saxo:trade:8" {
		t.Fatalf("%+v", r)
	}
}

func TestDividendWithWithholdingTax(t *testing.T) {
	r := mapper().Map(parse(t, `{
		"TransactionType": "CorporateAction", "Event": "Cash Dividend", "Date": "2025-04-10", "CorporateActionId": "5",
		"Currency": "EUR", "DividendCurrency": "SEK", "ConversionRate": 0.1,
		"Instrument": {"AssetType": "Stock", "Currency": "SEK", "ISINCode": "SE0000000001"},
		"Bookings": [{"AmountType": "Corporate Actions - Cash Dividends", "BookedAmount": 10, "ConversionRate": 0.1},
		             {"AmountType": "Corporate Actions - Withholding Tax", "BookedAmount": -1.5, "ConversionRate": 0.1}]
	}`))
	a := r.Activities[0]
	if a.Type != "DIVIDEND" || a.Currency != "SEK" || !near(a.UnitPrice, 100) || !near(a.Fee, 15) || a.Quantity != 1 ||
		a.Comment != "saxo:ca:5" {
		t.Fatalf("%+v", a)
	}
}

func TestSpinOff(t *testing.T) {
	r := mapper().Map(parse(t, `{
		"TransactionType": "CorporateAction", "Event": "Spin-Off", "Date": "2025-04-23", "CorporateActionId": "6",
		"Instrument": {"ISINCode": "SE0000000001"}, "Bookings": [],
		"Trades": [{"TradedQuantity": 50, "Price": 0, "Instrument": {"Currency": "NOK", "ISINCode": "NO0000000003"}}]
	}`))
	if a := r.Activities[0]; a.Type != "BUY" || a.Symbol != "NO0000000003" || a.Quantity != 50 || a.UnitPrice != 0 ||
		a.Comment != "saxo:ca:6:NO0000000003" {
		t.Fatalf("%+v", r)
	}
}

func TestOtherCorporateActionIsAProblem(t *testing.T) {
	r := mapper().Map(parse(t, `{"TransactionType": "CorporateAction", "Event": "Stock Split", "CorporateActionId": "7"}`))
	if !strings.Contains(r.Problem, "Stock Split") {
		t.Fatalf("%+v", r)
	}
}

func TestCashAmounts(t *testing.T) {
	m := mapper()
	r := m.Map(parse(t, `{"TransactionType": "CashAmount", "Date": "2025-03-02", "Currency": "EUR", "Bookings": [
		{"BookingId": "b1", "AmountType": "Interest", "BookedAmount": 29.5},
		{"BookingId": "b2", "AmountType": "Holding Fee", "BookedAmount": -0.07},
		{"BookingId": "b3", "AmountType": "Interest", "BookedAmount": -1.25},
		{"BookingId": "b4", "AmountType": "ADR Charges", "BookedAmount": -0.94}]}`))
	if len(r.Activities) != 4 {
		t.Fatalf("%+v", r)
	}
	in, hold, neg, adr := r.Activities[0], r.Activities[1], r.Activities[2], r.Activities[3]
	if in.Type != "INTEREST" || in.Quantity != 1 || in.UnitPrice != 29.5 || in.Fee != 0 {
		t.Fatalf("%+v", in)
	}
	if hold.Type != "FEE" || hold.Symbol != "11111111-1111-1111-1111-111111111111" || hold.Fee != 0.07 || hold.Quantity != 0 ||
		hold.UnitPrice != 0 {
		t.Fatalf("%+v", hold)
	}
	if neg.Type != "FEE" || m.Profiles["Interest fee"].Symbol != neg.Symbol || neg.Fee != 1.25 {
		t.Fatalf("%+v", neg)
	}
	// A new profile: a name-based UUID, the same on every run
	if p := m.Profiles["ADR Charges"]; p.Symbol != adr.Symbol || p.Currency != "EUR" || len(p.Symbol) != 36 || p.Symbol[14] != '5' {
		t.Fatalf("%+v", p)
	}
	if again := mapper().profile("ADR Charges", "EUR"); again != adr.Symbol {
		t.Fatalf("%s != %s", again, adr.Symbol)
	}
}

func TestDepositIsNoActivity(t *testing.T) {
	r := mapper().Map(parse(t, `{"TransactionType": "CashTransfer", "Event": "Deposit", "BookedAmount": 1000}`))
	if r.Problem != "" || len(r.Activities) != 0 {
		t.Fatalf("%+v", r)
	}
}
