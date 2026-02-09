{
  description = "ink - a tiny, fast markdown renderer for your terminal";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    zig-overlay,
  }:
    flake-utils.lib.eachSystem ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"] (
      system: let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [
            (final: prev: {
              zigpkgs = zig-overlay.packages.${system};
            })
          ];
        };

        version = builtins.replaceStrings ["\n"] [""] (builtins.readFile ./ink.version);
        deps = pkgs.callPackage ./build.zig.zon.nix {};
      in {
        packages = {
          default = pkgs.stdenv.mkDerivation {
            pname = "ink";
            inherit version;
            src = ./.;

            nativeBuildInputs = [pkgs.zig_0_15];

            dontConfigure = true;
            dontInstall = true;

            buildPhase = ''
              runHook preBuild

              export HOME=$TMPDIR
              export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-cache"
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"

              mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
              ln -s ${deps} "$ZIG_GLOBAL_CACHE_DIR/p"

              zig build \
                --prefix $out \
                -Dversion="${version}" \
                -Dcpu=baseline \
                --color off \
                install

              runHook postBuild
            '';

            meta = with pkgs.lib; {
              description = "A tiny, fast markdown renderer for your terminal";
              homepage = "https://github.com/matthew-hre/ink";
              license = licenses.mit;
              mainProgram = "ink";
            };
          };
        };

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [pkgs.zigpkgs."0.15.2"];
        };
      }
    );
}
