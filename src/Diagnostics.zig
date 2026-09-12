// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! What the parser noticed and carried on past.
//!
//! This library reads playlists that RFC 8216 would refuse, because nearly
//! every playlist in the world is one of those: a missing `#EXTM3U`, a byte
//! order mark, an unquoted `URI`, an attribute nobody has heard of, a space
//! after a comma. Refusing them would make the library useless and accepting
//! them silently would make it untrustworthy, so it accepts them and writes
//! down what it accepted.
//!
//! ```
//! var diagnostics: Diagnostics = .init(gpa);
//! defer diagnostics.deinit();
//!
//! var playlist = try Playlist.parse(gpa, bytes, .{ .diagnostics = &diagnostics });
//! defer playlist.deinit();
//!
//! if (diagnostics.count() != 0) std.debug.print("{f}", .{diagnostics});
//! ```
//!
//! Passing none costs nothing: the parser checks for null before it builds a
//! message, so a caller that does not care pays for no formatting.
//!
//! # Severity, and what `strict` does
//!
//! A `Problem` is either a `.warning` — understood, and not what the
//! specification says — or an `.invalid` — not understood, and something was
//! dropped or defaulted as a result. `ParseOptions.strict` turns the first
//! `.invalid` into a returned error; nothing turns a warning into one, since
//! a playlist that provoked no warnings at all would be a rare thing.
//!
//! # Lifetimes
//!
//! A `Problem`'s text is copied into this structure rather than borrowed from
//! the playlist, so a `Diagnostics` outlives both the input bytes and the
//! `Playlist` that was parsed from them. That is the point: a tool typically
//! frees the playlist and then reports.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Diagnostics = @This();

/// Where the copied message text lives.
arena: std.heap.ArenaAllocator,
/// Everything noticed, in the order it was noticed, which is the order of
/// the lines it was noticed on.
problems: std.ArrayList(Problem) = .empty,
/// How many problems were not recorded because `limit` was reached or
/// because recording one failed to allocate.
///
/// A playlist made of random bytes produces a problem per line, and a
/// megabyte of those is a megabyte of messages nobody will read. The count
/// is here so that a report can end with "and 41,000 more" rather than
/// pretending the list is complete.
dropped: u32 = 0,
/// How many problems to keep. The rest are counted in `dropped`.
limit: u32 = 512,

/// How much a problem matters.
pub const Severity = enum {
    /// Understood, and not what RFC 8216 says. Nothing was lost.
    warning,
    /// Not understood: something in the playlist was skipped, or a required
    /// value was defaulted. `ParseOptions.strict` stops at the first of
    /// these.
    invalid,

    pub fn format(s: Severity, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeAll(switch (s) {
            .warning => "warning",
            .invalid => "invalid",
        });
    }
};

/// What kind of thing went wrong. The `detail` on a `Problem` says which
/// tag, attribute or value it was.
pub const Kind = enum {
    /// A UTF-8 byte order mark, which RFC 8216 §4 forbids. Harmless once
    /// removed, and it is removed.
    byte_order_mark,
    /// The first line was not `#EXTM3U`, so this is a plain M3U rather than
    /// an extended one. Legal for an `.m3u` file and not for HLS.
    missing_extm3u,
    /// `#EXTM3U` was there and was not the first line.
    misplaced_extm3u,
    /// A `#EXT` tag this library does not model. It is carried through
    /// unchanged, so nothing is lost by it.
    unknown_tag,
    /// A tag that may appear once appeared twice. The last one wins, which
    /// is what a player that overwrites a field would do.
    duplicate_tag,
    /// A tag's value is not what its definition says: `#EXT-X-VERSION:x`,
    /// an `#EXTINF` with no comma.
    invalid_tag_value,
    /// A tag that takes a value has none, or one that takes none has a
    /// value.
    wrong_tag_arity,
    /// The attribute list could not be walked: an unterminated quoted
    /// string, a name that is not a name. Whatever was read before the
    /// failure is kept.
    invalid_attribute_list,
    /// An attribute this library does not know. Carried through unchanged.
    unknown_attribute,
    /// An attribute whose value is not of the type its definition says.
    invalid_attribute_value,
    /// An attribute the tag's definition says is required is missing.
    missing_required_attribute,
    /// An attribute is present that this tag does not allow — `FRAME-RATE`
    /// on an `#EXT-X-I-FRAME-STREAM-INF`, say.
    attribute_not_allowed,
    /// An `enumerated-string` whose value this library does not know. Kept
    /// as it was written.
    unknown_enumerated_value,
    /// A `quoted-string` attribute written without its quotes. Understood,
    /// and not what §4.2 says.
    missing_quotes,
    /// Whitespace where §4.2 allows none.
    stray_whitespace,
    /// Both Media Playlist tags and Multivariant Playlist tags appeared.
    /// RFC 8216 §4.3.4 says a playlist is one or the other; the tags of
    /// whichever kind lost are kept as unknown tags.
    mixed_playlist_kinds,
    /// A tag that belongs to the other kind of playlist.
    tag_in_wrong_playlist,
    /// A Media Playlist with no `#EXT-X-TARGETDURATION`, which §4.3.3.1
    /// makes mandatory.
    missing_target_duration,
    /// An `#EXTINF` or a segment tag with no URI line after it.
    segment_without_uri,
    /// A URI line with no tag before it saying what it is: no `#EXTINF` in
    /// a Media Playlist, no `#EXT-X-STREAM-INF` in a Multivariant one.
    uri_without_tag,
    /// An `#EXT-X-BYTERANGE` with no offset, where no earlier segment was a
    /// sub-range of the same resource for it to carry on from.
    ///
    /// §4.3.2.2 says the segment is undefined in that case and that a
    /// client "MUST fail to parse the Playlist", which is about as strongly
    /// as the specification ever puts anything.
    byterange_without_offset,
    /// A duration in an `#EXTINF` longer than `#EXT-X-TARGETDURATION`
    /// rounded to the nearest integer allows, which §4.3.3.1 forbids.
    duration_over_target,
    /// `#EXT-X-VERSION` says one thing and a tag in the playlist needs
    /// another.
    version_conflict,
    /// A `{$name}` substitution naming a variable no `#EXT-X-DEFINE`
    /// defined.
    undefined_variable,
    /// An `#EXT-X-DEFINE` whose attributes do not make one of the three
    /// shapes it is allowed to have.
    invalid_define,

    /// A sentence saying what this kind of problem is, with no full stop and
    /// no detail in it — the detail is on the `Problem`.
    pub fn message(k: Kind) []const u8 {
        return switch (k) {
            .byte_order_mark => "a byte order mark, which RFC 8216 §4 forbids",
            .missing_extm3u => "no #EXTM3U on the first line, so this is a plain M3U",
            .misplaced_extm3u => "#EXTM3U is not the first line",
            .unknown_tag => "unknown tag, carried through unchanged",
            .duplicate_tag => "repeated tag; the last one wins",
            .invalid_tag_value => "the tag's value is not of the type it should be",
            .wrong_tag_arity => "the tag has a value where it takes none, or none where it takes one",
            .invalid_attribute_list => "the attribute list could not be read to the end",
            .unknown_attribute => "unknown attribute, carried through unchanged",
            .invalid_attribute_value => "the attribute's value is not of the type it should be",
            .missing_required_attribute => "a required attribute is missing",
            .attribute_not_allowed => "this tag does not allow that attribute",
            .unknown_enumerated_value => "unknown enumerated value, kept as written",
            .missing_quotes => "a quoted-string attribute written without its quotes",
            .stray_whitespace => "whitespace where RFC 8216 §4.2 allows none",
            .mixed_playlist_kinds => "both Media Playlist and Multivariant Playlist tags",
            .tag_in_wrong_playlist => "a tag belonging to the other kind of playlist",
            .missing_target_duration => "a Media Playlist with no #EXT-X-TARGETDURATION",
            .segment_without_uri => "segment tags with no URI line after them",
            .uri_without_tag => "a URI with nothing before it saying what it is",
            .byterange_without_offset => "an #EXT-X-BYTERANGE with no offset and nothing to follow on from",
            .duration_over_target => "a segment longer than #EXT-X-TARGETDURATION allows",
            .version_conflict => "#EXT-X-VERSION is lower than a tag used here requires",
            .undefined_variable => "a substitution naming an undefined variable",
            .invalid_define => "an #EXT-X-DEFINE that is not one of its three shapes",
        };
    }
};

/// One thing the parser noticed.
pub const Problem = struct {
    /// The line it was on, counting from one. Zero for a problem about the
    /// playlist as a whole rather than a line, which `missing_extm3u` and
    /// `missing_target_duration` are.
    line: u32,
    severity: Severity,
    kind: Kind,
    /// The tag, attribute or value it was about, copied. Empty when the kind
    /// says it all.
    detail: []const u8 = "",

    /// `line 12: invalid: unknown attribute, carried through unchanged: FOO`
    pub fn format(p: Problem, w: *Io.Writer) Io.Writer.Error!void {
        if (p.line != 0) try w.print("line {d}: ", .{p.line});
        try w.print("{f}: {s}", .{ p.severity, p.kind.message() });
        if (p.detail.len != 0) try w.print(": {s}", .{p.detail});
    }
};

pub fn init(gpa: Allocator) Diagnostics {
    return .{ .arena = .init(gpa) };
}

pub fn deinit(d: *Diagnostics) void {
    const gpa = d.arena.child_allocator;
    d.problems.deinit(gpa);
    d.arena.deinit();
    d.* = undefined;
}

/// Forget everything, keeping the memory, so that one `Diagnostics` can be
/// used for a directory full of playlists.
pub fn clear(d: *Diagnostics) void {
    d.problems.clearRetainingCapacity();
    _ = d.arena.reset(.retain_capacity);
    d.dropped = 0;
}

/// Record a problem.
///
/// Cannot fail. A `Diagnostics` that runs out of memory counts what it could
/// not keep in `dropped` rather than failing the parse, because a report
/// about a playlist is worth less than the playlist.
pub fn add(d: *Diagnostics, problem: Problem) void {
    if (d.problems.items.len >= d.limit) {
        d.dropped +|= 1;
        return;
    }
    var copy = problem;
    if (problem.detail.len != 0) {
        copy.detail = d.arena.allocator().dupe(u8, problem.detail) catch {
            d.dropped +|= 1;
            return;
        };
    }
    d.problems.append(d.arena.child_allocator, copy) catch {
        d.dropped +|= 1;
    };
}

/// Record a problem whose detail has to be formatted.
///
/// Separate from `add` so that a caller with a plain string does not go
/// through `std.fmt`: the parser reports an unknown attribute for every
/// unknown attribute in the file, and that is the hot path of a parse of
/// something hostile.
pub fn addPrint(
    d: *Diagnostics,
    line: u32,
    severity: Severity,
    kind: Kind,
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (d.problems.items.len >= d.limit) {
        d.dropped +|= 1;
        return;
    }
    const detail = std.fmt.allocPrint(d.arena.allocator(), fmt, args) catch {
        d.dropped +|= 1;
        return;
    };
    d.problems.append(d.arena.child_allocator, .{
        .line = line,
        .severity = severity,
        .kind = kind,
        .detail = detail,
    }) catch {
        d.dropped +|= 1;
    };
}

/// How many problems were recorded, not counting those dropped.
pub fn count(d: *const Diagnostics) usize {
    return d.problems.items.len;
}

/// How many of the recorded problems are `.invalid`.
pub fn invalidCount(d: *const Diagnostics) usize {
    var n: usize = 0;
    for (d.problems.items) |p| {
        if (p.severity == .invalid) n += 1;
    }
    return n;
}

/// The first problem of the given kind, if there is one. For a test that
/// wants to assert what the parser noticed.
pub fn find(d: *const Diagnostics, kind: Kind) ?Problem {
    for (d.problems.items) |p| if (p.kind == kind) return p;
    return null;
}

/// Whether any problem of the given kind was recorded.
pub fn has(d: *const Diagnostics, kind: Kind) bool {
    return d.find(kind) != null;
}

/// Every problem, one per line, with a count of what was dropped if any was.
///
/// Reached by `{f}`. Ends with a newline if there was anything to say and
/// writes nothing at all if there was not, so it can be printed
/// unconditionally.
pub fn format(d: *const Diagnostics, w: *Io.Writer) Io.Writer.Error!void {
    for (d.problems.items) |p| try w.print("{f}\n", .{p});
    if (d.dropped != 0) try w.print("and {d} more not recorded\n", .{d.dropped});
}

// -- tests -----------------------------------------------------------------

const testing = std.testing;

test "a problem formats as a line" {
    var buffer: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try w.print("{f}", .{Problem{
        .line = 12,
        .severity = .invalid,
        .kind = .unknown_attribute,
        .detail = "FOO",
    }});
    try testing.expectEqualStrings(
        "line 12: invalid: unknown attribute, carried through unchanged: FOO",
        w.buffered(),
    );
}

test "a problem about the whole playlist has no line number" {
    var buffer: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try w.print("{f}", .{Problem{
        .line = 0,
        .severity = .warning,
        .kind = .missing_extm3u,
    }});
    try testing.expectEqualStrings(
        "warning: no #EXTM3U on the first line, so this is a plain M3U",
        w.buffered(),
    );
}

test "the detail is copied, so it outlives what it described" {
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    {
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(testing.allocator);
        try source.appendSlice(testing.allocator, "EXT-X-WHAT");
        diagnostics.add(.{ .line = 1, .severity = .invalid, .kind = .unknown_tag, .detail = source.items });
    }
    // `source` is gone; the detail is not.
    try testing.expectEqualStrings("EXT-X-WHAT", diagnostics.problems.items[0].detail);
}

test "counting, finding and asking" {
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    diagnostics.add(.{ .line = 1, .severity = .warning, .kind = .byte_order_mark });
    diagnostics.add(.{ .line = 3, .severity = .invalid, .kind = .unknown_tag, .detail = "EXT-X-Q" });

    try testing.expectEqual(@as(usize, 2), diagnostics.count());
    try testing.expectEqual(@as(usize, 1), diagnostics.invalidCount());
    try testing.expect(diagnostics.has(.unknown_tag));
    try testing.expect(!diagnostics.has(.version_conflict));
    try testing.expectEqual(@as(u32, 3), diagnostics.find(.unknown_tag).?.line);
    try testing.expectEqual(@as(?Problem, null), diagnostics.find(.version_conflict));
}

test "the limit is a limit, and what it drops is counted" {
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();
    diagnostics.limit = 3;

    for (0..10) |i| {
        diagnostics.add(.{ .line = @intCast(i + 1), .severity = .invalid, .kind = .unknown_tag });
    }
    try testing.expectEqual(@as(usize, 3), diagnostics.count());
    try testing.expectEqual(@as(u32, 7), diagnostics.dropped);

    var buffer: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try w.print("{f}", .{&diagnostics});
    try testing.expect(std.mem.endsWith(u8, w.buffered(), "and 7 more not recorded\n"));
}

test "addPrint formats its detail" {
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();
    diagnostics.addPrint(7, .invalid, .invalid_attribute_value, "{s}={s}", .{ "BANDWIDTH", "lots" });
    try testing.expectEqualStrings("BANDWIDTH=lots", diagnostics.problems.items[0].detail);
}

test "an empty Diagnostics formats as nothing at all" {
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    var buffer: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try w.print("{f}", .{&diagnostics});
    try testing.expectEqualStrings("", w.buffered());
}

test "clear keeps the memory and forgets the problems" {
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    diagnostics.add(.{ .line = 1, .severity = .invalid, .kind = .unknown_tag, .detail = "x" });
    diagnostics.dropped = 4;
    diagnostics.clear();
    try testing.expectEqual(@as(usize, 0), diagnostics.count());
    try testing.expectEqual(@as(u32, 0), diagnostics.dropped);

    // And it still works afterwards.
    diagnostics.add(.{ .line = 2, .severity = .warning, .kind = .stray_whitespace, .detail = "y" });
    try testing.expectEqualStrings("y", diagnostics.problems.items[0].detail);
}

test "every kind has a message, and none of them ends in a full stop" {
    for (std.enums.values(Kind)) |kind| {
        const message = kind.message();
        try testing.expect(message.len != 0);
        try testing.expect(message[message.len - 1] != '.');
    }
}
