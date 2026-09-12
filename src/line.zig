// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Splitting a playlist into lines, and saying what each one is.
//!
//! RFC 8216 §4.1 makes this simple enough to state in four rules: a line is
//! terminated by a line feed or a carriage return and line feed; a blank line
//! is ignored; a line beginning `#EXT` is a tag; any other line beginning `#`
//! is a comment; and everything else is a URI. Tag and comment lines are
//! never continued, so a line is the whole of its own syntax.
//!
//! Nothing here allocates, and every slice borrows from the bytes handed in.
//!
//! # What a line is worth being careful about
//!
//! **The terminator.** A lone carriage return is not one. Old Mac text files
//! used it, and treating it as a terminator would split a URI containing a
//! `%0D` escape — but more to the point, a file with `\r\n` endings that was
//! then truncated mid-line would silently gain a line. So carriage returns
//! are stripped from the *end* of a line and are otherwise ordinary bytes.
//!
//! *All* of them are stripped, not just the one before the line feed, and
//! that matters more than it looks. Whatever ends a line — a URI, an
//! `#EXTINF` title, an unknown tag's value — is written back out with a `\n`
//! after it, and a trailing carriage return would then be swallowed as part
//! of the next terminator. `B.2#\r\r\n` read as a URI of `B.2#\r` could not be
//! written and read again as itself, so the line is `B.2#` and nothing in
//! this format can hold a carriage return at the end of a line.
//!
//! **Trailing whitespace is not stripped from a tag's value.** `#EXTINF:10,
//! Title ` has a title with a space on the end, and a parser that trimmed it
//! would be editing the file. It *is* stripped from a tag name, so that
//! `#EXT-X-ENDLIST ` is still that tag, and from a URI, which cannot contain
//! whitespace.
//!
//! **A tag's name ends at the first byte that cannot be in one**, not at the
//! first colon. RFC 8216 §4.1 builds a name out of `[A-Z0-9-]`, so the two
//! rules agree on every conformant tag — and disagree on the one line every
//! IPTV playlist starts with:
//!
//! ```
//! #EXTM3U x-tvg-url="https://example.com/guide.xml.gz"
//! ```
//!
//! Splitting that at the first colon gives a tag called
//! `EXTM3U x-tvg-url="https` and a value of `//example.com/...`, which is
//! nonsense. Ending the name at the space gives `EXTM3U` with the rest in
//! `attributes`, which is what it means.
//!
//! **The byte order mark.** RFC 8216 §4 forbids one. Windows tools write them
//! anyway, and a playlist whose first line is `\xEF\xBB\xBF#EXTM3U` is not
//! recognised as extended at all if the mark is left on. `stripByteOrderMark`
//! takes the one at the start of the file off and says whether it was there,
//! so that `write` can put it back rather than quietly reformatting
//! somebody's file.
//!
//! A mark at the start of any *other* line is taken off by `classify` and not
//! put back, because there is nowhere to record it and because the
//! alternative is worse. U+FEFF is not a character a URI may carry
//! unencoded, and a line that kept one would be written back as the first
//! line of some rewritten playlist — where it would then be read as the
//! file's byte order mark and change what the first line is. So the mark is
//! trimmed like the whitespace around it, and the line is whatever it is
//! without it. `hadByteOrderMark` is how the parser reports one.

const std = @import("std");

/// The UTF-8 encoding of U+FEFF, which is what a byte order mark is in a
/// file this format says must be UTF-8.
pub const byte_order_mark = "\xEF\xBB\xBF";

/// What the tag prefix is. A `#` line that does not start with this is a
/// comment, however much it looks like a directive — which is why
/// `#PLAYLIST:` is a comment to RFC 8216 and why this library has to go out
/// of its way to recognise it.
pub const tag_prefix = "#EXT";

/// `bytes` with a leading byte order mark removed, and whether there was one.
///
/// Only the mark at the very start of the file, which is the only one that
/// has anywhere to be recorded. `classify` deals with one at the start of a
/// later line.
pub fn stripByteOrderMark(bytes: []const u8) struct { rest: []const u8, present: bool } {
    if (std.mem.startsWith(u8, bytes, byte_order_mark)) {
        return .{ .rest = bytes[byte_order_mark.len..], .present = true };
    }
    return .{ .rest = bytes, .present = false };
}

/// Whether `raw` begins with a byte order mark, once the whitespace before
/// it has been ignored — which is what `classify` is about to throw away.
///
/// Cheap: it walks only the whitespace at the front of the line.
pub fn hadByteOrderMark(raw: []const u8) bool {
    return std.mem.startsWith(u8, trimStart(raw), byte_order_mark);
}

/// A tag: `#EXT`, the name that follows it, and whatever came after that.
pub const Tag = struct {
    /// The name with the `#` and the separator removed, so
    /// `EXT-X-STREAM-INF`. The case is as it was written; the parser matches
    /// names without regard to it.
    name: []const u8,
    /// Whatever followed the colon, or null if no colon separated it from
    /// the name.
    ///
    /// The difference matters. `#EXT-X-ENDLIST` is a tag with no value and
    /// `#EXT-X-ENDLIST:` is a tag with an empty one, and a playlist that
    /// wrote the second should get the second back.
    value: ?[]const u8 = null,
    /// Text that followed the name with no colon introducing it, trimmed of
    /// the whitespace on either side of it.
    ///
    /// Empty for every tag RFC 8216 defines, which is the point: the only
    /// thing that puts anything here is the `#EXTM3U x-tvg-url="..."` line
    /// an IPTV playlist begins with, whose attributes are separated by
    /// spaces rather than introduced by a colon.
    attributes: []const u8 = "",
};

/// What a line turned out to be.
pub const Content = union(enum) {
    /// Empty, or nothing but spaces and tabs. RFC 8216 §4.1 ignores these.
    blank,
    /// A `#` line that is not a tag: the text after the `#`, untrimmed.
    comment: []const u8,
    /// A line beginning `#EXT`.
    tag: Tag,
    /// Anything else: a URI or a relative path, trimmed of the whitespace
    /// that cannot be part of one.
    uri: []const u8,
};

/// One line of a playlist.
pub const Line = struct {
    /// Which line this was, counting from one, for a diagnostic to point at.
    number: u32,
    /// The line as it stood, with its terminator and any trailing carriage
    /// return removed. `content` is derived from this, so anything a caller
    /// wants to reproduce byte for byte is here.
    raw: []const u8,
    content: Content,
};

/// Walks a playlist one line at a time.
///
/// ```
/// var scanner: line.Scanner = .init(bytes);
/// while (scanner.next()) |l| switch (l.content) {
///     .tag => |t| ...,
///     .uri => |u| ...,
///     .comment, .blank => {},
/// };
/// ```
///
/// The byte order mark is not handled here: hand `stripByteOrderMark`'s
/// `rest` to `init`, or the first tag will not be recognised.
pub const Scanner = struct {
    rest: []const u8,
    /// The number of the line `next` will return.
    number: u32 = 1,

    pub fn init(bytes: []const u8) Scanner {
        return .{ .rest = bytes };
    }

    /// The next line, or null at the end of the input.
    ///
    /// A file that does not end with a terminator still yields its last
    /// line; a file that does end with one does not yield an extra blank
    /// after it.
    pub fn next(s: *Scanner) ?Line {
        if (s.rest.len == 0) return null;
        const end = std.mem.findScalar(u8, s.rest, '\n') orelse s.rest.len;
        var raw = s.rest[0..end];
        s.rest = if (end == s.rest.len) s.rest[end..] else s.rest[end + 1 ..];
        // Every trailing carriage return, not only the one before the line
        // feed: see the note at the top of this file about why one is not
        // enough.
        while (raw.len > 0 and raw[raw.len - 1] == '\r') raw = raw[0 .. raw.len - 1];

        const number = s.number;
        s.number += 1;
        return .{ .number = number, .raw = raw, .content = classify(raw) };
    }
};

/// What a line is, given the line.
///
/// Exposed on its own because it is useful without a `Scanner`: a caller
/// reading lines from somewhere else — a `std.Io.Reader`, a database column —
/// can classify them with this.
pub fn classify(raw: []const u8) Content {
    // Leading whitespace is not allowed anywhere by §4.1 and is harmless to
    // ignore, and a byte order mark in front of a line's real content is
    // ignored with it -- see the note at the top of this file. A line of
    // nothing but the two is blank.
    const text = withoutLeading(raw);
    if (text.len == 0) return .blank;
    if (text[0] != '#') return .{ .uri = trimEnd(text) };

    if (!std.mem.startsWith(u8, text, tag_prefix)) return .{ .comment = text[1..] };

    // `#EXT` and then the name, which ends at the first byte that cannot be
    // part of one. For a conformant tag that byte is the colon, or the end
    // of the line; for an IPTV `#EXTM3U x-tvg-url="https://..."` it is the
    // space, and stopping there is what keeps the `https:` out of it.
    const body = text[1..];
    var end: usize = 0;
    while (end < body.len and isNameByte(body[end])) end += 1;
    const name = body[0..end];
    const rest = body[end..];

    if (rest.len == 0) return .{ .tag = .{ .name = name } };
    if (rest[0] == ':') return .{ .tag = .{ .name = name, .value = rest[1..] } };
    return .{ .tag = .{ .name = name, .attributes = trimEnd(trimStart(rest)) } };
}

/// Whether `c` may appear in a tag's name: RFC 8216 §4.1 writes them with
/// `[A-Z]` and `-`, and this accepts digits and lower case besides, so that
/// a name is recognised however it was spelled.
fn isNameByte(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or c == '-' or c == '_';
}

/// Whether a line is one this library would call a tag, without classifying
/// it. Handy for a caller sniffing a file to see whether it is an extended
/// playlist at all.
///
/// Agrees with `classify` by construction, which matters because the two
/// have to ignore the same things: a line of `\xEF\xBB\xBF#EXTM3U` is a tag to
/// both of them, or to neither.
pub fn isTag(raw: []const u8) bool {
    return std.mem.startsWith(u8, withoutLeading(raw), tag_prefix);
}

/// `raw` with the leading whitespace and byte order marks taken off, which
/// is where a line's real content starts. Used by `classify` and `isTag`, so
/// that they cannot disagree.
fn withoutLeading(raw: []const u8) []const u8 {
    var text = trimStart(raw);
    while (std.mem.startsWith(u8, text, byte_order_mark)) {
        text = trimStart(text[byte_order_mark.len..]);
    }
    return text;
}

/// The whitespace trimmed from the ends of a line before it is classified,
/// and from the ends of a URI and of a tag's name and attributes.
///
/// The carriage return is in here as well as being stripped by the scanner,
/// and both are needed: the scanner takes the run of them at the very end of
/// the line, and this takes one that a space or a tab is hiding behind. A URI
/// line of `a.ts\r\t` ends in a tab, so the scanner strips nothing, and a
/// trim of spaces and tabs alone would leave `a.ts\r` — which is written back
/// with a `\n` after it and read again as `a.ts`.
const trimmed = " \t\r";

fn trimStart(text: []const u8) []const u8 {
    var i: usize = 0;
    while (i < text.len and std.mem.findScalar(u8, trimmed, text[i]) != null) i += 1;
    return text[i..];
}

fn trimEnd(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0 and std.mem.findScalar(u8, trimmed, text[end - 1]) != null) end -= 1;
    return text[0..end];
}

// -- tests -----------------------------------------------------------------

const testing = std.testing;

test "the byte order mark comes off and is reported" {
    const marked = stripByteOrderMark(byte_order_mark ++ "#EXTM3U\n");
    try testing.expect(marked.present);
    try testing.expectEqualStrings("#EXTM3U\n", marked.rest);

    const plain = stripByteOrderMark("#EXTM3U\n");
    try testing.expect(!plain.present);
    try testing.expectEqualStrings("#EXTM3U\n", plain.rest);

    // A mark not at the start is not a mark.
    const late = stripByteOrderMark("#EXTM3U\n" ++ byte_order_mark);
    try testing.expect(!late.present);
}

test "a mark on a line other than the first is trimmed with the whitespace" {
    // There is nowhere to record it, and a line that kept one would be
    // written back as some rewritten playlist's first line -- where it would
    // be read as *that* file's byte order mark and change what the first
    // line is.
    try testing.expectEqualStrings("a.ts", classify(byte_order_mark ++ "a.ts").uri);
    try testing.expectEqualStrings("EXTM3U", classify(" " ++ byte_order_mark ++ "#EXTM3U").tag.name);
    try testing.expectEqualStrings("a.ts", classify(byte_order_mark ++ byte_order_mark ++ "a.ts").uri);
    try testing.expectEqual(Content.blank, classify(byte_order_mark));

    // `isTag` has to ignore exactly what `classify` ignores, or the two
    // disagree about what a line is.
    try testing.expect(isTag(byte_order_mark ++ "#EXTM3U"));
    try testing.expect(isTag(" \t" ++ byte_order_mark ++ " #EXT-X-ENDLIST"));
    try testing.expect(!isTag(byte_order_mark ++ "a.ts"));

    try testing.expect(hadByteOrderMark(byte_order_mark ++ "a.ts"));
    try testing.expect(hadByteOrderMark("  " ++ byte_order_mark ++ "#EXTM3U"));
    try testing.expect(!hadByteOrderMark("a.ts"));
    try testing.expect(!hadByteOrderMark("a" ++ byte_order_mark));
}

test "a mark no longer hides the tag, and is still worth recording" {
    // It used to: a line of `\xEF\xBB\xBF#EXTM3U` does not *begin* `#EXT`, so a
    // classifier that only trimmed whitespace called it a URI and the
    // playlist was not an extended one. Both `classify` and `isTag` skip the
    // mark now.
    try testing.expect(isTag(byte_order_mark ++ "#EXTM3U"));
    try testing.expectEqualStrings("EXTM3U", classify(byte_order_mark ++ "#EXTM3U").tag.name);
    try testing.expect(isTag("#EXTM3U"));

    // `stripByteOrderMark` is still what records the one at the start of the
    // file, so that `write` can put it back.
    try testing.expect(stripByteOrderMark(byte_order_mark ++ "#EXTM3U").present);
}

test "both line terminators, and a last line with neither" {
    var scanner: Scanner = .init("a\nb\r\nc");
    try testing.expectEqualStrings("a", scanner.next().?.raw);
    try testing.expectEqualStrings("b", scanner.next().?.raw);
    try testing.expectEqualStrings("c", scanner.next().?.raw);
    try testing.expectEqual(@as(?Line, null), scanner.next());
}

test "a terminator at the end does not make an extra line" {
    var scanner: Scanner = .init("a\n");
    try testing.expectEqualStrings("a", scanner.next().?.raw);
    try testing.expectEqual(@as(?Line, null), scanner.next());

    // ...and a blank line in the middle is a line.
    var blank: Scanner = .init("a\n\nb\n");
    _ = blank.next();
    try testing.expectEqual(Content.blank, blank.next().?.content);
    try testing.expectEqualStrings("b", blank.next().?.raw);
    try testing.expectEqual(@as(?Line, null), blank.next());
}

test "a lone carriage return is not a terminator" {
    var scanner: Scanner = .init("a\rb\n");
    const only = scanner.next().?;
    try testing.expectEqualStrings("a\rb", only.raw);
    try testing.expectEqual(@as(?Line, null), scanner.next());
}

test "a carriage return hiding behind a tab comes off a URI too" {
    // The scanner strips the run of carriage returns at the very end of the
    // line, and there is none here -- the line ends in a tab. Trimming only
    // spaces and tabs would leave `a.ts\r`, which cannot be written back and
    // read again as itself.
    try testing.expectEqualStrings("a.ts", classify("a.ts\r\t").uri);
    try testing.expectEqualStrings("a.ts", classify("\t\ra.ts\t \r").uri);
    try testing.expectEqualStrings("EXT-X-ENDLIST", classify("\r#EXT-X-ENDLIST\r ").tag.name);
}

test "every trailing carriage return comes off, not just the last" {
    // Whatever ends a line is written back with a `\n` after it, so a line
    // that kept a trailing carriage return could not survive the round trip:
    // the return would become part of the next terminator.
    var scanner: Scanner = .init("B.2#\r\r\n");
    try testing.expectEqualStrings("B.2#", scanner.next().?.raw);
    try testing.expectEqual(@as(?Line, null), scanner.next());

    // A line of nothing but carriage returns is therefore blank.
    var all: Scanner = .init("\r\r\r\n");
    try testing.expectEqual(Content.blank, all.next().?.content);

    // And one with no line feed at all is treated the same way.
    var unterminated: Scanner = .init("a\r\r");
    try testing.expectEqualStrings("a", unterminated.next().?.raw);
}

test "line numbers count from one and count blanks" {
    var scanner: Scanner = .init("#EXTM3U\n\nurl\n");
    try testing.expectEqual(@as(u32, 1), scanner.next().?.number);
    try testing.expectEqual(@as(u32, 2), scanner.next().?.number);
    try testing.expectEqual(@as(u32, 3), scanner.next().?.number);
}

test "an empty input yields nothing" {
    var scanner: Scanner = .init("");
    try testing.expectEqual(@as(?Line, null), scanner.next());
}

test "classification" {
    try testing.expectEqual(Content.blank, classify(""));
    try testing.expectEqual(Content.blank, classify("   \t "));

    try testing.expectEqualStrings("url.ts", classify("url.ts").uri);
    try testing.expectEqualStrings("url.ts", classify("  url.ts  ").uri);
    try testing.expectEqualStrings("https://example.com/a?b=c", classify("https://example.com/a?b=c").uri);

    try testing.expectEqualStrings(" a comment", classify("# a comment").comment);
    // `#PLAYLIST` does not begin `#EXT`, so RFC 8216 calls it a comment --
    // which is exactly why the parser has to look inside comments to find
    // the extended-M3U directives.
    try testing.expectEqualStrings("PLAYLIST:Mix", classify("#PLAYLIST:Mix").comment);
}

test "tags, with and without a value" {
    const none = classify("#EXT-X-ENDLIST").tag;
    try testing.expectEqualStrings("EXT-X-ENDLIST", none.name);
    try testing.expectEqual(@as(?[]const u8, null), none.value);

    const empty = classify("#EXT-X-ENDLIST:").tag;
    try testing.expectEqualStrings("EXT-X-ENDLIST", empty.name);
    try testing.expectEqualStrings("", empty.value.?);

    const valued = classify("#EXT-X-VERSION:7").tag;
    try testing.expectEqualStrings("EXT-X-VERSION", valued.name);
    try testing.expectEqualStrings("7", valued.value.?);
}

test "the colon that splits the line is the one after the name" {
    // A URI in the value has colons of its own, and they are not it.
    const tag = classify("#EXT-X-MAP:URI=\"https://e.com/i.mp4\",BYTERANGE=\"1@0\"").tag;
    try testing.expectEqualStrings("EXT-X-MAP", tag.name);
    try testing.expectEqualStrings("URI=\"https://e.com/i.mp4\",BYTERANGE=\"1@0\"", tag.value.?);
    try testing.expectEqualStrings("", tag.attributes);
}

test "a tag whose name is followed by a space, not a colon" {
    // The line every IPTV playlist begins with. Splitting at the first colon
    // would give a tag called `EXTM3U x-tvg-url="https`.
    const tag = classify("#EXTM3U x-tvg-url=\"https://example.com/guide.xml.gz\"").tag;
    try testing.expectEqualStrings("EXTM3U", tag.name);
    try testing.expectEqual(@as(?[]const u8, null), tag.value);
    try testing.expectEqualStrings("x-tvg-url=\"https://example.com/guide.xml.gz\"", tag.attributes);
}

test "a name followed by nothing but whitespace has no attributes" {
    // ...so that `#EXT-X-ENDLIST ` is written back out as itself rather than
    // gaining a colon or a trailing space.
    const tag = classify("#EXT-X-ENDLIST  ").tag;
    try testing.expectEqualStrings("EXT-X-ENDLIST", tag.name);
    try testing.expectEqual(@as(?[]const u8, null), tag.value);
    try testing.expectEqualStrings("", tag.attributes);
}

test "trailing whitespace comes off a name and stays on a value" {
    const spaced = classify("#EXT-X-ENDLIST\t").tag;
    try testing.expectEqualStrings("EXT-X-ENDLIST", spaced.name);

    // The title of an `#EXTINF` really can end with a space, and trimming it
    // would be editing the playlist.
    const inf = classify("#EXTINF:10,Title ").tag;
    try testing.expectEqualStrings("10,Title ", inf.value.?);
}

test "leading whitespace is ignored for classification and kept in raw" {
    var scanner: Scanner = .init("   #EXT-X-ENDLIST\n");
    const l = scanner.next().?;
    try testing.expectEqualStrings("   #EXT-X-ENDLIST", l.raw);
    try testing.expectEqualStrings("EXT-X-ENDLIST", l.content.tag.name);
}

test "a bare hash is a comment with no text" {
    try testing.expectEqualStrings("", classify("#").comment);
    // ...and `#EXT` on its own is a tag with no name to speak of, which the
    // parser will not recognise and will carry through.
    try testing.expectEqualStrings("EXT", classify("#EXT").tag.name);
}

test "case is preserved rather than folded" {
    // Folding here would make `write` unable to put an unrecognised tag back
    // as it was found. The parser matches names case-insensitively itself.
    try testing.expectEqualStrings("EXTINF", classify("#EXTINF:10,").tag.name);
    // A lower-case `#extinf` does not even begin `#EXT`, so it is a comment.
    try testing.expectEqualStrings("extinf:10,", classify("#extinf:10,").comment);
}
