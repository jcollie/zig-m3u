// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! What this library must do with a playlist nobody wrote.
//!
//! Everything here is a property rather than an example — the tests in
//! `tests/playlists.zig` have the examples. The properties are the ones that
//! a parser and a writer maintained separately will eventually break:
//!
//! * **It terminates, stays inside its buffers, and does not leak.** Whatever
//!   arrives. A playlist is a file off the network, so this is the floor.
//! * **A playlist that parses survives being written and read again.** Deeply
//!   equal, every time. This is the one that catches a parser and a writer
//!   that have drifted apart, and it is worth much more than any fixed
//!   example: a field that `write` forgets is caught the moment the fuzzer
//!   produces a playlist that sets it.
//! * **Writing is a fixed point.** The second write is byte-identical to the
//!   first, so a tool that opens a playlist and saves it does not keep
//!   changing the file.
//! * **`strict` only ever refuses more.** A playlist accepted strictly is
//!   accepted leniently, and the two agree about what is in it.
//!
//! Each target is an ordinary test as well as a fuzz target. Without `--fuzz`
//! it runs the seeds beside it, so `zig build test` exercises the same
//! properties on input that has already been interesting once.
//!
//! `zig build fuzz --fuzz` hands them to Zig's fuzzer, and `zig build
//! fuzz-run` to the loop in `tools/fuzz.zig`.

const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const Smith = std.testing.Smith;

const m3u = @import("m3u");
const Playlist = m3u.Playlist;

/// The allocator the targets run against.
///
/// Under `zig build test` that is the testing allocator, which reports a leak
/// as a failure. `tools/fuzz.zig` cannot name it -- it is not a test build --
/// so it sets this to a checked allocator of its own instead.
pub var backing: Allocator = if (builtin.is_test) testing.allocator else undefined;

// -- whole playlists -------------------------------------------------------

const playlist_seeds = [_][]const u8{
    // The shortest thing that is a playlist at all.
    "#EXTM3U\n",
    "",
    "\n",
    // A Media Playlist, and the tags that make one.
    "#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:9.009,\na.ts\n#EXT-X-ENDLIST\n",
    "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:99\n" ++
        "#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:4.0,\na.m4s\n",
    "#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\n#EXT-X-BYTERANGE:100@0\na.ts\n" ++
        "#EXTINF:10,\n#EXT-X-BYTERANGE:100\na.ts\n",
    "#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXT-X-KEY:METHOD=AES-128,URI=\"k\",IV=0x0f\n" ++
        "#EXTINF:10,\na.ts\n#EXT-X-KEY:METHOD=NONE\n#EXTINF:10,\nb.ts\n",
    "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-PROGRAM-DATE-TIME:2010-02-19T14:54:23.031+08:00\n" ++
        "#EXT-X-DATERANGE:ID=\"a\",START-DATE=\"2010-02-19T14:54:23Z\",DURATION=30,X-Q=1\n" ++
        "#EXTINF:6,\na.ts\n",
    // Low latency, whose trailing parts have no URI and are not a mistake.
    "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-PART-INF:PART-TARGET=0.33\n" ++
        "#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=1\n" ++
        "#EXT-X-PART:DURATION=0.33,URI=\"p.mp4\",INDEPENDENT=YES\n" ++
        "#EXT-X-PRELOAD-HINT:TYPE=PART,URI=\"n.mp4\"\n" ++
        "#EXT-X-RENDITION-REPORT:URI=\"../a/i.m3u8\",LAST-MSN=1\n",
    "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-SKIP:SKIPPED-SEGMENTS=30\n#EXTINF:4,\na.ts\n",
    // A Multivariant Playlist.
    "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1280000,CODECS=\"avc1.4d401e,mp4a.40.2\"," ++
        "RESOLUTION=640x360,CLOSED-CAPTIONS=NONE\nlow.m3u8\n",
    "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"n\",DEFAULT=YES,AUTOSELECT=YES\n" ++
        "#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=1,URI=\"i.m3u8\"\n",
    "#EXTM3U\n#EXT-X-SESSION-DATA:DATA-ID=\"d\",VALUE=\"v\"\n" ++
        "#EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI=\"k\"\n" ++
        "#EXT-X-CONTENT-STEERING:SERVER-URI=\"/s\",PATHWAY-ID=\"A\"\n",
    // Extended M3U, and the IPTV dialect of it.
    "#EXTM3U\n#PLAYLIST:Name\n#EXTINF:553,Artist - Title\na.flac\n",
    "#EXTM3U x-tvg-url=\"https://e.com/g.xml\"\n" ++
        "#EXTINF:-1 tvg-id=\"a\" group-title=\"A, B\",Channel\nhttps://e.com/a.m3u8\n",
    "#EXTM3U\n#EXTGRP:G\n#EXTALB:A\n#EXTVLCOPT:x=1\n#EXTINF:1,T\na.mp3\n",
    // A plain M3U of paths.
    "a.mp3\nb.mp3\n../c.mp3\n",
    // Variables, and the substitutions that name them.
    "#EXTM3U\n#EXT-X-DEFINE:NAME=\"h\",VALUE=\"e.com\"\n#EXT-X-DEFINE:IMPORT=\"i\"\n" ++
        "#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nhttps://{$h}/a.ts?t={$i}\n",
    // Things that are wrong in the ways real playlists are wrong.
    "\xEF\xBB\xBF#EXTM3U\r\n#EXT-X-TARGETDURATION:10.0\r\n#EXTINF:1, t \r\na.ts\r\n",
    "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128, URI=k\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\na.ts\n",
    "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"n\"\n" ++
        "#EXTINF:1,\na.ts\n",
    "#EXTM3U\n#EXT-X-FUTURE:A=1,B=\"x, y\"\n#EXT-X-FLAG\n#EXTINF:1,\na.ts\n",
    "#EXTM3U\n#EXT-X-TARGETDURATION:1\na.ts\n",
    "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\n",
    // Not a playlist at all.
    "<!DOCTYPE html>\n<html></html>\n",
    "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=\"unterminated\nx\n",
    "#EXTM3U\n#EXT-X-VERSION:99999999999999999999999\n",
};

/// The whole of what this library promises, as one property.
fn playlistProperty(input: []const u8) !void {
    const gpa = backing;

    var diagnostics: m3u.Diagnostics = .init(gpa);
    defer diagnostics.deinit();

    // One set of options, shared by every parse below. They have to be the
    // same set: `validate_uris` reports problems the other parses would not
    // see, and comparing a parse that had it against one that did not is
    // comparing two different questions.
    const options: Playlist.ParseOptions = .{
        .diagnostics = &diagnostics,
        // On, because it is the path that allocates the most and the one a
        // caller checking a playlist will take.
        .validate_uris = true,
    };

    var first = Playlist.parse(gpa, input, options) catch |err| switch (err) {
        // Nothing generated here comes near a million lines, so this would
        // be a surprise; it is still not a failure.
        error.TooManyLines => return,
        error.InvalidPlaylist => unreachable, // not asked for
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer first.deinit();

    // Asking for the diagnostics must not change what was parsed, so parse
    // it again without them and compare.
    {
        var quietly = try Playlist.parse(gpa, input, .{ .validate_uris = true });
        defer quietly.deinit();
        try testing.expect(first.eql(&quietly));
    }

    // `strict` only ever refuses more. When it accepts, it accepts the same
    // playlist.
    var strict_options = options;
    strict_options.strict = true;
    strict_options.diagnostics = null;
    if (Playlist.parse(gpa, input, strict_options)) |strict_result| {
        var strictly = strict_result;
        defer strictly.deinit();
        try testing.expect(first.eql(&strictly));
        try testing.expectEqual(@as(usize, 0), diagnostics.invalidCount());
    } else |err| switch (err) {
        error.InvalidPlaylist => try testing.expect(diagnostics.invalidCount() != 0),
        error.TooManyLines => {},
        error.OutOfMemory => return error.OutOfMemory,
    }

    const written = try first.toTextAlloc(gpa);
    defer gpa.free(written);

    var second = try Playlist.parse(gpa, written, .{ .validate_uris = true });
    defer second.deinit();

    // The property that keeps the parser and the writer together.
    if (!first.eql(&second)) {
        std.debug.print(
            "round trip changed the playlist\n--- in ---\n{s}\n--- out ---\n{s}\n--- again ---\n{f}\n",
            .{ input, written, &second },
        );
        return error.RoundTripChangedThePlaylist;
    }

    // ...and that writing settles rather than drifting.
    const again = try second.toTextAlloc(gpa);
    defer gpa.free(again);
    if (!std.mem.eql(u8, written, again)) {
        std.debug.print(
            "writing is not a fixed point\n--- once ---\n{s}\n--- twice ---\n{s}\n",
            .{ written, again },
        );
        return error.WritingIsNotAFixedPoint;
    }

    // A playlist is equal to itself, and the comparison does not crash on
    // anything the parser can produce.
    try testing.expect(first.eql(&first));

    // Every accessor, on every entry, since several of them index and
    // several walk backwards.
    for (first.entries(), 0..) |entry, i| {
        _ = entry.group();
        _ = entry.tagValue("EXTALB");
        _ = entry.attributeValue("group-title");
        _ = entry.partDuration();
        if (first.body == .media) {
            const media = first.body.media;
            _ = media.sequenceNumber(i);
            _ = media.mapFor(i);
            _ = media.keysFor(i);
            _ = media.encrypted(i);
        }
    }
    // ...including out of range, which `mapFor` and `keysFor` clamp rather
    // than trusting.
    if (first.body == .media) {
        _ = first.body.media.mapFor(std.math.maxInt(usize));
        _ = first.body.media.keysFor(std.math.maxInt(usize));
        _ = first.body.media.totalDuration();
    }
    if (first.body == .multivariant) {
        const mv = first.body.multivariant;
        _ = mv.highestBandwidth();
        _ = mv.lowestBandwidth();
        var group = mv.groupIterator("a");
        while (group.next()) |_| {}
    }
    _ = first.title();
    _ = first.duplicateVariable();
    _ = first.kind();
}

test "fuzz whole playlists" {
    for (playlist_seeds) |seed| try playlistProperty(seed);
    try testing.fuzz({}, fuzzPlaylist, .{});
}

fn fuzzPlaylist(_: void, smith: *Smith) !void {
    var buffer: [8192]u8 = undefined;
    const len = smith.slice(&buffer);
    try playlistProperty(buffer[0..len]);
}

// -- variable substitution -------------------------------------------------

const substitute_seeds = [_][]const u8{
    "https://{$host}/a.ts",
    "{$a}{$b}{$a}",
    "{$",
    "{$}",
    "}{$",
    "{{$a}}",
    "no substitutions here",
    "{$a",
    "$ {a}",
    "{$" ++ @as([200]u8, @splat('a')) ++ "}",
};

/// Substitution terminates and is deterministic.
///
/// The loop looks for `{$`, finds the `}`, and continues from after it; a
/// mistake in that arithmetic is an infinite loop rather than a wrong
/// answer, which is why this is a target of its own.
///
/// It is deliberately *not* asserted to be idempotent. Substitution is one
/// pass, so a value that completes a `{$…}` in the text around it is not
/// expanded again: `{{$empty}$a}` becomes `{$a}`, and substituting that
/// would give the value of `a`. `Playlist.substituteAlloc` says so.
fn substituteProperty(input: []const u8) !void {
    const gpa = backing;
    var playlist = try Playlist.parse(gpa,
        \\#EXTM3U
        \\#EXT-X-DEFINE:NAME="a",VALUE="A"
        \\#EXT-X-DEFINE:NAME="b",VALUE=""
        \\#EXT-X-TARGETDURATION:1
        \\
    , .{});
    defer playlist.deinit();

    const imported: []const Playlist.Variable = &.{.{ .name = "host", .value = "e.com" }};

    const once = playlist.substituteAlloc(gpa, input, imported) catch |err| switch (err) {
        error.UndefinedVariable => {
            // Refusing is allowed, and must be refused *consistently*.
            try testing.expectError(
                error.UndefinedVariable,
                playlist.substituteAlloc(gpa, input, imported),
            );
            return;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer gpa.free(once);

    const again = try playlist.substituteAlloc(gpa, input, imported);
    defer gpa.free(again);
    try testing.expectEqualStrings(once, again);

    // Text with no substitution in it comes back untouched, which is the
    // one thing the pass must not do anything to.
    if (std.mem.find(u8, input, "{$") == null) {
        try testing.expectEqualStrings(input, once);
    }
}

test "fuzz variable substitution" {
    for (substitute_seeds) |seed| try substituteProperty(seed);
    try testing.fuzz({}, fuzzSubstitute, .{});
}

fn fuzzSubstitute(_: void, smith: *Smith) !void {
    var buffer: [1024]u8 = undefined;
    const len = smith.slice(&buffer);
    try substituteProperty(buffer[0..len]);
}

// -- attribute lists -------------------------------------------------------

const attribute_seeds = [_][]const u8{
    "BANDWIDTH=1280000",
    "CODECS=\"avc1.4d401e,mp4a.40.2\",RESOLUTION=1280x720",
    "A=1, B=2 , C=\"3\"",
    "URI=\"unterminated",
    "=1",
    "A=",
    "A",
    ",,,",
    "IV=0x9c7db8778570d05c3f4a0e6e0bcc5b5c",
    "START-DATE=\"2010-02-19T14:54:23.031+08:00\"",
    "TIME-OFFSET=-25.5,PRECISE=YES",
    "RESOLUTION=1920x1080",
    "BYTERANGE=\"100@0\"",
    "X=" ++ @as([40]u8, @splat('9')),
    "A=\"" ++ @as([200]u8, @splat('x')) ++ "\"",
};

/// Walking an attribute list terminates, and every decoder on every
/// attribute either answers or fails -- never panics.
///
/// The decoders are where a panic would hide: a narrowing cast, a shift, an
/// overflow in `decimalInteger`, a buffer written past its end in
/// `hexBytes`.
fn attributeProperty(input: []const u8) !void {
    const attribute = m3u.attribute;

    var seen: usize = 0;
    var it: attribute.Iterator = .init(input);
    while (it.next() catch return) |a| {
        seen += 1;
        // Every attribute names a non-empty slice of the input, and the
        // offset only ever moves forwards -- without which the loop would
        // not terminate.
        try testing.expect(a.name.len != 0);
        try testing.expect(it.offset() <= input.len);

        _ = a.isQuoted();
        _ = a.string();
        _ = a.integer() catch {};
        _ = a.float() catch {};
        _ = a.signed() catch {};
        _ = a.boolean() catch {};
        _ = a.resolution() catch {};
        _ = a.hex() catch {};
        var iv: [16]u8 = undefined;
        _ = a.hexBytes(&iv) catch {};
        var big: [512]u8 = undefined;
        _ = a.hexBytes(&big) catch {};
        var words = a.words();
        while (words.next()) |_| {}
        var comma_words = a.commaWords();
        while (comma_words.next()) |_| {}
    }
    // A list cannot yield more attributes than it has bytes.
    try testing.expect(seen <= input.len + 1);

    // The space-separated dialect, on the same input.
    var space: attribute.SpaceIterator = .init(input);
    var space_seen: usize = 0;
    while (space.next()) |a| {
        space_seen += 1;
        try testing.expect(a.name.len != 0);
    }
    try testing.expect(space_seen <= input.len + 1);
}

test "fuzz attribute lists" {
    for (attribute_seeds) |seed| try attributeProperty(seed);
    try testing.fuzz({}, fuzzAttribute, .{});
}

fn fuzzAttribute(_: void, smith: *Smith) !void {
    var buffer: [1024]u8 = undefined;
    const len = smith.slice(&buffer);
    try attributeProperty(buffer[0..len]);
}

// -- dates -----------------------------------------------------------------

const date_seeds = [_][]const u8{
    "2010-02-19T14:54:23.031+08:00",
    "2020-01-01T00:00:00Z",
    "2020-01-01T00:00:00",
    "2020-01-01T00:00:00.000000000Z",
    "2020-01-01t00:00:00z",
    "2020-01-01 00:00:00-0530",
    "1969-07-20T20:17:40Z",
    "2016-12-31T23:59:60Z",
    "0000-01-01T00:00:00Z",
    "9999-12-31T23:59:59Z",
    "2010-99-01T00:00:00Z",
    "2010-02-30T00:00:00Z",
    "2010-02-19",
    "",
    "2020-01-01T00:00:00.1234567891234Z",
};

/// A date that parses survives being written and read again, exactly -- and
/// the instant it names is the same one both times.
fn dateProperty(input: []const u8) !void {
    const DateTime = m3u.time.DateTime;

    const first = DateTime.parse(input) catch return;
    // Anything `parse` produces must be something `validate` accepts, or
    // `format` would write text that does not parse back.
    try first.validate();

    var buffer: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try w.print("{f}", .{first});

    const second = try DateTime.parse(w.buffered());
    if (!first.sameText(second)) {
        std.debug.print("date changed: {s} -> {s}\n", .{ input, w.buffered() });
        return error.DateRoundTripChanged;
    }
    // The instant, where there is one, is the same and goes both ways. A
    // date with no zone names no instant, so `sameInstant` is false for it
    // even against itself -- which is why this is inside the check.
    if (first.zone != .none) {
        try testing.expect(first.sameInstant(second));
        const nanoseconds = try first.toUnixNanoseconds();
        const from_instant = DateTime.fromUnixNanoseconds(nanoseconds) catch return;
        try testing.expectEqual(nanoseconds, try from_instant.toUnixNanoseconds());
        // The calendar is exact in both directions. zig-datetime's, now,
        // rather than this library's -- and still worth asserting here,
        // because the dates a playlist carries are the ones that matter and
        // a calendar that had gone wrong would otherwise surface as a
        // puzzling failure somewhere else.
        const date = from_instant.value.asDate();
        const round_tripped: m3u.time.Date = .fromDaysSinceStartOfEra(date.toDaysSinceStartOfEra());
        try testing.expectEqual(date.year, round_tripped.year);
        try testing.expectEqual(date.month, round_tripped.month);
        try testing.expectEqual(date.day, round_tripped.day);
    }
}

test "fuzz dates" {
    for (date_seeds) |seed| try dateProperty(seed);
    try testing.fuzz({}, fuzzDate, .{});
}

fn fuzzDate(_: void, smith: *Smith) !void {
    var buffer: [64]u8 = undefined;
    const len = smith.slice(&buffer);
    try dateProperty(buffer[0..len]);
}

// The other direction: any instant an `i64` second count can name either
// becomes a date that writes and reads back, or is refused.
test "fuzz instants" {
    try testing.fuzz({}, fuzzInstant, .{});
}

fn fuzzInstant(_: void, smith: *Smith) !void {
    const DateTime = m3u.time.DateTime;
    const seconds = smith.value(i64);
    const parsed = DateTime.fromUnixNanoseconds(
        @as(i128, seconds) * std.time.ns_per_s,
    ) catch return;
    // Anything it hands out must be something `validate` accepts and
    // `format` can write back, or the two halves disagree.
    try parsed.validate();
    try testing.expectEqual(seconds, try parsed.toUnixSeconds());

    var buffer: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try w.print("{f}", .{parsed});
    try testing.expect(parsed.sameText(try DateTime.parse(w.buffered())));
}

// -- byte ranges -----------------------------------------------------------

const byterange_seeds = [_][]const u8{
    "75232@0",
    "82112",
    "0@0",
    "18446744073709551615@18446744073709551615",
    "75232@",
    "@0",
    "a@b",
    "",
    "1@2@3",
};

fn byteRangeProperty(input: []const u8) !void {
    const ByteRange = m3u.tags.ByteRange;
    const first = ByteRange.parse(input) catch return;

    var buffer: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try w.print("{f}", .{first});

    const second = try ByteRange.parse(w.buffered());
    try testing.expectEqual(first.length, second.length);
    try testing.expectEqual(first.offset, second.offset);
    // `end` must not overflow on any range that parses.
    _ = first.end();
}

test "fuzz byte ranges" {
    for (byterange_seeds) |seed| try byteRangeProperty(seed);
    try testing.fuzz({}, fuzzByteRange, .{});
}

fn fuzzByteRange(_: void, smith: *Smith) !void {
    var buffer: [64]u8 = undefined;
    const len = smith.slice(&buffer);
    try byteRangeProperty(buffer[0..len]);
}

// -- lines -----------------------------------------------------------------

const line_seeds = [_][]const u8{
    "#EXTM3U\n#EXTINF:1,\na.ts\n",
    "a\r\nb\nc",
    "\r\r\r",
    "\n\n\n",
    "#",
    "#EXT",
    "#EXTM3U x=\"1\"",
    "   #EXT-X-ENDLIST   ",
    "\xEF\xBB\xBF#EXTM3U",
};

/// The scanner consumes its input exactly once, and every slice it hands
/// back points inside that input.
fn lineProperty(input: []const u8) !void {
    const line = m3u.line;
    const stripped = line.stripByteOrderMark(input);
    const source = stripped.rest;

    var scanner: line.Scanner = .init(source);
    var count: usize = 0;
    var previous_end: usize = 0;
    while (scanner.next()) |current| {
        count += 1;
        // Line numbers count from one and never repeat.
        try testing.expectEqual(@as(u32, @intCast(count)), current.number);

        // `raw` is a slice of `source`, and the lines move forwards through
        // it without overlapping.
        const start = @intFromPtr(current.raw.ptr) - @intFromPtr(source.ptr);
        try testing.expect(start >= previous_end);
        try testing.expect(start + current.raw.len <= source.len);
        previous_end = start + current.raw.len;

        // Classifying the same line twice gives the same answer, and doing
        // it through `classify` gives what the scanner gave.
        const again = line.classify(current.raw);
        try testing.expectEqual(std.meta.activeTag(current.content), std.meta.activeTag(again));
        switch (current.content) {
            .blank => try testing.expect(line.classify(current.raw) == .blank),
            .tag => |tag| {
                try testing.expectEqualStrings(tag.name, again.tag.name);
                // A tag is `#EXT` and then a name, so the name starts with
                // `EXT` -- and `isTag` agrees that this was one.
                try testing.expect(line.isTag(current.raw));
                // A name holds no whitespace and no colon, whatever arrived.
                for (tag.name) |c| {
                    try testing.expect(c != ' ' and c != '\t' and c != ':');
                }
                // A tag has a colon-introduced value or space-separated
                // attributes, never both.
                try testing.expect(tag.value == null or tag.attributes.len == 0);
            },
            .comment => |text| try testing.expectEqualStrings(text, again.comment),
            .uri => |uri| {
                try testing.expectEqualStrings(uri, again.uri);
                // A URI is trimmed, so it neither starts nor ends with
                // whitespace.
                if (uri.len != 0) {
                    try testing.expect(uri[0] != ' ' and uri[0] != '\t');
                    try testing.expect(uri[uri.len - 1] != ' ' and uri[uri.len - 1] != '\t');
                }
            },
        }
    }
    // A file cannot have more lines than it has bytes, plus the one that
    // needs no terminator.
    try testing.expect(count <= source.len + 1);
}

test "fuzz lines" {
    for (line_seeds) |seed| try lineProperty(seed);
    try testing.fuzz({}, fuzzLine, .{});
}

fn fuzzLine(_: void, smith: *Smith) !void {
    var buffer: [2048]u8 = undefined;
    const len = smith.slice(&buffer);
    try lineProperty(buffer[0..len]);
}

// -- resolving URIs --------------------------------------------------------

const resolve_seeds = [_][]const u8{
    "seg1.ts",
    "../a/b.ts",
    "/rooted.ts",
    "//cdn.example.net/a.ts",
    "https://other.example/a.ts",
    "",
    "?query-only",
    "#fragment-only",
    "../../../../../../escape.ts",
    "C:\\Music\\track.mp3",
    "http://[::1/unterminated",
};

/// Resolving a reference against a base gives something that parses as a URI
/// and resolves to itself.
///
/// zig-uri has its own fuzzing for the parser; this is about the use this
/// library puts it to, which is resolving thousands of playlist entries
/// against one base without leaking an arena per entry.
fn resolveProperty(input: []const u8) !void {
    const gpa = backing;
    var base: m3u.resolve.Base = try .init(gpa, "https://example.com/hls/720p/index.m3u8");
    defer base.deinit();

    const resolved = base.resolveAlloc(gpa, input, .{}) catch return;
    defer gpa.free(resolved);

    // Resolving the result against the same base gives the result again,
    // since it is absolute.
    const twice = try base.resolveAlloc(gpa, resolved, .{});
    defer gpa.free(twice);
    try testing.expectEqualStrings(resolved, twice);

    _ = m3u.resolve.looksLikePath(input);
    _ = m3u.resolve.valid(gpa, input);
}

test "fuzz URI resolution" {
    for (resolve_seeds) |seed| try resolveProperty(seed);
    try testing.fuzz({}, fuzzResolve, .{});
}

fn fuzzResolve(_: void, smith: *Smith) !void {
    var buffer: [1024]u8 = undefined;
    const len = smith.slice(&buffer);
    try resolveProperty(buffer[0..len]);
}

// -- the same targets, for a driver that is not the test runner -------------

/// One fuzz target, addressable by name.
///
/// `zig build test` reaches these through the `test` blocks above and Zig's
/// own fuzzer reaches them through `std.testing.fuzz`. This is the third way
/// in, for `tools/fuzz.zig`, a loop that trades coverage feedback for a run
/// that is the same on every machine.
pub const Target = struct {
    name: []const u8,
    run: *const fn (input: []const u8) anyerror!void,
    /// Inputs worth mutating: the same seeds the tests above run, which are
    /// what stands in for the coverage feedback Zig's fuzzer has.
    corpus: []const []const u8,
    /// The buffer this target reads its input into.
    ///
    /// `Smith.slice` yields an *empty* slice for a length larger than the
    /// buffer rather than a truncated one, so a generator that does not know
    /// this number hands the target nothing at all most of the time. Getting
    /// it wrong is silent: the run reports millions of iterations and has
    /// been parsing the empty string.
    content_max: usize,
};

/// Wraps one of the `fuzz*` functions above so that it takes raw bytes.
fn Driven(comptime one: fn (void, *Smith) anyerror!void) type {
    return struct {
        fn run(input: []const u8) anyerror!void {
            var smith: Smith = .{ .in = input };
            return one({}, &smith);
        }
    };
}

pub const all = [_]Target{
    .{ .name = "playlists", .run = Driven(fuzzPlaylist).run, .corpus = &playlist_seeds, .content_max = 8192 },
    .{ .name = "lines", .run = Driven(fuzzLine).run, .corpus = &line_seeds, .content_max = 2048 },
    .{ .name = "attributes", .run = Driven(fuzzAttribute).run, .corpus = &attribute_seeds, .content_max = 1024 },
    .{ .name = "dates", .run = Driven(fuzzDate).run, .corpus = &date_seeds, .content_max = 64 },
    .{ .name = "instants", .run = Driven(fuzzInstant).run, .corpus = &.{}, .content_max = 64 },
    .{ .name = "byteranges", .run = Driven(fuzzByteRange).run, .corpus = &byterange_seeds, .content_max = 64 },
    .{ .name = "substitutions", .run = Driven(fuzzSubstitute).run, .corpus = &substitute_seeds, .content_max = 1024 },
    .{ .name = "resolution", .run = Driven(fuzzResolve).run, .corpus = &resolve_seeds, .content_max = 1024 },
};
