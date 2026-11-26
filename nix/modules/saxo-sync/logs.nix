# How the Saxo sync's logs are parsed: slog's text handler, logfmt with upper-case levels
{ ... }:
{
  lib,
  config,
  ...
}:
let
  cfg = config.homelab.ghostfolio;
  pod = examples: {
    namespace = "ghostfolio";
    format = "logfmt";
    inherit examples;
  };
in
{
  config = lib.mkIf (cfg.enable && cfg.saxo.enable) {
    homelab.alloy.logs.pods = {
      saxo-refresh = pod [
        {
          lines = [
            ''time=2026-11-26T14:31:02.120+01:00 level=INFO msg="Saxo token refreshed" access_expires_at=2026-11-26T14:50:32Z refresh_expires_at=2026-11-26T15:30:32Z''
            ''time=2026-11-26T14:41:02.120+01:00 level=ERROR msg="Saxo login required" reason="login required: token endpoint answered 401: {\"error\":\"invalid_grant\"}"''
          ];
          expect = [
            {
              message = "Saxo token refreshed";
              level = "info";
            }
            {
              message = "Saxo login required";
              level = "error";
            }
          ];
        }
      ];
      saxo-sync = pod [
        {
          lines = [
            ''time=2026-11-26T06:30:04.745+01:00 level=INFO msg="Saxo transactions read" account=Tradingkonto transactions=478 new_activities=2''
            ''time=2026-11-26T06:30:09.110+01:00 level=WARN msg="Position differs from Saxo" account=Tradingkonto symbol=LYP6.DE saxo=244 ghostfolio=240''
          ];
          expect = [
            {
              message = "Saxo transactions read";
              level = "info";
            }
            {
              message = "Position differs from Saxo";
              level = "warning";
            }
          ];
        }
      ];
    };
  };
}
