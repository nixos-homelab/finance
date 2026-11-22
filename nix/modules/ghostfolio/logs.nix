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
        # Ghostfolio logs one line for every date without an exchange rate, at each portfolio calculation (two per account
        # sync). Most are weekends and holidays, which have no FX quotes; Ghostfolio carries the last rate forward
        demote.missing-exchange-rate.expression = "No exchange rate has been found for [A-Z]{6} at \\d{4}-\\d\\d-\\d\\d(?:\\. Please complement market data for [A-Z]{6}(?: and [A-Z]{6})?\\.)?";
        examples = [
          # The entrypoint's shell trace, Prisma's and npm's output, before Nest logs anything
          {
            lines = [
              "+ echo Running database migrations"
              "Running database migrations"
              "+ npx prisma migrate deploy"
              "No pending migrations to apply."
              "npm notice New major version of npm available! 10.9.9 -> 12.2.3"
            ];
            expect = [
              {
                message = "+ echo Running database migrations";
                level = "info";
              }
              {
                message = "Running database migrations";
                level = "info";
              }
              {
                message = "+ npx prisma migrate deploy";
                level = "info";
              }
              {
                message = "No pending migrations to apply.";
                level = "info";
              }
              {
                message = "npm notice New major version of npm available! 10.9.9 -> 12.2.3";
                level = "info";
              }
            ];
          }
          {
            lines = [
              "${esc}[31m[Nest] 14  - ${esc}[39m11/18/2026, 5:05:09 PM ${esc}[31m  ERROR${esc}[39m ${esc}[38;5;3m[ExchangeRateDataService] ${esc}[39m${esc}[31mNo exchange rate has been found for CHFDKK at 2026-10-04. Please complement market data for USDCHF and USDDKK.${esc}[39m"
            ];
            expect = [
              {
                message = "No exchange rate has been found for CHFDKK at 2026-10-04. Please complement market data for USDCHF and USDDKK.";
                level = "debug";
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
        demote = {
          # dotenv's advertising, with a different tip on every run
          dotenv.expression = "\\[dotenv@[\\d.]+\\] injecting env \\(\\d+\\) from \\.env.*";
          # The Actual API's own progress, which says nothing the sync's lines around it don't
          breadcrumbs.expression = "(?s)\\[Breadcrumb\\] \\{.*\\}";
        };
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
                level = "debug";
              }
              {
                message = "Starting sync process...";
                level = "info";
              }
              {
                message = "[Breadcrumb] { message: 'loading spreadsheet', category: 'server' }";
                level = "debug";
              }
            ];
          }
        ];
      };
    };
  };
}
