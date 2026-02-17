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
  };

  outputs =
    { flake-parts, ... }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];

      perSystem =
        { pkgs, inputs', ... }:
        {
          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.ldc
              pkgs.dub
              pkgs.lld
              pkgs.wabt
              pkgs.dformat
              inputs'.nix-src.packages.nix-cli
            ];
          };
        };
    };
}
