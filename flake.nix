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

      # The devshell's Zig, with one line of its own standard library put
      # right, because without it `zig build fuzz --fuzz` cannot compile.
      #
      # Zig 0.16.0's `compiler/test_runner.zig` reports a failing fuzz input by
      # asking `std.debug.writeStackTrace` to print what `@errorReturnTrace()`
      # gave it. Those are two different types: an error return trace is a
      # `builtin.StackTrace`, a ring buffer with a write index, and that
      # function takes a `debug.StackTrace`, which is a plain slice and a count
      # of what was skipped. It is a type error, it is on the path taken only
      # under `-ffuzz`, and it stops *any* project with a fuzz test in it from
      # building one. The fix is the function next door: `writeErrorReturnTrace`
      # takes exactly the type in hand and is what the other three places in
      # the same file use.
      #
      # `--replace-fail` is the whole safety of this: the day Zig ships the fix
      # the pattern will not be found, the build will fail here rather than
      # patch something else, and this can go.
      #
      # It buys the fuzzer and not its coverage. Nothing in this release
      # populates the table of program counters, so a bounded run ends with
      # "corrupted coverage file: pcs_len was zero" and an unbounded one
      # panics in the build runner's coverage thread; neither is a finding,
      # and a finding says "input saved to" above the report. The properties in
      # `tests/fuzz.zig` run as ordinary tests either way, and
      # `zig build fuzz-run` drives them from a loop of our own.
      fuzzableZig =
        pkgs:
        let
          # A farm of symlinks rather than a copy: the library is 217 MB, and
          # exactly one file of it is being changed.
          library = pkgs.runCommand "zig-0.16.0-lib-fuzz-fix" { } ''
            cp -rs --no-preserve=mode ${pkgs.zig_0_16}/lib/zig $out
            chmod -R u+w $out
            rm $out/compiler/test_runner.zig
            cp --no-preserve=mode \
              ${pkgs.zig_0_16}/lib/zig/compiler/test_runner.zig \
              $out/compiler/test_runner.zig
            substituteInPlace $out/compiler/test_runner.zig \
              --replace-fail \
                'std.debug.writeStackTrace(trace, stderr)' \
                'std.debug.writeErrorReturnTrace(trace, stderr)'
          '';
        in
        pkgs.symlinkJoin {
          name = "zig-0.16.0-fuzzable";
          paths = [ pkgs.zig_0_16 ];
          nativeBuildInputs = [ pkgs.makeWrapper ];
          postBuild = ''
            wrapProgram $out/bin/zig --set ZIG_LIB_DIR ${library}
          '';
        };
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
              (fuzzableZig pkgs)
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
                    --prefix PATH : ${lib.makeBinPath [ pkgs.zig_0_16 ]}
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
