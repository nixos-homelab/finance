{ inputs, self, ... }:
{
  lib,
  config,
  pkgs,
  ...
}:
let
  images = inputs.homelab-shared.lib.images.pinned pkgs ./Dockerfile;
  cfg = config.homelab.ghostfolio;
  hllib = inputs.homelab-shared.lib;
  # Generated only when the Secret is missing, never when the API call fails
  secretSource = description: field: {
    inherit description;
    cmd = hllib.setup-secrets.mkScript pkgs ''
      if [[ -n $(kubectl -n ghostfolio get secret ghostfolio-secrets --ignore-not-found -oname) ]]; then
        getKubeSecret ghostfolio ghostfolio-secrets ${field}
      else
        head -c 1024 /dev/urandom | tr -dc A-Za-z0-9 | head -c 64
      fi
    '';
  };
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
    services.k3s.images = builtins.attrValues images;
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
      sources.GHOSTFOLIO_ACCESS_TOKEN_SALT = secretSource "Ghostfolio Access Token Salt" "ACCESS_TOKEN_SALT";
      sources.GHOSTFOLIO_JWT_SECRET_KEY = secretSource "Ghostfolio JWT Secret Key" "JWT_SECRET_KEY";
      destinations = [
        {
          logPrefix = "Ghostfolio (ACCESS_TOKEN_SALT & JWT_SECRET_KEY)";
          requires = [
            "GHOSTFOLIO_ACCESS_TOKEN_SALT"
            "GHOSTFOLIO_JWT_SECRET_KEY"
          ];
          cmd = hllib.setup-secrets.mkScript pkgs ''
            setKubeSecret ghostfolio ghostfolio-secrets \
              ACCESS_TOKEN_SALT "''${GHOSTFOLIO_ACCESS_TOKEN_SALT:?}" \
              JWT_SECRET_KEY "''${GHOSTFOLIO_JWT_SECRET_KEY:?}"
          '';
        }
      ];
    };
    homelab.redis.databases.ghostfolio = lib.mkDefault "0";
    homelab.kubernetes.submodules.instances.ghostfolio = {
      submodule = "manifest";
      config.submodules.instances.ghostfolio = {
        submodule = "workload";
        args = {
          allowEgress = [
            "internet"
            "postgresql"
            "redis"
          ];
          ingressPort = 3333;
          ports.web = 3333;
          container = {
            image = images."ghostfolio/ghostfolio".ref;
            imagePullPolicy = "Never";
            # Defined before DATABASE_URL, which $(…) needs
            env.DATABASE_PASSWORD.valueFrom.secretKeyRef = {
              name = "postgresql-password";
              key = "password";
            };
            env.DATABASE_URL.value = "postgresql://ghostfolio:$(DATABASE_PASSWORD)@postgresql.postgresql:5432/ghostfolio";
            env.REDIS_HOST.value = "redis.redis";
            env.REDIS_DB.value = config.homelab.redis.databases.ghostfolio;
            envFrom = [ { secretRef.name = "ghostfolio-secrets"; } ];
            # A first start migrates the database, which can outlast the liveness probe on a busy node
            startupProbe = {
              httpGet.port = "web";
              failureThreshold = 30;
            };
            livenessProbe.httpGet.port = "web";
            readinessProbe.httpGet.port = "web";
          };
        };
      };
    };
  };
}
