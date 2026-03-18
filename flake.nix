{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    naersk.url = "github:nix-community/naersk";
    fenix.url = "github:nix-community/fenix/monthly";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      flake-utils,
      naersk,
      fenix,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

      in
      {
        packages = {
          nixos-autodeploy = pkgs.callPackage ./package.nix { };
          default = self.packages.${system}.nixos-autodeploy;
        };

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

        devShells = {
          default = pkgs.mkShell rec {
            inputsFrom = [
              self.packages.${system}.nixos-autodeploy
            ];

            nativeBuildInputs = [
              fenix.packages.${system}.complete.toolchain
            ];

            LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath
              self.packages.${system}.nixos-autodeploy.buildInputs
            }";

            RUST_BACKTRACE = "full";
            RUST_SRC_PATH = "${fenix.packages.${system}.complete.rust-src}/lib/rustlib/src/rust/library";
          };
        };
      }
    )
    // {
      nixosModules = {
        nixos-autodeploy = import ./module.nix;
        default = self.nixosModules.nixos-autodeploy;
      };
    };
}
