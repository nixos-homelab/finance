{
  description = "NixOS Homelab Finance Workloads";
  inputs = {
    systems.url = "github:nix-systems/default-linux";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-parts.url = "github:hercules-ci/flake-parts";
    kube-generators.url = "github:farcaller/nix-kube-generators";
    kubetree = {
      url = "github:andsens/nix-kubetree";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
    };
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
      inputs.kubetree.follows = "kubetree";
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
          let
            options-docs = inputs.docs.lib.docs.options {
              inherit pkgs;
              modules = lib.attrValues self.nixosModules;
              repoPath = toString self;
              repoLinkPrefix = "https://github.com/nixos-homelab/finance/blob/main";
            };
          in
          {
            apps.update-docs.program = inputs.docs.lib.docs.updateRepo {
              inherit pkgs;
              paths."docs/options.md" = options-docs.optionsCommonMark;
            };
            packages.options-docs = options-docs.optionsCommonMark;
          };
      }
    );
}
