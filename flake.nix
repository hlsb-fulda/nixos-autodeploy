{
  description = "NixOS Auto-Deployment Module";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      flake-utils,
      nixpkgs,
      nixpkgs-unstable,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (system: {
      checks = {
        moduleTestStable = import ./test.nix {
          flake = self;
          pkgs = nixpkgs.legacyPackages.${system};
        };

        moduleTestUnstable = import ./test.nix {
          flake = self;
          pkgs = nixpkgs-unstable.legacyPackages.${system};
        };
      };

      formatter = nixpkgs.legacyPackages.${system}.nixfmt-tree;
    })
    // {
      nixosModules = {
        autodeploy = import ./module.nix;
        default = self.nixosModules.autodeploy;
      };
    };
}
