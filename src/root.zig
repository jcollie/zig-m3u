// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! M3U and M3U8: reading them, and writing them back.
//!
//! One file format with three layers of history in it. At the bottom is the
//! plain `.m3u` — a list of file names, one per line — which Fraunhofer's
//! Winamp shipped in 1996 and which needs no specification. On top of that
//! came the extended M3U, adding `#EXTM3U` and `#EXTINF` and a handful of
//! `#EXT` directives, still with no specification and still what most `.m3u`
//! files and every IPTV channel list are. On top of *that* is HTTP Live
//! Streaming, which took the same syntax, wrote it down as
//! [RFC 8216](https://www.rfc-editor.org/rfc/rfc8216), added forty tags and
//! called the result `.m3u8`.
//!
//! This library reads all three, and the tags added to HLS after RFC 8216
//! was published — low-latency parts, delta updates, content steering,
//! variable substitution.
//!
//! ```zig
//! const m3u = @import("m3u");
//!
//! var playlist = try m3u.Playlist.parse(gpa, bytes, .{});
//! defer playlist.deinit();
//!
//! switch (playlist.body) {
//!     .multivariant => |mv| {
//!         const start = mv.lowestBandwidth().?;
//!         std.debug.print("start at {d} bps: {s}\n", .{
//!             start.stream_inf.bandwidth,
//!             start.uri,
//!         });
//!     },
//!     .media => |media| {
//!         std.debug.print("{d} segments, {d:.1}s\n", .{
//!             media.entries.len,
//!             media.totalDuration(),
//!         });
//!     },
//!     .basic => |entries| {
//!         for (entries) |entry| std.debug.print("{s}\n", .{entry.uri});
//!     },
//! }
//! ```
//!
//! # Where to start
//!
//! * `Playlist` is the whole of the reading and writing API: `parse`,
//!   `write`, and the three shapes a playlist's `body` can take.
//! * `Diagnostics` is how to find out what the parser had to tolerate,
//!   which for a real playlist is usually something.
//! * `resolve` turns the relative URIs a playlist is made of into ones that
//!   can be fetched.
//! * `tags` has a type per tag, if you want to build a playlist rather than
//!   read one.
//! * `attribute`, `line` and `time` are the three grammars underneath:
//!   RFC 8216 §4.2's attribute lists, §4.1's line syntax, and the ISO 8601
//!   dates that `#EXT-X-PROGRAM-DATE-TIME` carries.
//!
//! # It is lenient, and it says so
//!
//! Almost no playlist in the world is strictly conformant. They arrive with
//! byte order marks, missing `#EXTM3U` lines, unquoted `URI` attributes,
//! spaces after commas, attributes nobody has heard of and enumerated values
//! that postdate whatever wrote the parser. Refusing them would make this
//! library useless; accepting them quietly would make it untrustworthy. So
//! it accepts them and writes down every one, and
//! `Playlist.ParseOptions.strict` turns the ones that lost information into
//! a returned error for a caller who would rather know.
//!
//! # A playlist survives being rewritten
//!
//! Parse, write and parse again, and the two playlists are deeply equal.
//! That is a property the test suite asserts on every playlist in
//! `tests/playlists` and on fuzzer output besides, and it is what makes this
//! library safe to put in a tool that edits playlists: a tag it has never
//! heard of comes out the other side intact. It is not a promise about
//! *bytes* — `Playlist` says exactly what `write` normalises.

const std = @import("std");

pub const Playlist = @import("Playlist.zig");
pub const Diagnostics = @import("Diagnostics.zig");

pub const attribute = @import("attribute.zig");
pub const line = @import("line.zig");
pub const resolve = @import("resolve.zig");
pub const tags = @import("tags.zig");
pub const time = @import("time.zig");

/// Read a playlist. The short spelling of `Playlist.parse`.
pub const parse = Playlist.parse;

/// The media type RFC 8216 §4 registers for a playlist, and the one a server
/// must send for a player to accept it.
pub const content_type = "application/vnd.apple.mpegurl";

/// The media type the extended M3U used before HLS existed, still sent by
/// plenty of servers and still what a `.m3u` of local files is.
pub const legacy_content_type = "audio/x-mpegurl";

/// The extension a playlist conventionally has. RFC 8216 §4 says a UTF-8
/// playlist should be `.m3u8` and that `.m3u` implies the older,
/// non-UTF-8-guaranteed encoding — a distinction this library does not act
/// on, since it reads bytes either way.
pub const extension = ".m3u8";

/// Whether `path` ends in one of the two playlist extensions, ignoring case.
pub fn hasPlaylistExtension(path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, ".m3u8") or
        std.ascii.endsWithIgnoreCase(path, ".m3u");
}

test {
    std.testing.refAllDecls(@This());
}

test "the extensions a playlist has" {
    try std.testing.expect(hasPlaylistExtension("index.m3u8"));
    try std.testing.expect(hasPlaylistExtension("playlist.M3U"));
    try std.testing.expect(hasPlaylistExtension("a/b/c.m3u"));
    try std.testing.expect(!hasPlaylistExtension("index.mpd"));
    try std.testing.expect(!hasPlaylistExtension("m3u8"));
    try std.testing.expect(!hasPlaylistExtension(""));
}
