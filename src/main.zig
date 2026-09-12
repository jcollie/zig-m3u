// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A command line tool over the library, which exists for three reasons: to
//! show what the library looks like from outside, to check a playlist without
//! writing a program, and to be the thing a round-trip bug is reduced with.
//!
//! ```console
//! $ zig-m3u show master.m3u8              # what is in it
//! $ zig-m3u check *.m3u8                  # what is wrong with it
//! $ zig-m3u normalise index.m3u8          # write it back out
//! $ zig-m3u urls index.m3u8 --base https://example.com/hls/index.m3u8
//! ```

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const m3u = @import("m3u");

const usage =
    \\usage: zig-m3u <command> [options] [file...]
    \\
    \\  show      FILE...     describe each playlist
    \\  check     FILE...     report what is not conformant
    \\  normalise FILE...     parse and write back out, to stdout
    \\  urls      FILE...     one URI per line, resolved against --base if given
    \\
    \\options:
    \\      --base URI        the address the playlist came from, for `urls`
    \\      --strict          refuse a playlist that lost information when parsed
    \\      --validate-uris   check that every URI parses as one
    \\  -                     read from standard input (the default with no FILE)
    \\
    \\`check` prints every problem and exits 1 only when one of them lost
    \\information -- a playlist that is merely unconformant, which nearly every
    \\real playlist is, exits 0. `--strict` makes it exit 1 for those too.
    \\
;

/// A playlist is a file that fits in memory; this is the bound on how much of
/// one will be read, which is generous — a day of six-second segments is
/// about a megabyte.
const max_playlist_bytes: Io.Limit = .limited(64 * 1024 * 1024);

const Options = struct {
    base: ?[]const u8 = null,
    strict: bool = false,
    validate_uris: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file.interface;
    defer stdout.flush() catch {};

    if (args.len < 2) {
        try stdout.writeAll(usage);
        return error.MissingCommand;
    }

    const command = std.meta.stringToEnum(Command, args[1]) orelse {
        try stdout.writeAll(usage);
        return error.UnknownCommand;
    };

    var options: Options = .{};
    var files: std.ArrayList([]const u8) = .empty;
    var rest = args[2..];
    while (rest.len > 0) : (rest = rest[1..]) {
        const arg = rest[0];
        if (std.mem.eql(u8, arg, "--base")) {
            if (rest.len < 2) return error.MissingBase;
            options.base = rest[1];
            rest = rest[1..];
        } else if (std.mem.eql(u8, arg, "--strict")) {
            options.strict = true;
        } else if (std.mem.eql(u8, arg, "--validate-uris")) {
            options.validate_uris = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            try stdout.writeAll(usage);
            return error.UnknownOption;
        } else {
            try files.append(gpa, arg);
        }
    }
    if (files.items.len == 0) try files.append(gpa, "-");

    var diagnostics: m3u.Diagnostics = .init(gpa);
    defer diagnostics.deinit();

    // Counted separately, because `check` exits 1 for the ones that lost
    // something and not for the ones that are merely unconformant. Nearly
    // every real playlist is unconformant.
    var lost_information = false;
    for (files.items) |path| {
        const bytes = try read(io, gpa, path);
        defer gpa.free(bytes);

        diagnostics.clear();
        var playlist = m3u.Playlist.parse(gpa, bytes, .{
            .diagnostics = &diagnostics,
            .strict = options.strict,
            .validate_uris = options.validate_uris,
        }) catch |err| {
            try stdout.print("{s}: {t}\n", .{ path, err });
            try stdout.print("{f}", .{&diagnostics});
            lost_information = true;
            continue;
        };
        defer playlist.deinit();

        switch (command) {
            .show => try show(stdout, path, &playlist, files.items.len > 1),
            .check => {
                if (diagnostics.count() != 0) {
                    if (files.items.len > 1) try stdout.print("== {s}\n", .{path});
                    try stdout.print("{f}", .{&diagnostics});
                    if (diagnostics.invalidCount() != 0) lost_information = true;
                }
            },
            .normalise => try playlist.write(stdout),
            .urls => try urls(gpa, stdout, &playlist, options),
        }
    }

    try stdout.flush();
    // An exit code rather than a returned error: this is a report, and a
    // stack trace on top of it would be noise.
    if (command == .check and lost_information) std.process.exit(1);
}

const Command = enum { show, check, normalise, urls };

/// Read a whole playlist, from a file or from standard input.
fn read(io: Io, gpa: Allocator, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "-")) {
        var buffer: [64 * 1024]u8 = undefined;
        var stdin: Io.File.Reader = .init(.stdin(), io, &buffer);
        return stdin.interface.allocRemaining(gpa, max_playlist_bytes);
    }
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, max_playlist_bytes);
}

/// What is in a playlist, in a form somebody reading a terminal wants.
fn show(w: *Io.Writer, path: []const u8, playlist: *const m3u.Playlist, several: bool) !void {
    if (several) try w.print("== {s}\n", .{path});

    try w.print("{s} playlist", .{@tagName(playlist.kind())});
    if (playlist.version) |version| try w.print(", version {d}", .{version});
    if (!playlist.extm3u) try w.writeAll(", no #EXTM3U");
    if (playlist.byte_order_mark) try w.writeAll(", byte order mark");
    try w.writeByte('\n');

    if (playlist.title()) |title| try w.print("name: {s}\n", .{title});
    for (playlist.defines) |define| {
        if (define.name) |defined| {
            try w.print("define: {s} = {s}\n", .{ defined, define.value orelse "" });
        } else if (define.variableName()) |imported| {
            try w.print("define: {s} (imported)\n", .{imported});
        }
    }

    switch (playlist.body) {
        .basic => |entries| {
            try w.print("{d} entries\n", .{entries.len});
            for (entries) |entry| try showEntry(w, entry);
        },
        .media => |media| {
            if (media.target_duration) |target| {
                try w.print("target duration: {d}s\n", .{target});
            }
            try w.print("media sequence: {d}\n", .{media.media_sequence});
            if (media.playlist_type) |playlist_type| {
                try w.print("type: {f}\n", .{playlist_type});
            }
            if (media.iframes_only) try w.writeAll("I-frames only\n");
            if (media.part_inf) |part_inf| {
                try w.print("part target: {d}s\n", .{part_inf.part_target});
            }
            if (media.skip) |skip| {
                try w.print("delta update: {d} segments skipped\n", .{skip.skipped_segments});
            }
            try w.print("{d} segments, {d:.3}s total, {s}\n", .{
                media.entries.len,
                media.totalDuration(),
                if (media.endlist) "complete" else "still growing",
            });
            for (media.entries, 0..) |entry, i| {
                try w.print("  #{d} ", .{media.sequenceNumber(i)});
                try showEntry(w, entry);
                if (media.encrypted(i)) {
                    for (media.keysFor(i)) |key| {
                        if (key.method.is(.none)) continue;
                        try w.print("       key {f} {s}\n", .{ key.method, key.uri orelse "" });
                    }
                }
            }
            for (media.trailing_parts) |part| {
                try w.print("  part {d}s {s}\n", .{ part.duration, part.uri });
            }
            for (media.rendition_reports) |report| {
                try w.print("  rendition report: {s}\n", .{report.uri});
            }
        },
        .multivariant => |mv| {
            if (mv.content_steering) |steering| {
                try w.print("content steering: {s}\n", .{steering.server_uri});
            }
            for (mv.session_data) |data| {
                try w.print("session data: {s} = {s}\n", .{
                    data.data_id,
                    data.value orelse data.uri orelse "",
                });
            }
            try w.print("{d} renditions\n", .{mv.renditions.len});
            for (mv.renditions) |rendition| {
                try w.print("  {f} group {s} name {s}", .{
                    rendition.type,
                    rendition.group_id,
                    rendition.name,
                });
                if (rendition.language) |language| try w.print(" [{s}]", .{language});
                if (rendition.default) try w.writeAll(" default");
                if (rendition.uri) |uri| try w.print(" -> {s}", .{uri});
                try w.writeByte('\n');
            }
            try w.print("{d} variants\n", .{mv.variants.len});
            for (mv.variants) |variant| {
                try w.print("  {d} bps", .{variant.stream_inf.bandwidth});
                if (variant.stream_inf.resolution) |resolution| {
                    try w.print(" {f}", .{resolution});
                }
                if (variant.stream_inf.codecs) |codecs| try w.print(" [{s}]", .{codecs});
                if (variant.iframe_only) try w.writeAll(" I-frame only");
                try w.print(" -> {s}\n", .{variant.uri});
            }
        },
    }
}

fn showEntry(w: *Io.Writer, entry: m3u.Playlist.Entry) !void {
    if (entry.duration) |duration| {
        try w.print("{d}s ", .{duration});
    }
    try w.writeAll(entry.uri);
    if (entry.title.len != 0) try w.print(" — {s}", .{entry.title});
    if (entry.group()) |group| try w.print(" ({s})", .{group});
    if (entry.gap) try w.writeAll(" [gap]");
    if (entry.discontinuity) try w.writeAll(" [discontinuity]");
    if (entry.byterange) |range| try w.print(" [{f}]", .{range});
    try w.writeByte('\n');
}

/// Every URI in the playlist, one per line, resolved if a base was given.
///
/// The point of `--base` is that almost every URI in a playlist is relative,
/// so the list without it is not a list of things that can be fetched.
fn urls(
    gpa: Allocator,
    w: *Io.Writer,
    playlist: *const m3u.Playlist,
    options: Options,
) !void {
    const base: ?m3u.resolve.Base = if (options.base) |text|
        try .init(gpa, text)
    else
        null;
    defer if (base) |b| b.deinit();

    const emit = struct {
        fn one(
            out: *Io.Writer,
            allocator: Allocator,
            resolver: ?m3u.resolve.Base,
            uri: []const u8,
        ) !void {
            if (resolver) |r| {
                const resolved = try r.resolveAlloc(allocator, uri, .{});
                defer allocator.free(resolved);
                try out.print("{s}\n", .{resolved});
            } else {
                try out.print("{s}\n", .{uri});
            }
        }
    }.one;

    switch (playlist.body) {
        .basic => |list| {
            for (list) |entry| try emit(w, gpa, base, entry.uri);
        },
        .media => |media| {
            // In the order a player would fetch them: each segment's
            // initialisation section before the segments that use it, and
            // only when it changes. A delta update's `#EXT-X-SKIP` means the
            // segments before it are not here at all, so there is no map to
            // report for them either.
            var current_map: ?[]const u8 = null;
            for (media.entries) |entry| {
                if (entry.map) |map| {
                    if (current_map == null or !std.mem.eql(u8, current_map.?, map.uri)) {
                        try emit(w, gpa, base, map.uri);
                        current_map = map.uri;
                    }
                }
                try emit(w, gpa, base, entry.uri);
            }
            // The parts of a segment that has not been published yet, which
            // a low-latency player is fetching right now.
            for (media.trailing_parts) |part| try emit(w, gpa, base, part.uri);
        },
        .multivariant => |mv| {
            for (mv.renditions) |rendition| {
                if (rendition.uri) |uri| try emit(w, gpa, base, uri);
            }
            for (mv.variants) |variant| try emit(w, gpa, base, variant.uri);
        },
    }
}

test {
    std.testing.refAllDecls(@This());
}
