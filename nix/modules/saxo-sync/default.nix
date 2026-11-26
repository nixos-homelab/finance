# Saxo Bank → Ghostfolio: transactions and cash balances from Saxo's OpenAPI (LIVE, read-only), as two CronJobs in
# Ghostfolio's namespace that share a PersistentVolumeClaim with the OAuth tokens. `saxo-refresh` rotates the tokens
# every 10 minutes and fails when the session is gone, which is when a browser login is due (kube-state-metrics' "Job
# failed" alert); `saxo-sync` imports on `schedule`. See README.md next to this file
{ inputs, self, ... }:
{
  pkgs,
  lib,
  config,
  ...
}:
let
  ccfg = config.homelab.cluster;
  gcfg = config.homelab.ghostfolio;
  cfg = gcfg.saxo;
  hllib = inputs.homelab-shared.lib;
  saxo-sync = self.packages.${pkgs.stdenv.hostPlatform.system}.saxo-sync;
  image = pkgs.dockerTools.buildImage {
    name = "cluster.local/saxo-sync";
    copyToRoot = [ pkgs.cacert ] ++ lib.optionals cfg.debug ccfg.debugTools;
    config.Env = [ "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt" ];
    config.Entrypoint = [ (lib.getExe saxo-sync) ];
  };
  ghostbudgetEnabled = gcfg.importSchedule != null && config.homelab.actualbudget.enable;
  env = {
    SAXO_APP_KEY.value = cfg.appKey;
    SAXO_REDIRECT_URI.value = cfg.redirectUri;
    SAXO_STATE_DIR.value = "/state";
    SAXO_CONFIG.value = "/config.json";
  };
  volumeMounts = {
    "/state".name = "state";
    "/config.json" = {
      name = "config";
      subPath = "config.json";
    };
  };
  volumes = {
    state.persistentVolumeClaim.claimName = "saxo-sync";
    config.configMap.name = "saxo-sync";
  };
  labelled = name: {
    metadata.labels."app.kubernetes.io/name" = lib.mkForce name;
    spec.jobTemplate.spec.template.metadata.labels."app.kubernetes.io/name" = lib.mkForce name;
  };
in
{
  options.homelab.ghostfolio.saxo = {
    enable = lib.mkEnableOption "the Saxo Bank import into Ghostfolio";
    debug = lib.mkEnableOption "debug tools in the image";
    appKey = lib.mkOption {
      description = "App Key of the LIVE app in Saxo's developer portal (Code grant, trading not allowed). Its App Secret goes in through setup-secrets (`SAXO_APP_SECRET`).";
      type = lib.types.str;
      example = "0123456789abcdef0123456789abcdef";
    };
    redirectUri = lib.mkOption {
      description = "A redirect URL of the app. Nothing has to answer there: the login is finished with the URL the browser lands on.";
      type = lib.types.str;
      example = "https://example.org/saxo";
    };
    schedule = lib.mkOption {
      description = "When the import runs, in cron notation. Saxo publishes a day's transactions at the end of its processing cycle, so mornings see yesterday's.";
      type = lib.types.str;
      default = "30 6 * * *";
    };
    dryRun = lib.mkOption {
      description = "Whether the import only logs what it would write to Ghostfolio. Ghostfolio checks the activities in its own dry run; nothing is written.";
      type = lib.types.bool;
      default = false;
    };
    accounts = lib.mkOption {
      description = "The Saxo accounts to import and the Ghostfolio account of each.";
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            saxoAccountId = lib.mkOption {
              description = "Saxo's AccountId (`/port/v1/accounts/me`), as SaxoTraderGO shows it.";
              type = lib.types.str;
              example = "123456INET";
            };
            ghostfolioName = lib.mkOption {
              description = "Name of the Ghostfolio account.";
              type = lib.types.str;
            };
            importFrom = lib.mkOption {
              description = "The first day whose transactions are imported. Ghostfolio's history before it stays as it is (typed in by hand, without the `saxo:` comments the import recognises its own activities by).";
              type = lib.types.strMatching "[0-9]{4}-[0-9]{2}-[0-9]{2}";
              default = "2000-01-01";
            };
          };
        }
      );
      default = [ ];
    };
    symbols = lib.mkOption {
      description = ''
        Ghostfolio symbols by ISIN, for instruments Ghostfolio already holds under a symbol of its own. Any other
        instrument goes to the import as its ISIN, which Ghostfolio resolves through the data provider; the dry run
        logs what it resolves to.
      '';
      type = lib.types.attrsOf (
        lib.types.coercedTo lib.types.str (symbol: { inherit symbol; }) (
          lib.types.submodule {
            options = {
              symbol = lib.mkOption {
                description = "The symbol at the data source.";
                type = lib.types.str;
              };
              dataSource = lib.mkOption {
                description = "Ghostfolio's data source.";
                type = lib.types.str;
                default = "YAHOO";
              };
            };
          }
        )
      );
      default = { };
      example = {
        DK0062498333 = "NOVO-B.CO";
      };
    };
    ignore = lib.mkOption {
      description = "Saxo transactions left out on purpose, by the comment their activity would get (`saxo:trade:<TradeId>`, `saxo:ca:<CorporateActionId>`, `saxo:booking:<BookingId>`). Anything the import can't map stops it until it is mapped or listed here.";
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
  };
  imports = [ inputs.setup-secrets.nixosModules.default ] ++ self.lib.importsApply [ ./logs.nix ];
  config = lib.mkIf (gcfg.enable && cfg.enable) {
    homelab.cluster.images = [ image ];
    setup-secrets = {
      sources.SAXO_APP_SECRET = hllib.setup-secrets.kubeSecretSource pkgs {
        description = "Saxo App Secret";
        namespace = "ghostfolio";
        name = "saxo-app";
        field = "SAXO_APP_SECRET";
        # Copied from Saxo's developer portal on a real machine
        test = "echo test-saxo-app-secret";
      };
      destinations = [
        (hllib.setup-secrets.kubeSecretDestination pkgs {
          logPrefix = "Saxo sync (SAXO_APP_SECRET)";
          namespace = "ghostfolio";
          name = "saxo-app";
          data.SAXO_APP_SECRET = "SAXO_APP_SECRET";
        })
      ]
      # ghostbudget writes the same Secret when it runs
      ++ lib.optional (!ghostbudgetEnabled) (
        hllib.setup-secrets.kubeSecretDestination pkgs {
          logPrefix = "Saxo sync (GHOSTFOLIO_TOKEN)";
          namespace = "ghostfolio";
          name = "ghostfolio-token";
          data.GHOSTFOLIO_TOKEN = "GHOSTFOLIO_TOKEN";
        }
      );
    };
    homelab.kubernetes.submodules.instances.ghostfolio.config = {
      kubernetes.resources = {
        configMaps.saxo-sync = {
          metadata.labels."app.kubernetes.io/name" = "saxo-sync";
          data."config.json" = builtins.toJSON { inherit (cfg) accounts symbols ignore; };
        };
        persistentVolumeClaims.saxo-sync.spec = {
          accessModes = [ "ReadWriteOnce" ];
          resources.requests.storage = "16Mi";
          volumeMode = "Filesystem";
        };
      };
      submodules.instances = {
        saxo-refresh = {
          submodule = "cronjob";
          args = {
            schedule = "*/10 * * * *";
            allowEgress = [ "internet" ];
            container = {
              image = "${image.buildArgs.name}:${image.imageTag}";
              imagePullPolicy = "Never";
              args = [ "refresh" ];
              env = env // {
                SAXO_APP_SECRET.valueFrom.secretKeyRef = {
                  name = "saxo-app";
                  key = "SAXO_APP_SECRET";
                };
              };
              inherit volumeMounts;
            };
          };
          config.kubernetes.resources.cronJobs.saxo-refresh = lib.mkMerge [
            (labelled "saxo-sync")
            {
              # One rotation at a time: two would race for the refresh token, and the loser ends the session
              spec.concurrencyPolicy = "Forbid";
              # A failed run is due to the next one: no retries of the pod, and the failed Job (and with it the
              # alert) goes once the next runs have had their chance
              spec.jobTemplate.spec.backoffLimit = 0;
              spec.jobTemplate.spec.ttlSecondsAfterFinished = 1500;
              spec.jobTemplate.spec.activeDeadlineSeconds = 540;
              spec.jobTemplate.spec.template.spec.volumes = volumes;
            }
          ];
        };
        saxo-sync = {
          submodule = "cronjob";
          args = {
            inherit (cfg) schedule;
            allowEgress = [
              "internet"
              "ghostfolio"
            ];
            container = {
              image = "${image.buildArgs.name}:${image.imageTag}";
              imagePullPolicy = "Never";
              args = [ "sync" ] ++ lib.optional cfg.dryRun "--dry-run";
              env = env // {
                GHOSTFOLIO_URL.value = "http://ghostfolio.ghostfolio:3333";
                GHOSTFOLIO_TOKEN.valueFrom.secretKeyRef = {
                  name = "ghostfolio-token";
                  key = "GHOSTFOLIO_TOKEN";
                };
              };
              inherit volumeMounts;
            };
          };
          config.kubernetes.resources.cronJobs.saxo-sync = lib.mkMerge [
            (labelled "saxo-sync")
            {
              spec.concurrencyPolicy = "Forbid";
              spec.jobTemplate.spec.backoffLimit = 0;
              spec.jobTemplate.spec.template.spec.volumes = volumes;
            }
          ];
        };
      };
    };
  };
}
