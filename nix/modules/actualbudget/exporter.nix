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
  nodejs = pkgs.nodejs_22;
  nodejs-slim = pkgs.nodejs-slim_22;
  exporter = pkgs.buildNpmPackage rec {
    inherit nodejs;
    pname = "actual-budget-prometheus-exporter";
    version = "1.3.2";
    src = pkgs.fetchFromGitHub {
      owner = "sakowicz";
      repo = pname;
      rev = "b8b6ffaea71c0e819143ef4805b78e86cb722871";
      hash = "sha256-vxDeTQo9jfEzj56niBdDTG3X7NpFYgjipfwTcI9YtAY=";
    };
    npmDepsHash = "sha256-7ss7xFANWMDQlgEvttgm18DQMYQY9kPJGf0qcCl3qCY=";
    nativeBuildInputs = [ pkgs.python3 ];
    # better-sqlite3 13 ships prebuilt addons and no install script: the addon from its sources instead, against
    # this node, where the loader falls back to it without prebuilds
    preBuild = ''
      rm -r node_modules/better-sqlite3/prebuilds
      npm run --prefix node_modules/better-sqlite3 build-release -- --nodedir=${nodejs}
    '';
    # `npm run build` (tsc) makes dist/
    dontNpmInstall = true;
    installPhase = ''
      runHook preInstall
      npm prune --omit=dev --no-save
      # Keep only the compiled addon; the build tree references python3
      find node_modules/better-sqlite3/build -type f ! -name better_sqlite3.node -delete
      rm -r node_modules/better-sqlite3/{deps,src}
      # The image only has nodejs-slim, without npm
      grep -rlZ ${nodejs} node_modules | xargs -0 -r sed -i 's|${nodejs}|${nodejs-slim}|'
      mkdir $out
      cp -a node_modules dist $out
      runHook postInstall
    '';
  };
  image = pkgs.dockerTools.buildImage {
    name = "cluster.local/${name}";
    copyToRoot = [ nodejs-slim ];
    config.Entrypoint = [
      (lib.getExe nodejs-slim)
      "${exporter}/dist/app.js"
    ];
  };
in
{
  imports = [ inputs.homelab-monitoring.nixosModules.alloy ];
  options.homelab.actualbudget.exporter.budgets = lib.mkOption {
    description = ''
      Budgets whose balances [actual-budget-prometheus-exporter](https://github.com/sakowicz/actual-budget-prometheus-exporter)
      exports, by the name in their `budget` label, each the sync ID of the budget (Settings, Advanced settings).
      Without any, no exporter runs. End-to-end encrypted budgets aren't supported.
    '';
    type = lib.types.attrsOf lib.types.str;
    default = { };
    example.main = "bba4b622-c8d1-4bdb-84d0-a8ecfb240ca8";
  };
  config = lib.mkIf (cfg.enable && cfg.exporter.budgets != { }) {
    homelab.cluster.images = [ image ];
    # Every scrape downloads the budgets and walks all their transactions: not every minute. Balances are sensitive,
    # only Alloy gets the egress label that lets it in.
    homelab.alloy.monitors.${name} = {
      namespace = "actualbudget";
      endpoint = {
        interval = "2m";
        scrapeTimeout = "1m";
      };
    };
    # In the manifest of actualbudget, with the namespace
    homelab.kubernetes.submodules.instances.actualbudget.config.submodules.instances = {
      ${name} = {
        submodule = "deployment";
        args = {
          allowEgress = [ "actualbudget" ];
          ports.metrics = port;
          container = {
            image = "${image.buildArgs.name}:${image.imageTag}";
            imagePullPolicy = "Never";
            env = {
              PORT.value = toString port;
              ACTUAL_SERVER_URL.value = "http://actualbudget.actualbudget:5006";
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
            # /metrics fetches the budgets, every other path is a 404
            livenessProbe.tcpSocket.port = "metrics";
            readinessProbe.tcpSocket.port = "metrics";
            # The API library keeps the downloaded budgets in /tmp/actual-budget-prometheus-exporter
            volumeMounts."/tmp".name = "tmp";
          };
        };
        config.kubernetes.resources.deployments.${name}.spec.template.spec.volumes.tmp.emptyDir = { };
      };
      # A key apart from the Deployment instance, the same object name
      "${name}-service" = {
        inherit name;
        submodule = "service";
        args.ports.metrics = port;
      };
    };
  };
}
