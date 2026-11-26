package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"slices"
	"sort"
	"strings"
	"time"
)

type SyncOptions struct {
	DryRun, JSON bool
	From, To     string
}

type Config struct {
	Accounts []struct {
		SaxoAccountID  string `json:"saxoAccountId"`
		GhostfolioName string `json:"ghostfolioName"`
		// Transactions before this date are never imported: that history was typed into Ghostfolio by hand
		ImportFrom string `json:"importFrom"`
	} `json:"accounts"`
	Symbols map[string]Target `json:"symbols"`
	// Saxo transactions to leave out on purpose, by the comment they would get (saxo:trade:…, saxo:ca:…)
	Ignore []string `json:"ignore"`
}

func loadConfig() (Config, error) {
	var c Config
	b, err := os.ReadFile(env("SAXO_CONFIG", "/config.json"))
	if err != nil {
		return c, err
	}
	return c, json.Unmarshal(b, &c)
}

type BalanceUpdate struct {
	Account            string  `json:"account"`
	AccountID          string  `json:"-"`
	Cash               float64 `json:"cash"`
	SaxoCurrency       string  `json:"saxoCurrency"`
	GhostfolioCurrency string  `json:"ghostfolioCurrency"`
	Before             float64 `json:"ghostfolioBefore"`
}

type PositionDiff struct {
	Account  string  `json:"account"`
	Symbol   string  `json:"symbol"`
	Saxo     string  `json:"saxo,omitempty"`
	SaxoQty  float64 `json:"saxoQuantity"`
	GhostQty float64 `json:"ghostfolioQuantity"`
}

type Report struct {
	Payload       ImportPayload     `json:"payload"`
	Deletions     []string          `json:"deletions"`
	Balances      []BalanceUpdate   `json:"balances"`
	PositionDiffs []PositionDiff    `json:"positionDiffs"`
	Blockers      []string          `json:"blockers"`
	Resolved      map[string]string `json:"resolvedSymbols,omitempty"`
}

type position struct {
	PositionBase struct {
		AccountId string
		Uic       int64
		Amount    float64
	}
	DisplayAndFormat struct {
		Symbol      string
		Description string
	}
}

func Sync(ctx context.Context, auth *Auth, opts SyncOptions) error {
	cfg, err := loadConfig()
	if err != nil {
		return fmt.Errorf("config: %w", err)
	}
	// Fail before Ghostfolio when the session is gone
	if _, err := auth.AccessToken(); err != nil {
		return err
	}
	gf, err := NewGhostfolio(ctx, env("GHOSTFOLIO_URL", ""), env("GHOSTFOLIO_TOKEN", ""))
	if err != nil {
		return err
	}
	gfAccounts, err := gf.Accounts(ctx)
	if err != nil {
		return err
	}
	existing, err := gf.Activities(ctx)
	if err != nil {
		return err
	}
	profiles := map[string]AssetProfile{}
	have := map[string]GFActivity{} // accountId|comment
	for _, a := range existing {
		if strings.HasPrefix(a.comment(), "saxo:") {
			have[a.AccountID+"|"+a.comment()] = a
		}
		if a.AssetProfile.DataSource == "MANUAL" && (a.Type == "FEE" || a.Type == "INTEREST") {
			profiles[a.AssetProfile.Name] = AssetProfile{DataSource: "MANUAL", Name: a.AssetProfile.Name, Symbol: a.AssetProfile.Symbol}
		}
	}

	saxo := NewSaxo(auth)
	var client struct{ ClientKey string }
	if err := saxo.Get(ctx, "/port/v1/clients/me", nil, &client); err != nil {
		return err
	}
	saxoAccounts, err := GetAll[struct{ AccountId, AccountKey, Currency string }](ctx, saxo, "/port/v1/accounts/me", nil)
	if err != nil {
		return err
	}

	from, to := opts.From, opts.To
	if from == "" {
		from = "2010-01-01" // all of it: a handful of pages, and the history gives every instrument's ISIN
	}
	if to == "" {
		to = time.Now().UTC().Format(time.DateOnly)
	}
	ignore := map[string]bool{}
	for _, c := range cfg.Ignore {
		ignore[c] = true
	}

	var report Report
	report.Deletions = []string{}
	report.Blockers = []string{}
	report.PositionDiffs = []PositionDiff{}
	var deletions []GFActivity
	uicISIN := map[int64]string{}
	type held struct {
		account, accountID string
		positions          []position
	}
	var holdings []held
	// The configured symbols, and those Ghostfolio resolved an ISIN to in an earlier import: the symbol its saxo:
	// activities of that instrument have. New activities go in under it too, so an instrument stays one holding
	symbols := map[string]Target{}
	for isin, t := range cfg.Symbols {
		symbols[isin] = t
	}
	learn := func(accountID, comment, isin string) {
		if a, ok := have[accountID+"|"+comment]; ok && isin != "" {
			if _, known := symbols[isin]; !known {
				symbols[isin] = Target{Symbol: a.AssetProfile.Symbol, DataSource: a.AssetProfile.DataSource}
			}
		}
	}

	for _, acc := range cfg.Accounts {
		var sa *struct{ AccountId, AccountKey, Currency string }
		for i := range saxoAccounts {
			if saxoAccounts[i].AccountId == acc.SaxoAccountID {
				sa = &saxoAccounts[i]
			}
		}
		if sa == nil {
			return fmt.Errorf("Saxo has no account %s", acc.SaxoAccountID)
		}
		var ga *GFAccount
		for i := range gfAccounts {
			if gfAccounts[i].Name == acc.GhostfolioName {
				ga = &gfAccounts[i]
			}
		}
		if ga == nil {
			return fmt.Errorf("Ghostfolio has no account %s", acc.GhostfolioName)
		}
		txs, err := GetAll[Transaction](ctx, saxo, "/hist/v1/transactions", map[string]string{
			"ClientKey": client.ClientKey, "AccountKeys": sa.AccountKey, "FromDate": from, "ToDate": to,
		})
		if err != nil {
			return err
		}
		for _, tx := range txs {
			learn(ga.ID, "saxo:trade:"+tx.TradeId, tx.Instrument.ISINCode)
			learn(ga.ID, "saxo:ca:"+tx.CorporateActionId, tx.Instrument.ISINCode)
			for _, t := range tx.Trades {
				if t.Instrument != nil {
					learn(ga.ID, "saxo:ca:"+tx.CorporateActionId+":"+t.Instrument.ISINCode, t.Instrument.ISINCode)
				}
			}
		}
		m := &Mapper{Symbols: symbols, AccountID: ga.ID, Profiles: profiles}
		added := 0
		for _, tx := range txs {
			if tx.Instrument.ISINCode != "" {
				uicISIN[tx.Instrument.Uic] = tx.Instrument.ISINCode
			}
			for _, t := range tx.Trades {
				if t.Instrument != nil && t.Instrument.ISINCode != "" {
					uicISIN[t.Instrument.Uic] = t.Instrument.ISINCode
				}
			}
			if tx.IsIntradayData || tx.Date < acc.ImportFrom {
				continue
			}
			r := m.Map(tx)
			if r.Problem != "" {
				report.Blockers = append(report.Blockers, acc.GhostfolioName+": "+r.Problem)
			}
			if r.Reverses != "" {
				if a, ok := have[ga.ID+"|"+r.Reverses]; ok {
					deletions = append(deletions, a)
					report.Deletions = append(report.Deletions, acc.GhostfolioName+": "+r.Reverses)
				}
			}
			for _, a := range r.Activities {
				if _, ok := have[ga.ID+"|"+a.Comment]; ok || ignore[a.Comment] {
					continue
				}
				report.Payload.Activities = append(report.Payload.Activities, a)
				added++
			}
		}
		slog.Info("Saxo transactions read", "account", acc.GhostfolioName, "transactions", len(txs), "new_activities", added)

		var bal struct {
			Currency    string
			CashBalance float64
		}
		if err := saxo.Get(ctx, "/port/v1/balances", map[string]string{"ClientKey": client.ClientKey, "AccountKey": sa.AccountKey}, &bal); err != nil {
			return err
		}
		report.Balances = append(report.Balances, BalanceUpdate{
			Account: acc.GhostfolioName, AccountID: ga.ID, Cash: bal.CashBalance,
			SaxoCurrency: bal.Currency, GhostfolioCurrency: ga.Currency, Before: ga.Balance,
		})
		if bal.Currency != ga.Currency {
			report.Blockers = append(report.Blockers, fmt.Sprintf("%s: Saxo keeps its cash in %s, Ghostfolio in %s",
				acc.GhostfolioName, bal.Currency, ga.Currency))
		}
		pos, err := GetAll[position](ctx, saxo, "/port/v1/positions/me", map[string]string{
			"ClientKey": client.ClientKey, "AccountKey": sa.AccountKey, "FieldGroups": "PositionBase,DisplayAndFormat",
		})
		if err != nil {
			return err
		}
		// positions/me answers for the whole client, whatever the AccountKey
		pos = slices.DeleteFunc(pos, func(p position) bool { return p.PositionBase.AccountId != sa.AccountId })
		holdings = append(holdings, held{acc.GhostfolioName, ga.ID, pos})
	}
	for _, p := range profiles {
		if p.Currency != "" { // only the new ones carry a currency
			report.Payload.AssetProfiles = append(report.Payload.AssetProfiles, p)
		}
	}

	// Ghostfolio's quantities after the import against Saxo's positions, per account and symbol
	qty := map[string]float64{}
	add := func(accountID, symbol, typ string, q float64) {
		switch typ {
		case "BUY":
			qty[accountID+"|"+symbol] += q
		case "SELL":
			qty[accountID+"|"+symbol] -= q
		}
	}
	for _, a := range existing {
		if !slices.ContainsFunc(deletions, func(d GFActivity) bool { return d.ID == a.ID }) {
			add(a.AccountID, a.AssetProfile.Symbol, a.Type, a.Quantity)
		}
	}
	for _, a := range report.Payload.Activities {
		add(a.AccountID, a.Symbol, a.Type, a.Quantity)
	}
	symbolOf := func(isin string) string {
		if t, ok := symbols[isin]; ok {
			return t.Symbol
		}
		return isin
	}
	for _, h := range holdings {
		saxoQty := map[string]float64{}
		names := map[string]string{}
		for _, p := range h.positions {
			isin, ok := uicISIN[p.PositionBase.Uic]
			if !ok {
				isin = fmt.Sprintf("uic:%d", p.PositionBase.Uic)
			}
			s := symbolOf(isin)
			saxoQty[s] += p.PositionBase.Amount
			names[s] = p.DisplayAndFormat.Symbol
		}
		for k, q := range qty {
			if id, s, _ := strings.Cut(k, "|"); id == h.accountID && round(q) != 0 {
				if _, ok := saxoQty[s]; !ok {
					saxoQty[s] = 0
				}
			}
		}
		for s, sq := range saxoQty {
			if gq := qty[h.accountID+"|"+s]; round(sq) != round(gq) {
				report.PositionDiffs = append(report.PositionDiffs, PositionDiff{h.account, s, names[s], sq, round(gq)})
			}
		}
	}
	sort.Slice(report.PositionDiffs, func(i, j int) bool {
		a, b := report.PositionDiffs[i], report.PositionDiffs[j]
		return a.Account+a.Symbol < b.Account+b.Symbol
	})

	if opts.DryRun {
		if len(report.Payload.Activities) > 0 {
			res, err := gf.Import(ctx, report.Payload, true)
			if err != nil {
				report.Blockers = append(report.Blockers, "Ghostfolio dry run: "+err.Error())
			} else {
				report.Resolved = map[string]string{}
				sent := map[string]Activity{}
				for _, a := range report.Payload.Activities {
					sent[a.AccountID+"|"+a.Comment] = a
				}
				for _, a := range res.Activities {
					comment := ""
					if a.Comment != nil {
						comment = *a.Comment
					}
					if a.Error != nil {
						report.Blockers = append(report.Blockers, fmt.Sprintf("Ghostfolio: %s for %s", a.Error.Code, comment))
					}
					p := a.AssetProfile
					if p == nil {
						p = a.SymbolProfile
					}
					if s, ok := sent[a.AccountID+"|"+comment]; ok && p != nil && s.DataSource != "MANUAL" && s.Symbol != p.Symbol {
						report.Resolved[s.Symbol] = p.Symbol + " " + p.Name
					}
				}
			}
		}
		if opts.JSON {
			out, _ := json.MarshalIndent(report, "", "  ")
			os.Stdout.Write(append(out, '\n'))
		} else {
			names := map[string]string{}
			for _, a := range gfAccounts {
				names[a.ID] = a.Name
			}
			for _, a := range report.Payload.Activities {
				slog.Info("Would import", "account", names[a.AccountID], "date", a.Date, "type", a.Type, "symbol", a.Symbol,
					"quantity", a.Quantity, "unit_price", a.UnitPrice, "fee", a.Fee, "currency", a.Currency, "comment", a.Comment)
			}
			for _, d := range report.Deletions {
				slog.Info("Would delete", "activity", d)
			}
			for _, b := range report.Balances {
				slog.Info("Would set cash balance", "account", b.Account, "balance", b.Cash, "currency", b.SaxoCurrency, "before", b.Before)
			}
			for _, d := range report.PositionDiffs {
				slog.Warn("Position would differ from Saxo", "account", d.Account, "symbol", d.Symbol, "saxo", d.SaxoQty, "ghostfolio", d.GhostQty)
			}
			for s, r := range report.Resolved {
				slog.Info("Ghostfolio resolves", "symbol", s, "to", r)
			}
			for _, b := range report.Blockers {
				slog.Warn("Would be blocked", "blocker", b)
			}
		}
		slog.Info("Dry run done, nothing written", "activities", len(report.Payload.Activities),
			"deletions", len(deletions), "position_diffs", len(report.PositionDiffs), "blockers", len(report.Blockers))
		return nil
	}

	if len(report.Blockers) > 0 {
		for _, b := range report.Blockers {
			slog.Error("Saxo sync blocked", "blocker", b)
		}
		return errors.New("Saxo sync blocked, nothing written")
	}
	for _, d := range deletions {
		if err := gf.DeleteActivity(ctx, d.ID); err != nil {
			return err
		}
		slog.Info("Reversed trade deleted from Ghostfolio", "comment", d.comment())
	}
	if len(report.Payload.Activities) > 0 {
		res, err := gf.Import(ctx, report.Payload, false)
		if err != nil {
			return err
		}
		slog.Info("Activities imported into Ghostfolio", "count", len(res.Activities))
	}
	today := time.Now().UTC().Format(time.DateOnly)
	for _, b := range report.Balances {
		if err := gf.SetBalance(ctx, b.AccountID, b.Cash, today); err != nil {
			return err
		}
		slog.Info("Cash balance set", "account", b.Account, "balance", b.Cash, "currency", b.SaxoCurrency)
	}
	for _, d := range report.PositionDiffs {
		slog.Warn("Position differs from Saxo", "account", d.Account, "symbol", d.Symbol, "saxo", d.SaxoQty, "ghostfolio", d.GhostQty)
	}
	slog.Info("Saxo sync done", "activities", len(report.Payload.Activities), "deletions", len(deletions))
	return nil
}
