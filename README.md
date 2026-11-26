# nixos-homelab-finance

Personal finance apps on top of [nixos-homelab](https://github.com/nixos-homelab/shared):
budgeting and portfolio tracking, plus companion services that keep them
in sync with each other and with external data sources.

For the full list of module options, see [the documentation](https://nixos-homelab.github.io/finance/), under Options.

## Setup

```nix
{
  inputs = {
    ...
    homelab-finance = {
      url = "github:nixos-homelab/finance";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    ...
  };
}
```

```nix
{ inputs, ... }:
{
  imports = [ inputs.homelab-finance.nixosModules.actualbudget ];
  config.homelab.actualbudget.enable = true;
}
```

## Modules

- **actualbudget**: [Actual Budget](https://actualbudget.org), envelope
  budgeting. With `metrics.enable` (off by default, for privacy) and
  `exporter.budgets` set, account and category balances go to Alloy through
  [actual-budget-prometheus-exporter](https://github.com/sakowicz/actual-budget-prometheus-exporter).
- **ghostfolio**: [Ghostfolio](https://ghostfol.io), portfolio and net
  worth tracking.
- **ghostbudget**: syncs Actual Budget account balances into Ghostfolio
  on a schedule.
