# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

{
  description = "zig-m3u";

  inputs = {
    nixpkgs = {
      url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.xz";
    };
    # Mine, not the one in nixpkgs, which is Jari Vetoniemi's original and
    # takes different options.
    zon2nix = {
      url = "github:jcollie/zon2nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };
  };

  outputs =
    {
      nixpkgs,
      zon2nix,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      makePackages =
        system:
        import nixpkgs {
          inherit system;
        };
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = makePackages system;
        in
        rec {
          zig-m3u = pkgs.callPackage ./package.nix { };
          default = zig-m3u;
          # The Zig dependencies on their own, so that a workflow job can
          # run `zig build docs` without building the package to get at
          # them: `zig build docs --system "$(nix build --print-out-paths
          # .#zig-deps)"`.
          zig-deps = pkgs.callPackage ./build.zig.zon.nix { };
        }
      );

      # The one test that is not this library checking its own work: ffmpeg
      # writes a real HLS stream, this library rewrites its playlist, and
      # ffprobe decodes the media through the result. It lives here rather
      # than in `zig build test` because it needs ffmpeg, which is not
      # something to make a consumer of the library depend on.
      checks = forAllSystems (
        system:
        let
          pkgs = makePackages system;
          zig-m3u = pkgs.callPackage ./package.nix { };
        in
        {
          inherit zig-m3u;
          ffmpeg-interop = pkgs.callPackage ./tests/nix/ffmpeg-interop.nix { inherit zig-m3u; };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = makePackages system;
        in
        {
          default = pkgs.mkShell {
            name = "zig-m3u";
            nativeBuildInputs = [
              pkgs.zig_0_17
              pkgs.git-pages-cli
              pkgs.pinact
              pkgs.reuse

              # What the round-trip tests are checked against. ffmpeg writes
              # HLS playlists and reads them back, and `ffprobe` on a
              # playlist this library wrote is the cheapest proof that
              # something other than this library understands it.
              pkgs.ffmpeg

              # Regenerates `build.zig.zon.nix`, which is what lets the Nix
              # build -- which has no network -- find the Zig dependencies.
              # Wrapped so that the `zig env` it shells out to is the one
              # this project builds with rather than whatever is on the
              # caller's PATH; without a Zig at all it writes nothing and
              # leaves the old file looking untouched.
              (pkgs.symlinkJoin {
                name = "zon2nix";
                paths = [ zon2nix.packages.${system}.zon2nix ];
                nativeBuildInputs = [ pkgs.makeWrapper ];
                postBuild = ''
                  wrapProgram $out/bin/zon2nix \
                    --prefix PATH : ${lib.makeBinPath [ pkgs.zig_0_17 ]}
                '';
              })
            ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.kcov
            ];
          };
        }
      );
    };
}
