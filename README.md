# nixos-homelab-finance

Personal finance apps on top of [nixos-homelab](https://github.com/nixos-homelab/shared):
budgeting and portfolio tracking, plus companion services that keep them
in sync with each other and with external data sources.

For the full list of module options, see [docs/options.md](docs/options.md).

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
  budgeting.
- **actual-flow**: syncs transactions from [Lunchflow](https://www.lunchflow.app)
  into Actual Budget accounts on a schedule.
- **ghostfolio**: [Ghostfolio](https://ghostfol.io), portfolio and net
  worth tracking.
- **ghostbudget**: syncs Actual Budget account balances into Ghostfolio
  on a schedule.
