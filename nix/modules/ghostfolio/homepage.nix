{ inputs, self, ... }:
{
  lib,
  pkgs,
  config,
  ...
}:
let
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
      defaultText = lib.literalExpression "config.homelab.ghostfolio.enable && config.homelab.homepage.enable";
    };
  };
  imports = [
    inputs.setup-secrets.nixosModules.default
    inputs.homelab-shared.nixosModules.homepage
    self.nixosModules.homepage
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
      sections.Finance.enable = lib.mkDefault true;
      allowEgress = [ "ghostfolio" ];
      services.Finance.Ghostfolio = {
        enable = lib.mkDefault true;
        icon = "ghostfolio.png";
        description = "Portfolio tracker";
        href = "https://ghostfolio.${config.homelab.workloads.domain}";
        widgets = [
          {
            type = "ghostfolio";
            url = "http://ghostfolio.ghostfolio:3333";
            fields = [
              "gross_percent_today"
              "gross_percent_1y"
              "net_worth"
            ];
            key = "{{HOMEPAGE_VAR_GHOSTFOLIO_API_TOKEN}}";
          }
        ];
      };
      envFrom = [ { secretRef.name = "ghostfolio-api-token"; } ];
    };
    homelab.cluster.manifests.homepage-refresh-ghostfolio-api-token-static.source = ./homepage.yaml;
    # In the manifest of ghostfolio, as before
    homelab.kubernetes.submodules.instances.ghostfolio.config.submodules.instances = {
      create-ghostfolio-api-token = {
        submodule = "script";
        args = {
          script = refreshGhostfolioAPIToken;
          allowEgress = [
            "apiserver"
            "ghostfolio"
          ];
          container.envFrom = [ { secretRef.name = "ghostfolio-token"; } ];
        };
        config.kubernetes = {
          namespace = "homepage";
          resources.jobs.create-ghostfolio-api-token.spec.template.spec.serviceAccountName =
            "refresh-ghostfolio-api-token";
        };
      };
      refresh-ghostfolio-api-token = {
        submodule = "cronjob";
        args = {
          schedule = "30 03 01 */6 *";
          allowEgress = [
            "apiserver"
            "ghostfolio"
          ];
          container = {
            image = "${container-utils.buildArgs.name}:${container-utils.imageTag}";
            imagePullPolicy = "Never";
            command = [ "bash" ];
            args = [ "/scripts/create-ghostfolio-api-token.sh" ];
            env.GHOSTFOLIO_TOKEN.valueFrom.secretKeyRef = {
              name = "ghostfolio-token";
              key = "GHOSTFOLIO_TOKEN";
            };
            volumeMounts."/scripts/create-ghostfolio-api-token.sh" = {
              name = "script";
              subPath = "create-ghostfolio-api-token.sh";
              readOnly = true;
            };
          };
        };
        config.kubernetes = {
          namespace = "homepage";
          # Labeled as the homepage pods
          resources.cronJobs.refresh-ghostfolio-api-token = {
            metadata.labels."app.kubernetes.io/name" = lib.mkForce "homepage";
            spec.jobTemplate.spec.template = {
              metadata.labels."app.kubernetes.io/name" = lib.mkForce "homepage";
              spec = {
                serviceAccountName = "refresh-ghostfolio-api-token";
                volumes.script.configMap.name = "create-ghostfolio-api-token";
              };
            };
          };
        };
      };
    };
  };
}
