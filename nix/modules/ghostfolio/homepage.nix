{ inputs, self, ... }:
{
  lib,
  pkgs,
  config,
  ...
}:
let
  ccfg = config.homelab.cluster;
  hllib = inputs.homelab-shared.lib;
  container-utils = inputs.homelab-shared.packages.${pkgs.stdenv.hostPlatform.system}.container-utils;
  refreshGhostfolioAPIToken = pkgs.writeShellScriptBin "refresh-ghostfolio-api-token.sh" ''
    set -eo pipefail
    GHOSTFOLIO_API_TOKEN=$(curl -sX POST http://ghostfolio.ghostfolio:3333/api/v1/auth/anonymous \
      -H 'Content-Type: application/json' -d "{ \"accessToken\": \"$GHOSTFOLIO_TOKEN\" }" | \
      jq -r .authToken
    )
    ${lib.getExe pkgs.kubectl} create -n homepage secret generic --dry-run=client -oyaml ghostfolio-api-token \
      --from-literal=GHOSTFOLIO_API_TOKEN="$GHOSTFOLIO_API_TOKEN" | \
      ${lib.getExe pkgs.kubectl} apply -f -
  '';
  cfg = config.homelab.homepage.integrations.ghostfolio;
in
{
  options.homelab.homepage.integrations.ghostfolio = {
    enable = lib.mkOption {
      description = "integration of ghostfolio with homepage";
      type = lib.types.bool;
      default = config.homelab.ghostfolio.enable && config.homelab.homepage.enable;
    };
  };
  imports = [
    inputs.setup-secrets.nixosModules.default
    inputs.homelab-shared.nixosModules.homepage
  ];
  config = lib.mkIf cfg.enable {
    setup-secrets.destinations = [
      {
        logPrefix = "Homepage (GHOSTFOLIO_TOKEN)";
        requires = [ "GHOSTFOLIO_TOKEN" ];
        cmd = hllib.setup-secrets.mkScript pkgs ''setKubeSecret homepage ghostfolio-token GHOSTFOLIO_TOKEN "''${GHOSTFOLIO_TOKEN:?}"'';
      }
    ];
    homelab.homepage = {
      allowEgress = [ "ghostfolio" ];
      services.Finance.Ghostfolio = {
        icon = "ghostfolio.png";
        description = "Portfolio tracker";
        href = "https://ghostfolio.${ccfg.domain}";
        widget = {
          type = "ghostfolio";
          url = "http://ghostfolio.ghostfolio:3333";
          fields = [
            "gross_percent_today"
            "gross_percent_1y"
            "net_worth"
          ];
          key = "{{HOMEPAGE_VAR_GHOSTFOLIO_API_TOKEN}}";
        };
      };
      envByName.HOMEPAGE_VAR_GHOSTFOLIO_API_TOKEN.valueFrom.secretKeyRef = {
        name = "ghostfolio-api-token";
        key = "GHOSTFOLIO_API_TOKEN";
      };
    };
    services.k3s.manifests.homepage-refresh-ghostfolio-api-token-static.source = ./homepage.yaml;
    kubetree.resources.homepage =
      let
        jobSpec = {
          template.metadata.labels = {
            "app.kubernetes.io/name" = "ghostfolio";
            "cluster.local/apiserver-egress" = "allow";
            "cluster.local/ghostfolio-egress" = "allow";
          };
          template.podSpecMacro = {
            name = "token";
            restartPolicy = "OnFailure";
            serviceAccountName = "refresh-ghostfolio-api-token";
            mainContainer =
              let
                # Calculate mountpath dynamically so the job re-runs on changes
                refreshGhostfolioAPITokenMountPath = "/scripts/${
                  builtins.substring 0 8 (builtins.hashString "sha256" (lib.getExe refreshGhostfolioAPIToken))
                }.sh";
              in
              {
                image = "${container-utils.buildArgs.name}:${container-utils.imageTag}";
                imagePullPolicy = "Never";
                command = [ (lib.getExe pkgs.bash) ];
                args = [ "${refreshGhostfolioAPITokenMountPath}" ];
                envByName.GHOSTFOLIO_TOKEN.valueFrom.secretKeyRef = {
                  name = "ghostfolio-token";
                  key = "GHOSTFOLIO_TOKEN";
                };
                volumeMountsByPath = {
                  ${refreshGhostfolioAPITokenMountPath} = {
                    name = "script";
                    subPath = "refresh-ghostfolio-api-token.sh";
                    readOnly = true;
                  };
                };
              };
            volumesByName.script.configMap.name = "refresh-ghostfolio-api-token-script";
          };
        };
      in
      {
        refresh-ghostfolio-api-token-script = {
          apiVersion = "v1";
          kind = "ConfigMap";
          metadata.namespace = "homepage";
          metadata.name = "refresh-ghostfolio-api-token-script";
          data."refresh-ghostfolio-api-token.sh" = builtins.readFile (lib.getExe refreshGhostfolioAPIToken);
        };
        create-ghostfolio-api-token = {
          apiVersion = "batch/v1";
          kind = "Job";
          metadata = {
            namespace = "homepage";
            name = "create-ghostfolio-api-token";
            labels."app.kubernetes.io/name" = "homepage";
          };
          spec = jobSpec;
        };
        refresh-ghostfolio-api-token = {
          apiVersion = "batch/v1";
          kind = "CronJob";
          metadata = {
            namespace = "homepage";
            name = "refresh-ghostfolio-api-token";
            labels."app.kubernetes.io/name" = "homepage";
          };
          spec.schedule = "30 03 01 */6 *";
          spec.jobTemplate.spec = jobSpec;
        };
      };
  };
}
