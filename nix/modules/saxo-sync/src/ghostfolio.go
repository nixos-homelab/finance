package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
)

type Ghostfolio struct {
	base, jwt string
}

type GFAccount struct {
	ID       string  `json:"id"`
	Name     string  `json:"name"`
	Currency string  `json:"currency"`
	Balance  float64 `json:"balance"`
}

type GFActivity struct {
	ID           string  `json:"id"`
	AccountID    string  `json:"accountId"`
	Comment      *string `json:"comment"`
	Type         string  `json:"type"`
	Quantity     float64 `json:"quantity"`
	AssetProfile struct {
		DataSource string `json:"dataSource"`
		Symbol     string `json:"symbol"`
		Name       string `json:"name"`
	} `json:"assetProfile"`
}

func (a GFActivity) comment() string {
	if a.Comment == nil {
		return ""
	}
	return *a.Comment
}

func NewGhostfolio(ctx context.Context, base, token string) (*Ghostfolio, error) {
	g := &Ghostfolio{base: strings.TrimSuffix(base, "/")}
	var auth struct {
		AuthToken string `json:"authToken"`
	}
	if err := g.call(ctx, http.MethodPost, "/api/v1/auth/anonymous", map[string]string{"accessToken": token}, &auth); err != nil {
		return nil, err
	}
	g.jwt = auth.AuthToken
	return g, nil
}

func (g *Ghostfolio) call(ctx context.Context, method, path string, body, out any) error {
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, g.base+path, rd)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if g.jwt != "" {
		req.Header.Set("Authorization", "Bearer "+g.jwt)
	}
	res, err := httpClient.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(res.Body, 256<<20))
	if res.StatusCode/100 != 2 {
		return fmt.Errorf("Ghostfolio %s %s answered %d: %.1000s", method, path, res.StatusCode, b)
	}
	if out == nil || len(b) == 0 {
		return nil
	}
	return json.Unmarshal(b, out)
}

func (g *Ghostfolio) Accounts(ctx context.Context) ([]GFAccount, error) {
	var r struct{ Accounts []GFAccount }
	return r.Accounts, g.call(ctx, http.MethodGet, "/api/v1/account", nil, &r)
}

func (g *Ghostfolio) Activities(ctx context.Context) ([]GFActivity, error) {
	var r struct{ Activities []GFActivity }
	return r.Activities, g.call(ctx, http.MethodGet, "/api/v1/activities?take=1000000", nil, &r)
}

type ImportResult struct {
	Activities []struct {
		AccountID string  `json:"accountId"`
		Comment   *string `json:"comment"`
		Error     *struct {
			Code string `json:"code"`
		} `json:"error"`
		AssetProfile *struct {
			Symbol string `json:"symbol"`
			Name   string `json:"name"`
		} `json:"assetProfile"`
		SymbolProfile *struct {
			Symbol string `json:"symbol"`
			Name   string `json:"name"`
		} `json:"SymbolProfile"`
	} `json:"activities"`
}

type ImportPayload struct {
	Activities    []Activity     `json:"activities"`
	AssetProfiles []AssetProfile `json:"assetProfiles,omitempty"`
}

func (g *Ghostfolio) Import(ctx context.Context, p ImportPayload, dryRun bool) (ImportResult, error) {
	var r ImportResult
	return r, g.call(ctx, http.MethodPost, fmt.Sprintf("/api/v1/import?dryRun=%t", dryRun), p, &r)
}

func (g *Ghostfolio) DeleteActivity(ctx context.Context, id string) error {
	return g.call(ctx, http.MethodDelete, "/api/v1/activities/"+id, nil, nil)
}

func (g *Ghostfolio) SetBalance(ctx context.Context, accountID string, balance float64, date string) error {
	return g.call(ctx, http.MethodPost, "/api/v1/account-balance",
		map[string]any{"accountId": accountID, "balance": balance, "date": date}, nil)
}
