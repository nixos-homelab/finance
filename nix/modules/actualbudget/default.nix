{ inputs, self, ... }:
{
  lib,
  pkgs,
  config,
  ...
}:
let
  images = inputs.homelab-shared.lib.images.pinned pkgs ./Dockerfile;
  cfg = config.homelab.actualbudget;
in
{
  options.homelab.actualbudget = {
    enable = lib.mkEnableOption "Actual Budget";
  };
  imports = self.lib.importsApply [ ./homepage.nix ];
  config = lib.mkIf cfg.enable {
    services.k3s.images = builtins.attrValues images;
    homelab.cluster.backup.volumes.actualbudget.actualbudget = [ "/" ];
    homelab.kubernetes.submodules.instances.actualbudget = {
      submodule = "workload";
      args = {
        allowEgress = [ "internet" ];
        dataPath = "/data";
        ingressPort = 5006;
        ports.web = 5006;
        container = {
          image = images."actualbudget/actual-server".ref;
          imagePullPolicy = "Never";
          env = {
            ACTUAL_LOGIN_METHOD.value = "header";
            ACTUAL_ALLOWED_LOGIN_METHODS.value = "header,password";
            ACTUAL_TRUSTED_AUTH_PROXIES.value = "::/0,0.0.0.0/0";
            ACTUAL_DATA_DIR.value = "/data";
            ACTUAL_UPLOAD_FILE_SYNC_SIZE_LIMIT_MB.value = "512";
            ACTUAL_UPLOAD_SYNC_ENCRYPTED_FILE_SYNC_SIZE_LIMIT_MB.value = "512";
            ACTUAL_UPLOAD_FILE_SIZE_LIMIT_MB.value = "512";
          };
          livenessProbe.httpGet.port = "web";
          readinessProbe.httpGet.port = "web";
        };
      };
      # The catch-all rule of the workload, adding the password header login reads
      config.kubernetes.resources.hTTPRoutes.actualbudget.spec.rules = lib.mkForce [
        {
          matches = [
            {
              path.type = "PathPrefix";
              path.value = "/";
            }
          ];
          backendRefs = [
            {
              name = "actualbudget";
              port = 5006;
            }
          ];
          filters = [
            {
              type = "RequestHeaderModifier";
              requestHeaderModifier.add = [
                {
                  name = "X-ACTUAL-PASSWORD";
                  value = "actual";
                }
              ];
            }
          ];
        }
      ];
    };
  };
}
