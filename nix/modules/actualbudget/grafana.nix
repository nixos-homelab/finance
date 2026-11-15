# Actual Budget's rows of the Workload dashboard, shown for its namespace
{ inputs, ... }:
{ config, lib, ... }:
let
  g = inputs.homelab-monitoring.lib.grafana;
  cfg = config.homelab.actualbudget;
  j = ''namespace="actualbudget"'';
in
{
  imports = [ inputs.homelab-monitoring.nixosModules.grafana ];
  options.homelab.actualbudget.grafana.enable = lib.mkOption {
    description = "Whether the Workload dashboard has Actual Budget's rows.";
    type = lib.types.bool;
    default =
      cfg.enable && cfg.metrics.enable && config.homelab.alloy.enable && config.homelab.grafana.enable;
    defaultText = lib.literalExpression ''
      config.homelab.actualbudget.enable && config.homelab.actualbudget.metrics.enable && config.homelab.alloy.enable
      && config.homelab.grafana.enable
    '';
  };
  config = lib.mkIf cfg.grafana.enable {
    homelab.grafana.drilldown.rows.actualbudget = {
      workload = "actualbudget";
      row = g.row { title = "Actual Budget"; } (
        g.autoGrid { columns = 2; } [
          (g.stat {
            title = "Total balance";
            description = "Every account; Actual keeps amounts in cents";
            decimals = 2;
            queries = [
              (g.prom "actual_budget_balance{${j}} / 100" {
                instant = true;
                legend = "{{budget}}";
              })
            ];
          })
          (g.bargauge {
            title = "Accounts";
            decimals = 2;
            queries = [
              (g.prom "sort_desc(actual_budget_account_balance{${j}} / 100)" {
                instant = true;
                legend = "{{account}}";
              })
            ];
          })
          (g.bargauge {
            title = "Categories this month";
            decimals = 2;
            queries = [
              (g.prom "sort_desc(actual_budget_category_balance{${j}} / 100)" {
                instant = true;
                legend = "{{category}}";
              })
            ];
          })
          (g.timeseries {
            title = "Total balance over time";
            decimals = 2;
            queries = [ (g.prom "actual_budget_balance{${j}} / 100" { legend = "{{budget}}"; }) ];
          })
          (g.stat {
            title = "Transactions";
            decimals = 0;
            queries = [
              (g.prom "sum(actual_budget_transaction_count{${j}})" {
                instant = true;
                legend = "all";
              })
              (g.prom "sum(actual_budget_uncategorized_transaction_count{${j}})" {
                instant = true;
                legend = "uncategorized";
              })
            ];
          })
        ]
      );
    };
  };
}
