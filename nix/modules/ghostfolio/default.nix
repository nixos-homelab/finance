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
  secretSource =
    description: field:
    hllib.setup-secrets.kubeSecretSource pkgs {
      inherit description field;
      namespace = "ghostfolio";
      name = "ghostfolio-secrets";
      generate = "head -c 1024 /dev/urandom | tr -dc A-Za-z0-9 | head -c 64";
    };
in
{
  options.homelab.ghostfolio = {
    enable = lib.mkEnableOption "Ghostfolio";
  };
  imports = [
    inputs.setup-secrets.nixosModules.default
    inputs.homelab-storage.nixosModules.postgresql
    inputs.homelab-storage.nixosModules.redis
  ]
  ++ self.lib.importsApply [
    ./home-area.nix
    ./homepage.nix
    ./logs.nix
  ];
  config = lib.mkIf cfg.enable {
    homelab.cluster.images = builtins.attrValues images;
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
      sources.GHOSTFOLIO_TOKEN = hllib.setup-secrets.kubeSecretSource pkgs {
        description = "Ghostfolio Token";
        namespace = "ghostfolio";
        name = "ghostfolio-token";
        field = "GHOSTFOLIO_TOKEN";
      };
      sources.GHOSTFOLIO_ACCESS_TOKEN_SALT = secretSource "Ghostfolio Access Token Salt" "ACCESS_TOKEN_SALT";
      sources.GHOSTFOLIO_JWT_SECRET_KEY = secretSource "Ghostfolio JWT Secret Key" "JWT_SECRET_KEY";
      destinations = [
        (hllib.setup-secrets.kubeSecretDestination pkgs {
          logPrefix = "Ghostfolio (ACCESS_TOKEN_SALT & JWT_SECRET_KEY)";
          namespace = "ghostfolio";
          name = "ghostfolio-secrets";
          data = {
            ACCESS_TOKEN_SALT = "GHOSTFOLIO_ACCESS_TOKEN_SALT";
            JWT_SECRET_KEY = "GHOSTFOLIO_JWT_SECRET_KEY";
          };
        })
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
        # The image runs node as PID 1 of the container, where SIGTERM does nothing without a handler, and ghostfolio
        # has none: it was killed at the end of the grace period. With the pause container as PID 1 SIGTERM ends it
        config.kubernetes.resources.deployments.ghostfolio.spec.template.spec.shareProcessNamespace = true;
      };
    };
  };
}
