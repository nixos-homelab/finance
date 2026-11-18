# How Ghostfolio's and its account sync's logs are parsed: NestJS in Ghostfolio, the Actual client's console in the sync
# job (ghostbudget)
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
  config = lib.mkIf config.homelab.ghostfolio.enable {
    homelab.alloy.logs.pods = {
      ghostfolio = {
        format = "nest";
        examples = [
          {
            lines = [
              "${esc}[31m[Nest] 14  - ${esc}[39m11/18/2026, 5:05:09 PM ${esc}[31m  ERROR${esc}[39m ${esc}[38;5;3m[ExchangeRateDataService] ${esc}[39m${esc}[31mNo exchange rate has been found for CHFDKK at 2026-10-04. Please complement market data for USDCHF and USDDKK.${esc}[39m"
            ];
            expect = [
              {
                message = "No exchange rate has been found for CHFDKK at 2026-10-04. Please complement market data for USDCHF and USDDKK.";
                level = "error";
                fields = {
                  component = "ExchangeRateDataService";
                  pid = "14";
                };
              }
            ];
          }
        ];
      };
      sync-accounts = {
        namespace = "ghostfolio";
        format = "actual-client";
        examples = [
          {
            lines = [
              "[dotenv@17.2.3] injecting env (0) from .env -- tip: enable debug logging with { debug: true }"
              ''${esc}[32minfo${esc}[39m: Starting sync process... {"timestamp":"2026-11-18T16:05:01.667Z"}''
              "[Breadcrumb] { message: 'loading spreadsheet', category: 'server' }"
            ];
            expect = [
              {
                message = "[dotenv@17.2.3] injecting env (0) from .env -- tip: enable debug logging with { debug: true }";
                level = "info";
              }
              {
                message = "Starting sync process...";
                level = "info";
              }
              {
                message = "[Breadcrumb] { message: 'loading spreadsheet', category: 'server' }";
                level = "info";
              }
            ];
          }
        ];
      };
    };
  };
}
