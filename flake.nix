{
  description = "ink - a tiny, fast markdown renderer for your terminal";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    systems.url = "github:nix-systems/default";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems.outPath;

      perSystem =
        {
          lib,
          pkgs,
          ...
        }:
        let
          zig = pkgs.zig_0_15;
          version = lib.pipe ./ink.version [
            builtins.readFile
            lib.trim
          ];
        in
        {
          packages.default = pkgs.stdenv.mkDerivation (finalAttrs: {
            pname = "ink";
            inherit version;
            src = lib.cleanSource ./.;

            deps = pkgs.callPackage ./build.zig.zon.nix { };

            nativeBuildInputs = [
              zig.hook
              pkgs.writableTmpDirAsHomeHook
            ];

            dontConfigure = true;

            zigBuildFlags = [
              "--system"
              "${finalAttrs.deps}"
              "-Dversion=${version}"
            ];

            meta = {
              description = "A tiny, fast markdown renderer for your terminal";
              homepage = "https://github.com/theMackabu/ink";
              license = lib.licenses.mit;
              mainProgram = "ink";
            };
          });

          devShells.default = pkgs.mkShell {
            nativeBuildInputs = [
              zig
            ];
          };
        };
    };
}
