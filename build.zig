// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Every entry in a playlist is a URI, and resolving a relative one
    // against the playlist's own address is most of what a consumer does
    // with this library. zig-uri does that properly -- RFC 3986 reference
    // resolution, percent-encoding, IPv6 literals -- so `resolve.zig` calls
    // it rather than this project growing a second URI parser.
    const uri = b.dependency("uri", .{ .target = target, .optimize = optimize });

    // One module. The line scanner, the attribute grammar, the tag types, the
    // parser and the writer are all one job — reading and writing this file
    // format — and Zig only analyses what is referenced, so a program that
    // parses and never writes does not compile the writer.
    const mod = b.addModule("m3u", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{.{ .name = "uri", .module = uri.module("uri") }},
    });

    const exe = b.addExecutable(.{
        .name = "zig-m3u",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "m3u", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.stdio = .inherit;
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the command line tool");
    run_step.dependOn(&run_cmd.step);

    // A test executable covers one module, so each needs its own. Missing one
    // out would not fail: its tests would simply never run.
    const test_step = b.step("test", "Run tests");
    for ([_]*std.Build.Module{ mod, exe.root_module }) |m| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
    }

    // The round-trip and conformance tests, which read the playlists in
    // `tests/playlists` rather than strings written inline. They are a module
    // of their own so that a consumer of the library never compiles them, and
    // they get the directory as a build option because a test binary is run
    // from wherever the build runner happens to be.
    const playlists = b.addOptions();
    playlists.addOptionPath("dir", b.path("tests/playlists"));

    const suite_mod = b.createModule(.{
        .root_source_file = b.path("tests/playlists.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "m3u", .module = mod },
            .{ .name = "playlists", .module = playlists.createModule() },
        },
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = suite_mod })).step);

    // The fuzz targets: what the parser and the writer must do with input
    // nobody wrote. They are ordinary tests as well as fuzz tests, so `zig
    // build test` exercises the same properties on the seeds checked in
    // beside them.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("tests/fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "m3u", .module = mod }},
    });
    // Zig's fuzzer takes one test at a time and keeps a coverage file per
    // test, so naming a target is what you want when a finding is being
    // chased: `zig build fuzz --fuzz -Dfuzz-filter=playlist`.
    const fuzz_filter = b.option(
        []const u8,
        "fuzz-filter",
        "Fuzz or test only the targets whose name contains this",
    );
    const fuzz_tests = b.addTest(.{
        .root_module = fuzz_mod,
        .filters = if (fuzz_filter) |f| &.{f} else &.{},
    });
    test_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    // A step of its own for `zig build fuzz --fuzz`, which needs a run step
    // holding nothing else: the fuzzer takes over the terminal and runs until
    // it is stopped, so it must not be reached by `zig build test`.
    const fuzz_step = b.step("fuzz", "The fuzz targets: add --fuzz to fuzz them");
    fuzz_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    // The loop that drives those same targets without Zig's fuzzer, which
    // this toolchain cannot usefully run: `tools/fuzz.zig` says why, and the
    // short version is that the coverage table comes back empty. Optimised,
    // because a fuzzer's whole job is how many inputs it gets through, and
    // ReleaseSafe keeps every check that makes a failure a failure.
    const fuzz_run = b.addExecutable(.{
        .name = "zig-m3u-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fuzz.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "fuzz_targets", .module = fuzz_mod }},
        }),
    });
    const run_fuzz = b.addRunArtifact(fuzz_run);
    run_fuzz.stdio = .inherit;
    if (b.args) |a| run_fuzz.addArgs(a);
    const fuzz_run_step = b.step("fuzz-run", "Fuzz the targets with a loop of our own");
    fuzz_run_step.dependOn(&run_fuzz.step);

    // Nothing else builds it, so without this it could stop compiling and
    // `zig build test` would not notice.
    const check_step = b.step("check", "Compile everything without running it");
    check_step.dependOn(&fuzz_run.step);

    // -- documentation -------------------------------------------------------
    //
    // Zig emits the API documentation as a side effect of compiling, so the
    // module is built as a library purely to get at it. What comes out is not
    // a page but a program: a WebAssembly viewer, its javascript, and a tar of
    // the sources it reads from.
    const library = b.addLibrary(.{ .name = "m3u", .root_module = mod });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = library.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Build the API documentation into zig-out/docs");
    docs_step.dependOn(&install_docs.step);

    // That viewer fetches `sources.tar` and `main.wasm` at runtime, which a
    // browser refuses to do from a `file://` page, so reading the docs
    // locally means serving them. It is the same reason `zig std` runs a
    // server rather than opening a file.
    const docs_port = b.option(u16, "docs-port", "Port for `zig build docs-serve` (default 8000)") orelse 8000;

    const docs_server = b.addExecutable(.{
        .name = "docs-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/docs_server.zig"),
            // Always built for the machine running the build, never for
            // whatever -Dtarget the library is being built for.
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const run_docs_server = b.addRunArtifact(docs_server);
    run_docs_server.step.dependOn(&install_docs.step);
    run_docs_server.addArg(b.getInstallPath(.prefix, "docs"));
    run_docs_server.addArg(b.fmt("{d}", .{docs_port}));
    // The server runs until interrupted, so its output has to reach the
    // terminal rather than being captured by the build runner.
    run_docs_server.stdio = .inherit;

    const docs_serve_step = b.step("docs-serve", "Serve the API documentation over HTTP");
    docs_serve_step.dependOn(&run_docs_server.step);

    // The server has tests of its own; without this they would never run.
    test_step.dependOn(&b.addRunArtifact(
        b.addTest(.{ .root_module = docs_server.root_module }),
    ).step);
    check_step.dependOn(&docs_server.step);
}
