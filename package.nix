# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

{
  lib,
  stdenv,
  callPackage,
  zig_0_17,
}:

let
  # Generated from build.zig.zon by zon2nix; regenerate with
  #   nix develop -c zon2nix --17 --nix=build.zig.zon.nix build.zig.zon
  zigDeps = callPackage ./build.zig.zon.nix { };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "zig-m3u";
  version = "0.2.0";

  # Named rather than filtered, so that editing something outside this list --
  # the flake, a scratch file -- does not rebuild the package.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./build.zig
      ./build.zig.zon
      ./src
      ./tests
      ./tools
      ./LICENSES
      ./README.md
      ./REUSE.toml
    ];
  };

  nativeBuildInputs = [ zig_0_17 ];

  zigBuildFlags = [
    "--system"
    "${zigDeps}"
  ];
  # The check phase assembles its own flags rather than reusing the build's,
  # so without this `zig build test` runs without --system, tries to fetch,
  # and fails in the sandbox.
  zigCheckFlags = finalAttrs.zigBuildFlags;

  # Everything here is pure: the tests read the playlists in `tests/playlists`
  # and talk to nothing.
  doCheck = true;

  meta = {
    description = "An M3U and M3U8 playlist parser and writer for Zig";
    homepage = "https://git.jcollie.dev/jeff/zig-m3u";
    license = lib.licenses.mit;
    mainProgram = "zig-m3u";
    platforms = lib.platforms.all;
  };
})
