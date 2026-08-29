{ inputs, self, ... }:
{
  lib,
  pkgs,
  config,
  ...
}:
let
  ccfg = config.homelab.cluster;
  cfg = config.homelab.homepage.integrations.actualbudget;
in
{
  options.homelab.homepage.integrations.actualbudget = {
    enable = lib.mkOption {
      description = "integration of actualbudget with homepage";
      type = lib.types.bool;
      default = config.homelab.actualbudget.enable && config.homelab.homepage.enable;
      defaultText = lib.literalExpression "config.homelab.actualbudget.enable && config.homelab.homepage.enable";
    };
  };
  imports = [
    inputs.setup-secrets.nixosModules.default
    inputs.homelab-shared.nixosModules.homepage
    self.nixosModules.homepage
  ];
  config = lib.mkIf cfg.enable {
    homelab.homepage = {
      sections.Finance.enable = lib.mkDefault true;
      services.Finance.actualbudget = {
        enable = lib.mkDefault true;
        icon = "actual-budget.png";
        href = "https://actualbudget.${ccfg.domain}";
        description = "Budgeting app";
      };
    };
  };
}
