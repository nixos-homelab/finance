{ inputs, self, ... }:
{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.homelab.ghostfolio;
  hllib = inputs.homelab-shared.lib;
in
{
  options.homelab.ghostfolio = {
    enable = lib.mkEnableOption "Ghostfolio";
  };
  imports = [
    inputs.setup-secrets.nixosModules.default
    inputs.homelab-shared.nixosModules.postgresql
    inputs.homelab-shared.nixosModules.redis
  ]
  ++ self.lib.importsApply [ ./homepage.nix ];
  # TODO: Add tini
  config = lib.mkIf cfg.enable {
    homelab.postgresql.databases.ghostfolio.backup.enable = lib.mkDefault true;
    assertions = [
      {
        assertion = config.homelab.postgresql.enable;
        message = "Ghostfolio depends on the PostgreSQL service. Enable with `homelab.postgresql.enable=true`";
      }
      {
        assertion = config.homelab.redis.enable;
        message = "Ghostfolio depends on the Redis service. Enable with `homelab.redis.enable=true`";
      }
    ];
    setup-secrets = {
      sources.GHOSTFOLIO_TOKEN = {
        description = "Ghostfolio Token";
        cmd = hllib.setup-secrets.mkScript pkgs "getKubeSecret ghostfolio ghostfolio-token GHOSTFOLIO_TOKEN";
      };
      sources.GHOSTFOLIO_ACCESS_TOKEN_SALT = {
        description = "Ghostfolio Access Token Salt";
        cmd = hllib.setup-secrets.mkScript pkgs ''
          getKubeSecret ghostfolio ghostfolio-secrets ACCESS_TOKEN_SALT || \
          tr -dc A-Za-z0-9 </dev/urandom | head -c 64; echo
        '';
      };
      sources.GHOSTFOLIO_JWT_SECRET_KEY = {
        description = "Ghostfolio JWT Secret Key";
        cmd = hllib.setup-secrets.mkScript pkgs ''
          getKubeSecret ghostfolio ghostfolio-secrets JWT_SECRET_KEY || \
          tr -dc A-Za-z0-9 </dev/urandom | head -c 64; echo
        '';
      };
      destinations = [
        {
          logPrefix = "Ghostfolio (ACCESS_TOKEN_SALT & JWT_SECRET_KEY)";
          requires = [
            "GHOSTFOLIO_ACCESS_TOKEN_SALT"
            "GHOSTFOLIO_JWT_SECRET_KEY"
          ];
          cmd = hllib.setup-secrets.mkScript pkgs ''
            kubectl create secret generic -n ghostfolio --dry-run=client ghostfolio-secrets -oyaml \
              --from-literal=ACCESS_TOKEN_SALT="$GHOSTFOLIO_ACCESS_TOKEN_SALT" \
              --from-literal=JWT_SECRET_KEY="$GHOSTFOLIO_JWT_SECRET_KEY" \
              | kubectl apply -f -
          '';
        }
      ];
    };
    homelab.redis.databases.ghostfolio = lib.mkDefault "0";
    kubetree.resources.ghostfolio.workload = {
      apiVersion = "cluster.local";
      kind = "WorkloadMacro";
      metadata.name = "ghostfolio";
      spec = {
        allowEgress = [
          "internet"
          "postgresql"
          "redis"
        ];
        ingressPort = 3333;
        podSpecMacro.mainContainer = {
          image = "ghostfolio/ghostfolio:2.228.0";
          envByName."DATABASE_URL" =
            "postgresql://ghostfolio:ghostfolio@postgresql.postgresql:5432/ghostfolio";
          envByName."REDIS_HOST" = "redis.redis";
          envByName."REDIS_DB" = config.homelab.redis.databases.ghostfolio;
          portsByName.web = 3333;
          envFrom = [ { secretRef.name = "ghostfolio-secrets"; } ];
          livenessProbe.httpGet.port = "web";
          readinessProbe.httpGet.port = "web";
        };
      };
    };
  };
}
