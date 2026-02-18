{
  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0";
    nix-src = {
      url = "https://flakehub.com/f/DeterminateSystems/nix-src/3.16.0";
      inputs.flake-parts.follows = "flake-parts";
    };

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    git-hooks-nix = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { flake-parts, ... }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.git-hooks-nix.flakeModule

        ./nix/checks/pre-commit.nix
      ];

      systems = [ "x86_64-linux" ];

      perSystem =
        {
          config,
          pkgs,
          inputs',
          ...
        }:
        let
          inherit (config.pre-commit.settings) enabledPackages package configFile;
        in
        {
          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.ldc
              pkgs.dub
              pkgs.lld
              pkgs.wabt
              pkgs.dformat
              pkgs.zlib
              pkgs.openssl
              inputs'.nix-src.packages.nix-cli
            ]
            ++ enabledPackages
            ++ [ package ];

            shellHook = ''
              ln -fvs ${configFile} .pre-commit-config.yaml
            ''
            + config.pre-commit.installationScript;
          };
        };
    };
}
