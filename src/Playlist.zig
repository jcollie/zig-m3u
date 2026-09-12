// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A whole playlist: parsed, owned, and writable again.
//!
//! ```
//! var playlist = try Playlist.parse(gpa, bytes, .{});
//! defer playlist.deinit();
//!
//! switch (playlist.body) {
//!     .multivariant => |m| for (m.variants) |v| {
//!         std.debug.print("{d} bps at {s}\n", .{ v.stream_inf.bandwidth, v.uri });
//!     },
//!     .media => |m| for (m.entries) |e| {
//!         std.debug.print("{d}s {s}\n", .{ e.duration.?, e.uri });
//!     },
//!     .basic => |entries| for (entries) |e| std.debug.print("{s}\n", .{e.uri}),
//! }
//! ```
//!
//! # One arena, one copy of the source
//!
//! `parse` copies the bytes it was given into an arena and every string on
//! every structure below borrows from that copy, so a `Playlist` is valid for
//! as long as it lives and the caller's buffer can go. One `deinit` frees all
//! of it, and nothing in here needs freeing individually.
//!
//! # Three kinds of playlist
//!
//! RFC 8216 §2 has two — a Multivariant (once Master) Playlist listing
//! variants, and a Media Playlist listing segments — and the tags of one may
//! not appear in the other. There is a third in practice: the plain or
//! extended M3U that predates HLS by a decade and is still what most `.m3u`
//! files are, being a list of URIs with an `#EXTINF` apiece and none of the
//! `#EXT-X-` tags at all. `body` is a union over the three, and `Kind`
//! describes how the parser tells them apart.
//!
//! # What survives a rewrite, and what does not
//!
//! Parsing and writing gives back an *equal playlist*, not identical bytes.
//! `write` normalises: tags come out in the order this file writes them
//! rather than the order they were read, an unquoted `URI` gains its quotes,
//! a `YES`/`NO` attribute at its default is left out, and a number is written
//! in its shortest form — so `#EXT-X-TARGETDURATION:10.0` comes back as
//! `:10`. What is *not* lost is anything a reader could act on: unknown tags,
//! unknown attributes, unknown enumerated values, comments and blank lines
//! are all kept where they were found. `tests/playlists.zig` asserts the
//! property this gives: parse, write, parse again, and the two playlists are
//! deeply equal.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const attribute = @import("attribute.zig");
const line = @import("line.zig");
const resolve = @import("resolve.zig");
const tags = @import("tags.zig");
const time = @import("time.zig");

pub const Diagnostics = @import("Diagnostics.zig");

const Attribute = attribute.Attribute;
const ByteRange = tags.ByteRange;
const ContentSteering = tags.ContentSteering;
const DateRange = tags.DateRange;
const DateTime = time.DateTime;
const Define = tags.Define;
const Key = tags.Key;
const Map = tags.Map;
const Part = tags.Part;
const PartInf = tags.PartInf;
const PreloadHint = tags.PreloadHint;
const Rendition = tags.Rendition;
const RenditionReport = tags.RenditionReport;
const Reporter = tags.Reporter;
const ServerControl = tags.ServerControl;
const SessionData = tags.SessionData;
const Skip = tags.Skip;
const Start = tags.Start;
const StreamInf = tags.StreamInf;

const Playlist = @This();

/// Everything below lives in here, including a copy of the source bytes.
arena: std.heap.ArenaAllocator,
/// The bytes as they were parsed, with the byte order mark removed. Every
/// string in the playlist points into this.
source: []const u8,
/// The input began with a UTF-8 byte order mark, which RFC 8216 §4 forbids.
/// `write` puts it back, so that a tool asked to change one tag does not
/// silently re-encode somebody's file.
byte_order_mark: bool = false,
/// The first line was `#EXTM3U`. A playlist without it is a plain M3U: legal
/// as an `.m3u` file and not as HLS, which §4.3.1.1 makes this tag mandatory
/// for.
extm3u: bool = false,
/// Attributes on the `#EXTM3U` line itself, which RFC 8216 does not allow.
/// IPTV playlists put `x-tvg-url` and `url-tvg` there, space-separated.
extm3u_attributes: []const Attribute = &.{},
/// `#EXT-X-VERSION`. Absent means version 1, per §4.3.1.2.
version: ?u64 = null,
/// `#EXT-X-INDEPENDENT-SEGMENTS`: every segment starts with an independent
/// frame.
independent_segments: bool = false,
/// `#EXT-X-START`: where a player should begin.
start: ?Start = null,
/// `#EXT-X-DEFINE`, in the order written. §4.2 requires their names to be
/// unique, which `duplicateVariable` will tell you about.
defines: []const Define = &.{},
/// What this playlist actually is.
body: Body,
/// Lines after the last URI that nothing claimed: the comments and blank
/// lines at the foot of the file, and any tag this library does not model
/// that appeared there.
trailing: []const Extra = &.{},

/// Which of the three kinds of playlist this is.
pub const Kind = enum {
    /// Neither a Media Playlist tag nor a Multivariant one appeared: a plain
    /// or extended M3U, which is a list of URIs with at most an `#EXTINF`
    /// apiece.
    ///
    /// `#EXTINF` alone does *not* make a playlist a Media Playlist, because
    /// an extended M3U is exactly `#EXTM3U` and `#EXTINF` and nothing else —
    /// which is what every IPTV channel list in the world is.
    basic,
    /// A Media Playlist, §4.3.3: segments. Chosen when any Media Playlist
    /// tag appeared, or any Media Segment tag other than `#EXTINF`.
    media,
    /// A Multivariant Playlist, §4.3.4: variants to choose between. Chosen
    /// when any Multivariant Playlist tag appeared.
    multivariant,
};

/// The part of a playlist that depends on which kind it is.
pub const Body = union(Kind) {
    /// A plain or extended M3U's entries. The same `Entry` type a Media
    /// Playlist uses, with the HLS-only fields left at their defaults.
    basic: []const Entry,
    media: Media,
    multivariant: Multivariant,
};

/// A line kept exactly as it was found, because this library had no better
/// place for it.
///
/// Everything in a playlist that is not a tag this library models ends up in
/// one of these, attached to the entry or variant it preceded, so that
/// writing the playlist puts it back where it was. That includes blank lines,
/// which makes a rewritten playlist look like the one that went in rather
/// than like a minified version of it.
pub const Extra = union(enum) {
    /// A blank line, or one of nothing but spaces and tabs.
    blank,
    /// A `#` line that is not a tag: the text after the `#`.
    comment: []const u8,
    /// A `#EXT` tag this library does not model — which includes the
    /// extended-M3U directives it knows the names of but gives no types to,
    /// such as `#EXTALB`.
    tag: line.Tag,
    /// A URI line that no tag introduced. Kept rather than dropped, since
    /// dropping it would lose a segment.
    uri: []const u8,

    pub fn write(e: Extra, w: *Io.Writer) Io.Writer.Error!void {
        switch (e) {
            .blank => try w.writeByte('\n'),
            .comment => |text| try w.print("#{s}\n", .{text}),
            .tag => |t| if (t.value) |value| {
                try w.print("#{s}:{s}\n", .{ t.name, value });
            } else if (t.attributes.len != 0) {
                try w.print("#{s} {s}\n", .{ t.name, t.attributes });
            } else {
                try w.print("#{s}\n", .{t.name});
            },
            .uri => |u| try w.print("{s}\n", .{u}),
        }
    }
};

/// One URI and everything that was written before it.
///
/// Used for a Media Playlist's segments and for a plain M3U's entries alike,
/// because the two overlap almost entirely: both are a URI with an optional
/// duration and title, and the difference is only which of the other fields
/// can be set.
///
/// **The fields hold the tags written before this URI, not the tags in
/// effect at it.** `#EXT-X-KEY` and `#EXT-X-MAP` apply to every segment after
/// them until the next one, so a playlist that declares a key once has it on
/// its first entry and nowhere else. `Media.keyFor` and `Media.mapFor` do
/// that walk for you.
pub const Entry = struct {
    /// The URI or path, trimmed of surrounding whitespace. Relative to the
    /// playlist's own address; `resolve.Base` turns it into something
    /// fetchable.
    uri: []const u8,
    /// `#EXTINF`'s duration, in seconds. Null when there was no `#EXTINF`
    /// at all, which a plain M3U is allowed and a Media Playlist is not.
    ///
    /// IPTV playlists write `-1` for a live stream of unknown length, so
    /// this really can be negative.
    duration: ?f64 = null,
    /// `#EXTINF`'s title: everything after the comma.
    ///
    /// Empty both when the title was empty and when there was no comma at
    /// all, which is a distinction nothing needs and which `write` would not
    /// be able to reproduce — it always writes the comma, as §4.3.2.1
    /// requires.
    title: []const u8 = "",
    /// The attributes an IPTV playlist writes between the duration and the
    /// comma: `tvg-id`, `tvg-logo`, `group-title` and the rest. Not in
    /// RFC 8216. `attributeValue` looks one up.
    inf_attributes: []const Attribute = &.{},
    /// `#EXT-X-BYTERANGE`: this segment is a range of the resource at `uri`
    /// rather than all of it.
    byterange: ?ByteRange = null,
    /// `#EXT-X-DISCONTINUITY` immediately before this segment.
    discontinuity: bool = false,
    /// The `#EXT-X-KEY` tags written immediately before this segment. More
    /// than one is legal and means the same content under several key
    /// formats.
    keys: []const Key = &.{},
    /// `#EXT-X-MAP` written before this segment.
    map: ?Map = null,
    /// `#EXT-X-PROGRAM-DATE-TIME`: the wall-clock time the first sample of
    /// this segment was at.
    program_date_time: ?DateTime = null,
    /// The `#EXT-X-DATERANGE` tags written before this segment.
    dateranges: []const DateRange = &.{},
    /// `#EXT-X-GAP`: the segment is missing and must not be fetched.
    gap: bool = false,
    /// `#EXT-X-BITRATE`, in bits per second.
    bitrate: ?u64 = null,
    /// The `#EXT-X-PART` tags belonging to this segment.
    parts: []const Part = &.{},
    /// Comments, blank lines and unmodelled tags written before this entry,
    /// in order.
    leading: []const Extra = &.{},

    /// The value of one of the `#EXTINF` attributes, by name, ignoring case
    /// and with the quotes taken off. `entry.attributeValue("group-title")`.
    pub fn attributeValue(e: Entry, name: []const u8) ?[]const u8 {
        for (e.inf_attributes) |a| {
            if (tags.eqlName(a.name, name)) return a.string();
        }
        return null;
    }

    /// The value of one of the tags in `leading`, by name, ignoring case.
    /// `entry.tagValue("EXTALB")` reads an extended-M3U album directive.
    ///
    /// Null when the tag is not there; a tag written with no `:` at all
    /// gives an empty string rather than null, since it *was* there.
    pub fn tagValue(e: Entry, name: []const u8) ?[]const u8 {
        for (e.leading) |extra| switch (extra) {
            .tag => |t| if (tags.eqlName(t.name, name)) return t.value orelse "",
            else => {},
        };
        return null;
    }

    /// Which group this entry belongs to, however the playlist said so:
    /// `#EXTGRP` if there is one, otherwise the `group-title` attribute that
    /// IPTV playlists use instead.
    pub fn group(e: Entry) ?[]const u8 {
        return e.tagValue("EXTGRP") orelse e.attributeValue("group-title");
    }

    /// How long the parts of this segment add up to, for checking them
    /// against `duration`.
    pub fn partDuration(e: Entry) f64 {
        var total: f64 = 0;
        for (e.parts) |part| total += part.duration;
        return total;
    }

    pub fn write(e: Entry, w: *Io.Writer) Io.Writer.Error!void {
        for (e.leading) |extra| try extra.write(w);
        if (e.discontinuity) try w.writeAll("#EXT-X-DISCONTINUITY\n");
        for (e.keys) |key| {
            try w.writeAll("#EXT-X-KEY:");
            try key.write(w);
            try w.writeByte('\n');
        }
        if (e.map) |map| {
            try w.writeAll("#EXT-X-MAP:");
            try map.write(w);
            try w.writeByte('\n');
        }
        if (e.program_date_time) |at| try w.print("#EXT-X-PROGRAM-DATE-TIME:{f}\n", .{at});
        for (e.dateranges) |range| {
            try w.writeAll("#EXT-X-DATERANGE:");
            try range.write(w);
            try w.writeByte('\n');
        }
        if (e.gap) try w.writeAll("#EXT-X-GAP\n");
        if (e.bitrate) |bitrate| try w.print("#EXT-X-BITRATE:{d}\n", .{bitrate});
        for (e.parts) |part| {
            try w.writeAll("#EXT-X-PART:");
            try part.write(w);
            try w.writeByte('\n');
        }
        if (e.duration) |duration| {
            try w.print("#EXTINF:{d}", .{duration});
            for (e.inf_attributes) |a| try w.print(" {s}={s}", .{ a.name, a.raw });
            try w.print(",{s}\n", .{e.title});
        }
        // After the `#EXTINF`, which is where §4.3.2.2's examples put it.
        if (e.byterange) |range| try w.print("#EXT-X-BYTERANGE:{f}\n", .{range});
        try w.print("{s}\n", .{e.uri});
    }
};

/// One variant of a Multivariant Playlist: an `#EXT-X-STREAM-INF` and the URI
/// on the line after it, or an `#EXT-X-I-FRAME-STREAM-INF`, whose URI is an
/// attribute instead.
pub const Variant = struct {
    stream_inf: StreamInf,
    /// The Media Playlist this variant is. For an ordinary variant this came
    /// from the line after the tag; for an I-frame variant, from the tag's
    /// own `URI` attribute.
    uri: []const u8,
    /// Whether this was an `#EXT-X-I-FRAME-STREAM-INF`, which is a variant
    /// made only of I-frames, for scrubbing and trick play.
    iframe_only: bool = false,
    /// Comments, blank lines and unmodelled tags written before this
    /// variant.
    leading: []const Extra = &.{},

    pub fn write(v: Variant, w: *Io.Writer) Io.Writer.Error!void {
        for (v.leading) |extra| try extra.write(w);
        if (v.iframe_only) {
            // Its URI is an attribute, and `stream_inf.uri` is where the
            // parser put it, so it needs nothing here.
            try w.writeAll("#EXT-X-I-FRAME-STREAM-INF:");
            try v.stream_inf.write(w);
            try w.writeByte('\n');
        } else {
            try w.writeAll("#EXT-X-STREAM-INF:");
            try v.stream_inf.write(w);
            try w.print("\n{s}\n", .{v.uri});
        }
    }
};

/// A Multivariant Playlist, §4.3.4.
pub const Multivariant = struct {
    /// The variants, in the order written, including the I-frame-only ones —
    /// which `Variant.iframe_only` tells apart. Keeping them in one list is
    /// what preserves their order relative to each other.
    variants: []const Variant = &.{},
    /// The `#EXT-X-MEDIA` renditions the variants choose between.
    renditions: []const Rendition = &.{},
    /// `#EXT-X-SESSION-DATA`.
    session_data: []const SessionData = &.{},
    /// `#EXT-X-SESSION-KEY`: the keys the Media Playlists will use, given
    /// here so that a player can fetch them before it starts.
    session_keys: []const Key = &.{},
    /// `#EXT-X-CONTENT-STEERING`.
    content_steering: ?ContentSteering = null,

    /// The renditions in one group, by `GROUP-ID`.
    ///
    /// Walks the list, so a player switching tracks in a loop should collect
    /// them once rather than calling this per frame.
    pub fn groupIterator(m: Multivariant, group_id: []const u8) GroupIterator {
        return .{ .renditions = m.renditions, .group_id = group_id };
    }

    pub const GroupIterator = struct {
        renditions: []const Rendition,
        group_id: []const u8,
        index: usize = 0,

        pub fn next(it: *GroupIterator) ?Rendition {
            while (it.index < it.renditions.len) {
                const rendition = it.renditions[it.index];
                it.index += 1;
                if (std.mem.eql(u8, rendition.group_id, it.group_id)) return rendition;
            }
            return null;
        }
    };

    /// The variant with the highest `BANDWIDTH`, which is what a player
    /// picks when it has bandwidth to spare.
    pub fn highestBandwidth(m: Multivariant) ?Variant {
        var best: ?Variant = null;
        for (m.variants) |variant| {
            if (variant.iframe_only) continue;
            if (best == null or variant.stream_inf.bandwidth > best.?.stream_inf.bandwidth) {
                best = variant;
            }
        }
        return best;
    }

    /// The variant with the lowest `BANDWIDTH`, which §6.3.1 says a player
    /// should start with unless it knows better.
    pub fn lowestBandwidth(m: Multivariant) ?Variant {
        var best: ?Variant = null;
        for (m.variants) |variant| {
            if (variant.iframe_only) continue;
            if (best == null or variant.stream_inf.bandwidth < best.?.stream_inf.bandwidth) {
                best = variant;
            }
        }
        return best;
    }
};

/// A Media Playlist, §4.3.3.
pub const Media = struct {
    /// `#EXT-X-TARGETDURATION`, required by §4.3.3.1: the longest any
    /// segment is, rounded to the nearest integer. Null only in a playlist
    /// that left it out, which is reported as `missing_target_duration`.
    target_duration: ?u64 = null,
    /// `#EXT-X-MEDIA-SEQUENCE`: the sequence number of the first segment.
    /// Absent means zero, per §4.3.3.2.
    media_sequence: u64 = 0,
    /// `#EXT-X-DISCONTINUITY-SEQUENCE`. Absent means zero.
    discontinuity_sequence: u64 = 0,
    /// `#EXT-X-PLAYLIST-TYPE`. Absent means the playlist may change in any
    /// way, which is what a live one does.
    playlist_type: ?tags.Enumerated(tags.PlaylistType) = null,
    /// `#EXT-X-I-FRAMES-ONLY`: every segment is one I-frame.
    iframes_only: bool = false,
    /// `#EXT-X-ENDLIST`: no more segments will be added.
    endlist: bool = false,
    /// `#EXT-X-PART-INF`.
    part_inf: ?PartInf = null,
    /// `#EXT-X-SERVER-CONTROL`.
    server_control: ?ServerControl = null,
    /// `#EXT-X-SKIP`: this is a delta update and the first
    /// `skipped_segments` segments are not here.
    skip: ?Skip = null,
    /// `#EXT-X-PRELOAD-HINT`, at most one per `TYPE`.
    preload_hints: []const PreloadHint = &.{},
    /// `#EXT-X-RENDITION-REPORT`.
    rendition_reports: []const RenditionReport = &.{},
    /// The segments.
    entries: []const Entry = &.{},
    /// `#EXT-X-PART` tags after the last complete segment: the parts of a
    /// segment that is still being produced, which have no `#EXTINF` and no
    /// URI line yet. This is what a low-latency playlist ends with.
    trailing_parts: []const Part = &.{},

    /// The media sequence number of `entries[index]`.
    ///
    /// Counts from `media_sequence`, and past the segments an
    /// `#EXT-X-SKIP` left out — which is the whole reason this is a method
    /// rather than an addition the caller does.
    pub fn sequenceNumber(m: Media, index: usize) u64 {
        const skipped = if (m.skip) |s| s.skipped_segments else 0;
        return m.media_sequence + skipped + index;
    }

    /// How long the playlist is, being the sum of its segments' durations.
    ///
    /// Only meaningful once `endlist` is set: a live playlist's real length
    /// is whatever has been published so far.
    pub fn totalDuration(m: Media) f64 {
        var total: f64 = 0;
        for (m.entries) |entry| total += entry.duration orelse 0;
        return total;
    }

    /// The `#EXT-X-MAP` in effect at `entries[index]`: the last one declared
    /// at or before it.
    pub fn mapFor(m: Media, index: usize) ?Map {
        // `+|` rather than `+`: these are documented to clamp, and
        // `index + 1` for `maxInt(usize)` is an overflow panic rather than a
        // clamp. Saturating reaches `maxInt`, `@min` brings it into range,
        // and an empty list gives zero so the loop below does not run.
        var i = @min(index +| 1, m.entries.len);
        while (i > 0) {
            i -= 1;
            if (m.entries[i].map) |map| return map;
        }
        return null;
    }

    /// The `#EXT-X-KEY` tags in effect at `entries[index]`: the last set
    /// declared at or before it.
    ///
    /// A set rather than one key, because §4.3.2.4 allows several with
    /// different `KEYFORMAT`s to apply at once. An empty result means the
    /// segment is not encrypted — either because no key was declared or
    /// because the last one declared had `METHOD=NONE`, which this
    /// deliberately does *not* filter out: which of several keys applies is
    /// the caller's business, and a `METHOD=NONE` among them is information.
    pub fn keysFor(m: Media, index: usize) []const Key {
        // `+|` rather than `+`: these are documented to clamp, and
        // `index + 1` for `maxInt(usize)` is an overflow panic rather than a
        // clamp. Saturating reaches `maxInt`, `@min` brings it into range,
        // and an empty list gives zero so the loop below does not run.
        var i = @min(index +| 1, m.entries.len);
        while (i > 0) {
            i -= 1;
            if (m.entries[i].keys.len != 0) return m.entries[i].keys;
        }
        return &.{};
    }

    /// Whether `entries[index]` is encrypted, which is the common question
    /// `keysFor` is asked in service of.
    pub fn encrypted(m: Media, index: usize) bool {
        for (m.keysFor(index)) |key| {
            if (!key.method.is(.none)) return true;
        }
        return false;
    }
};

// -- parsing ---------------------------------------------------------------

pub const ParseOptions = struct {
    /// Where to write down what had to be tolerated. Costs nothing when
    /// null: the parser checks before it builds a message.
    diagnostics: ?*Diagnostics = null,
    /// Refuse a playlist rather than tolerating anything the parser would
    /// report as `.invalid`, which is anything that lost information.
    /// Warnings never fail a parse, since almost every real playlist earns
    /// at least one.
    ///
    /// Works with or without a `Diagnostics`; pass one to find out *what*
    /// was wrong.
    strict: bool = false,
    /// Check that every URI this library recognises as one parses as a URI
    /// reference, reporting `invalid_tag_value` if it does not.
    ///
    /// Off by default, because a plain `.m3u` from a music player holds
    /// filesystem paths rather than URIs and every one of them would be
    /// reported.
    validate_uris: bool = false,
    /// The most lines to read, so that a hostile file cannot ask for
    /// unbounded memory: each line can cost an `Extra`, and a megabyte of
    /// newlines is a million of them.
    max_lines: u32 = 1_000_000,
};

pub const ParseError = error{
    OutOfMemory,
    /// `strict` was set and something in the playlist lost information.
    InvalidPlaylist,
    /// More lines than `ParseOptions.max_lines`.
    TooManyLines,
};

/// Read a playlist.
///
/// `bytes` is copied, so it may be freed as soon as this returns.
pub fn parse(gpa: Allocator, bytes: []const u8, options: ParseOptions) ParseError!Playlist {
    // The arena is built in place and never copied until this returns.
    // A `std.heap.ArenaAllocator` holds its list of buffers inline, so a
    // copy taken before an allocation cannot free what the original went on
    // to allocate -- which is a leak that only shows up under
    // `checkAllAllocationFailures`, since it needs the error path to be
    // taken.
    var playlist: Playlist = .{
        .arena = .init(gpa),
        .source = "",
        .body = .{ .basic = &.{} },
    };
    errdefer playlist.arena.deinit();

    const stripped = line.stripByteOrderMark(bytes);
    playlist.source = try playlist.arena.allocator().dupe(u8, stripped.rest);
    playlist.byte_order_mark = stripped.present;

    var reporter: Reporter = .{
        .arena = playlist.arena.allocator(),
        .diagnostics = options.diagnostics,
    };
    if (stripped.present) reporter.warn(.byte_order_mark, "");

    try playlist.fill(&reporter, options);

    if (options.strict and reporter.invalid_count != 0) return error.InvalidPlaylist;
    return playlist;
}

/// Read a playlist from an `Io.Reader`, up to `limit` bytes.
///
/// The whole playlist is read into memory before parsing: it is a file, not a
/// stream, and the shape of it — a tag applying to the line after it, a
/// `#EXT-X-ENDLIST` that changes what the whole thing means — is not one a
/// streaming parser would make easier.
pub fn parseReader(
    gpa: Allocator,
    reader: *Io.Reader,
    limit: Io.Limit,
    options: ParseOptions,
) (ParseError || Io.Reader.LimitedAllocError)!Playlist {
    const bytes = try reader.allocRemaining(gpa, limit);
    defer gpa.free(bytes);
    return parse(gpa, bytes, options);
}

pub fn deinit(p: *Playlist) void {
    p.arena.deinit();
    p.* = undefined;
}

/// Which of the three kinds this is, which is `body`'s tag.
pub fn kind(p: *const Playlist) Kind {
    return std.meta.activeTag(p.body);
}

/// The entries of a Media Playlist or a plain M3U, and nothing for a
/// Multivariant one.
///
/// For a caller that wants the list of things to play and does not care
/// which of the two it came from.
pub fn entries(p: *const Playlist) []const Entry {
    return switch (p.body) {
        .basic => |list| list,
        .media => |m| m.entries,
        .multivariant => &.{},
    };
}

/// The value of a variable declared by an `#EXT-X-DEFINE` with a `NAME`.
///
/// Null for a variable declared by `IMPORT` or `QUERYPARAM`, whose value
/// comes from outside this playlist — the Multivariant Playlist that
/// referred to it, or the query string it was fetched with. `substituteAlloc`
/// takes those as an argument.
pub fn variable(p: *const Playlist, name: []const u8) ?[]const u8 {
    for (p.defines) |define| {
        const declared = define.name orelse continue;
        if (std.mem.eql(u8, declared, name)) return define.value orelse "";
    }
    return null;
}

/// The first variable name declared twice, which §4.2 forbids. Null if
/// every name is unique.
pub fn duplicateVariable(p: *const Playlist) ?[]const u8 {
    for (p.defines, 0..) |a, i| {
        const name = a.variableName() orelse continue;
        for (p.defines[i + 1 ..]) |b| {
            const other = b.variableName() orelse continue;
            if (std.mem.eql(u8, name, other)) return name;
        }
    }
    return null;
}

/// One name and value, for the variables an `#EXT-X-DEFINE` imports rather
/// than declares.
pub const Variable = struct {
    name: []const u8,
    value: []const u8,
};

pub const SubstituteError = error{
    OutOfMemory,
    /// A `{$name}` naming a variable nothing defined.
    UndefinedVariable,
};

/// Expand the `{$name}` substitutions in `text`, which the caller frees.
///
/// Variable substitution was added to HLS after RFC 8216 and applies to URI
/// lines and to the values of a listed set of attributes. This library does
/// not apply it for you, because doing so would mean a playlist could not be
/// written back out as it came; call this on the strings you are about to
/// use.
///
/// `imported` supplies the values for variables an `#EXT-X-DEFINE` brought
/// in with `IMPORT` or `QUERYPARAM`, which this playlist does not itself
/// know. A name found there wins over one declared here, since that is what
/// importing means.
///
/// One pass, left to right, which is what the specification describes and is
/// therefore **not idempotent**: a value that happens to complete a `{$…}`
/// in the text around it is not expanded again. `{{$empty}$a}` becomes
/// `{$a}` and stays that way, and substituting the result a second time
/// would give something else. Substitute once, on the text you are about to
/// use.
pub fn substituteAlloc(
    p: *const Playlist,
    gpa: Allocator,
    text: []const u8,
    imported: []const Variable,
) SubstituteError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var rest = text;
    while (std.mem.find(u8, rest, "{$")) |at| {
        try out.appendSlice(gpa, rest[0..at]);
        const after = rest[at + 2 ..];
        const close = std.mem.findScalar(u8, after, '}') orelse {
            // An unclosed `{$` is not a substitution, so it is text.
            try out.appendSlice(gpa, rest[at..]);
            rest = rest[rest.len..];
            break;
        };
        const name = after[0..close];
        const value = blk: {
            for (imported) |v| {
                if (std.mem.eql(u8, v.name, name)) break :blk v.value;
            }
            break :blk p.variable(name) orelse return error.UndefinedVariable;
        };
        try out.appendSlice(gpa, value);
        rest = after[close + 1 ..];
    }
    try out.appendSlice(gpa, rest);
    return out.toOwnedSlice(gpa);
}

/// The `#PLAYLIST` directive of an extended M3U, which names the playlist.
///
/// It does not begin `#EXT`, so RFC 8216 §4.1 makes it a comment rather than
/// a tag — which is why it is found among the comments rather than given a
/// field of its own, and why it is a search rather than a lookup.
pub fn title(p: *const Playlist) ?[]const u8 {
    for (p.trailing) |extra| {
        if (playlistDirective(extra)) |value| return value;
    }
    for (p.entries()) |entry| {
        for (entry.leading) |extra| {
            if (playlistDirective(extra)) |value| return value;
        }
    }
    if (p.body == .multivariant) {
        for (p.body.multivariant.variants) |v| {
            for (v.leading) |extra| {
                if (playlistDirective(extra)) |value| return value;
            }
        }
    }
    return null;
}

fn playlistDirective(extra: Extra) ?[]const u8 {
    const text = switch (extra) {
        .comment => |c| c,
        else => return null,
    };
    if (!std.ascii.startsWithIgnoreCase(text, "PLAYLIST:")) return null;
    return text["PLAYLIST:".len..];
}

/// The state a tag builds up until a URI line arrives to claim it.
const Pending = struct {
    leading: std.ArrayList(Extra) = .empty,
    keys: std.ArrayList(Key) = .empty,
    dateranges: std.ArrayList(DateRange) = .empty,
    parts: std.ArrayList(Part) = .empty,
    duration: ?f64 = null,
    title: []const u8 = "",
    inf_attributes: []const Attribute = &.{},
    byterange: ?ByteRange = null,
    discontinuity: bool = false,
    map: ?Map = null,
    program_date_time: ?DateTime = null,
    gap: bool = false,
    bitrate: ?u64 = null,
    stream_inf: ?StreamInf = null,
    /// Whether any tag that wants a URI after it has been seen, so that one
    /// left dangling at the end of the file can be reported.
    expecting_uri: bool = false,
    /// Those tags, kept verbatim in case the URI never comes.
    ///
    /// Dropping them would lose more than the tags. A Media Segment tag is
    /// part of what tells the parser this is a Media Playlist, so a playlist
    /// ending in an unclaimed `#EXT-X-KEY` — or a Multivariant one ending in
    /// an `#EXT-X-STREAM-INF` whose URI line is missing — would come back as
    /// a `Kind.basic` playlist once written and read again. Discarded unread
    /// the moment a URI claims them.
    unclaimed: std.ArrayList(Extra) = .empty,

    /// Take everything gathered so far as an `Entry` for `uri`, leaving the
    /// state empty for the next one.
    fn takeEntry(pending: *Pending, uri: []const u8) Entry {
        const entry: Entry = .{
            .uri = uri,
            .duration = pending.duration,
            .title = pending.title,
            .inf_attributes = pending.inf_attributes,
            .byterange = pending.byterange,
            .discontinuity = pending.discontinuity,
            .keys = pending.keys.items,
            .map = pending.map,
            .program_date_time = pending.program_date_time,
            .dateranges = pending.dateranges.items,
            .gap = pending.gap,
            .bitrate = pending.bitrate,
            .parts = pending.parts.items,
            .leading = pending.leading.items,
        };
        pending.* = .{};
        return entry;
    }

    /// Take everything gathered so far as a `Variant`.
    fn takeVariant(pending: *Pending, uri: []const u8, iframe_only: bool) Variant {
        const variant: Variant = .{
            .stream_inf = pending.stream_inf orelse .{},
            .uri = uri,
            .iframe_only = iframe_only,
            .leading = pending.leading.items,
        };
        pending.* = .{};
        return variant;
    }
};

/// Everything the parser is building, so that the two passes and the
/// per-line work can share it without a dozen parameters.
const Builder = struct {
    playlist: *Playlist,
    reporter: *Reporter,
    options: ParseOptions,
    arena: Allocator,

    pending: Pending = .{},
    defines: std.ArrayList(Define) = .empty,
    trailing: std.ArrayList(Extra) = .empty,

    entries: std.ArrayList(Entry) = .empty,
    variants: std.ArrayList(Variant) = .empty,
    renditions: std.ArrayList(Rendition) = .empty,
    session_data: std.ArrayList(SessionData) = .empty,
    session_keys: std.ArrayList(Key) = .empty,
    preload_hints: std.ArrayList(PreloadHint) = .empty,
    rendition_reports: std.ArrayList(RenditionReport) = .empty,

    media: Media = .{},
    multivariant: Multivariant = .{},

    /// Note that a URI line is expected, keeping the tag that says so in
    /// case one never arrives. See `Pending.unclaimed`.
    ///
    /// Called only once a tag's value has been *read*. A tag whose value
    /// could not be read says nothing about a following segment, and goes to
    /// `keepVerbatim` instead — which is also what stops it being kept in
    /// two places and written out twice.
    fn expectUri(b: *Builder, tag: line.Tag) Allocator.Error!void {
        b.pending.expecting_uri = true;
        try b.pending.unclaimed.append(b.arena, .{ .tag = tag });
    }

    /// Keep a tag exactly as it was found, because its value could not be
    /// read.
    ///
    /// Dropping it instead would lose more than the tag. A Media Playlist
    /// tag is *what tells the parser it is reading a Media Playlist*, so a
    /// dropped `#EXT-X-TARGETDURATION:v` would make the rewritten playlist a
    /// `Kind.basic` one the next time it was read — the parse would be
    /// self-consistent and a different playlist. Keeping the line verbatim
    /// makes writing and reading again give back what went in, whatever was
    /// wrong with it.
    fn keepVerbatim(b: *Builder, tag: line.Tag) Allocator.Error!void {
        try b.pending.leading.append(b.arena, .{ .tag = tag });
    }

    // -- the small value readers ------------------------------------------
    //
    // Each of these reports what it could not read and gives back null, so
    // that the field keeps its default and the playlist still parses; the
    // caller then calls `keepVerbatim` so that nothing is lost on the way
    // out. A tag whose value is an attribute list does not come through
    // here: those have a `parse` of their own in `tags.zig`, and they always
    // produce a value.

    /// A tag whose value is a `decimal-integer`.
    fn integer(b: *Builder, tag_name: []const u8, value: ?[]const u8) ?u64 {
        const text = value orelse {
            b.reporter.invalid(.wrong_tag_arity, tag_name);
            return null;
        };
        return attribute.decimalInteger(std.mem.trim(u8, text, " \t")) catch {
            b.reporter.invalid(.invalid_tag_value, text);
            return null;
        };
    }

    /// `#EXT-X-TARGETDURATION`, which §4.3.3.1 says is a `decimal-integer`.
    ///
    /// Lenient about a playlist that writes `10.0`, because several encoders
    /// do and the value is a duration rounded to the second either way. The
    /// fraction is dropped rather than rounded up, which is what
    /// `@intFromFloat` does and is the safe direction: a target duration
    /// that is too small only makes a player reload sooner.
    fn targetDuration(b: *Builder, tag_name: []const u8, value: ?[]const u8) ?u64 {
        const text = value orelse {
            b.reporter.invalid(.wrong_tag_arity, tag_name);
            return null;
        };
        const trimmed = std.mem.trim(u8, text, " \t");
        if (attribute.decimalInteger(trimmed)) |n| return n else |_| {}

        const seconds = attribute.signedFloat(trimmed) catch {
            b.reporter.invalid(.invalid_tag_value, text);
            return null;
        };
        if (seconds < 0 or seconds >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) {
            b.reporter.invalid(.invalid_tag_value, text);
            return null;
        }
        b.reporter.warn(.invalid_tag_value, "#EXT-X-TARGETDURATION is not an integer");
        return @intFromFloat(seconds);
    }

    /// A tag whose value is a `<length>[@<offset>]`.
    fn byteRange(b: *Builder, tag_name: []const u8, value: ?[]const u8) ?ByteRange {
        const text = value orelse {
            b.reporter.invalid(.wrong_tag_arity, tag_name);
            return null;
        };
        return ByteRange.parse(std.mem.trim(u8, text, " \t")) catch {
            b.reporter.invalid(.invalid_tag_value, text);
            return null;
        };
    }

    /// A tag whose value is an ISO 8601 date and time.
    fn dateTime(b: *Builder, tag_name: []const u8, value: ?[]const u8) ?DateTime {
        const text = value orelse {
            b.reporter.invalid(.wrong_tag_arity, tag_name);
            return null;
        };
        return DateTime.parse(std.mem.trim(u8, text, " \t")) catch {
            b.reporter.invalid(.invalid_tag_value, text);
            return null;
        };
    }

    /// A tag that takes no value at all.
    ///
    /// A value on one of these is `.invalid` rather than a warning, because
    /// `write` drops whatever was after the colon: the tag still means what
    /// it means, and the text is gone. An *empty* value is not reported at
    /// all, since it only means the line ended in a colon.
    fn flag(b: *Builder, tag_name: []const u8, value: ?[]const u8) void {
        if (value) |text| {
            if (text.len != 0) b.reporter.invalid(.wrong_tag_arity, tag_name);
        }
    }
};

/// Read `source` into `self`.
fn fill(self: *Playlist, reporter: *Reporter, options: ParseOptions) ParseError!void {
    const playlist_kind = try classify(self.source, reporter, options);

    var builder: Builder = .{
        .playlist = self,
        .reporter = reporter,
        .options = options,
        .arena = self.arena.allocator(),
    };

    var scanner: line.Scanner = .init(self.source);
    // §4.3.1.1 says `#EXTM3U` must be the first line. Leading blank lines
    // are let through, because they are ignored by §4.1 and so are not
    // really lines; anything else before it makes it misplaced rather than
    // absent.
    var seen_content = false;
    while (scanner.next()) |current| {
        reporter.line = current.number;
        // A mark in front of a line's content is trimmed away by
        // `line.classify`, and this is the only place it can be reported.
        // The one at the start of the file is reported by `parse`.
        if (current.number != 1 and line.hadByteOrderMark(current.raw)) {
            reporter.invalid(.byte_order_mark, "");
        }
        switch (current.content) {
            .blank => try builder.pending.leading.append(builder.arena, .blank),
            .comment => |text| try builder.pending.leading.append(builder.arena, .{ .comment = text }),
            .uri => |uri| try uriLine(&builder, playlist_kind, uri),
            .tag => |tag| {
                const known = tags.fromText(tag.name);
                if (!seen_content and known != null and known.? == .extm3u) {
                    self.extm3u = true;
                    self.extm3u_attributes = try extm3uAttributes(builder.arena, tag, reporter);
                } else {
                    try tagLine(&builder, playlist_kind, tag);
                }
            },
        }
        if (current.content != .blank) seen_content = true;
    }

    if (!self.extm3u) {
        reporter.line = 0;
        reporter.warn(.missing_extm3u, "");
    }

    // Whatever the last URI did not claim.
    reporter.line = 0;
    if (builder.pending.expecting_uri) {
        // Tags with no URI after them describe a segment -- or a variant --
        // that is not there, so what they said is lost, which is what makes
        // this `.invalid` rather than a warning. The *lines* are kept all
        // the same, so that writing the playlist and reading it again gives
        // back the same thing; `Pending.unclaimed` says why that matters.
        //
        // `#EXT-X-PART` is the exception, and does not come through here: a
        // low-latency playlist ends with the parts of a segment that has not
        // been published yet, and those are not a mistake.
        reporter.invalid(.segment_without_uri, "");
        try builder.pending.leading.appendSlice(
            builder.arena,
            builder.pending.unclaimed.items,
        );
    }
    // The parts of a segment still being produced have no URI and are not a
    // mistake; they belong to the playlist rather than to an entry.
    builder.media.trailing_parts = builder.pending.parts.items;
    builder.trailing = builder.pending.leading;

    self.defines = builder.defines.items;
    self.trailing = builder.trailing.items;

    switch (playlist_kind) {
        .basic => self.body = .{ .basic = builder.entries.items },
        .media => {
            builder.media.entries = builder.entries.items;
            builder.media.preload_hints = builder.preload_hints.items;
            builder.media.rendition_reports = builder.rendition_reports.items;
            if (builder.media.target_duration == null) {
                reporter.invalid(.missing_target_duration, "");
            }
            self.body = .{ .media = builder.media };
        },
        .multivariant => {
            builder.multivariant.variants = builder.variants.items;
            builder.multivariant.renditions = builder.renditions.items;
            builder.multivariant.session_data = builder.session_data.items;
            builder.multivariant.session_keys = builder.session_keys.items;
            self.body = .{ .multivariant = builder.multivariant };
        },
    }

    if (self.duplicateVariable()) |duplicate| {
        reporter.invalid(.invalid_define, duplicate);
    }
    if (self.body == .media) checkSegments(self.body.media, reporter);
}

/// The two rules about a Media Playlist's segments that can only be checked
/// once all of them have been read.
fn checkSegments(media: Media, reporter: *Reporter) void {
    for (media.entries, 0..) |entry, i| {
        // §4.3.2.2: an `#EXT-X-BYTERANGE` with no offset carries on from the
        // previous sub-range, so there has to be one, and it has to be of
        // the same resource. The specification says a client must refuse a
        // playlist where it is not, which is why this is `.invalid`.
        if (entry.byterange) |range| {
            if (range.offset == null and !followsRangeOfSameResource(media.entries[0..i], entry.uri)) {
                reporter.line = 0;
                reporter.invalid(.byterange_without_offset, entry.uri);
            }
        }

        // §4.3.3.1: every segment's duration, rounded to the nearest
        // integer, must be at most the target duration. A warning rather
        // than an `.invalid`, since nothing was lost by reading it -- but
        // worth saying, because the specification's reason for the rule is
        // that longer segments stall playback.
        const target = media.target_duration orelse continue;
        const duration = entry.duration orelse continue;
        if (duration < 0) continue;
        const rounded = @round(duration);
        if (rounded > @as(f64, @floatFromInt(target))) {
            reporter.line = 0;
            reporter.warn(.duration_over_target, entry.uri);
        }
    }
}

/// Whether any of `earlier` was a sub-range of the resource at `uri`, which
/// is what an `#EXT-X-BYTERANGE` with no offset needs in front of it.
fn followsRangeOfSameResource(earlier: []const Entry, uri: []const u8) bool {
    var i = earlier.len;
    while (i > 0) {
        i -= 1;
        if (!std.mem.eql(u8, earlier[i].uri, uri)) continue;
        return earlier[i].byterange != null;
    }
    return false;
}

/// Decide which kind of playlist this is, before reading it properly.
///
/// A pass of its own because a tag near the end of the file — an
/// `#EXT-X-ENDLIST`, an `#EXT-X-I-FRAME-STREAM-INF` — settles the question
/// for lines that came before it.
fn classify(source: []const u8, reporter: *Reporter, options: ParseOptions) ParseError!Kind {
    var media_tags: u32 = 0;
    var multivariant_tags: u32 = 0;
    var lines: u32 = 0;

    var scanner: line.Scanner = .init(source);
    while (scanner.next()) |current| {
        lines += 1;
        if (lines > options.max_lines) return error.TooManyLines;
        const tag = switch (current.content) {
            .tag => |t| t,
            else => continue,
        };
        const tag_name = tags.fromText(tag.name) orelse continue;
        switch (tag_name.settlesKind() orelse continue) {
            .media_playlist => media_tags += 1,
            .multivariant => multivariant_tags += 1,
            // `settlesKind` returns only those two.
            .segment, .either => unreachable,
        }
    }

    if (media_tags != 0 and multivariant_tags != 0) {
        reporter.line = 0;
        reporter.invalid(.mixed_playlist_kinds, "");
        // Whichever there is more of. A tie goes to the Media Playlist,
        // since a stray `#EXT-X-MEDIA` in a list of segments is a likelier
        // mistake than the other way round.
        return if (multivariant_tags > media_tags) .multivariant else .media;
    }
    if (multivariant_tags != 0) return .multivariant;
    if (media_tags != 0) return .media;
    return .basic;
}

/// A URI line, which claims whatever tags came before it.
fn uriLine(b: *Builder, playlist_kind: Kind, uri: []const u8) ParseError!void {
    if (b.options.validate_uris and !resolve.valid(b.playlist.arena.child_allocator, uri)) {
        b.reporter.invalid(.invalid_tag_value, uri);
    }
    switch (playlist_kind) {
        .basic => try b.entries.append(b.arena, b.pending.takeEntry(uri)),
        .media => {
            if (b.pending.duration == null) b.reporter.warn(.uri_without_tag, uri);
            try b.entries.append(b.arena, b.pending.takeEntry(uri));
        },
        .multivariant => {
            if (b.pending.stream_inf == null) {
                // Nothing said what this URI is, so it is kept where it was
                // found rather than becoming a variant with no bandwidth.
                b.reporter.warn(.uri_without_tag, uri);
                try b.pending.leading.append(b.arena, .{ .uri = uri });
                return;
            }
            try b.variants.append(b.arena, b.pending.takeVariant(uri, false));
        },
    }
}

/// One tag.
fn tagLine(b: *Builder, playlist_kind: Kind, tag: line.Tag) ParseError!void {
    const tag_name = tags.fromText(tag.name) orelse {
        b.reporter.warn(.unknown_tag, tag.name);
        try b.pending.leading.append(b.arena, .{ .tag = tag });
        return;
    };

    // A tag from the other kind of playlist is kept rather than acted on:
    // acting on it would mean putting an `#EXT-X-MEDIA` in a Media Playlist,
    // which has nowhere to hold one.
    const scope = tag_name.scope();
    const wrong = switch (playlist_kind) {
        .basic => false,
        .media => scope == .multivariant,
        .multivariant => scope == .media_playlist or scope == .segment,
    };
    if (wrong) {
        b.reporter.warn(.tag_in_wrong_playlist, tag.name);
        try b.pending.leading.append(b.arena, .{ .tag = tag });
        return;
    }

    if (b.playlist.version) |version| {
        const needed = tag_name.minimumVersion();
        if (needed > version) {
            b.reporter.versionConflict(tag.name, needed, version);
        }
    }

    const value = tag.value;
    switch (tag_name) {
        .extm3u => {
            // Not the first line, since `fill` handles that case.
            b.reporter.warn(.misplaced_extm3u, "");
            b.playlist.extm3u = true;
            b.playlist.extm3u_attributes = try extm3uAttributes(b.arena, tag, b.reporter);
        },
        .ext_x_version => {
            if (b.integer(tag.name, value)) |version| {
                b.playlist.version = version;
            } else try b.keepVerbatim(tag);
        },
        .ext_x_independent_segments => {
            b.flag(tag.name, value);
            b.playlist.independent_segments = true;
        },
        .ext_x_start => b.playlist.start = try Start.parse(b.reporter, value orelse ""),
        .ext_x_define => try b.defines.append(
            b.arena,
            try Define.parse(b.reporter, value orelse ""),
        ),

        // -- media segment tags --
        .extinf => {
            try extinf(b, tag, value orelse "");
        },
        .ext_x_byterange => {
            if (b.byteRange(tag.name, value)) |range| {
                b.pending.byterange = range;
                try b.expectUri(tag);
            } else try b.keepVerbatim(tag);
        },
        .ext_x_discontinuity => {
            b.flag(tag.name, value);
            try b.expectUri(tag);
            b.pending.discontinuity = true;
        },
        .ext_x_key => {
            try b.expectUri(tag);
            try b.pending.keys.append(b.arena, try Key.parse(b.reporter, value orelse ""));
        },
        .ext_x_map => {
            try b.expectUri(tag);
            b.pending.map = try Map.parse(b.reporter, value orelse "");
        },
        .ext_x_program_date_time => {
            if (b.dateTime(tag.name, value)) |at| {
                b.pending.program_date_time = at;
                try b.expectUri(tag);
            } else try b.keepVerbatim(tag);
        },
        .ext_x_daterange => {
            try b.expectUri(tag);
            try b.pending.dateranges.append(b.arena, try DateRange.parse(b.reporter, value orelse ""));
        },
        .ext_x_gap => {
            b.flag(tag.name, value);
            try b.expectUri(tag);
            b.pending.gap = true;
        },
        .ext_x_bitrate => {
            if (b.integer(tag.name, value)) |bitrate| {
                b.pending.bitrate = bitrate;
                try b.expectUri(tag);
            } else try b.keepVerbatim(tag);
        },
        .ext_x_part => try b.pending.parts.append(
            b.arena,
            try Part.parse(b.reporter, value orelse ""),
        ),

        // -- media playlist tags --
        .ext_x_targetduration => {
            if (b.targetDuration(tag.name, value)) |target| {
                b.media.target_duration = target;
            } else try b.keepVerbatim(tag);
        },
        .ext_x_media_sequence => {
            if (b.integer(tag.name, value)) |sequence| {
                b.media.media_sequence = sequence;
            } else try b.keepVerbatim(tag);
        },
        .ext_x_discontinuity_sequence => {
            if (b.integer(tag.name, value)) |sequence| {
                b.media.discontinuity_sequence = sequence;
            } else try b.keepVerbatim(tag);
        },
        .ext_x_endlist => {
            b.flag(tag.name, value);
            b.media.endlist = true;
        },
        .ext_x_playlist_type => {
            const text = value orelse {
                b.reporter.invalid(.wrong_tag_arity, tag.name);
                return b.keepVerbatim(tag);
            };
            const parsed = tags.Enumerated(tags.PlaylistType).parse(text);
            if (parsed == .unknown) b.reporter.warn(.unknown_enumerated_value, text);
            b.media.playlist_type = parsed;
        },
        .ext_x_i_frames_only => {
            b.flag(tag.name, value);
            b.media.iframes_only = true;
        },
        .ext_x_part_inf => b.media.part_inf = try PartInf.parse(b.reporter, value orelse ""),
        .ext_x_server_control => {
            b.media.server_control = try ServerControl.parse(b.reporter, value orelse "");
        },
        .ext_x_skip => b.media.skip = try Skip.parse(b.reporter, value orelse ""),
        .ext_x_preload_hint => try b.preload_hints.append(
            b.arena,
            try PreloadHint.parse(b.reporter, value orelse ""),
        ),
        .ext_x_rendition_report => try b.rendition_reports.append(
            b.arena,
            try RenditionReport.parse(b.reporter, value orelse ""),
        ),

        // -- multivariant playlist tags --
        .ext_x_media => try b.renditions.append(
            b.arena,
            try Rendition.parse(b.reporter, value orelse ""),
        ),
        .ext_x_stream_inf => {
            const stream = try StreamInf.parse(b.reporter, value orelse "");
            stream.checkKind(b.reporter, false);
            b.pending.stream_inf = stream;
            try b.expectUri(tag);
        },
        .ext_x_i_frame_stream_inf => {
            const stream = try StreamInf.parse(b.reporter, value orelse "");
            stream.checkKind(b.reporter, true);
            // Its URI is an attribute, so the variant is complete already
            // and no URI line follows it.
            b.pending.stream_inf = stream;
            try b.variants.append(b.arena, b.pending.takeVariant(stream.uri orelse "", true));
        },
        .ext_x_session_data => try b.session_data.append(
            b.arena,
            try SessionData.parse(b.reporter, value orelse ""),
        ),
        .ext_x_session_key => try b.session_keys.append(
            b.arena,
            try Key.parse(b.reporter, value orelse ""),
        ),
        .ext_x_content_steering => {
            b.multivariant.content_steering = try ContentSteering.parse(b.reporter, value orelse "");
        },

        // -- extended M3U, recognised and carried through --
        .extgrp,
        .extalb,
        .extart,
        .extgenre,
        .extimg,
        .extbyt,
        .extbin,
        .extenc,
        .extvlcopt,
        => try b.pending.leading.append(b.arena, .{ .tag = tag }),
    }
}

/// `#EXTINF:<duration>[ <attributes>],[<title>]`.
///
/// Nothing is assigned unless the duration reads, because an `#EXTINF` whose
/// duration cannot be read is an `#EXTINF` that is not there: `write` emits
/// the tag only when there is a duration to put in it, so keeping the title
/// from a broken one would lose it on the way out.
fn extinf(b: *Builder, tag: line.Tag, value: []const u8) ParseError!void {
    // The comma that ends the duration is the first one *outside* any quoted
    // string, because an IPTV `group-title="Sport, News"` has commas of its
    // own and comes before it.
    const comma = unquotedComma(value);
    const head = if (comma) |at| value[0..at] else head: {
        // §4.3.2.1 makes the comma mandatory even with no title. Playlists
        // leave it off, and nothing is lost by reading one that does.
        b.reporter.warn(.invalid_tag_value, "#EXTINF with no comma");
        break :head value;
    };

    // The duration ends at the first space, after which come the attributes
    // an IPTV playlist writes. There is no such thing in RFC 8216.
    const space = std.mem.findAny(u8, head, " \t");
    const duration_text = std.mem.trim(u8, if (space) |at| head[0..at] else head, " \t");

    const duration = attribute.signedFloat(duration_text) catch {
        b.reporter.invalid(.invalid_tag_value, duration_text);
        // An `#EXTINF` with no readable duration says nothing about a
        // following segment, so it is kept as a line rather than as a tag.
        return b.keepVerbatim(tag);
    };
    if (b.pending.duration != null) b.reporter.warn(.duplicate_tag, "EXTINF");
    try b.expectUri(tag);

    b.pending.duration = duration;
    b.pending.title = if (comma) |at| value[at + 1 ..] else "";
    b.pending.inf_attributes = if (space) |at|
        try spaceAttributes(b.arena, head[at..], b.reporter)
    else
        &.{};
}

/// The index of the first comma not inside a quoted string.
fn unquotedComma(text: []const u8) ?usize {
    var quoted = false;
    for (text, 0..) |c, i| {
        switch (c) {
            '"' => quoted = !quoted,
            ',' => if (!quoted) return i,
            else => {},
        }
    }
    return null;
}

/// The attributes on an `#EXTM3U` line, from wherever the playlist put them.
///
/// `#EXTM3U x-tvg-url="..."` is the shape that occurs, and `line.classify`
/// leaves those in `attributes`. `#EXTM3U:x-tvg-url="..."` is not a shape
/// anybody writes and costs one line to read anyway.
fn extm3uAttributes(
    arena: Allocator,
    tag: line.Tag,
    reporter: *Reporter,
) Allocator.Error![]const Attribute {
    if (tag.attributes.len != 0) return spaceAttributes(arena, tag.attributes, reporter);
    return spaceAttributes(arena, tag.value orelse "", reporter);
}

/// Collect a space-separated attribute list into the arena.
///
/// Two things are dropped and reported rather than kept, both because
/// keeping them would produce a playlist that cannot be written back:
///
/// * An attribute whose name or unquoted value holds a `"` or a `,`. The
///   `#EXTINF` line is split at its first comma *outside any quoted string*,
///   so an unbalanced quote moves that split: `group-title=X"A, B"` written
///   back out and read again puts `B",Channel` inside the quotes and loses
///   the title. The values that occur in practice are quoted, and a quoted
///   one can hold neither character.
/// * Whatever followed an attribute the iterator could not read at all.
///   That part is gone either way — `SpaceIterator.stopped_early` says so —
///   and what came before it is still reproducible, so it is kept.
fn spaceAttributes(
    arena: Allocator,
    value: []const u8,
    reporter: *Reporter,
) Allocator.Error![]const Attribute {
    var list: std.ArrayList(Attribute) = .empty;
    var it: attribute.SpaceIterator = .init(value);
    while (it.next()) |a| {
        if (!writableSpaceAttribute(a)) {
            reporter.invalid(.invalid_attribute_value, a.name);
            continue;
        }
        try list.append(arena, a);
    }
    if (it.stopped_early) reporter.invalid(.invalid_attribute_list, value);
    return list.items;
}

/// Whether a space-separated attribute can be written back out and read
/// again as itself. See `spaceAttributes` for why it might not be.
fn writableSpaceAttribute(a: Attribute) bool {
    if (std.mem.findAny(u8, a.name, "\",") != null) return false;
    // A quoted value is safe by construction: the quotes could not have
    // contained a quote, a carriage return or a line feed in the first
    // place, and the comma inside them is what they are for.
    if (a.isQuoted()) return true;
    return std.mem.findAny(u8, a.raw, "\",") == null;
}

// -- writing ---------------------------------------------------------------

/// Write the playlist.
///
/// The result parses to a playlist equal to this one; see the note at the top
/// of this file about what that does and does not mean byte for byte.
pub fn write(p: *const Playlist, w: *Io.Writer) Io.Writer.Error!void {
    if (p.byte_order_mark) try w.writeAll(line.byte_order_mark);
    if (p.extm3u) {
        try w.writeAll("#EXTM3U");
        for (p.extm3u_attributes) |a| try w.print(" {s}={s}", .{ a.name, a.raw });
        try w.writeByte('\n');
    }
    if (p.version) |version| try w.print("#EXT-X-VERSION:{d}\n", .{version});
    if (p.independent_segments) try w.writeAll("#EXT-X-INDEPENDENT-SEGMENTS\n");
    if (p.start) |start| {
        try w.writeAll("#EXT-X-START:");
        try start.write(w);
        try w.writeByte('\n');
    }
    for (p.defines) |define| {
        try w.writeAll("#EXT-X-DEFINE:");
        try define.write(w);
        try w.writeByte('\n');
    }

    switch (p.body) {
        .basic => |list| for (list) |entry| try entry.write(w),
        .media => |m| try writeMedia(m, w),
        .multivariant => |m| try writeMultivariant(m, w),
    }

    for (p.trailing) |extra| try extra.write(w);
}

fn writeMedia(m: Media, w: *Io.Writer) Io.Writer.Error!void {
    if (m.target_duration) |target| try w.print("#EXT-X-TARGETDURATION:{d}\n", .{target});
    // Written only when it is not the default, since `#EXT-X-MEDIA-SEQUENCE:0`
    // and no tag at all mean the same thing to §4.3.3.2.
    if (m.media_sequence != 0) try w.print("#EXT-X-MEDIA-SEQUENCE:{d}\n", .{m.media_sequence});
    if (m.discontinuity_sequence != 0) {
        try w.print("#EXT-X-DISCONTINUITY-SEQUENCE:{d}\n", .{m.discontinuity_sequence});
    }
    if (m.playlist_type) |playlist_type| try w.print("#EXT-X-PLAYLIST-TYPE:{f}\n", .{playlist_type});
    if (m.iframes_only) try w.writeAll("#EXT-X-I-FRAMES-ONLY\n");
    if (m.server_control) |control| {
        try w.writeAll("#EXT-X-SERVER-CONTROL:");
        try control.write(w);
        try w.writeByte('\n');
    }
    if (m.part_inf) |part_inf| {
        try w.writeAll("#EXT-X-PART-INF:");
        try part_inf.write(w);
        try w.writeByte('\n');
    }
    if (m.skip) |skip| {
        try w.writeAll("#EXT-X-SKIP:");
        try skip.write(w);
        try w.writeByte('\n');
    }

    for (m.entries) |entry| try entry.write(w);

    for (m.trailing_parts) |part| {
        try w.writeAll("#EXT-X-PART:");
        try part.write(w);
        try w.writeByte('\n');
    }
    for (m.preload_hints) |hint| {
        try w.writeAll("#EXT-X-PRELOAD-HINT:");
        try hint.write(w);
        try w.writeByte('\n');
    }
    for (m.rendition_reports) |report| {
        try w.writeAll("#EXT-X-RENDITION-REPORT:");
        try report.write(w);
        try w.writeByte('\n');
    }
    if (m.endlist) try w.writeAll("#EXT-X-ENDLIST\n");
}

fn writeMultivariant(m: Multivariant, w: *Io.Writer) Io.Writer.Error!void {
    if (m.content_steering) |steering| {
        try w.writeAll("#EXT-X-CONTENT-STEERING:");
        try steering.write(w);
        try w.writeByte('\n');
    }
    for (m.session_keys) |key| {
        try w.writeAll("#EXT-X-SESSION-KEY:");
        try key.write(w);
        try w.writeByte('\n');
    }
    for (m.session_data) |data| {
        try w.writeAll("#EXT-X-SESSION-DATA:");
        try data.write(w);
        try w.writeByte('\n');
    }
    for (m.renditions) |rendition| {
        try w.writeAll("#EXT-X-MEDIA:");
        try rendition.write(w);
        try w.writeByte('\n');
    }
    for (m.variants) |variant| try variant.write(w);
}

/// Write the playlist into a buffer the caller frees.
pub fn toTextAlloc(p: *const Playlist, gpa: Allocator) Allocator.Error![]u8 {
    var w: Io.Writer.Allocating = .init(gpa);
    errdefer w.deinit();
    p.write(&w.writer) catch return error.OutOfMemory;
    return w.toOwnedSlice();
}

/// Reached by `{f}`, so a playlist can be printed or logged directly.
pub fn format(p: *const Playlist, w: *Io.Writer) Io.Writer.Error!void {
    try p.write(w);
}

// -- comparison ------------------------------------------------------------

/// Whether two playlists say the same thing.
///
/// Deep: every tag, every attribute, every comment and blank line, in order.
/// It ignores the arena and the `source` bytes, since two playlists that say
/// the same thing need not have been written the same way — which is exactly
/// the question this answers, and why `write` normalising the notation does
/// not make two playlists unequal.
///
/// Two uses. A player reloading a live Media Playlist can ask whether
/// anything actually changed; and the test suite asserts that parsing,
/// writing and parsing again gives an equal playlist, which is the property
/// that keeps the parser and the writer from drifting apart.
///
/// It reflects over the fields rather than naming them, so a field added to
/// any of these types is compared without this having to be updated.
pub fn eql(a: *const Playlist, b: *const Playlist) bool {
    inline for (@typeInfo(Playlist).@"struct".fields) |field| {
        const skip = comptime std.mem.eql(u8, field.name, "arena") or
            std.mem.eql(u8, field.name, "source");
        if (!skip and !deepEql(field.type, @field(a, field.name), @field(b, field.name))) {
            return false;
        }
    }
    return true;
}

/// Structural equality over the types a playlist is made of: numbers, enums,
/// strings, slices, optionals, structs and tagged unions.
///
/// `f64` is compared with `==`, which is exact and is what is wanted here.
/// It is safe because the only floats in a playlist came from `signedFloat`,
/// which refuses `nan` and `inf`, and are written back by `{d}` as the
/// shortest decimal that reads as the same `f64`.
fn deepEql(comptime T: type, a: T, b: T) bool {
    return switch (@typeInfo(T)) {
        .void => true,
        .bool, .int, .float, .@"enum" => a == b,
        .optional => |info| if (a) |x| (if (b) |y| deepEql(info.child, x, y) else false) else b == null,
        .pointer => |info| switch (info.size) {
            .slice => blk: {
                if (a.len != b.len) break :blk false;
                if (info.child == u8) break :blk std.mem.eql(u8, a, b);
                for (a, b) |x, y| {
                    if (!deepEql(info.child, x, y)) break :blk false;
                }
                break :blk true;
            },
            else => @compileError("no deep comparison for " ++ @typeName(T)),
        },
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| {
                if (!deepEql(field.type, @field(a, field.name), @field(b, field.name))) {
                    break :blk false;
                }
            }
            break :blk true;
        },
        .@"union" => |info| blk: {
            if (info.tag_type == null) @compileError("no deep comparison for " ++ @typeName(T));
            const Tag = std.meta.Tag(T);
            const tag = std.meta.activeTag(a);
            if (tag != std.meta.activeTag(b)) break :blk false;
            inline for (info.fields) |field| {
                if (tag == @field(Tag, field.name)) {
                    break :blk deepEql(
                        field.type,
                        @field(a, field.name),
                        @field(b, field.name),
                    );
                }
            }
            break :blk true;
        },
        else => @compileError("no deep comparison for " ++ @typeName(T)),
    };
}

// -- tests -----------------------------------------------------------------

const testing = std.testing;

test {
    // The submodules' own tests, so that `zig build test` on the module runs
    // everything rather than only what this file names.
    testing.refAllDecls(@This());
}
