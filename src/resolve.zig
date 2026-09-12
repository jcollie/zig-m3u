// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Turning the URIs in a playlist into ones that can be fetched.
//!
//! Almost every URI in a real playlist is relative. A Multivariant Playlist
//! at `https://example.com/hls/master.m3u8` points at `720p/index.m3u8`, and
//! that Media Playlist's segments are `seg00001.ts` — so nothing in either
//! file can be fetched without knowing the address the file itself came from.
//! RFC 8216 §4.1 says as much: a URI in a playlist is resolved against the
//! URI of the playlist.
//!
//! That resolution is RFC 3986 §5, which is more than string concatenation:
//! `../` has to be removed, a reference beginning `//` keeps the scheme and
//! replaces the authority, a query has to be dropped from the base unless the
//! reference is empty. [zig-uri](https://git.jcollie.dev/jeff/zig-uri) does
//! all of it, so this file is a thin layer over its `click` rather than a
//! second implementation.
//!
//! # Parse the base once
//!
//! A Media Playlist has thousands of segments and one address. `Base` holds
//! the parsed playlist URI so that resolving each segment does not reparse
//! it:
//!
//! ```
//! var base: resolve.Base = try .init(gpa, "https://example.com/hls/720p/index.m3u8");
//! defer base.deinit();
//!
//! for (playlist.entries()) |entry| {
//!     const url = try base.resolveAlloc(gpa, entry.uri, .{});
//!     defer gpa.free(url);
//!     // https://example.com/hls/720p/seg00001.ts
//! }
//! ```
//!
//! # Not every entry is a URI
//!
//! A plain `.m3u` written by a music player holds filesystem paths —
//! `..\Music\track.mp3`, `/home/jeff/track.flac` — and those are not URIs.
//! Resolving one against an `http` base produces something that looks like a
//! URL and is not one. `looksLikePath` is the cheap test for that case; the
//! parser leaves the decision alone by default and only checks URIs when
//! `ParseOptions.validate_uris` asks it to.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const uri = @import("uri");

/// zig-uri's parsed URI. Re-exported so that a caller resolving playlist URIs
/// does not have to depend on zig-uri by name.
pub const Uri = uri.Uri;

/// What can go wrong: everything zig-uri's parser can refuse, plus running
/// out of memory.
pub const Error = uri.Error;

/// How to write a resolved URI out.
pub const Options = struct {
    /// Whether to keep a password that came from the base URI.
    ///
    /// Off by default, which is zig-uri's default and the safe one: a
    /// resolved URI often ends up in a log. A playlist genuinely fetched
    /// from `https://user:secret@host/x.m3u8` needs this on, or the segment
    /// URLs it produces will not authenticate.
    with_password: bool = false,

    fn text(o: Options) Uri.TextOptions {
        return .{ .with_password = o.with_password };
    }
};

/// The address a playlist came from, parsed once.
pub const Base = struct {
    uri: Uri,

    /// Parse the playlist's own address.
    pub fn init(gpa: Allocator, text: []const u8) Error!Base {
        return .{ .uri = try Uri.parse(gpa, text) };
    }

    /// Take an already-parsed URI as the base. It is not copied, so it must
    /// outlive the `Base`, and `deinit` does not free it.
    pub fn fromUri(parsed: Uri) Base {
        return .{ .uri = parsed };
    }

    /// Frees what `init` allocated. Do not call it on a `Base` made by
    /// `fromUri`, which does not own its URI.
    pub fn deinit(b: Base) void {
        b.uri.deinit();
    }

    /// Resolve `reference` against the base, as RFC 3986 §5 says to.
    ///
    /// The result owns its own arena; `deinit` it. Use `resolveAlloc` when
    /// the text is all that is wanted.
    pub fn resolve(b: Base, gpa: Allocator, reference: []const u8) Error!Uri {
        return b.uri.click(gpa, reference);
    }

    /// Resolve `reference` and give back the text, which the caller frees.
    pub fn resolveAlloc(
        b: Base,
        gpa: Allocator,
        reference: []const u8,
        options: Options,
    ) Error![]u8 {
        const resolved = try b.resolve(gpa, reference);
        defer resolved.deinit();
        return resolved.toText(gpa, options.text());
    }

    /// Resolve `reference` and write the text.
    ///
    /// Still needs an allocator, because resolution builds a URI rather than
    /// streaming one; it is freed before this returns.
    pub fn resolveWrite(
        b: Base,
        gpa: Allocator,
        w: *Io.Writer,
        reference: []const u8,
        options: Options,
    ) (Error || Io.Writer.Error)!void {
        const resolved = try b.resolve(gpa, reference);
        defer resolved.deinit();
        try resolved.write(w, options.text());
    }
};

/// Resolve one reference against one base, for a caller with a single URI to
/// deal with. Parses the base every time, so `Base` is the one to use inside
/// a loop.
pub fn resolveAlloc(
    gpa: Allocator,
    base: []const u8,
    reference: []const u8,
    options: Options,
) Error![]u8 {
    const parsed: Base = try .init(gpa, base);
    defer parsed.deinit();
    return parsed.resolveAlloc(gpa, reference, options);
}

/// Whether `text` parses as a URI reference at all.
///
/// Used by the parser when `ParseOptions.validate_uris` is on. Needs an
/// allocator because zig-uri stores its components decoded, and throws away
/// everything it allocated before returning.
pub fn valid(gpa: Allocator, text: []const u8) bool {
    const parsed = Uri.parse(gpa, text) catch return false;
    parsed.deinit();
    return true;
}

/// Whether `text` looks more like a filesystem path than a URI.
///
/// A guess, and deliberately a conservative one: it says yes only for the
/// two shapes that cannot be a relative URI reference — a Windows drive
/// letter followed by a backslash, and any text containing a backslash where
/// a URI would have a forward slash. A POSIX absolute path like
/// `/home/jeff/track.flac` is *also* a perfectly good relative URI
/// reference, so this says no to it and the caller has to know from context
/// which it meant.
///
/// The point of it is a plain `.m3u` from a music player, whose entries are
/// paths and for which resolution against an HTTP base is meaningless.
pub fn looksLikePath(text: []const u8) bool {
    if (text.len >= 3 and text[1] == ':' and (text[2] == '\\' or text[2] == '/') and
        std.ascii.isAlphabetic(text[0]))
    {
        return true;
    }
    return std.mem.findScalar(u8, text, '\\') != null;
}

// -- tests -----------------------------------------------------------------

const testing = std.testing;

/// Resolve and compare, for the tests below.
fn expectResolved(expected: []const u8, base: []const u8, reference: []const u8) !void {
    const got = try resolveAlloc(testing.allocator, base, reference, .{});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "a segment beside its playlist" {
    try expectResolved(
        "https://example.com/hls/720p/seg00001.ts",
        "https://example.com/hls/720p/index.m3u8",
        "seg00001.ts",
    );
}

test "a variant in a subdirectory of the multivariant playlist" {
    try expectResolved(
        "https://example.com/hls/720p/index.m3u8",
        "https://example.com/hls/master.m3u8",
        "720p/index.m3u8",
    );
}

test "the dot segments RFC 3986 §5 says to remove" {
    try expectResolved(
        "https://example.com/hls/audio/a.aac",
        "https://example.com/hls/720p/index.m3u8",
        "../audio/a.aac",
    );
    try expectResolved(
        "https://example.com/a.ts",
        "https://example.com/hls/720p/index.m3u8",
        "../../a.ts",
    );
    // Climbing past the root stops at the root rather than escaping it.
    try expectResolved(
        "https://example.com/a.ts",
        "https://example.com/hls/index.m3u8",
        "../../../../a.ts",
    );
}

test "a rooted reference replaces the whole path" {
    try expectResolved(
        "https://example.com/other/a.ts",
        "https://example.com/hls/720p/index.m3u8",
        "/other/a.ts",
    );
}

test "a network-path reference keeps the scheme and replaces the host" {
    try expectResolved(
        "https://cdn.example.net/a.ts",
        "https://example.com/hls/index.m3u8",
        "//cdn.example.net/a.ts",
    );
}

test "an absolute reference ignores the base entirely" {
    try expectResolved(
        "http://other.example/a.ts",
        "https://example.com/hls/index.m3u8",
        "http://other.example/a.ts",
    );
}

test "the base's query is dropped and the reference's is kept" {
    try expectResolved(
        "https://example.com/hls/a.ts?token=xyz",
        "https://example.com/hls/index.m3u8?token=abc",
        "a.ts?token=xyz",
    );
    try expectResolved(
        "https://example.com/hls/a.ts",
        "https://example.com/hls/index.m3u8?token=abc",
        "a.ts",
    );
}

test "the base is parsed once and resolves many" {
    var base: Base = try .init(testing.allocator, "https://example.com/hls/720p/index.m3u8");
    defer base.deinit();

    for ([_][]const u8{ "seg1.ts", "seg2.ts", "seg3.ts" }, 1..) |reference, n| {
        const got = try base.resolveAlloc(testing.allocator, reference, .{});
        defer testing.allocator.free(got);

        var expected: [64]u8 = undefined;
        try testing.expectEqualStrings(
            try std.fmt.bufPrint(&expected, "https://example.com/hls/720p/seg{d}.ts", .{n}),
            got,
        );
    }
}

test "resolveWrite writes the same thing resolveAlloc returns" {
    var base: Base = try .init(testing.allocator, "https://example.com/hls/index.m3u8");
    defer base.deinit();

    var buffer: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try base.resolveWrite(testing.allocator, &w, "../a.ts", .{});
    try testing.expectEqualStrings("https://example.com/a.ts", w.buffered());
}

test "a password in the base is withheld unless it is asked for" {
    var base: Base = try .init(testing.allocator, "https://user:secret@example.com/hls/index.m3u8");
    defer base.deinit();

    const hidden = try base.resolveAlloc(testing.allocator, "a.ts", .{});
    defer testing.allocator.free(hidden);
    try testing.expect(std.mem.findScalarPos(u8, hidden, 0, 's') != null);
    try testing.expect(std.mem.find(u8, hidden, "secret") == null);

    const shown = try base.resolveAlloc(testing.allocator, "a.ts", .{ .with_password = true });
    defer testing.allocator.free(shown);
    try testing.expectEqualStrings("https://user:secret@example.com/hls/a.ts", shown);
}

test "fromUri does not take ownership" {
    const parsed = try Uri.parse(testing.allocator, "https://example.com/hls/index.m3u8");
    defer parsed.deinit();

    const base: Base = .fromUri(parsed);
    const got = try base.resolveAlloc(testing.allocator, "a.ts", .{});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("https://example.com/hls/a.ts", got);
    // `parsed` is still usable, which is the point of not calling
    // `base.deinit()` here.
    try testing.expectEqualStrings("example.com", parsed.host.?.hostname);
}

test "what is and is not a URI" {
    try testing.expect(valid(testing.allocator, "https://example.com/a.ts"));
    try testing.expect(valid(testing.allocator, "seg1.ts"));
    try testing.expect(valid(testing.allocator, "../a/b.ts"));
    // An unterminated IPv6 literal is one of the few things that is not.
    try testing.expect(!valid(testing.allocator, "http://[::1/a"));
    try testing.expect(!valid(testing.allocator, "http://example.com:99999/a"));
}

test "what looks like a path rather than a URI" {
    try testing.expect(looksLikePath("C:\\Music\\track.mp3"));
    try testing.expect(looksLikePath("c:/Music/track.mp3"));
    try testing.expect(looksLikePath("..\\Music\\track.mp3"));
    // A POSIX absolute path is also a legal relative URI reference, so this
    // deliberately does not claim to know.
    try testing.expect(!looksLikePath("/home/jeff/track.flac"));
    try testing.expect(!looksLikePath("seg1.ts"));
    try testing.expect(!looksLikePath("https://example.com/a.ts"));
    try testing.expect(!looksLikePath(""));
}
