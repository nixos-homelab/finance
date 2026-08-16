## homelab\.actualbudget\.enable



Whether to enable Actual Budget\.



*Type:*
boolean



*Default:*
` false `



*Example:*
` true `

*Declared by:*
 - [nix/modules/actualbudget/default\.nix](https://github.com/nixos-homelab/finance/blob/main/nix/modules/actualbudget/default.nix)



## homelab\.actualbudget\.debug

Whether to enable debug mode\.



*Type:*
boolean



*Default:*
` false `



*Example:*
` true `

*Declared by:*
 - [nix/modules/actual-flow/default\.nix](https://github.com/nixos-homelab/finance/blob/main/nix/modules/actual-flow/default.nix)



## homelab\.actualbudget\.importConfig



actual-flow synchronization configuration



*Type:*
submodule

*Declared by:*
 - [nix/modules/actual-flow/default\.nix](https://github.com/nixos-homelab/finance/blob/main/nix/modules/actual-flow/default.nix)



## homelab\.actualbudget\.importConfig\.accountMappings



List of mappings between lunchflow \& actual budget accounts



*Type:*
list of (submodule)

*Declared by:*
 - [nix/modules/actual-flow/default\.nix](https://github.com/nixos-homelab/finance/blob/main/nix/modules/actual-flow/default.nix)



## homelab\.actualbudget\.importConfig\.accountMappings\.\*\.actualBudgetAccountId



ID of the Actual budget account to sync (Navigate to AB account -> https://actualbudget\.DOMAIN/accounts/bba4b622-c8d1-4bdb-84d0-a8ecfb240ca8)



*Type:*
string



*Example:*
` "bba4b622-c8d1-4bdb-84d0-a8ecfb240ca8" `

*Declared by:*
 - [nix/modules/actual-flow/default\.nix](https://github.com/nixos-homelab/finance/blob/main/nix/modules/actual-flow/default.nix)



## homelab\.actualbudget\.importConfig\.accountMappings\.\*\.actualBudgetAccountName



Name of the Actual budget account to sync



*Type:*
string



*Example:*
` "Budget" `

*Declared by:*
 - [nix/modules/actual-flow/default\.nix](https://github.com/nixos-homelab/finance/blob/main/nix/modules/actual-flow/default.nix)



## homelab\.actualbudget\.importConfig\.accountMappings\.\*\.lunchFlowAccountId



ID of the lunchflow account to sync (as in https://www\.lunchflow\.app/accounts/\<ID>)



*Type:*
signed integer



*Example:*
` "1234" `

*Declared by:*
 - [nix/modules/actual-flow/default\.nix](https://github.com/nixos-homelab/finance/blob/main/nix/modules/actual-flow/default.nix)



## homelab\.actualbudget\.importConfig\.accountMappings\.\*\.lunchFlowAccountName



Name of the lunchflow account to sync



*Type:*
string



*Example:*
` "Budget" `

*Declared by:*
 - [nix/modules/actual-flow/default\.nix](https://github.com/nixos-homelab/finance/blob/main/nix/modules/actual-flow/default.nix)



## homelab\.actualbudget\.importConfig\.accountMappings\.\*\.syncStartDate



Date from when to sync



*Type:*
string



*Example:*
` "2026-01-10" `

*Declared by:*
 - [nix/modules/actual-flow/default\.nix](https://github.com/nixos-homelab/finance/blob/main/nix/modules/actual-flow/default.nix)



## homelab\.actualbudget\.importConfig\.budgetSyncId



The budget that actual-flow should sync (found in https://actualbudget\.DOMAIN/settings -> Advanced Settings -> Sync ID)



*Type:*
string



*Example:*
` "1a3e9e7a-691c-46d0-b8ec-b27773270e27" `

*Declared by:*
 - [nix/modules/actual-flow/default\.nix](https://github.com/nixos-homelab/finance/blob/main/nix/modules/actual-flow/default.nix)



## homelab\.actualbudget\.importConfig\.duplicateCheckingAcrossAccounts



Check for duplicate transactions across all accounts before import



*Type:*
boolean



*Default:*
` false `

*Declared by:*
 - [nix/modules/actual-flow/default\.nix](https://github.com/nixos-homelab/finance/blob/main/nix/modules/actual-flow/default.nix)



## homelab\.actualbudget\.importConfig\.lunchFlowBaseUrl



The lunchflow base url



*Type:*
null or string



*Default:*
` "https://lunchflow.app/api/v1" `

*Declared by:*
 - [nix/modules/actual-flow/default\.nix](https://github.com/nixos-homelab/finance/blob/main/nix/modules/actual-flow/default.nix)



## homelab\.actualbudget\.importSchedule



Cronjob notation of when the actual-flow import runs



*Type:*
null or string



*Default:*
` null `



*Example:*
` "0 3 * * *" `

*Declared by:*
 - [nix/modules/actual-flow/default\.nix](https://github.com/nixos-homelab/finance/blob/main/nix/modules/actual-flow/default.nix)



## homelab\.ghostfolio\.enable



Whether to enable Ghostfolio\.



*Type:*
boolean



*Default:*
` false `



*Example:*
` true `

*Declared by:*
 - [nix/modules/ghostfolio/default\.nix](https://github.com/nixos-homelab/finance/blob/main/nix/modules/ghostfolio/default.nix)



## homelab\.ghostfolio\.actualBudgetSyncId



Actualbudget sync ID to use when running ghostbudget



*Type:*
string



*Example:*
` "bba4b622-c8d1-4bdb-84d0-a8ecfb240ca8" `

*Declared by:*
 - [nix/modules/ghostbudget/default\.nix](https://github.com/nixos-homelab/finance/blob/main/nix/modules/ghostbudget/default.nix)



## homelab\.ghostfolio\.actualBudgetSyncMap



Map of Actual Budget account names to Ghostfolio account names, use an attrSet for extended options



*Type:*
attribute set of (string or (submodule))



*Example:*

```
''
  {
    ActualBudgetAccountName = "GhostfolioAccountName";
    Cash = "Liquid Assets";
    Investments = {
      ghostfolioName = "Liquid Assets";
      factor = 7.45;
    };
  }
''
```

*Declared by:*
 - [nix/modules/ghostbudget/default\.nix](https://github.com/nixos-homelab/finance/blob/main/nix/modules/ghostbudget/default.nix)



## homelab\.ghostfolio\.debug



Whether to enable debug mode\.



*Type:*
boolean



*Default:*
` false `



*Example:*
` true `

*Declared by:*
 - [nix/modules/ghostbudget/default\.nix](https://github.com/nixos-homelab/finance/blob/main/nix/modules/ghostbudget/default.nix)



## homelab\.ghostfolio\.importSchedule



Cronjob notation of when the ghostbudget sync runs



*Type:*
null or string



*Default:*
` null `



*Example:*
` "5 3 * * *" `

*Declared by:*
 - [nix/modules/ghostbudget/default\.nix](https://github.com/nixos-homelab/finance/blob/main/nix/modules/ghostbudget/default.nix)



## homelab\.homepage\.integrations\.ghostfolio\.enable



integration of ghostfolio with homepage



*Type:*
boolean



*Default:*
` config.homelab.ghostfolio.enable && config.homelab.homepage.enable `

*Declared by:*
 - [nix/modules/ghostfolio/homepage\.nix](https://github.com/nixos-homelab/finance/blob/main/nix/modules/ghostfolio/homepage.nix)


