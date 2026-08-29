{ inputs, ... }:
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
  ];
  config = lib.mkIf cfg.enable {
    homelab.homepage = {
      assets."actualbudget.png" = ./logo.png;
      bookmarks.Finance.actualbudget = {
        icon = "/assets/actualbudget.png";
        href = "https://actualbudget.${ccfg.domain}";
        description = "Budgeting app";
      };
    };
  };
}
