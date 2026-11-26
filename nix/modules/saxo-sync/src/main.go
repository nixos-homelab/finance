// saxo-sync: Saxo Bank (OpenAPI, LIVE, read-only) → Ghostfolio.
//
//	saxo-sync login                 print the URL to log in with, in a browser
//	saxo-sync login <callback-url>  trade the code in the URL the browser landed on for tokens
//	saxo-sync refresh               refresh the session once; exits 1 when it is gone (a login is needed) or about to
//	                                go: a failure that the next run can still make up for only warns
//	saxo-sync sync [--dry-run [--json]] [--from YYYY-MM-DD] [--to YYYY-MM-DD]
//	                                import the transactions and cash balances of the configured accounts
//	saxo-sync get <path> [k=v ...]  GET one allowlisted Saxo path and print the JSON
//
// Only `login` and `refresh` touch the refresh token, and they run one at a time (a CronJob that forbids concurrency),
// so nothing races for the rotating token. `sync` and `get` read the access token and never refresh it.
//
// Environment: SAXO_APP_KEY, SAXO_APP_SECRET, SAXO_REDIRECT_URI, SAXO_STATE_DIR (token and login state, default
// /state), SAXO_CONFIG (default /config.json), GHOSTFOLIO_URL, GHOSTFOLIO_TOKEN. Any of them can be given as
// <NAME>_FILE instead.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"time"
)

func env(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	if f := os.Getenv(name + "_FILE"); f != "" {
		b, err := os.ReadFile(f)
		if err != nil {
			fatal(fmt.Errorf("reading %s_FILE: %w", name, err))
		}
		return strings.TrimSpace(string(b))
	}
	if fallback != "" {
		return fallback
	}
	fatal(fmt.Errorf("%s is not set", name))
	return ""
}

func fatal(err error) {
	if errors.Is(err, errLoginRequired) {
		slog.Error("Saxo login required", "reason", err.Error())
	} else {
		slog.Error(err.Error())
	}
	os.Exit(1)
}

const usage = "usage: saxo-sync login [<callback-url>] | refresh | sync [--dry-run [--json]] [--from D] [--to D] | get <path> [k=v ...]"

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, nil)))
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, usage)
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()
	auth := &Auth{
		AppKey:      env("SAXO_APP_KEY", ""),
		RedirectURI: env("SAXO_REDIRECT_URI", ""),
		StateDir:    env("SAXO_STATE_DIR", "/state"),
		secret:      func() string { return env("SAXO_APP_SECRET", "") },
	}
	var err error
	switch cmd, args := os.Args[1], os.Args[2:]; cmd {
	case "login":
		if len(args) == 0 {
			err = auth.LoginURL()
		} else {
			err = auth.LoginCallback(ctx, args[0])
		}
	case "refresh":
		err = auth.Refresh(ctx)
	case "sync":
		var opts SyncOptions
		if opts, err = parseSyncArgs(args); err == nil {
			err = Sync(ctx, auth, opts)
		}
	case "get":
		if len(args) == 0 {
			err = errors.New(usage)
			break
		}
		query := map[string]string{}
		for _, kv := range args[1:] {
			k, v, _ := strings.Cut(kv, "=")
			query[k] = v
		}
		var raw json.RawMessage
		if err = NewSaxo(auth).Get(ctx, args[0], query, &raw); err == nil {
			os.Stdout.Write(append(raw, '\n'))
		}
	default:
		fmt.Fprintln(os.Stderr, usage)
		os.Exit(2)
	}
	if err != nil {
		fatal(err)
	}
}

func parseSyncArgs(args []string) (SyncOptions, error) {
	var o SyncOptions
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--dry-run":
			o.DryRun = true
		case "--json":
			o.JSON = true
		case "--from", "--to":
			if i+1 == len(args) {
				return o, fmt.Errorf("%s needs a date", args[i])
			}
			if _, err := time.Parse(time.DateOnly, args[i+1]); err != nil {
				return o, fmt.Errorf("%s: %w", args[i], err)
			}
			if args[i] == "--from" {
				o.From = args[i+1]
			} else {
				o.To = args[i+1]
			}
			i++
		default:
			return o, fmt.Errorf("unknown argument %s", args[i])
		}
	}
	return o, nil
}
