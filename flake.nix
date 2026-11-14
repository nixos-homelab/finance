{
  description = "NixOS Homelab Finance Workloads";
  inputs = {
    systems.url = "github:nix-systems/default-linux";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-parts.url = "github:hercules-ci/flake-parts";
    kube-generators.url = "github:farcaller/nix-kube-generators";
    setup-secrets = {
      url = "github:andsens/nixos-setup-secrets";
      inputs.systems.follows = "systems";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
    };
    homelab-shared = {
      url = "github:nixos-homelab/shared";
      inputs.systems.follows = "systems";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
      inputs.setup-secrets.follows = "setup-secrets";
      inputs.kube-generators.follows = "kube-generators";
    };
    docs = {
      url = "github:andsens/nix-docs";
      inputs.systems.follows = "systems";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
    };
  };
  outputs =
    {
      systems,
      flake-parts,
      nixpkgs,
      ...
    }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } (
      {
        flake-parts-lib,
        self,
        inputs,
        lib,
        ...
      }:
      let
        inherit (flake-parts-lib) importApply;
      in
      {
        systems = import systems;
        flake = {
          lib = {
            importsApply = map (path: importApply path { inherit self inputs; });
          };
          nixosModules = {
            actualbudget = importApply ./nix/modules/actualbudget { inherit self inputs; };
            ghostbudget = importApply ./nix/modules/ghostbudget { inherit self inputs; };
            ghostfolio = importApply ./nix/modules/ghostfolio { inherit self inputs; };
            homepage = importApply ./nix/modules/homepage { inherit self inputs; };
          };
        };
        perSystem =
          { pkgs, lib, ... }:
          {
            checks.manifests = inputs.homelab-shared.lib.checks.manifests {
              inherit pkgs;
              modules = lib.attrValues self.nixosModules ++ [
                {
                  homelab = {
                    actualbudget.enable = true;
                    ghostfolio = {
                      enable = true;
                      importSchedule = "5 3 * * *";
                      actualBudgetSyncId = "00000000-0000-0000-0000-000000000000";
                      actualBudgetSyncMap.Checking = "Checking";
                    };
                    homepage.enable = true;
                  };
                }
              ];
            };
            packages = {
              options-docs = inputs.docs.lib.docs.options {
                inherit pkgs;
                modules = lib.attrValues self.nixosModules;
                repoPath = toString self;
                repoLinkPrefix = "https://github.com/nixos-homelab/finance/blob/main";
                prefixGroups = {
                  actualbudget = [
                    "homelab.actualbudget"
                    "homelab.homepage.integrations.actualbudget"
                  ];
                  ghostfolio = [
                    "homelab.ghostfolio"
                    "homelab.homepage.integrations.ghostfolio"
                  ];
                  homepage = [ "homelab.homepage.sections" ];
                };
              };
              manual-docs = inputs.docs.lib.mkdocs.manual {
                inherit pkgs;
                rootDoc = ./README.md;
              };
            };
          };
      }
    );
}
