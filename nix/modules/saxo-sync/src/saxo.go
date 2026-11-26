package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const (
	authURL = "https://live.logonvalidation.net"
	apiURL  = "https://gateway.saxobank.com/openapi"
)

var errLoginRequired = errors.New("login required")

// The only Saxo paths this program reads. It sends nothing but GET to the API
var allowedPaths = []*regexp.Regexp{
	regexp.MustCompile(`^/port/v1/clients/me$`),
	regexp.MustCompile(`^/port/v1/accounts/me$`),
	regexp.MustCompile(`^/port/v1/balances$`),
	regexp.MustCompile(`^/port/v1/positions/me$`),
	regexp.MustCompile(`^/port/v1/netpositions/me$`),
	regexp.MustCompile(`^/hist/v1/transactions$`),
}

// No redirects: neither endpoint has a reason to send one, and a followed redirect would carry the token elsewhere
var httpClient = &http.Client{
	Timeout:       60 * time.Second,
	CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
}

type Token struct {
	AccessToken           string    `json:"access_token"`
	RefreshToken          string    `json:"refresh_token"`
	ExpiresIn             int       `json:"expires_in"`
	RefreshTokenExpiresIn int       `json:"refresh_token_expires_in"`
	ObtainedAt            time.Time `json:"obtained_at"`
}

func (t Token) AccessExpiresAt() time.Time {
	return t.ObtainedAt.Add(time.Duration(t.ExpiresIn) * time.Second)
}

func (t Token) RefreshExpiresAt() time.Time {
	return t.ObtainedAt.Add(time.Duration(t.RefreshTokenExpiresIn) * time.Second)
}

type Auth struct {
	AppKey, RedirectURI, StateDir string
	secret                        func() string
}

func (a *Auth) tokenPath() string { return filepath.Join(a.StateDir, "token.json") }
func (a *Auth) loginPath() string { return filepath.Join(a.StateDir, "login.json") }

func writeJSONAtomic(path string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	tmp := fmt.Sprintf("%s.%d.tmp", path, os.Getpid())
	if err := os.WriteFile(tmp, append(b, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func (a *Auth) ReadToken() (Token, error) {
	var t Token
	b, err := os.ReadFile(a.tokenPath())
	if errors.Is(err, os.ErrNotExist) {
		return t, fmt.Errorf("%w: no token yet", errLoginRequired)
	} else if err != nil {
		return t, err
	}
	return t, json.Unmarshal(b, &t)
}

// AccessToken is the current access token, with at least two minutes left
func (a *Auth) AccessToken() (string, error) {
	t, err := a.ReadToken()
	if err != nil {
		return "", err
	}
	if time.Until(t.AccessExpiresAt()) < 2*time.Minute {
		return "", fmt.Errorf("%w: access token expired at %s; did the refresh job stop?", errLoginRequired,
			t.AccessExpiresAt().Format(time.RFC3339))
	}
	return t.AccessToken, nil
}

func (a *Auth) tokenRequest(ctx context.Context, form url.Values) (Token, error) {
	form.Set("redirect_uri", a.RedirectURI)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, authURL+"/token", strings.NewReader(form.Encode()))
	if err != nil {
		return Token{}, err
	}
	req.SetBasicAuth(a.AppKey, a.secret())
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	res, err := httpClient.Do(req)
	if err != nil {
		return Token{}, err
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	switch {
	case res.StatusCode >= 400 && res.StatusCode < 500:
		// invalid_grant and friends: the session is gone, only a browser login brings it back
		return Token{}, fmt.Errorf("%w: token endpoint answered %d: %.300s", errLoginRequired, res.StatusCode, body)
	case res.StatusCode != http.StatusOK:
		return Token{}, fmt.Errorf("token endpoint answered %d: %.300s", res.StatusCode, body)
	}
	t := Token{ObtainedAt: time.Now().UTC()}
	if err := json.Unmarshal(body, &t); err != nil {
		return Token{}, fmt.Errorf("token response: %w", err)
	}
	if t.AccessToken == "" || t.RefreshToken == "" {
		return Token{}, errors.New("token response without tokens")
	}
	return t, writeJSONAtomic(a.tokenPath(), t)
}

func (a *Auth) LoginURL() error {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return err
	}
	state := hex.EncodeToString(b)
	if err := writeJSONAtomic(a.loginPath(), map[string]string{"state": state}); err != nil {
		return err
	}
	u := authURL + "/authorize?" + url.Values{
		"response_type": {"code"},
		"client_id":     {a.AppKey},
		"state":         {state},
		"redirect_uri":  {a.RedirectURI},
	}.Encode()
	fmt.Printf("Open this in a browser and log in to Saxo:\n\n  %s\n\n", u)
	fmt.Printf("Then run login again with the full URL the browser landed on.\n")
	return nil
}

func (a *Auth) LoginCallback(ctx context.Context, callback string) error {
	u, err := url.Parse(callback)
	if err != nil {
		return err
	}
	var saved struct{ State string }
	b, err := os.ReadFile(a.loginPath())
	if err != nil {
		return fmt.Errorf("no login in progress (run login without a URL first): %w", err)
	}
	if err := json.Unmarshal(b, &saved); err != nil {
		return err
	}
	q := u.Query()
	if q.Get("state") != saved.State {
		return errors.New("the state in the URL is not the one of the last login")
	}
	if q.Get("code") == "" {
		return fmt.Errorf("no code in the URL: %s", q.Get("error"))
	}
	t, err := a.tokenRequest(ctx, url.Values{"grant_type": {"authorization_code"}, "code": {q.Get("code")}})
	if err != nil {
		return err
	}
	os.Remove(a.loginPath())
	slog.Info("Saxo login done", "access_expires_at", t.AccessExpiresAt(), "refresh_expires_at", t.RefreshExpiresAt())
	return nil
}

// Refresh rotates the tokens once. A refresh token that expired or that Saxo refuses means a login is needed; network
// trouble and 5xx are retried for a few minutes, then fail the run, which the next one makes up for while the refresh
// token lasts
func (a *Auth) Refresh(ctx context.Context) error {
	t, err := a.ReadToken()
	if err != nil {
		return err
	}
	if time.Now().After(t.RefreshExpiresAt()) {
		return fmt.Errorf("%w: refresh token expired at %s", errLoginRequired, t.RefreshExpiresAt().Format(time.RFC3339))
	}
	for attempt := 1; ; attempt++ {
		nt, err := a.tokenRequest(ctx, url.Values{"grant_type": {"refresh_token"}, "refresh_token": {t.RefreshToken}})
		if err == nil {
			slog.Info("Saxo token refreshed", "access_expires_at", nt.AccessExpiresAt(),
				"refresh_expires_at", nt.RefreshExpiresAt())
			return nil
		}
		if errors.Is(err, errLoginRequired) {
			return err
		}
		if attempt == 4 {
			// Exit 0 while the next run, 10 minutes on, can still refresh: only a session about to go needs anyone
			if left := time.Until(t.RefreshExpiresAt()); left > 20*time.Minute {
				slog.Warn("Saxo token refresh failed, the next run tries again", "error", err, "refresh_expires_in", left.Round(time.Second))
				return nil
			}
			return fmt.Errorf("Saxo token refresh failed with the refresh token about to expire at %s: %w",
				t.RefreshExpiresAt().Format(time.RFC3339), err)
		}
		slog.Warn("Saxo token refresh failed, retrying", "error", err, "attempt", attempt)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Duration(attempt) * 30 * time.Second):
		}
	}
}

type Saxo struct{ auth *Auth }

func NewSaxo(a *Auth) *Saxo { return &Saxo{a} }

// Get reads one allowlisted path (or a __next link under the API) into out
func (s *Saxo) Get(ctx context.Context, path string, query map[string]string, out any) error {
	var u *url.URL
	var err error
	if strings.HasPrefix(path, "https://") {
		u, err = url.Parse(path)
	} else {
		u, err = url.Parse(apiURL + path)
	}
	if err != nil {
		return err
	}
	if u.Scheme != "https" || u.Host != "gateway.saxobank.com" || !strings.HasPrefix(u.Path, "/openapi/") {
		return fmt.Errorf("refusing to leave the Saxo API: %s", u)
	}
	rel := strings.TrimPrefix(u.Path, "/openapi")
	allowed := false
	for _, re := range allowedPaths {
		allowed = allowed || re.MatchString(rel)
	}
	if !allowed {
		return fmt.Errorf("path not allowlisted: %s", rel)
	}
	q := u.Query()
	for k, v := range query {
		q.Set(k, v)
	}
	u.RawQuery = q.Encode()
	for attempt := 1; ; attempt++ {
		token, err := s.auth.AccessToken()
		if err != nil {
			return err
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
		if err != nil {
			return err
		}
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("Accept", "application/json")
		res, err := httpClient.Do(req)
		if err != nil {
			return err
		}
		body, _ := io.ReadAll(io.LimitReader(res.Body, 64<<20))
		res.Body.Close()
		switch {
		case res.StatusCode == http.StatusOK:
			return json.Unmarshal(body, out)
		case res.StatusCode == http.StatusUnauthorized:
			return fmt.Errorf("%w: Saxo answered 401 for %s", errLoginRequired, rel)
		case (res.StatusCode == http.StatusTooManyRequests || res.StatusCode >= 500) && attempt < 4:
			slog.Warn("Saxo request failed, retrying", "path", rel, "status", res.StatusCode, "attempt", attempt)
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(time.Duration(attempt) * 10 * time.Second):
			}
		default:
			return fmt.Errorf("Saxo answered %d for %s: %.500s", res.StatusCode, rel, body)
		}
	}
}

// GetAll follows the __next links of a paged list
func GetAll[T any](ctx context.Context, s *Saxo, path string, query map[string]string) ([]T, error) {
	var all []T
	for {
		var page struct {
			Data []T    `json:"Data"`
			Next string `json:"__next"`
		}
		if err := s.Get(ctx, path, query, &page); err != nil {
			return nil, err
		}
		all = append(all, page.Data...)
		if page.Next == "" {
			return all, nil
		}
		path, query = page.Next, nil
	}
}
