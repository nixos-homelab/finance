{ inputs, ... }:
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.homelab.actualbudget;
  name = "actualbudget-exporter";
  port = 3001;
  # The exporter's own image, pinned in the Dockerfile next to Actual's
  image =
    (inputs.homelab-shared.lib.images.pinned pkgs ./Dockerfile)
    ."sakowicz/actual-budget-prometheus-exporter";
in
{
  imports = [ inputs.homelab-monitoring.nixosModules.alloy ];
  options.homelab.actualbudget.metrics.enable = lib.mkOption {
    description = ''
      Whether Alloy scrapes Actual Budget's metrics, and runs its exporter sidecar for the budgets in
      `exporter.budgets`. Off by default for privacy: the metrics are account and category balances, which land in
      Mimir for every Grafana user to query.
    '';
    type = lib.types.bool;
    default = false;
  };
  options.homelab.actualbudget.exporter.budgets = lib.mkOption {
    description = ''
      Budgets whose balances [actual-budget-prometheus-exporter](https://github.com/sakowicz/actual-budget-prometheus-exporter)
      exports, by the name in their `budget` label, each the sync ID of the budget (Settings, Advanced settings).
      Without any, with `metrics.enable` off or while Alloy is off, no exporter runs. End-to-end encrypted budgets aren't supported.
    '';
    type = lib.types.attrsOf lib.types.str;
    default = { };
    example.main = "bba4b622-c8d1-4bdb-84d0-a8ecfb240ca8";
  };
  config = lib.mkIf (cfg.enable && cfg.metrics.enable && cfg.exporter.budgets != { }) {
    # Every scrape downloads the budgets and walks all their transactions: not every minute. Balances are sensitive:
    # podPort, so Alloy reaches the exporter's port alone
    homelab.alloy.monitors.actualbudget = {
      podPort = port;
      # Its instance is a workload, which can't hold the policy (kubenix nesting): a manifest of its own
      manifest = null;
      endpoint = {
        interval = "2m";
        scrapeTimeout = "1m";
      };
    };
    homelab.cluster.images = lib.mkIf config.homelab.alloy.enable [ image ];
    # A sidecar of Actual: it reads the budgets over localhost and lives and dies with Actual. Turning Alloy on or off,
    # or changing the budgets, restarts Actual
    homelab.kubernetes.submodules.instances.actualbudget.config.kubernetes.resources =
      lib.mkIf config.homelab.alloy.enable
        {
          deployments.actualbudget.spec.template = {
            # The sidecar sorts first, where kubectl logs and exec would go without -c
            metadata.annotations."kubectl.kubernetes.io/default-container" = "actualbudget";
            spec = {
              containers.${name} = {
                image = image.ref;
                imagePullPolicy = "Never";
                env = {
                  PORT.value = toString port;
                  ACTUAL_SERVER_URL.value = "http://127.0.0.1:5006";
                  # The password the HTTPRoute of actualbudget logs in with, as ghostbudget does
                  ACTUAL_PASSWORD.value = "actual";
                }
                # Numbered from 1, the exporter reads them until the first missing ID
                // lib.listToAttrs (
                  lib.concatLists (
                    lib.imap1 (i: budget: [
                      (lib.nameValuePair "ACTUAL_BUDGET_ID_${toString i}" { value = cfg.exporter.budgets.${budget}; })
                      (lib.nameValuePair "ACTUAL_BUDGET_NAME_${toString i}" { value = budget; })
                    ]) (lib.attrNames cfg.exporter.budgets)
                  )
                );
                ports.metrics.containerPort = port;
                securityContext = {
                  allowPrivilegeEscalation = false;
                  readOnlyRootFilesystem = true;
                  capabilities.drop = [ "ALL" ];
                };
                # /metrics fetches the budgets, every other path is a 404
                livenessProbe.tcpSocket.port = "metrics";
                readinessProbe.tcpSocket.port = "metrics";
                # The API library keeps the downloaded budgets in /tmp/actual-budget-prometheus-exporter
                volumeMounts."/tmp".name = "${name}-tmp";
              };
              volumes."${name}-tmp".emptyDir = { };
            };
          };
          services.actualbudget.spec.ports.metrics.port = port;
        };
  };
}
