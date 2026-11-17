# Actual Budget's row of the Workload dashboard, shown for its namespace
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
        g.pack [
          {
            w = 6;
            h = 4;
            panel = g.stat {
              title = "Balance";
              description = "Every account together (Actual keeps amounts in cents; shown as units of the budget's currency)";
              decimals = 2;
              queries = [ (g.prom "sum(actual_budget_balance{${j}}) / 100" { }) ];
            };
          }
          {
            w = 6;
            h = 4;
            panel = g.stat {
              title = "Uncategorized";
              description = "Transactions without a category, waiting to be sorted; orange from 1, red from 20";
              decimals = 0;
              levels = g.levels {
                warn = 1;
                crit = 20;
              };
              queries = [ (g.prom "sum(actual_budget_uncategorized_transaction_count{${j}}) or vector(0)" { }) ];
            };
          }
          {
            w = 6;
            h = 4;
            panel = g.stat {
              title = "Overspent categories";
              description = "This month's categories with a negative balance: more spent than budgeted. Orange from 1, red from 3";
              decimals = 0;
              levels = g.levels {
                warn = 1;
                crit = 3;
              };
              queries = [ (g.prom "count(actual_budget_category_balance{${j}} < 0) or vector(0)" { }) ];
            };
          }
          {
            w = 6;
            h = 4;
            panel = g.stat {
              title = "Transactions";
              description = "Transactions in the budget";
              decimals = 0;
              queries = [ (g.prom "sum(actual_budget_transaction_count{${j}})" { }) ];
            };
          }
          {
            w = 12;
            h = 8;
            panel = g.timeseries {
              title = "Balance over time";
              description = "Every account together, over time";
              decimals = 2;
              queries = [
                (g.prom "sum by (budget) (actual_budget_balance{${j}}) / 100" { legend = "{{budget}}"; })
              ];
            };
          }
          {
            w = 12;
            h = 8;
            panel = g.bargauge {
              title = "Accounts";
              description = "Each account's balance, the biggest first";
              decimals = 2;
              queries = [
                (g.prom "sort_desc(actual_budget_account_balance{${j}} / 100)" {
                  instant = true;
                  legend = "{{account}}";
                })
              ];
            };
          }
          {
            w = 24;
            h = 9;
            panel = g.bargauge {
              title = "Categories this month";
              description = "What's left in each category this month: red where more was spent than budgeted";
              decimals = 2;
              thresholds = [
                {
                  value = null;
                  color = "red";
                }
                {
                  value = 0;
                  color = "text";
                }
              ];
              queries = [
                (g.prom "sort_desc(actual_budget_category_balance{${j}} / 100)" {
                  instant = true;
                  legend = "{{category}}";
                })
              ];
              options.displayMode = "basic";
            };
          }
        ]
      );
    };
  };
}
