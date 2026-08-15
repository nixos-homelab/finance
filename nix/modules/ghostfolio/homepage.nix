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
  refreshGhostfolioAPIToken = ''
    #!/usr/bin/env bash
    set -eo pipefail
    GHOSTFOLIO_API_TOKEN=$(curl -sX POST http://ghostfolio.ghostfolio:3333/api/v1/auth/anonymous \
      -H 'Content-Type: application/json' -d "{ \"accessToken\": \"$GHOSTFOLIO_TOKEN\" }" | \
      jq -r .authToken
    )
    kubectl create -n homepage secret generic --dry-run=client -oyaml ghostfolio-api-token \
      --from-literal=HOMEPAGE_VAR_GHOSTFOLIO_API_TOKEN="$GHOSTFOLIO_API_TOKEN" | \
      kubectl apply -f -
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
      envFrom = [ { secretRef.name = "ghostfolio-api-key"; } ];
    };
    services.k3s.manifests.homepage-refresh-ghostfolio-api-token-static.source = ./homepage.yaml;
    kubetree.resources.ghostfolio.create-ghostfolio-api-token = {
      apiVersion = "cluster.local";
      kind = "ScriptMacro";
      metadata.namespace = "homepage";
      metadata.name = "create-ghostfolio-api-token";
      spec.allowEgress = [
        "apiserver"
        "ghostfolio"
      ];
      spec = {
        script = refreshGhostfolioAPIToken;
        podSpecMacro.serviceAccountName = "refresh-ghostfolio-api-token";
        podSpecMacro.mainContainer.envFrom = [ { secretRef.name = "ghostfolio-token"; } ];
      };
    };
    kubetree.resources.ghostfolio.refresh-ghostfolio-api-token = {
      apiVersion = "cluster.local";
      kind = "CronJobMacro";
      metadata = {
        namespace = "homepage";
        name = "refresh-ghostfolio-api-token";
        labels."app.kubernetes.io/name" = "homepage";
      };
      spec = {
        schedule = "30 03 01 */6 *";
        allowEgress = [
          "apiserver"
          "ghostfolio"
        ];
        podSpecMacro = {
          serviceAccountName = "refresh-ghostfolio-api-token";
          mainContainer = {
            image = "${container-utils.buildArgs.name}:${container-utils.imageTag}";
            imagePullPolicy = "Never";
            command = [ "bash" ];
            args = [ "/scripts/create-ghostfolio-api-token.sh" ];
            envByName.GHOSTFOLIO_TOKEN.valueFrom.secretKeyRef = {
              name = "ghostfolio-token";
              key = "GHOSTFOLIO_TOKEN";
            };
            volumeMountsByPath = {
              "/scripts/create-ghostfolio-api-token.sh" = {
                name = "script";
                subPath = "create-ghostfolio-api-token.sh";
                readOnly = true;
              };
            };
          };
          volumesByName.script.configMap.name = "create-ghostfolio-api-token";
        };
      };
    };
  };
}
