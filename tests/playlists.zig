// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The playlists in `tests/playlists`, and what this library must do with
//! them.
//!
//! Two halves. The first is one property applied to every file in that
//! directory, whatever it is — including the ones that are deliberately
//! malformed:
//!
//! > Parse it, write it back out, parse that, and the two playlists are
//! > deeply equal. Write the second one out too, and the bytes are identical
//! > to the first output.
//!
//! That is what keeps the parser and the writer from drifting apart, and it
//! is a much better test than comparing against expected output, because a
//! new tag is covered by it the moment a playlist using the tag is dropped
//! into the directory. The second half of the property — that the *second*
//! write is byte-identical to the first — is what says the normalising
//! `write` does is a fixed point rather than something that keeps changing
//! the file every time a tool touches it.
//!
//! The second half of this file is a test per playlist, asserting what is
//! actually in it. Those are the ones that would catch a parser that read
//! every tag into the wrong field and round-tripped it perfectly.
//!
//! The fixtures whose names begin `rfc8216-` are the example playlists from
//! RFC 8216 §8, copied out of the RFC with nothing changed but the three
//! spaces of indentation its typesetting adds and, in §8.6 to §8.8, the `\`
//! line continuations it uses to fit a tag into 72 columns.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const m3u = @import("m3u");
const Playlist = m3u.Playlist;

/// The directory the fixtures are in, from `build.zig`. A test binary is run
/// from wherever the build runner happens to be, so the path cannot be
/// relative.
const dir_path = @import("playlists").dir;

/// No fixture is anywhere near this big; it is here so that a mistake in the
/// path cannot turn into an unbounded read.
const max_bytes: Io.Limit = .limited(1 << 20);

/// Read one fixture.
fn read(gpa: Allocator, name: []const u8) ![]u8 {
    const io = testing.io;
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    return dir.readFileAlloc(io, name, gpa, max_bytes);
}

/// Every fixture's name, in the order the filesystem gives them.
fn fixtureNames(gpa: Allocator, out: *std.ArrayList([]const u8)) !void {
    const io = testing.io;
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!m3u.hasPlaylistExtension(entry.name)) continue;
        try out.append(gpa, try gpa.dupe(u8, entry.name));
    }
}

test "every fixture survives being written and read again" {
    const gpa = testing.allocator;

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |name| gpa.free(name);
        names.deinit(gpa);
    }
    try fixtureNames(gpa, &names);
    // If the directory could not be found, everything below would pass by
    // testing nothing at all.
    try testing.expect(names.items.len >= 20);

    for (names.items) |name| {
        const bytes = try read(gpa, name);
        defer gpa.free(bytes);

        var first = Playlist.parse(gpa, bytes, .{}) catch |err| {
            std.debug.print("{s}: {t}\n", .{ name, err });
            return err;
        };
        defer first.deinit();

        const written = try first.toTextAlloc(gpa);
        defer gpa.free(written);

        var second = try Playlist.parse(gpa, written, .{});
        defer second.deinit();

        if (!first.eql(&second)) {
            std.debug.print(
                "{s}: writing and reading again changed it\n--- written ---\n{s}\n--- again ---\n{f}\n",
                .{ name, written, &second },
            );
            return error.RoundTripChangedThePlaylist;
        }

        // And writing is a fixed point, so a tool that opens a playlist and
        // saves it twice does not produce two different files.
        const again = try second.toTextAlloc(gpa);
        defer gpa.free(again);
        try testing.expectEqualStrings(written, again);
    }
}

test "every fixture parses without needing an allocation that could fail" {
    // `checkAllAllocationFailures` runs the body once per allocation the
    // parse makes, failing that one. Nothing may leak and nothing may crash
    // on any of them, which is the property an arena makes easy to get right
    // and easy to get subtly wrong -- an `errdefer` in the wrong place frees
    // the arena twice.
    const gpa = testing.allocator;

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |name| gpa.free(name);
        names.deinit(gpa);
    }
    try fixtureNames(gpa, &names);

    for (names.items) |name| {
        const bytes = try read(gpa, name);
        defer gpa.free(bytes);
        try testing.checkAllAllocationFailures(gpa, parseAndWrite, .{bytes});
    }
}

fn parseAndWrite(gpa: Allocator, bytes: []const u8) !void {
    var playlist = try Playlist.parse(gpa, bytes, .{});
    defer playlist.deinit();
    const written = try playlist.toTextAlloc(gpa);
    gpa.free(written);
}

/// Parse one fixture, for the tests below. The caller deinits.
fn parseFixture(name: []const u8, diagnostics: ?*m3u.Diagnostics) !Playlist {
    const gpa = testing.allocator;
    const bytes = try read(gpa, name);
    defer gpa.free(bytes);
    return Playlist.parse(gpa, bytes, .{ .diagnostics = diagnostics });
}

// -- the RFC's own examples ------------------------------------------------

test "RFC 8216 §8.1, a simple Media Playlist" {
    var playlist = try parseFixture("rfc8216-8.1-simple-media.m3u8", null);
    defer playlist.deinit();

    try testing.expectEqual(Playlist.Kind.media, playlist.kind());
    try testing.expect(playlist.extm3u);
    try testing.expectEqual(@as(?u64, 3), playlist.version);

    const media = playlist.body.media;
    try testing.expectEqual(@as(?u64, 10), media.target_duration);
    try testing.expect(media.endlist);
    try testing.expectEqual(@as(u64, 0), media.media_sequence);
    try testing.expectEqual(@as(usize, 3), media.entries.len);

    try testing.expectEqual(@as(f64, 9.009), media.entries[0].duration.?);
    try testing.expectEqualStrings("http://media.example.com/first.ts", media.entries[0].uri);
    // `#EXTINF:9.009,` has a comma and nothing after it, so the title is
    // empty rather than absent -- a distinction this library deliberately
    // does not make.
    try testing.expectEqualStrings("", media.entries[0].title);
    try testing.expectEqual(@as(f64, 3.003), media.entries[2].duration.?);
    try testing.expectEqual(@as(f64, 21.021), media.totalDuration());

    // Nothing is encrypted, so there is no key in effect anywhere.
    try testing.expectEqual(@as(usize, 0), media.keysFor(0).len);
    try testing.expect(!media.encrypted(2));
}

test "RFC 8216 §8.2, a live Media Playlist" {
    var diagnostics: m3u.Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();
    var playlist = try parseFixture("rfc8216-8.2-live-media.m3u8", &diagnostics);
    defer playlist.deinit();

    const media = playlist.body.media;
    try testing.expectEqual(@as(u64, 2680), media.media_sequence);
    // No `#EXT-X-ENDLIST`, which is what makes it live.
    try testing.expect(!media.endlist);
    try testing.expectEqual(@as(usize, 3), media.entries.len);
    // The sequence numbers count from `#EXT-X-MEDIA-SEQUENCE`.
    try testing.expectEqual(@as(u64, 2680), media.sequenceNumber(0));
    try testing.expectEqual(@as(u64, 2682), media.sequenceNumber(2));
    // The blank line between the header and the first segment is kept.
    try testing.expectEqual(@as(usize, 1), media.entries[0].leading.len);
    try testing.expectEqual(Playlist.Extra.blank, media.entries[0].leading[0]);
    // And the whole thing is conformant.
    try testing.expectEqual(@as(usize, 0), diagnostics.count());
}

test "RFC 8216 §8.3, encrypted segments with a key that changes" {
    var playlist = try parseFixture("rfc8216-8.3-encrypted.m3u8", null);
    defer playlist.deinit();

    const media = playlist.body.media;
    try testing.expectEqual(@as(usize, 4), media.entries.len);

    // The two `#EXT-X-KEY` tags are attached to the segments they were
    // written before, not to every segment they apply to.
    try testing.expectEqual(@as(usize, 1), media.entries[0].keys.len);
    try testing.expectEqual(@as(usize, 0), media.entries[1].keys.len);
    try testing.expectEqual(@as(usize, 1), media.entries[3].keys.len);

    // `keysFor` is what does the walk: segments 0 to 2 are under the first
    // key and segment 3 is under the second.
    try testing.expectEqualStrings(
        "https://priv.example.com/key.php?r=52",
        media.keysFor(0)[0].uri.?,
    );
    try testing.expectEqualStrings(
        "https://priv.example.com/key.php?r=52",
        media.keysFor(2)[0].uri.?,
    );
    try testing.expectEqualStrings(
        "https://priv.example.com/key.php?r=53",
        media.keysFor(3)[0].uri.?,
    );
    try testing.expect(media.keysFor(0)[0].method.is(.aes_128));
    try testing.expect(media.encrypted(0));
    try testing.expect(media.encrypted(3));
    // No `KEYFORMAT`, so §4.3.2.4's default applies.
    try testing.expectEqualStrings("identity", media.keysFor(0)[0].effectiveKeyFormat());
}

test "RFC 8216 §8.4, a Master Playlist" {
    var diagnostics: m3u.Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();
    var playlist = try parseFixture("rfc8216-8.4-master.m3u8", &diagnostics);
    defer playlist.deinit();

    try testing.expectEqual(Playlist.Kind.multivariant, playlist.kind());
    const mv = playlist.body.multivariant;
    try testing.expectEqual(@as(usize, 4), mv.variants.len);
    try testing.expectEqual(@as(u64, 1280000), mv.variants[0].stream_inf.bandwidth);
    try testing.expectEqual(@as(?u64, 1000000), mv.variants[0].stream_inf.average_bandwidth);
    try testing.expectEqualStrings("http://example.com/low.m3u8", mv.variants[0].uri);
    try testing.expectEqualStrings("mp4a.40.5", mv.variants[3].stream_inf.codecs.?);

    // §6.3.1 says a player starts at the lowest bandwidth unless it knows
    // better; the audio-only variant is that.
    try testing.expectEqual(@as(u64, 65000), mv.lowestBandwidth().?.stream_inf.bandwidth);
    try testing.expectEqual(@as(u64, 7680000), mv.highestBandwidth().?.stream_inf.bandwidth);

    // There is no `#EXT-X-VERSION` in this example, which means version 1.
    try testing.expectEqual(@as(?u64, null), playlist.version);
    try testing.expectEqual(@as(usize, 0), diagnostics.count());
}

test "RFC 8216 §8.5, I-frame variants among ordinary ones" {
    var playlist = try parseFixture("rfc8216-8.5-master-iframes.m3u8", null);
    defer playlist.deinit();

    const mv = playlist.body.multivariant;
    // Four ordinary and three I-frame variants, kept in one list so that
    // their order relative to each other survives.
    try testing.expectEqual(@as(usize, 7), mv.variants.len);
    try testing.expect(!mv.variants[0].iframe_only);
    try testing.expect(mv.variants[1].iframe_only);

    // An I-frame variant's address comes from its `URI` attribute rather
    // than from the line after it.
    try testing.expectEqualStrings("low/iframe.m3u8", mv.variants[1].uri);
    try testing.expectEqualStrings("low/iframe.m3u8", mv.variants[1].stream_inf.uri.?);
    try testing.expectEqual(@as(u64, 86000), mv.variants[1].stream_inf.bandwidth);

    // ...and the bandwidth extremes skip them, since a player does not
    // choose an I-frame playlist to play.
    try testing.expectEqual(@as(u64, 65000), mv.lowestBandwidth().?.stream_inf.bandwidth);
    try testing.expect(!mv.lowestBandwidth().?.iframe_only);
}

test "RFC 8216 §8.6, alternative audio renditions" {
    var diagnostics: m3u.Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();
    var playlist = try parseFixture("rfc8216-8.6-alternative-audio.m3u8", &diagnostics);
    defer playlist.deinit();

    const mv = playlist.body.multivariant;
    try testing.expectEqual(@as(usize, 3), mv.renditions.len);
    try testing.expectEqual(@as(usize, 4), mv.variants.len);

    try testing.expect(mv.renditions[0].type.is(.audio));
    try testing.expectEqualStrings("English", mv.renditions[0].name);
    try testing.expectEqualStrings("en", mv.renditions[0].language.?);
    try testing.expect(mv.renditions[0].default);
    try testing.expect(mv.renditions[0].autoselect);
    // The commentary track is neither default nor autoselected, which is
    // what makes it a commentary track.
    try testing.expect(!mv.renditions[2].default);
    try testing.expect(!mv.renditions[2].autoselect);

    // Every rendition is in one group, which every variant points at.
    var group = mv.groupIterator("aac");
    var count: usize = 0;
    while (group.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqualStrings("aac", mv.variants[0].stream_inf.audio.?);

    try testing.expectEqual(@as(usize, 0), diagnostics.count());
}

test "RFC 8216 §8.7, renditions interleaved with the variants that use them" {
    var playlist = try parseFixture("rfc8216-8.7-alternative-video.m3u8", null);
    defer playlist.deinit();

    const mv = playlist.body.multivariant;
    // Nine renditions in three groups of three, and three variants.
    try testing.expectEqual(@as(usize, 9), mv.renditions.len);
    try testing.expectEqual(@as(usize, 3), mv.variants.len);

    for ([_][]const u8{ "low", "mid", "hi" }) |group_id| {
        var group = mv.groupIterator(group_id);
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(testing.allocator);
        while (group.next()) |rendition| try names.append(testing.allocator, rendition.name);
        try testing.expectEqual(@as(usize, 3), names.items.len);
        try testing.expectEqualStrings("Main", names.items[0]);
        try testing.expectEqualStrings("Centerfield", names.items[1]);
        try testing.expectEqualStrings("Dugout", names.items[2]);
    }
    try testing.expectEqualStrings("hi", mv.variants[2].stream_inf.video.?);
    // No `AUDIO` attribute anywhere, which the RFC's own commentary on this
    // example points out means every video rendition has to carry the audio.
    try testing.expectEqual(@as(?[]const u8, null), mv.variants[0].stream_inf.audio);
}

test "RFC 8216 §8.8, session data" {
    var diagnostics: m3u.Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();
    var playlist = try parseFixture("rfc8216-8.8-session-data.m3u8", &diagnostics);
    defer playlist.deinit();

    const mv = playlist.body.multivariant;
    try testing.expectEqual(@as(usize, 3), mv.session_data.len);
    try testing.expectEqual(@as(usize, 0), mv.variants.len);

    // The first carries a URI, the other two carry values in two languages.
    try testing.expectEqualStrings("com.example.lyrics", mv.session_data[0].data_id);
    try testing.expectEqualStrings("lyrics.json", mv.session_data[0].uri.?);
    try testing.expectEqual(@as(?[]const u8, null), mv.session_data[0].value);

    try testing.expectEqualStrings("This is an example", mv.session_data[1].value.?);
    try testing.expectEqualStrings("en", mv.session_data[1].language.?);
    try testing.expectEqualStrings("Este es un ejemplo", mv.session_data[2].value.?);
    try testing.expectEqualStrings("es", mv.session_data[2].language.?);

    // No `#EXTM3U`, since the RFC shows only the tags in question -- which
    // this library reports and reads anyway.
    try testing.expect(playlist.extm3u);
    try testing.expectEqual(@as(usize, 0), diagnostics.invalidCount());
}

test "RFC 8216 §8.10, SCTE-35 date ranges" {
    var playlist = try parseFixture("rfc8216-8.10-daterange-scte35.m3u8", null);
    defer playlist.deinit();

    const media = playlist.body.media;
    try testing.expectEqual(@as(usize, 3), media.entries.len);

    const out = media.entries[0].dateranges[0];
    try testing.expectEqualStrings("splice-6FFFFFF0", out.id);
    try testing.expectEqual(@as(f64, 59.993), out.planned_duration.?);
    try testing.expectEqual(@as(?f64, null), out.duration);
    try testing.expect(std.mem.startsWith(u8, out.scte35_out.?, "0xFC002F"));
    // The date is kept as written, and the instant is derivable from it.
    try testing.expectEqual(@as(i32, 2014), out.start_date.?.year);
    try testing.expectEqual(@as(u8, 11), out.start_date.?.hour);
    try testing.expectEqual(
        @as(i64, 1394018100),
        try out.start_date.?.toUnixSeconds(),
    );

    // The second tag updates the same range with an "in" command, and has
    // the duration the first only planned.
    const in = media.entries[2].dateranges[0];
    try testing.expectEqualStrings("splice-6FFFFFF0", in.id);
    try testing.expectEqual(@as(f64, 59.993), in.duration.?);
    try testing.expect(in.scte35_in != null);
    try testing.expectEqual(@as(?[]const u8, null), in.scte35_out);
}

// -- the plain and extended M3U that predate all of this -------------------

test "a plain M3U is a list of paths and nothing else" {
    var diagnostics: m3u.Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();
    var playlist = try parseFixture("basic.m3u", &diagnostics);
    defer playlist.deinit();

    try testing.expectEqual(Playlist.Kind.basic, playlist.kind());
    try testing.expect(!playlist.extm3u);
    try testing.expect(diagnostics.has(.missing_extm3u));

    const list = playlist.body.basic;
    try testing.expectEqual(@as(usize, 5), list.len);
    try testing.expectEqualStrings("track01.mp3", list[0].uri);
    // A path with a space in it is a path, not two.
    try testing.expectEqualStrings("../other album/track01.flac", list[2].uri);
    // No `#EXTINF` anywhere, so no durations.
    for (list) |entry| try testing.expectEqual(@as(?f64, null), entry.duration);
}

test "an extended M3U's directives are carried through and can be read back" {
    var playlist = try parseFixture("extended.m3u", null);
    defer playlist.deinit();

    // `#EXTINF` alone does not make this a Media Playlist, which is the
    // whole reason `Kind.basic` exists.
    try testing.expectEqual(Playlist.Kind.basic, playlist.kind());
    try testing.expect(playlist.extm3u);

    // `#PLAYLIST` does not begin `#EXT`, so it is a comment that has to be
    // looked for among the comments.
    try testing.expectEqualStrings("Songs for a long drive", playlist.title().?);

    const list = playlist.body.basic;
    try testing.expectEqual(@as(usize, 4), list.len);
    try testing.expectEqual(@as(f64, 553), list[0].duration.?);
    try testing.expectEqualStrings("Miles Davis - So What", list[0].title);

    // `#EXTALB` and `#EXTART` came before the first entry, so they are among
    // its leading lines and `tagValue` finds them there.
    try testing.expectEqualStrings("Kind of Blue", list[0].tagValue("EXTALB").?);
    try testing.expectEqualStrings("Miles Davis", list[0].tagValue("extart").?);
    try testing.expectEqual(@as(?[]const u8, null), list[0].tagValue("EXTGENRE"));

    // `#EXTGRP` belongs to the entry after it.
    try testing.expectEqual(@as(?[]const u8, null), list[1].group());
    try testing.expectEqualStrings("Side two", list[2].group().?);
    try testing.expectEqualStrings("gain=0.8", list[3].tagValue("EXTVLCOPT").?);
}

test "an IPTV playlist's attributes live in the #EXTINF and on the #EXTM3U" {
    var playlist = try parseFixture("iptv.m3u", null);
    defer playlist.deinit();

    try testing.expectEqual(Playlist.Kind.basic, playlist.kind());

    // The `#EXTM3U` line carries attributes, which RFC 8216 does not allow
    // and every IPTV playlist does.
    try testing.expectEqual(@as(usize, 2), playlist.extm3u_attributes.len);
    try testing.expectEqualStrings("x-tvg-url", playlist.extm3u_attributes[0].name);
    try testing.expectEqualStrings(
        "https://example.com/guide.xml.gz",
        playlist.extm3u_attributes[0].string(),
    );

    const list = playlist.body.basic;
    try testing.expectEqual(@as(usize, 4), list.len);

    // `-1` is a duration, and a negative one: an IPTV channel has no length.
    try testing.expectEqual(@as(f64, -1), list[0].duration.?);
    try testing.expectEqualStrings("BBC One", list[0].title);
    try testing.expectEqualStrings("bbc1.uk", list[0].attributeValue("tvg-id").?);
    try testing.expectEqualStrings("UK", list[0].attributeValue("group-title").?);
    try testing.expectEqualStrings("UK", list[0].group().?);
    try testing.expectEqual(@as(?[]const u8, null), list[0].attributeValue("nope"));

    // A comma inside a quoted attribute value is not the comma that ends
    // the duration, which is the one thing a naive `#EXTINF` parser gets
    // wrong on a real IPTV playlist.
    try testing.expectEqualStrings("Rolling News HD", list[2].title);
    try testing.expectEqualStrings("News, Documentary", list[2].attributeValue("group-title").?);

    // `#EXTGRP` wins over `group-title` when both are there, since it is
    // the more specific statement.
    try testing.expectEqualStrings("Radio", list[3].group().?);
}

// -- the HLS features the RFC's examples do not cover ----------------------

test "byte ranges, with and without an offset" {
    var diagnostics: m3u.Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();
    var playlist = try parseFixture("byterange.m3u8", &diagnostics);
    defer playlist.deinit();

    const media = playlist.body.media;
    try testing.expectEqual(@as(usize, 4), media.entries.len);
    try testing.expectEqual(
        m3u.tags.ByteRange{ .length = 75232, .offset = 0 },
        media.entries[0].byterange.?,
    );
    // No offset: it follows on from the previous sub-range of the same
    // resource.
    try testing.expectEqual(@as(?u64, null), media.entries[1].byterange.?.offset);
    try testing.expectEqual(@as(u64, 82112), media.entries[1].byterange.?.length);

    // The last segment is a range of a *different* resource with an offset,
    // which is fine. Nothing here breaks §4.3.2.2's chain rule.
    try testing.expect(!diagnostics.has(.byterange_without_offset));
    try testing.expectEqual(@as(usize, 0), diagnostics.invalidCount());
}

test "an #EXT-X-BYTERANGE with no offset and nothing to follow on from" {
    const gpa = testing.allocator;
    var diagnostics: m3u.Diagnostics = .init(gpa);
    defer diagnostics.deinit();

    // §4.3.2.2 says the segment is undefined and a client must refuse the
    // playlist, so this is one of the few things reported as `.invalid`.
    var playlist = try Playlist.parse(gpa,
        \\#EXTM3U
        \\#EXT-X-VERSION:4
        \\#EXT-X-TARGETDURATION:10
        \\#EXTINF:10.0,
        \\#EXT-X-BYTERANGE:75232
        \\video.ts
        \\#EXT-X-ENDLIST
        \\
    , .{ .diagnostics = &diagnostics });
    defer playlist.deinit();
    try testing.expect(diagnostics.has(.byterange_without_offset));

    // ...and it is the *same resource* that matters, not merely a previous
    // segment.
    diagnostics.clear();
    var other = try Playlist.parse(gpa,
        \\#EXTM3U
        \\#EXT-X-VERSION:4
        \\#EXT-X-TARGETDURATION:10
        \\#EXTINF:10.0,
        \\#EXT-X-BYTERANGE:100@0
        \\one.ts
        \\#EXTINF:10.0,
        \\#EXT-X-BYTERANGE:100
        \\two.ts
        \\#EXT-X-ENDLIST
        \\
    , .{ .diagnostics = &diagnostics });
    defer other.deinit();
    try testing.expect(diagnostics.has(.byterange_without_offset));
}

test "fragmented MP4, with an initialisation section that changes" {
    var diagnostics: m3u.Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();
    var playlist = try parseFixture("fmp4.m3u8", &diagnostics);
    defer playlist.deinit();

    const media = playlist.body.media;
    try testing.expectEqual(@as(usize, 3), media.entries.len);
    try testing.expect(playlist.independent_segments);

    // The `#EXT-X-MAP` tags are on the segments they were written before...
    try testing.expectEqualStrings("init.mp4", media.entries[0].map.?.uri);
    try testing.expectEqual(@as(?m3u.tags.Map, null), media.entries[1].map);
    try testing.expectEqualStrings("init-2.mp4", media.entries[2].map.?.uri);
    // ...and `mapFor` says which one is in effect where.
    try testing.expectEqualStrings("init.mp4", media.mapFor(1).?.uri);
    try testing.expectEqualStrings("init-2.mp4", media.mapFor(2).?.uri);

    // The first map has no `BYTERANGE`, which §4.3.2.5 says means the whole
    // resource, and is not the error it would be on `#EXT-X-BYTERANGE`.
    try testing.expectEqual(@as(?m3u.tags.ByteRange, null), media.entries[0].map.?.byterange);
    try testing.expectEqual(
        m3u.tags.ByteRange{ .length = 1024, .offset = 0 },
        media.entries[2].map.?.byterange.?,
    );

    try testing.expect(media.entries[2].discontinuity);
    try testing.expectEqual(@as(i32, 2026), media.entries[0].program_date_time.?.year);
    try testing.expectEqual(@as(usize, 0), diagnostics.count());
}

test "several key formats at once, then a key that cancels them" {
    var playlist = try parseFixture("encrypted-rotating.m3u8", null);
    defer playlist.deinit();

    const media = playlist.body.media;
    try testing.expectEqual(@as(usize, 4), media.entries.len);

    // Two `#EXT-X-KEY` tags before the first segment: the same content
    // under two key systems, which §4.3.2.4 allows and which is how a
    // playlist serves FairPlay and Widevine at once.
    try testing.expectEqual(@as(usize, 2), media.entries[0].keys.len);
    try testing.expectEqual(@as(usize, 2), media.keysFor(1).len);
    try testing.expectEqualStrings(
        "com.apple.streamingkeydelivery",
        media.entries[0].keys[0].keyformat.?,
    );
    try testing.expect(media.entries[0].keys[0].method.is(.sample_aes));

    // The third segment's key has an `IV`, written with an upper-case `0X`
    // -- which is kept as it was written and still decodes.
    try testing.expectEqualStrings("0X9c7db8778570d05c3f4a0e6e0bcc5b5c", media.keysFor(2)[0].iv.?);
    const iv = try media.keysFor(2)[0].initialisationVector().?;
    try testing.expectEqual(@as(u8, 0x9c), iv[0]);
    try testing.expectEqual(@as(u8, 0x5c), iv[15]);

    // `METHOD=NONE` cancels the keys before it, so the last segment is not
    // encrypted -- though the key is still *in effect*, which is what
    // `keysFor` reports and `encrypted` interprets.
    try testing.expect(media.encrypted(2));
    try testing.expect(!media.encrypted(3));
    try testing.expectEqual(@as(usize, 1), media.keysFor(3).len);
    try testing.expect(media.keysFor(3)[0].method.is(.none));
}

test "a low-latency playlist, whose last segment does not exist yet" {
    var diagnostics: m3u.Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();
    var playlist = try parseFixture("low-latency.m3u8", &diagnostics);
    defer playlist.deinit();

    const media = playlist.body.media;
    try testing.expectEqual(@as(usize, 3), media.entries.len);

    const control = media.server_control.?;
    try testing.expect(control.can_block_reload);
    try testing.expect(control.can_skip_dateranges);
    try testing.expectEqual(@as(f64, 24.0), control.can_skip_until.?);
    try testing.expectEqual(@as(f64, 1.0), control.part_hold_back.?);
    try testing.expectEqual(@as(f64, 0.33334), media.part_inf.?.part_target);

    // The third segment is complete and has three parts.
    try testing.expectEqual(@as(usize, 3), media.entries[2].parts.len);
    try testing.expect(media.entries[2].parts[0].independent);
    try testing.expect(media.entries[2].parts[2].gap);
    try testing.expectEqualStrings("fs268.0.mp4", media.entries[2].parts[0].uri);

    // The two parts after it belong to a segment that has not been
    // published: no `#EXTINF`, no URI line, and not a mistake. This is what
    // `trailing_parts` is for, and the only place in the format where a
    // dangling segment tag is legal.
    try testing.expectEqual(@as(usize, 2), media.trailing_parts.len);
    try testing.expectEqualStrings("fs269.0.mp4", media.trailing_parts[0].uri);
    try testing.expectEqual(
        m3u.tags.ByteRange{ .length = 20000, .offset = 0 },
        media.trailing_parts[1].byterange.?,
    );
    try testing.expect(!diagnostics.has(.segment_without_uri));

    // The preload hint and the rendition reports, which come after the
    // parts.
    try testing.expectEqual(@as(usize, 1), media.preload_hints.len);
    try testing.expect(media.preload_hints[0].type.is(.part));
    try testing.expectEqual(@as(?u64, 20000), media.preload_hints[0].byterange_start.?);
    try testing.expectEqual(@as(usize, 2), media.rendition_reports.len);
    try testing.expectEqual(@as(?u64, 268), media.rendition_reports[0].last_msn);
    try testing.expectEqual(@as(?u64, 1), media.rendition_reports[1].last_part);

    try testing.expectEqual(@as(usize, 0), diagnostics.count());
}

test "a delta update counts the segments it left out" {
    var playlist = try parseFixture("delta-update.m3u8", null);
    defer playlist.deinit();

    const media = playlist.body.media;
    const skip = media.skip.?;
    try testing.expectEqual(@as(u64, 30), skip.skipped_segments);

    // The removed date ranges are separated by tabs, which is the one list
    // in the specification that is.
    var removed = skip.removedDateRanges();
    try testing.expectEqualStrings("ad-1", removed.next().?);
    try testing.expectEqualStrings("ad-2", removed.next().?);
    try testing.expectEqual(@as(?[]const u8, null), removed.next());

    // The sequence numbers have to count past what was skipped, which is
    // the whole reason `sequenceNumber` exists.
    try testing.expectEqual(@as(u64, 100), media.media_sequence);
    try testing.expectEqual(@as(u64, 130), media.sequenceNumber(0));
    try testing.expectEqual(@as(u64, 131), media.sequenceNumber(1));
}

test "an I-frames-only playlist, and where a player should start in it" {
    var playlist = try parseFixture("iframes-only.m3u8", null);
    defer playlist.deinit();

    const media = playlist.body.media;
    try testing.expect(media.iframes_only);
    try testing.expect(media.playlist_type.?.is(.vod));

    // `TIME-OFFSET` is the one signed floating-point value in the
    // specification: negative means from the end.
    const start = playlist.start.?;
    try testing.expectEqual(@as(f64, -30.5), start.time_offset);
    try testing.expect(start.precise);
}

test "variables are parsed, and substituted only when asked" {
    const gpa = testing.allocator;
    var diagnostics: m3u.Diagnostics = .init(gpa);
    defer diagnostics.deinit();
    var playlist = try parseFixture("define-variables.m3u8", &diagnostics);
    defer playlist.deinit();

    try testing.expectEqual(@as(usize, 4), playlist.defines.len);
    try testing.expectEqualStrings("cdn.example.com", playlist.variable("host").?);
    try testing.expectEqualStrings("/hls/720p", playlist.variable("path").?);
    // `IMPORT` and `QUERYPARAM` name variables whose values come from
    // outside the playlist, so there is nothing to look up.
    try testing.expectEqualStrings("session", playlist.defines[2].variableName().?);
    try testing.expectEqual(@as(?[]const u8, null), playlist.variable("session"));
    try testing.expectEqual(@as(?[]const u8, null), playlist.variable("token"));
    try testing.expectEqual(@as(?[]const u8, null), playlist.duplicateVariable());

    // The URI is *not* substituted by the parser, so the playlist can be
    // written back out as it came.
    const media = playlist.body.media;
    try testing.expectEqualStrings(
        "https://{$host}{$path}/seg1.ts?token={$token}",
        media.entries[0].uri,
    );

    // Substituting needs the imported values supplied.
    try testing.expectError(
        error.UndefinedVariable,
        playlist.substituteAlloc(gpa, media.entries[0].uri, &.{}),
    );
    const expanded = try playlist.substituteAlloc(gpa, media.entries[0].uri, &.{
        .{ .name = "token", .value = "abc123" },
    });
    defer gpa.free(expanded);
    try testing.expectEqualStrings(
        "https://cdn.example.com/hls/720p/seg1.ts?token=abc123",
        expanded,
    );

    try testing.expectEqual(@as(usize, 0), diagnostics.count());
}

test "content steering and everything added to #EXT-X-STREAM-INF since RFC 8216" {
    var diagnostics: m3u.Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();
    var playlist = try parseFixture("content-steering.m3u8", &diagnostics);
    defer playlist.deinit();

    const mv = playlist.body.multivariant;
    const steering = mv.content_steering.?;
    try testing.expectEqualStrings("/steering?video=00012", steering.server_uri);
    try testing.expectEqualStrings("CDN-A", steering.pathway_id.?);

    try testing.expectEqual(@as(usize, 1), mv.session_keys.len);
    try testing.expect(mv.session_keys[0].method.is(.sample_aes));

    // The audio rendition's post-RFC attributes.
    const audio = mv.renditions[0];
    try testing.expectEqualStrings("en-aac", audio.stable_rendition_id.?);
    try testing.expectEqual(@as(?u64, 16), audio.bit_depth);
    try testing.expectEqual(@as(?u64, 48000), audio.sample_rate);
    try testing.expectEqual(@as(?u64, 2), audio.channelCount());

    // The closed-captions rendition needs an `INSTREAM-ID` and no `URI`.
    const captions = mv.renditions[1];
    try testing.expect(captions.type.is(.closed_captions));
    try testing.expectEqualStrings("CC1", captions.instream_id.?);
    try testing.expectEqual(@as(?[]const u8, null), captions.uri);
    const characteristics = captions.characteristics.?;
    try testing.expect(std.mem.find(u8, characteristics, "public.easy-to-read") != null);

    const a = mv.variants[0].stream_inf;
    try testing.expectEqual(@as(?f64, 2.5), a.score);
    try testing.expectEqualStrings("dvh1.05.01/db1p", a.supplemental_codecs.?);
    try testing.expect(a.hdcp_level.?.is(.type_1));
    try testing.expect(a.video_range.?.is(.pq));
    try testing.expectEqualStrings("CH-STEREO CH-MONO", a.req_video_layout.?);
    try testing.expectEqualStrings("CDN-A", a.pathway_id.?);
    try testing.expectEqualStrings("cc", a.closed_captions.?.group);

    // The second variant is the same content on the other pathway, and its
    // `CLOSED-CAPTIONS=NONE` is the unquoted enumerated value rather than a
    // group called NONE.
    const b = mv.variants[1].stream_inf;
    try testing.expectEqualStrings("CDN-B", b.pathway_id.?);
    try testing.expectEqual(m3u.tags.ClosedCaptions.none, b.closed_captions.?);

    try testing.expectEqual(@as(usize, 0), diagnostics.count());
}

test "date ranges, gaps and a bitrate" {
    var playlist = try parseFixture("dates-and-gaps.m3u8", null);
    defer playlist.deinit();

    const media = playlist.body.media;
    try testing.expectEqual(@as(usize, 4), media.entries.len);

    // The programme date and the bitrate belong to the first segment.
    const first = media.entries[0];
    try testing.expectEqual(@as(i32, 2010), first.program_date_time.?.year);
    try testing.expectEqual(@as(i16, 480), first.program_date_time.?.offset_minutes);
    try testing.expectEqual(@as(?u64, 2000000), first.bitrate);

    try testing.expect(media.entries[1].gap);

    const ad = media.entries[2].dateranges[0];
    try testing.expectEqualStrings("ad-break", ad.id);
    try testing.expectEqual(@as(f64, 30.0), ad.duration.?);
    try testing.expectEqualStrings("PRE ONCE", ad.cue.?);
    try testing.expectEqualStrings("https://example.com/ad.m3u8", ad.clientAttribute("X-ASSET-URI").?);

    const chapter = media.entries[3].dateranges[0];
    try testing.expect(chapter.end_on_next);
    try testing.expectEqualStrings("com.example.chapter", chapter.class.?);
}

// -- what this library does with playlists that are wrong ------------------

test "tags and attributes nobody has heard of come out the other side" {
    const gpa = testing.allocator;
    var diagnostics: m3u.Diagnostics = .init(gpa);
    defer diagnostics.deinit();

    const bytes = try read(gpa, "unknown-tags.m3u8");
    defer gpa.free(bytes);
    var playlist = try Playlist.parse(gpa, bytes, .{ .diagnostics = &diagnostics });
    defer playlist.deinit();

    try testing.expect(diagnostics.has(.unknown_tag));
    try testing.expect(diagnostics.has(.unknown_attribute));
    try testing.expect(diagnostics.has(.unknown_enumerated_value));

    const written = try playlist.toTextAlloc(gpa);
    defer gpa.free(written);

    // Every one of them is in the output, unchanged. This is the property
    // that makes the library safe to put in a tool that edits playlists.
    for ([_][]const u8{
        "#EXT-X-FUTURE-TAG:WITH=A,LIST=\"of, things\"",
        "#EXT-X-FLAG-FROM-2030",
        "#EXT-X-STREAM-INF-BUT-NOT-REALLY:BANDWIDTH=1",
        "#EXT-X-VENDOR-SEGMENT-TAG:X=1",
        "#EXT-X-SOMETHING-AFTER-THE-END:V=1",
        "# An ordinary comment, which is not a tag at all.",
        "# And a comment at the very bottom.",
        // An enumerated value from a later version of the specification.
        "METHOD=AES-256-CTR",
        // An unknown attribute on a tag that is known.
        "X-VENDOR-FLAG=YES",
        // The `X-` client attributes of a date range.
        "X-COM-EXAMPLE-DEPTH=3",
        "X-COM-EXAMPLE-NAME=\"deep\"",
    }) |fragment| {
        if (std.mem.find(u8, written, fragment) == null) {
            std.debug.print("lost on the way out: {s}\n--- written ---\n{s}\n", .{ fragment, written });
            return error.UnknownThingWasDropped;
        }
    }
}

test "a playlist with everything wrong with it still parses" {
    const gpa = testing.allocator;
    var diagnostics: m3u.Diagnostics = .init(gpa);
    defer diagnostics.deinit();

    const bytes = try read(gpa, "messy.m3u");
    defer gpa.free(bytes);
    var playlist = try Playlist.parse(gpa, bytes, .{ .diagnostics = &diagnostics });
    defer playlist.deinit();

    // Every one of these is something a real playlist does and RFC 8216
    // forbids.
    try testing.expect(diagnostics.has(.byte_order_mark));
    try testing.expect(diagnostics.has(.missing_extm3u));
    try testing.expect(diagnostics.has(.missing_quotes));
    try testing.expect(diagnostics.has(.invalid_tag_value));

    try testing.expect(playlist.byte_order_mark);
    try testing.expect(!playlist.extm3u);
    // `#EXT-X-Version` in mixed case is still that tag.
    try testing.expectEqual(@as(?u64, 3), playlist.version);

    const media = playlist.body.media;
    // `#EXT-X-TARGETDURATION:10.0` is not an integer, and is read as one.
    try testing.expectEqual(@as(?u64, 10), media.target_duration);
    try testing.expectEqual(@as(usize, 2), media.entries.len);
    // `URI=key.bin` without its quotes, after a space that §4.2 forbids.
    try testing.expectEqualStrings("key.bin", media.keysFor(0)[0].uri.?);
    // The title keeps the space on its end, because trimming it would be
    // editing the playlist.
    try testing.expectEqualStrings(" With a title ", media.entries[0].title);

    // And `strict` *accepts* it, which is the interesting part: every one of
    // the things wrong with this playlist is a warning, because not one of
    // them lost anything. `strict` is about information, not conformance.
    var strictly = try Playlist.parse(gpa, bytes, .{ .strict = true });
    strictly.deinit();
    try testing.expectEqual(@as(usize, 0), diagnostics.invalidCount());
}

test "the conformance failures the check command exists to find" {
    var diagnostics: m3u.Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();
    var playlist = try parseFixture("nonconformant.m3u8", &diagnostics);
    defer playlist.deinit();

    // No `#EXT-X-TARGETDURATION`, which §4.3.3.1 makes mandatory.
    try testing.expect(diagnostics.has(.missing_target_duration));
    try testing.expectEqual(@as(?u64, null), playlist.body.media.target_duration);

    // A URI with no `#EXTINF` before it, which §4.3.2.1 requires for every
    // segment. It is still read as a segment rather than dropped.
    try testing.expect(diagnostics.has(.uri_without_tag));
    try testing.expectEqual(@as(usize, 3), playlist.body.media.entries.len);
    try testing.expectEqual(@as(?f64, null), playlist.body.media.entries[1].duration);

    // A missing `#EXT-X-TARGETDURATION` is information the playlist does not
    // have, so `strict` refuses it -- unlike everything in `messy.m3u`.
    const bytes = try read(testing.allocator, "nonconformant.m3u8");
    defer testing.allocator.free(bytes);
    try testing.expectError(
        error.InvalidPlaylist,
        Playlist.parse(testing.allocator, bytes, .{ .strict = true }),
    );
}

test "a segment longer than the target duration allows" {
    var diagnostics: m3u.Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();
    var playlist = try Playlist.parse(testing.allocator,
        \\#EXTM3U
        \\#EXT-X-TARGETDURATION:10
        \\#EXTINF:10.4,
        \\just-inside.ts
        \\#EXTINF:10.6,
        \\too-long.ts
        \\#EXT-X-ENDLIST
        \\
    , .{ .diagnostics = &diagnostics });
    defer playlist.deinit();

    // §4.3.3.1 measures the duration *rounded to the nearest integer*, so
    // 10.4 is inside the limit and 10.6 is not.
    try testing.expectEqual(@as(usize, 1), diagnostics.count());
    try testing.expectEqualStrings("too-long.ts", diagnostics.find(.duration_over_target).?.detail);
}

test "the two kinds of playlist mixed together" {
    var diagnostics: m3u.Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();
    var playlist = try Playlist.parse(testing.allocator,
        \\#EXTM3U
        \\#EXT-X-TARGETDURATION:10
        \\#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="n"
        \\#EXTINF:10.0,
        \\seg.ts
        \\#EXT-X-ENDLIST
        \\
    , .{ .diagnostics = &diagnostics });
    defer playlist.deinit();

    // Two Media Playlist tags against one Multivariant one, so it is read as
    // a Media Playlist and the `#EXT-X-MEDIA` is kept where it was found
    // rather than acted on -- a Media Playlist has nowhere to put one.
    try testing.expect(diagnostics.has(.mixed_playlist_kinds));
    try testing.expect(diagnostics.has(.tag_in_wrong_playlist));
    try testing.expectEqual(Playlist.Kind.media, playlist.kind());

    const written = try playlist.toTextAlloc(testing.allocator);
    defer testing.allocator.free(written);
    try testing.expect(std.mem.find(u8, written, "#EXT-X-MEDIA:TYPE=AUDIO") != null);
}

test "an empty file, and a playlist with no segments in it" {
    var diagnostics: m3u.Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    var empty = try parseFixture("empty.m3u", &diagnostics);
    defer empty.deinit();
    try testing.expectEqual(Playlist.Kind.basic, empty.kind());
    try testing.expectEqual(@as(usize, 0), empty.entries().len);
    try testing.expect(!empty.extm3u);

    diagnostics.clear();
    var header_only = try parseFixture("empty-media.m3u8", &diagnostics);
    defer header_only.deinit();
    try testing.expectEqual(Playlist.Kind.media, header_only.kind());
    try testing.expectEqual(@as(usize, 0), header_only.body.media.entries.len);
    try testing.expect(header_only.body.media.endlist);
    try testing.expectEqual(@as(f64, 0), header_only.body.media.totalDuration());
    // A playlist with no segments is legal and conformant; nothing about it
    // is a problem.
    try testing.expectEqual(@as(usize, 0), diagnostics.count());
}

test "segment tags at the end of the file with no segment to describe" {
    var diagnostics: m3u.Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();
    var playlist = try Playlist.parse(testing.allocator,
        \\#EXTM3U
        \\#EXT-X-TARGETDURATION:10
        \\#EXTINF:10.0,
        \\seg.ts
        \\#EXT-X-KEY:METHOD=AES-128,URI="k"
        \\#EXT-X-ENDLIST
        \\
    , .{ .diagnostics = &diagnostics });
    defer playlist.deinit();

    // The key describes segments that are not there, so it is dropped --
    // which is what makes it `.invalid` rather than a warning.
    try testing.expect(diagnostics.has(.segment_without_uri));
    try testing.expectEqual(@as(usize, 1), playlist.body.media.entries.len);
    try testing.expectEqual(@as(usize, 0), playlist.body.media.entries[0].keys.len);
}

test "reading a playlist from a reader, and the limit on how much" {
    const gpa = testing.allocator;
    const bytes = try read(gpa, "rfc8216-8.1-simple-media.m3u8");
    defer gpa.free(bytes);

    var reader: Io.Reader = .fixed(bytes);
    var playlist = try Playlist.parseReader(gpa, &reader, max_bytes, .{});
    defer playlist.deinit();
    try testing.expectEqual(@as(usize, 3), playlist.body.media.entries.len);

    // The limit is a limit, and being over it is an error rather than a
    // truncated playlist -- which would parse, and be wrong.
    var truncating: Io.Reader = .fixed(bytes);
    try testing.expectError(
        error.StreamTooLong,
        Playlist.parseReader(gpa, &truncating, .limited(8), .{}),
    );
}

// -- resolving what is in them ---------------------------------------------

test "the URIs of a real playlist, resolved against where it came from" {
    const gpa = testing.allocator;
    var playlist = try parseFixture("rfc8216-8.5-master-iframes.m3u8", null);
    defer playlist.deinit();

    var base: m3u.resolve.Base = try .init(gpa, "https://example.com/hls/master.m3u8");
    defer base.deinit();

    const expected = [_][]const u8{
        "https://example.com/hls/low/audio-video.m3u8",
        "https://example.com/hls/low/iframe.m3u8",
        "https://example.com/hls/mid/audio-video.m3u8",
        "https://example.com/hls/mid/iframe.m3u8",
        "https://example.com/hls/hi/audio-video.m3u8",
        "https://example.com/hls/hi/iframe.m3u8",
        "https://example.com/hls/audio-only.m3u8",
    };
    const variants = playlist.body.multivariant.variants;
    try testing.expectEqual(expected.len, variants.len);
    for (variants, expected) |variant, want| {
        const got = try base.resolveAlloc(gpa, variant.uri, .{});
        defer gpa.free(got);
        try testing.expectEqualStrings(want, got);
    }
}

test "a plain M3U's entries are paths, which is why resolution is not automatic" {
    var playlist = try parseFixture("basic.m3u", null);
    defer playlist.deinit();

    const list = playlist.body.basic;
    // Nothing here looks like a Windows path, so `looksLikePath` says no to
    // all of them -- a POSIX path really is a legal relative URI reference,
    // and only the caller knows which was meant.
    for (list) |entry| try testing.expect(!m3u.resolve.looksLikePath(entry.uri));
    try testing.expect(m3u.resolve.looksLikePath("C:\\Music\\track.mp3"));
}
