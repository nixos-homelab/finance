# saxo-sync

Imports a Saxo Bank client's transactions and cash balances into Ghostfolio, from
Saxo's OpenAPI on LIVE, read-only (`homelab.ghostfolio.saxo`).

## How it runs

Two CronJobs in Ghostfolio's namespace, both on the PersistentVolumeClaim
`saxo-sync` that holds the OAuth tokens:

- `saxo-refresh`, every 10 minutes: rotates the tokens. Saxo's access tokens
  last about 20 minutes and its refresh tokens about an hour, so a session
  lives as long as the refreshes keep coming. The CronJob forbids concurrent
  runs, since two rotations race for the same refresh token. A run fails
  (and kube-state-metrics' "Job failed" alert fires) when the session is gone
  or about to go; a failure the next run can still make up for only logs a
  warning.
- `saxo-sync`, on `schedule`: reads every transaction of the configured
  accounts (`/hist/v1/transactions`), maps those from `importFrom` on to
  Ghostfolio activities, leaves out those Ghostfolio already has (by their
  `saxo:` comment), and imports the rest. Then it sets each account's cash
  balance from `/port/v1/balances` and compares Ghostfolio's quantities with
  Saxo's positions, logging any difference. Anything it can't map stops the
  run before it writes anything. With `dryRun` it only logs what it would do.

## Mapping

- Trades of stocks and ETFs: BUY or SELL in the instrument's currency at the
  fill's price and time. The fee is Saxo's `TotalCost` (commission, taxes such as
  the Italian FTT, and the currency conversion) converted to the instrument's
  currency at the trade's rate.
- Cash dividends: DIVIDEND in the dividend's currency, gross, with the
  withholding tax as its fee.
- Spin-offs: a BUY of the new shares at 0; Saxo books no cost for them.
- Interest received: INTEREST. Every other cash booking (custody, ADR and
  exchange fees, negative interest, ASK withholding tax): FEE, in a manual
  asset profile named after Saxo's booking type, as Ghostfolio's own form
  enters them (the amount as the fee). Ghostfolio reuses a profile of the same
  name.
- Deposits and withdrawals: no activity; the cash balance covers them.
- Instruments by ISIN: `symbols` maps the ones Ghostfolio already holds under a
  symbol of its own, the rest go to the import as the ISIN, which Ghostfolio
  resolves through its data provider. Once an instrument has `saxo:`
  activities, its later ones (and the position check) use the symbol
  Ghostfolio resolved it to.
- Reversed trades: the activity of the original trade is deleted.
- Options, splits, exchange offers and other corporate actions stop the run:
  map them, or list them in `ignore`.

## Login

The app needs a browser login once, and again whenever the session is lost
(the refresh alert). From a machine with access to the cluster:

```sh
nix run github:nixos-homelab/finance#saxo-login
```

prints the address to log in at. Saxo then sends the browser to the app's
redirect URL; nothing has to answer there. Pass the address the browser landed
on:

```sh
nix run github:nixos-homelab/finance#saxo-login -- '<that URL>'
```

Both run as Jobs from the `saxo-refresh` CronJob, with its Secret and volume.

## Secrets

`SAXO_APP_SECRET`, the App Secret of the app in Saxo's developer portal,
through setup-secrets, into the Secret `saxo-app`. The import uses the
Ghostfolio token of `ghostfolio-token`.
