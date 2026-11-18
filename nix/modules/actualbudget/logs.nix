# How Actual Budget's logs are parsed: the server's `timestamp level: message` and bare lines, and the exporter's console
{ self, ... }:
{
  lib,
  config,
  ...
}:
let
  esc = builtins.fromJSON ''"\u001b"'';
in
{
  imports = self.lib.importsApply [ ../node-logs.nix ];
  config = lib.mkIf config.homelab.actualbudget.enable {
    homelab.alloy.logs = {
      formats.actualbudget = {
        decolorize = true;
        stages = ''
          stage.template {
            source   = "message"
            template = "{{ .Entry }}"
          }
          stage.regex {
            expression = "^\\d{4}-\\d\\d-\\d\\dT\\S+ (?P<level>[a-z]+): (?s)(?P<message>.*)$"
          }
        '';
      };
      pods.actualbudget = {
        format = "actualbudget";
        examples = [
          {
            lines = [
              "2026-11-18T17:27:10.482Z ${esc}[32minfo${esc}[39m: POST 404 /account/logout"
              "Logging in via password"
            ];
            expect = [
              {
                message = "POST 404 /account/logout";
                level = "info";
              }
              {
                message = "Logging in via password";
                level = "unknown";
              }
            ];
          }
        ];
      };
      pods.actualbudget-exporter = {
        namespace = "actualbudget";
        format = "actual-client";
        examples = [
          {
            lines = [
              "Budget downloaded"
              "[Breadcrumb] {"
              "  message: 'Loading budget /tmp/actual-budget-prometheus-exporter/c1ec9d6d'"
              "}"
              "Loaded spreadsheet from cache (60770 items)"
            ];
            expect = [
              {
                message = "Budget downloaded";
                level = "unknown";
              }
              {
                message = lib.concatStringsSep "\n" [
                  "[Breadcrumb] {"
                  "  message: 'Loading budget /tmp/actual-budget-prometheus-exporter/c1ec9d6d'"
                  "}"
                ];
                level = "unknown";
              }
              {
                message = "Loaded spreadsheet from cache (60770 items)";
                level = "unknown";
              }
            ];
          }
        ];
      };
    };
  };
}
