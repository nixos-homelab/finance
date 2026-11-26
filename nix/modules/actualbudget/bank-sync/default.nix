# The bank sync of Actual Budget on a schedule: Actual runs it only from its UI, or while a client with automatic sync
# is open. A CronJob runs bank-sync.js, which has the server sync every linked account and uploads the result
{ ... }:
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.homelab.actualbudget;
  nodejs = pkgs.nodejs_22;
  nodejs-slim = pkgs.nodejs-slim_22;
  bank-sync = pkgs.buildNpmPackage {
    inherit nodejs;
    pname = "actualbudget-bank-sync";
    version = "1.0.0";
    src = lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.unions [
        ./package.json
        ./package-lock.json
        ./bank-sync.js
      ];
    };
    npmDepsHash = "sha256-zvcK+ht5U71G60BypoxwDGc9Q8nZOnVTS+35i6YDaJ8=";
    nativeBuildInputs = [ pkgs.python3 ];
    dontNpmInstall = true;
    # better-sqlite3 ships prebuilt addons and no install script; build/Release takes precedence over them
    buildPhase = ''
      runHook preBuild
      (cd node_modules/better-sqlite3 && npm run build-release)
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      npm prune --omit=dev --no-save
      # Keep only the compiled addon; the build tree references python3
      find node_modules/better-sqlite3/build -type f ! -name better_sqlite3.node -delete
      rm -r node_modules/better-sqlite3/{deps,src,prebuilds}
      # The image only has nodejs-slim, without npm
      grep -rlZ ${nodejs} node_modules | xargs -0 sed -i 's|${nodejs}|${nodejs-slim}|'
      mkdir $out
      cp -a node_modules bank-sync.js $out
      runHook postInstall
    '';
  };
  image = pkgs.dockerTools.buildImage {
    name = "cluster.local/actualbudget-bank-sync";
    copyToRoot = [
      pkgs.cacert
      nodejs-slim
    ];
    config.Entrypoint = [
      (lib.getExe nodejs-slim)
      "${bank-sync}/bank-sync.js"
    ];
  };
in
{
  options.homelab.actualbudget.bankSync = {
    schedule = lib.mkOption {
      description = ''
        Cronjob notation of when the bank sync of Actual Budget runs for every linked account (SimpleFIN, GoCardless,
        ...). Providers limit how often you may sync (SimpleFIN allows 24 requests a day, and a run makes one for all
        its accounts), so keep it to a few runs a day.
      '';
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "15 6,12,18 * * *";
    };
    budgetSyncId = lib.mkOption {
      description = "Sync ID of the budget whose accounts the bank sync runs for, under Settings → Advanced in Actual";
      type = lib.types.str;
      example = "bba4b622-c8d1-4bdb-84d0-a8ecfb240ca8";
    };
  };
  config = lib.mkIf (cfg.enable && cfg.bankSync.schedule != null) {
    homelab.cluster.images = [ image ];
    homelab.kubernetes.submodules.instances.actualbudget.config.submodules.instances.bank-sync = {
      submodule = "cronjob";
      args = {
        inherit (cfg.bankSync) schedule;
        # The server talks to the providers, with the credentials it holds
        allowEgress = [ "actualbudget" ];
        container = {
          image = "${image.buildArgs.name}:${image.imageTag}";
          imagePullPolicy = "Never";
          env = {
            ACTUAL_BUDGET_URL.value = "http://actualbudget.actualbudget:5006";
            # The password the HTTPRoute of actualbudget logs in with, as ghostbudget and the exporter do
            ACTUAL_BUDGET_PASS.value = "actual";
            ACTUAL_BUDGET_SYNC_ID.value = cfg.bankSync.budgetSyncId;
            # The API library's copy of the budget, downloaded on every run
            ACTUAL_BUDGET_DATA_DIR.value = "/data";
          };
          volumeMounts."/data".name = "data";
        };
      };
      config.kubernetes.resources.cronJobs.bank-sync = {
        # A run that outlasts the next start would sync twice against the provider's limit
        spec.concurrencyPolicy = "Forbid";
        spec.jobTemplate.spec.template.spec.volumes.data.emptyDir = { };
      };
    };
    homelab.alloy.logs.pods.bank-sync = {
      namespace = "actualbudget";
      format = "actual-client";
      # The Actual API's own progress, which says nothing the sync's lines around it don't
      demote.breadcrumbs.expression = "(?s)\\[Breadcrumb\\] \\{.*\\}";
      examples = [
        {
          lines = [
            "info: Syncing 3 linked accounts: Privat (simpleFin, last sync 2026-11-14T08:12:00.000Z)"
            "[Breadcrumb] { message: 'loading spreadsheet', category: 'server' }"
            "error: Bank sync failed: Rate limit exceeded (RATE_LIMIT_EXCEEDED)"
          ];
          expect = [
            {
              message = "Syncing 3 linked accounts: Privat (simpleFin, last sync 2026-11-14T08:12:00.000Z)";
              level = "info";
            }
            {
              message = "[Breadcrumb] { message: 'loading spreadsheet', category: 'server' }";
              level = "debug";
            }
            {
              message = "Bank sync failed: Rate limit exceeded (RATE_LIMIT_EXCEEDED)";
              level = "error";
            }
          ];
        }
      ];
    };
  };
}
