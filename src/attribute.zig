// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The attribute list, which is the value of most of the interesting tags.
//!
//! RFC 8216 §4.2 gives it a grammar of its own: comma-separated
//! `NAME=value` pairs, where the name is upper-case letters, digits and
//! hyphens, and the value is one of seven types that are told apart by how
//! they are written rather than by what attribute they belong to. A
//! `quoted-string` may hold commas, so an attribute list cannot be split on
//! the comma without knowing where the quotes are — which is the whole
//! reason this file exists rather than a call to `splitScalar`.
//!
//! Everything here borrows from the line it was handed. Nothing allocates.
//!
//! # Order is preserved, and it matters less than it looks
//!
//! The specification says attributes may appear in any order, so two lists
//! with the same pairs in different orders mean the same thing. `Iterator`
//! still yields them in the order written, because an unrecognised attribute
//! has to be put back where it was found for a playlist to survive being
//! rewritten.
//!
//! # What this is lenient about
//!
//! The specification forbids whitespace anywhere in an attribute list. Real
//! playlists put a space after the comma, so `Iterator` skips one and reports
//! it as a `Problem` rather than refusing the line. See `Diagnostics`.
//!
//! The whitespace it skips includes the carriage return, and that is not
//! merely tidiness. An unquoted value is written back out as it stands, and
//! one at the end of its line is followed by a `\n` — so a value of
//! `AES-128\r` would be written as `METHOD=AES-128\r\n` and read again as
//! `AES-128`, since a carriage return before the line feed is part of the
//! terminator. A value §4.2 says cannot hold whitespace is therefore trimmed
//! of it, and what is left is something that can be written.

const std = @import("std");
const Io = std.Io;

/// The whitespace an attribute list is trimmed of.
///
/// The carriage return is in here for the reason at the top of this file: a
/// value keeping one could not be written back out and read again as itself.
const whitespace = " \t\r";

fn isWhitespace(c: u8) bool {
    return std.mem.findScalar(u8, whitespace, c) != null;
}

/// One `NAME=value` pair, borrowed from the line it was read from.
pub const Attribute = struct {
    /// The name, without the `=`. Case is preserved; RFC 8216 §4.2 requires
    /// upper case, and `Iterator` reports anything else as a problem rather
    /// than folding it, since folding would change what `write` puts back.
    name: []const u8,
    /// The value exactly as written, **including the quotes** if it is a
    /// `quoted-string`. Keeping them is what lets an attribute this library
    /// does not know be written back out unchanged; `string` takes them off.
    raw: []const u8,

    /// Whether the value was written as a `quoted-string`.
    pub fn isQuoted(a: Attribute) bool {
        return a.raw.len >= 2 and a.raw[0] == '"' and a.raw[a.raw.len - 1] == '"';
    }

    /// The value with its quotes removed, if it had any.
    ///
    /// An unquoted value is returned as it stands, because the distinction
    /// only matters to a strict reading: `URI="x"` and `URI=x` name the same
    /// resource, and playlists in the wild write both.
    pub fn string(a: Attribute) []const u8 {
        return if (a.isQuoted()) a.raw[1 .. a.raw.len - 1] else a.raw;
    }

    /// A `decimal-integer`: RFC 8216 §4.2 bounds it at 1 to 20 digits and
    /// a value that fits a `u64`, and nothing here is lenient about that
    /// because every use of it — `BANDWIDTH`, `BYTERANGE`, a sequence
    /// number — is a number a player does arithmetic on.
    pub fn integer(a: Attribute) error{InvalidInteger}!u64 {
        return decimalInteger(a.string());
    }

    /// A `decimal-floating-point`, which the specification says is
    /// non-negative. A negative value is an error here rather than silently
    /// accepted, since the attributes typed this way are durations.
    pub fn float(a: Attribute) error{InvalidFloat}!f64 {
        const text = a.string();
        const value = signedFloat(text) catch return error.InvalidFloat;
        if (value < 0) return error.InvalidFloat;
        return value;
    }

    /// A `signed-decimal-floating-point`, which is what `TIME-OFFSET` is:
    /// a negative offset means "from the end".
    pub fn signed(a: Attribute) error{InvalidFloat}!f64 {
        return signedFloat(a.string());
    }

    /// A `hexadecimal-sequence`: `0x` or `0X` and then hex digits, which is
    /// how an `IV` and the SCTE-35 payloads are written.
    ///
    /// The result is the digits read as one big-endian number, so a sequence
    /// longer than 16 bytes does not fit and is an error. `hexBytes` is the
    /// one to use for a payload of unknown length.
    pub fn hex(a: Attribute) error{InvalidHex}!u128 {
        const digits = try hexDigits(a.string());
        if (digits.len > 32) return error.InvalidHex;
        var value: u128 = 0;
        for (digits) |c| value = (value << 4) | try hexDigit(c);
        return value;
    }

    /// A `hexadecimal-sequence` decoded into `out` as big-endian bytes,
    /// returning the part of `out` that was written.
    ///
    /// An odd number of digits is padded on the left — `0xABC` is the three
    /// bytes `0A BC` — because that is what reading the sequence as a number
    /// means, and a number is what the specification says it is.
    pub fn hexBytes(a: Attribute, out: []u8) error{ InvalidHex, NoSpaceLeft }![]u8 {
        const digits = try hexDigits(a.string());
        const len = (digits.len + 1) / 2;
        if (len > out.len) return error.NoSpaceLeft;
        const bytes = out[0..len];
        var i = digits.len;
        var b = len;
        while (i > 0) {
            b -= 1;
            const lo = try hexDigit(digits[i - 1]);
            i -= 1;
            const hi: u8 = if (i > 0) blk: {
                i -= 1;
                break :blk try hexDigit(digits[i]);
            } else 0;
            bytes[b] = (hi << 4) | lo;
        }
        return bytes;
    }

    /// A `decimal-resolution`: `<width>x<height>`, as `RESOLUTION` is
    /// written.
    pub fn resolution(a: Attribute) error{InvalidResolution}!Resolution {
        return Resolution.parse(a.string());
    }

    /// An `enumerated-string` read as one of `E`'s tags.
    ///
    /// The tag names are matched against the attribute value with `-`
    /// standing for `_`, so the Zig enum reads as Zig — `.i_frame` for
    /// `I-FRAME` — without a translation table per enum.
    pub fn enumerated(a: Attribute, comptime E: type) error{UnknownValue}!E {
        return parseEnumerated(E, a.string());
    }

    /// `YES` or `NO`, which is how the specification spells a boolean.
    ///
    /// Absence is not false in general — `DEFAULT` and `AUTOSELECT` default
    /// to `NO`, but `PRECISE` and `INDEPENDENT` also default to `NO` while
    /// `CAN-BLOCK-RELOAD` has no default at all — so this answers only about
    /// an attribute that is present, and each tag says what its absence
    /// means.
    pub fn boolean(a: Attribute) error{UnknownValue}!bool {
        const text = a.string();
        if (std.mem.eql(u8, text, "YES")) return true;
        if (std.mem.eql(u8, text, "NO")) return false;
        return error.UnknownValue;
    }

    /// The words of an `enumerated-string-list`: a quoted string holding
    /// enumerated strings separated by single spaces, which is how
    /// `REQ-VIDEO-LAYOUT` and `CHARACTERISTICS`-style lists are written.
    ///
    /// `CHARACTERISTICS` itself is comma-separated inside its quotes rather
    /// than space-separated, so it uses `commaWords` instead. The
    /// specification really does use both.
    pub fn words(a: Attribute) std.mem.SplitIterator(u8, .scalar) {
        return std.mem.splitScalar(u8, a.string(), ' ');
    }

    /// The comma-separated items inside a quoted string, which is how
    /// `CHARACTERISTICS`, `CODECS` and `ALLOWED-CPC`'s per-format lists are
    /// written.
    pub fn commaWords(a: Attribute) std.mem.SplitIterator(u8, .scalar) {
        return std.mem.splitScalar(u8, a.string(), ',');
    }
};

/// Walks a *space*-separated attribute list.
///
/// This is not in RFC 8216 at all. It is the convention IPTV playlists use,
/// where the attributes sit between an `#EXTINF`'s duration and its comma:
///
/// ```
/// #EXTINF:-1 tvg-id="bbc1" tvg-name="BBC One" group-title="UK",BBC One
/// ```
///
/// and the same shape appears on the `#EXTM3U` line itself, carrying
/// `x-tvg-url`. The values are quoted far more often than not, and a quoted
/// one may hold spaces — which is the whole reason this cannot be a
/// `splitScalar` on the space.
///
/// The `Attribute`s it yields are the same type the comma-separated list
/// yields, so every decoder on `Attribute` works on them. Names here are
/// conventionally lower case with hyphens, and are matched case-insensitively
/// everywhere in this library.
pub const SpaceIterator = struct {
    rest: []const u8,
    /// Set when `next` gave up on text it could not read, which is how it
    /// reports a malformed attribute: there is no way to tell where the next
    /// one would start, so what is left is dropped.
    ///
    /// A caller that must not lose anything silently checks this after the
    /// loop; `Playlist` reports it as an `invalid_tag_value`.
    stopped_early: bool = false,

    pub fn init(list: []const u8) SpaceIterator {
        return .{ .rest = list };
    }

    /// The next attribute, or null at the end.
    ///
    /// Never fails. A malformed attribute — a name with no `=`, a quoted
    /// value with no closing quote — ends the iteration, because there is no
    /// way to tell where the next one would start. Whatever came before is
    /// kept, which is the same thing the comma-separated iterator does.
    pub fn next(it: *SpaceIterator) ?Attribute {
        while (it.rest.len > 0 and isWhitespace(it.rest[0])) it.rest = it.rest[1..];
        if (it.rest.len == 0) return null;

        const equals = std.mem.findScalar(u8, it.rest, '=') orelse return it.giveUp();
        const name = it.rest[0..equals];
        if (name.len == 0) return it.giveUp();
        for (name) |c| {
            // A space inside what should be a name means the previous
            // attribute's value ran on, and there is nothing to be done
            // about it.
            if (isWhitespace(c)) return it.giveUp();
        }

        const value = it.rest[equals + 1 ..];
        if (value.len > 0 and value[0] == '"') {
            const end = closingQuote(value) orelse return it.giveUp();
            it.rest = value[end + 1 ..];
            return .{ .name = name, .raw = value[0 .. end + 1] };
        }

        const end = for (value, 0..) |c, i| {
            if (isWhitespace(c)) break i;
        } else value.len;
        it.rest = value[end..];
        return .{ .name = name, .raw = value[0..end] };
    }

    /// Abandon the rest of the list, recording that something was dropped.
    fn giveUp(it: *SpaceIterator) ?Attribute {
        it.rest = it.rest[it.rest.len..];
        it.stopped_early = true;
        return null;
    }
};

/// A `decimal-resolution`, in pixels.
pub const Resolution = struct {
    width: u64,
    height: u64,

    pub fn parse(text: []const u8) error{InvalidResolution}!Resolution {
        // Lower case only: RFC 8216 §4.2 writes the separator as `x`, and
        // accepting `X` would make `RESOLUTION` the one attribute whose
        // value is case-insensitive.
        const at = std.mem.findScalar(u8, text, 'x') orelse return error.InvalidResolution;
        return .{
            .width = decimalInteger(text[0..at]) catch return error.InvalidResolution,
            .height = decimalInteger(text[at + 1 ..]) catch return error.InvalidResolution,
        };
    }

    pub fn format(r: Resolution, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("{d}x{d}", .{ r.width, r.height });
    }
};

/// What `Iterator` refuses outright. Everything it merely disapproves of
/// becomes a `Problem` instead; see `Diagnostics`.
pub const Error = error{
    /// A name that is not `1*[A-Z0-9-]`, or one that is empty.
    InvalidAttributeName,
    /// A name with nothing after it: no `=`, or the list ended.
    MissingValue,
    /// A `quoted-string` whose closing quote never came, or one holding a
    /// carriage return or line feed — which §4.2 forbids, and which would
    /// mean the line had been split in the wrong place.
    UnterminatedQuotedString,
};

/// Walks an attribute list left to right.
///
/// ```
/// var it: attribute.Iterator = .init(value);
/// while (try it.next()) |a| {
///     if (std.mem.eql(u8, a.name, "BANDWIDTH")) bandwidth = try a.integer();
/// }
/// ```
///
/// Pass `diagnostics` to hear about what was tolerated: a space after a
/// comma, a lower-case name, a trailing comma. Parsing does not depend on
/// it, and a null one costs nothing.
pub const Iterator = struct {
    rest: []const u8,
    /// Where `rest` began, so that a problem can be reported at a column.
    base: []const u8,

    pub fn init(list: []const u8) Iterator {
        return .{ .rest = list, .base = list };
    }

    /// The offset into the original list of whatever `next` will read,
    /// which is what a diagnostic points at.
    pub fn offset(it: Iterator) usize {
        return it.rest.ptr - it.base.ptr;
    }

    /// The next attribute, or null at the end of the list.
    pub fn next(it: *Iterator) Error!?Attribute {
        // Leading and trailing space around a comma is not allowed by §4.2
        // and is common anyway. Skipping it here means the caller sees a
        // clean list whether or not the writer was careful.
        while (it.rest.len > 0 and isWhitespace(it.rest[0])) it.rest = it.rest[1..];
        if (it.rest.len == 0) return null;

        const equals = std.mem.findScalar(u8, it.rest, '=') orelse return error.MissingValue;
        const name = it.rest[0..equals];
        if (name.len == 0) return error.InvalidAttributeName;
        // A comma before the `=` means this is not an attribute at all: the
        // list has a bare word in it, and whatever follows is not ours to
        // guess at.
        if (std.mem.findScalar(u8, name, ',') != null) return error.InvalidAttributeName;
        for (name) |c| if (!isNameByte(c)) return error.InvalidAttributeName;

        var value = it.rest[equals + 1 ..];
        if (value.len > 0 and value[0] == '"') {
            // A quoted string: the comma that ends the attribute is the
            // first one after the closing quote, not the first one at all.
            const end = closingQuote(value) orelse return error.UnterminatedQuotedString;
            const quoted = value[0 .. end + 1];
            var after = value[end + 1 ..];
            while (after.len > 0 and isWhitespace(after[0])) after = after[1..];
            if (after.len > 0) {
                if (after[0] != ',') return error.UnterminatedQuotedString;
                after = after[1..];
            }
            it.rest = after;
            return .{ .name = name, .raw = quoted };
        }

        if (std.mem.findScalar(u8, value, ',')) |comma| {
            it.rest = value[comma + 1 ..];
            value = value[0..comma];
        } else {
            it.rest = value[value.len..];
        }
        // Trailing space on an unquoted value, which is the other half of
        // the space-after-comma leniency: `A=1, B=2` gives `B` a clean value
        // only because the space was skipped above, and `A=1 , B=2` needs
        // this. It is also what keeps a value of `AES-128\r` from being
        // written at the end of a line and read back without the return.
        while (value.len > 0 and isWhitespace(value[value.len - 1])) {
            value = value[0 .. value.len - 1];
        }
        return .{ .name = name, .raw = value };
    }
};

/// Whether `text` can be written inside double quotes and read back as
/// itself.
///
/// RFC 8216 §4.2 lets a `quoted-string` hold anything but a double quote, a
/// carriage return and a line feed, and gives **no way to escape any of
/// them**. So a value holding one of the three cannot be written as a quoted
/// string at all, and a parser that accepted such a value into a field the
/// writer quotes would produce a playlist that could not be written back.
/// `tags.decode` refuses it instead.
pub fn quotable(text: []const u8) bool {
    return std.mem.findAny(u8, text, "\"\r\n") == null;
}

/// Whether `c` may appear in an `AttributeName`: RFC 8216 §4.2 says
/// `[A-Z]`, `[0-9]` and `-`.
///
/// Lower case is deliberately not in here. A name is matched
/// case-sensitively everywhere in this library, because `write` has to put
/// an unrecognised attribute back exactly as it was found and folding the
/// case would make that a lie.
pub fn isNameByte(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or
        // Not in the grammar. `_` turns up in vendor attributes and
        // accepting it costs nothing, since an unknown name is carried
        // through rather than acted on.
        c == '_' or (c >= 'a' and c <= 'z');
}

/// The index of the quote that closes the one at `text[0]`, or null if the
/// string is unterminated or holds a byte that §4.2 forbids inside one.
///
/// There is no escape sequence. RFC 8216 §4.2 says a `quoted-string` holds
/// anything but a double quote, a carriage return or a line feed, so the
/// first quote after the opening one ends it and a URI containing a quote
/// simply cannot be written.
fn closingQuote(text: []const u8) ?usize {
    var i: usize = 1;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '"' => return i,
            '\r', '\n' => return null,
            else => {},
        }
    }
    return null;
}

/// A `decimal-integer`: 1 to 20 digits, no sign, no leading `+`, fitting a
/// `u64`.
pub fn decimalInteger(text: []const u8) error{InvalidInteger}!u64 {
    if (text.len == 0 or text.len > 20) return error.InvalidInteger;
    var value: u64 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return error.InvalidInteger;
        value = std.math.mul(u64, value, 10) catch return error.InvalidInteger;
        value = std.math.add(u64, value, c - '0') catch return error.InvalidInteger;
    }
    return value;
}

/// A `signed-decimal-floating-point`, and by inclusion the unsigned kind.
///
/// Stricter than `std.fmt.parseFloat`, on purpose: that accepts `inf`, `nan`,
/// `0x1p3` and an exponent, none of which §4.2 allows, and a duration of
/// `inf` propagates into arithmetic instead of being rejected at the line
/// that wrote it.
pub fn signedFloat(text: []const u8) error{InvalidFloat}!f64 {
    var rest = text;
    var negative = false;
    if (rest.len > 0 and (rest[0] == '-' or rest[0] == '+')) {
        negative = rest[0] == '-';
        rest = rest[1..];
    }
    if (rest.len == 0) return error.InvalidFloat;

    var seen_digit = false;
    var seen_point = false;
    for (rest) |c| {
        switch (c) {
            '0'...'9' => seen_digit = true,
            '.' => {
                if (seen_point) return error.InvalidFloat;
                seen_point = true;
            },
            else => return error.InvalidFloat,
        }
    }
    if (!seen_digit) return error.InvalidFloat;

    const magnitude = std.fmt.parseFloat(f64, rest) catch return error.InvalidFloat;
    return if (negative) -magnitude else magnitude;
}

/// The digits of a `hexadecimal-sequence`, with the `0x` taken off.
fn hexDigits(text: []const u8) error{InvalidHex}![]const u8 {
    if (text.len < 3) return error.InvalidHex;
    if (text[0] != '0' or (text[1] != 'x' and text[1] != 'X')) return error.InvalidHex;
    const digits = text[2..];
    for (digits) |c| _ = try hexDigit(c);
    return digits;
}

fn hexDigit(c: u8) error{InvalidHex}!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHex,
    };
}

/// Match `text` against `E`'s tag names, with `_` in a tag standing for `-`
/// in the text and the comparison done in upper case.
///
/// This is what lets `VIDEO-RANGE=PQ` become `.pq` and `TYPE=CLOSED-CAPTIONS`
/// become `.closed_captions` without a name table beside every enum. A tag
/// whose spelling cannot be reached this way — there are a few, like
/// `SAMPLE-AES-CTR` — is spelled out in the enum with `@"..."`.
pub fn parseEnumerated(comptime E: type, text: []const u8) error{UnknownValue}!E {
    inline for (@typeInfo(E).@"enum".fields) |field| {
        if (eqlEnumerated(field.name, text)) return @field(E, field.name);
    }
    return error.UnknownValue;
}

/// Write `value`'s tag the way the specification spells it: upper case, with
/// `_` back to `-`.
pub fn writeEnumerated(w: *Io.Writer, value: anytype) Io.Writer.Error!void {
    for (@tagName(value)) |c| {
        try w.writeByte(if (c == '_') '-' else std.ascii.toUpper(c));
    }
}

fn eqlEnumerated(comptime tag: []const u8, text: []const u8) bool {
    if (tag.len != text.len) return false;
    for (tag, text) |t, c| {
        const want = if (t == '_') '-' else std.ascii.toUpper(t);
        if (want != std.ascii.toUpper(c)) return false;
    }
    return true;
}

// -- tests -----------------------------------------------------------------

const testing = std.testing;

/// Collect a whole list, for the tests below.
fn collect(list: []const u8, out: *std.ArrayList(Attribute)) !void {
    var it: Iterator = .init(list);
    while (try it.next()) |a| try out.append(testing.allocator, a);
}

test "a list of one" {
    var found: std.ArrayList(Attribute) = .empty;
    defer found.deinit(testing.allocator);
    try collect("BANDWIDTH=1280000", &found);
    try testing.expectEqual(@as(usize, 1), found.items.len);
    try testing.expectEqualStrings("BANDWIDTH", found.items[0].name);
    try testing.expectEqual(@as(u64, 1280000), try found.items[0].integer());
}

test "a comma inside a quoted string does not end the attribute" {
    var found: std.ArrayList(Attribute) = .empty;
    defer found.deinit(testing.allocator);
    try collect("CODECS=\"avc1.4d401e,mp4a.40.2\",BANDWIDTH=1", &found);
    try testing.expectEqual(@as(usize, 2), found.items.len);
    try testing.expectEqualStrings("avc1.4d401e,mp4a.40.2", found.items[0].string());
    try testing.expectEqualStrings("BANDWIDTH", found.items[1].name);
}

test "the quotes are kept in raw and dropped by string" {
    var it: Iterator = .init("URI=\"a.ts\"");
    const a = (try it.next()).?;
    try testing.expectEqualStrings("\"a.ts\"", a.raw);
    try testing.expectEqualStrings("a.ts", a.string());
    try testing.expect(a.isQuoted());
}

test "an unquoted value where a quoted one belongs is accepted" {
    // Not legal, and written by enough tools that refusing it would lose
    // playlists that every player reads.
    var it: Iterator = .init("URI=a.ts");
    const a = (try it.next()).?;
    try testing.expect(!a.isQuoted());
    try testing.expectEqualStrings("a.ts", a.string());
}

test "space after a comma is tolerated" {
    var found: std.ArrayList(Attribute) = .empty;
    defer found.deinit(testing.allocator);
    try collect("A=1, B=2 , C=\"3\"", &found);
    try testing.expectEqual(@as(usize, 3), found.items.len);
    try testing.expectEqualStrings("1", found.items[0].string());
    try testing.expectEqualStrings("2", found.items[1].string());
    try testing.expectEqualStrings("3", found.items[2].string());
}

test "an empty value is an empty value, not an error" {
    // `CLOSED-CAPTIONS=NONE` has a value; `A=` does not, and a strict reader
    // would refuse it. It parses to the empty string here so that the tag
    // that owns it decides, since for a quoted-string attribute an empty
    // value is legal.
    var it: Iterator = .init("A=,B=1");
    const a = (try it.next()).?;
    try testing.expectEqualStrings("", a.raw);
    const b = (try it.next()).?;
    try testing.expectEqualStrings("1", b.raw);
}

test "a name that is not a name" {
    var it: Iterator = .init("bad name=1");
    try testing.expectError(error.InvalidAttributeName, it.next());

    var no_equals: Iterator = .init("BANDWIDTH");
    try testing.expectError(error.MissingValue, no_equals.next());

    var bare: Iterator = .init("YES,A=1");
    try testing.expectError(error.InvalidAttributeName, bare.next());
}

test "an unterminated quoted string" {
    var it: Iterator = .init("URI=\"a.ts");
    try testing.expectError(error.UnterminatedQuotedString, it.next());

    var newline: Iterator = .init("URI=\"a\nb\"");
    try testing.expectError(error.UnterminatedQuotedString, newline.next());

    // A closing quote followed by something that is not a comma: the value
    // has run into whatever came after it.
    var trailing: Iterator = .init("URI=\"a\"x,B=1");
    try testing.expectError(error.UnterminatedQuotedString, trailing.next());
}

test "decimal integers" {
    try testing.expectEqual(@as(u64, 0), try decimalInteger("0"));
    try testing.expectEqual(@as(u64, 18446744073709551615), try decimalInteger("18446744073709551615"));
    try testing.expectError(error.InvalidInteger, decimalInteger(""));
    try testing.expectError(error.InvalidInteger, decimalInteger("-1"));
    try testing.expectError(error.InvalidInteger, decimalInteger("1.0"));
    // 21 digits: over the length the specification allows, and over `u64`.
    try testing.expectError(error.InvalidInteger, decimalInteger("100000000000000000000"));
    // 20 digits and still too big, which is the case the length check alone
    // would let through.
    try testing.expectError(error.InvalidInteger, decimalInteger("99999999999999999999"));
}

test "floats, and what is not one" {
    try testing.expectEqual(@as(f64, 10), try signedFloat("10"));
    try testing.expectEqual(@as(f64, 9.009), try signedFloat("9.009"));
    try testing.expectEqual(@as(f64, -1), try signedFloat("-1"));
    try testing.expectEqual(@as(f64, 0.5), try signedFloat(".5"));
    // Everything `parseFloat` would take and §4.2 does not.
    try testing.expectError(error.InvalidFloat, signedFloat("inf"));
    try testing.expectError(error.InvalidFloat, signedFloat("nan"));
    try testing.expectError(error.InvalidFloat, signedFloat("1e3"));
    try testing.expectError(error.InvalidFloat, signedFloat("0x1p3"));
    try testing.expectError(error.InvalidFloat, signedFloat("1.2.3"));
    try testing.expectError(error.InvalidFloat, signedFloat("-"));
    try testing.expectError(error.InvalidFloat, signedFloat(""));
}

test "a negative duration is refused where the specification says unsigned" {
    var it: Iterator = .init("DURATION=-1");
    const a = (try it.next()).?;
    try testing.expectError(error.InvalidFloat, a.float());
    try testing.expectEqual(@as(f64, -1), try a.signed());
}

test "hexadecimal sequences" {
    var it: Iterator = .init("IV=0x9c7db8778570d05c3f4a0e6e0bcc5b5c");
    const a = (try it.next()).?;
    try testing.expectEqual(@as(u128, 0x9c7db8778570d05c3f4a0e6e0bcc5b5c), try a.hex());

    var buffer: [16]u8 = undefined;
    const bytes = try a.hexBytes(&buffer);
    try testing.expectEqual(@as(usize, 16), bytes.len);
    try testing.expectEqual(@as(u8, 0x9c), bytes[0]);
    try testing.expectEqual(@as(u8, 0x5c), bytes[15]);
}

test "an odd number of hex digits pads on the left" {
    var it: Iterator = .init("X=0xABC");
    const a = (try it.next()).?;
    var buffer: [8]u8 = undefined;
    const bytes = try a.hexBytes(&buffer);
    try testing.expectEqualSlices(u8, &.{ 0x0a, 0xbc }, bytes);
    try testing.expectEqual(@as(u128, 0xabc), try a.hex());
}

test "hex that is not hex" {
    var it: Iterator = .init("A=0x,B=12,C=0xZZ,D=0X1f");
    const empty = (try it.next()).?;
    try testing.expectError(error.InvalidHex, empty.hex());
    const no_prefix = (try it.next()).?;
    try testing.expectError(error.InvalidHex, no_prefix.hex());
    const not_digits = (try it.next()).?;
    try testing.expectError(error.InvalidHex, not_digits.hex());
    const upper_x = (try it.next()).?;
    try testing.expectEqual(@as(u128, 0x1f), try upper_x.hex());
}

test "a hex sequence too long for a u128 still decodes to bytes" {
    var it: Iterator = .init("SCTE35-OUT=0x" ++ "AB" ** 20);
    const a = (try it.next()).?;
    try testing.expectError(error.InvalidHex, a.hex());
    var buffer: [32]u8 = undefined;
    const bytes = try a.hexBytes(&buffer);
    try testing.expectEqual(@as(usize, 20), bytes.len);
    try testing.expectEqual(@as(u8, 0xab), bytes[0]);

    var small: [4]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, a.hexBytes(&small));
}

test "resolutions" {
    try testing.expectEqual(Resolution{ .width = 1920, .height = 1080 }, try Resolution.parse("1920x1080"));
    try testing.expectError(error.InvalidResolution, Resolution.parse("1920"));
    try testing.expectError(error.InvalidResolution, Resolution.parse("1920X1080"));
    try testing.expectError(error.InvalidResolution, Resolution.parse("x1080"));

    var buffer: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try w.print("{f}", .{Resolution{ .width = 640, .height = 360 }});
    try testing.expectEqualStrings("640x360", w.buffered());
}

const Example = enum { none, closed_captions, @"SAMPLE-AES-CTR" };

test "enumerated strings map underscores to hyphens" {
    try testing.expectEqual(Example.none, try parseEnumerated(Example, "NONE"));
    try testing.expectEqual(Example.closed_captions, try parseEnumerated(Example, "CLOSED-CAPTIONS"));
    try testing.expectEqual(Example.@"SAMPLE-AES-CTR", try parseEnumerated(Example, "SAMPLE-AES-CTR"));
    try testing.expectError(error.UnknownValue, parseEnumerated(Example, "WHAT"));

    var buffer: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try writeEnumerated(&w, Example.closed_captions);
    try testing.expectEqualStrings("CLOSED-CAPTIONS", w.buffered());
}

test "booleans" {
    var it: Iterator = .init("A=YES,B=NO,C=yes");
    try testing.expectEqual(true, try (try it.next()).?.boolean());
    try testing.expectEqual(false, try (try it.next()).?.boolean());
    // Case-sensitive: `yes` is not a value §4.2 defines.
    try testing.expectError(error.UnknownValue, (try it.next()).?.boolean());
}

test "words and comma-separated words" {
    var it: Iterator = .init("REQ-VIDEO-LAYOUT=\"CH-STEREO CH-MONO\",CHARACTERISTICS=\"public.a,public.b\"");

    var layout = (try it.next()).?.words();
    try testing.expectEqualStrings("CH-STEREO", layout.next().?);
    try testing.expectEqualStrings("CH-MONO", layout.next().?);
    try testing.expectEqual(@as(?[]const u8, null), layout.next());

    var characteristics = (try it.next()).?.commaWords();
    try testing.expectEqualStrings("public.a", characteristics.next().?);
    try testing.expectEqualStrings("public.b", characteristics.next().?);
    try testing.expectEqual(@as(?[]const u8, null), characteristics.next());
}

test "an empty list yields nothing" {
    var it: Iterator = .init("");
    try testing.expectEqual(@as(?Attribute, null), try it.next());

    var spaces: Iterator = .init("   ");
    try testing.expectEqual(@as(?Attribute, null), try spaces.next());
}

test "a trailing comma yields nothing more" {
    var found: std.ArrayList(Attribute) = .empty;
    defer found.deinit(testing.allocator);
    try collect("A=1,", &found);
    try testing.expectEqual(@as(usize, 1), found.items.len);
}

test "offset points at what next will read" {
    var it: Iterator = .init("A=1,BBBB=2");
    try testing.expectEqual(@as(usize, 0), it.offset());
    _ = try it.next();
    try testing.expectEqual(@as(usize, 4), it.offset());
}

test "a space-separated attribute list, as IPTV playlists write one" {
    var it: SpaceIterator = .init("tvg-id=\"bbc1\" tvg-name=\"BBC One\" group-title=\"UK\"");

    const id = it.next().?;
    try testing.expectEqualStrings("tvg-id", id.name);
    try testing.expectEqualStrings("bbc1", id.string());

    // A space inside the quotes does not end the attribute.
    const name = it.next().?;
    try testing.expectEqualStrings("tvg-name", name.name);
    try testing.expectEqualStrings("BBC One", name.string());

    const group = it.next().?;
    try testing.expectEqualStrings("group-title", group.name);
    try testing.expectEqualStrings("UK", group.string());

    try testing.expectEqual(@as(?Attribute, null), it.next());
}

test "an unquoted value in a space-separated list ends at the space" {
    var it: SpaceIterator = .init("a=1  b=2\tc=3");
    try testing.expectEqualStrings("1", it.next().?.string());
    try testing.expectEqualStrings("2", it.next().?.string());
    try testing.expectEqualStrings("3", it.next().?.string());
    try testing.expectEqual(@as(?Attribute, null), it.next());
}

test "a space-separated list stops at what it cannot read, and says so" {
    // No `=` at all.
    var bare: SpaceIterator = .init("a=1 nonsense");
    try testing.expectEqualStrings("1", bare.next().?.string());
    try testing.expectEqual(@as(?Attribute, null), bare.next());
    try testing.expect(bare.stopped_early);

    // An unterminated quoted value.
    var unterminated: SpaceIterator = .init("a=1 b=\"oops");
    try testing.expectEqualStrings("1", unterminated.next().?.string());
    try testing.expectEqual(@as(?Attribute, null), unterminated.next());
    try testing.expect(unterminated.stopped_early);

    // A name with a space in it, which means the value before it ran on.
    var ran_on: SpaceIterator = .init("a=1 b c=2");
    try testing.expectEqualStrings("1", ran_on.next().?.string());
    try testing.expectEqual(@as(?Attribute, null), ran_on.next());
    try testing.expect(ran_on.stopped_early);

    // Reaching the end is not giving up.
    var complete: SpaceIterator = .init("a=1 b=2");
    while (complete.next()) |_| {}
    try testing.expect(!complete.stopped_early);

    var empty: SpaceIterator = .init("");
    try testing.expectEqual(@as(?Attribute, null), empty.next());
    try testing.expect(!empty.stopped_early);
}

test "what can and cannot be written inside quotes" {
    try testing.expect(quotable("https://example.com/a.ts"));
    try testing.expect(quotable(""));
    // §4.2 gives a quoted-string no escape sequence, so none of these can be
    // written as one.
    try testing.expect(!quotable("a\"b"));
    try testing.expect(!quotable("a\rb"));
    try testing.expect(!quotable("a\nb"));
}

test "a carriage return is whitespace, so a value cannot end with one" {
    // The reason: an unquoted value is written back as it stands, and one at
    // the end of its line is followed by a `\n`. `METHOD=AES-128\r` would be
    // written `METHOD=AES-128\r\n` and read again as `AES-128`.
    var it: Iterator = .init("METHOD=AES-128\r,A=1");
    try testing.expectEqualStrings("AES-128", (try it.next()).?.string());
    try testing.expectEqualStrings("1", (try it.next()).?.string());

    var trailing: Iterator = .init("A=1\r");
    try testing.expectEqualStrings("1", (try trailing.next()).?.string());

    var space: SpaceIterator = .init("a=1\r b=2\r");
    try testing.expectEqualStrings("1", space.next().?.string());
    try testing.expectEqualStrings("2", space.next().?.string());
    try testing.expectEqual(@as(?Attribute, null), space.next());
    try testing.expect(!space.stopped_early);

    // A quoted value needs none of this: §4.2 says a quoted-string holds no
    // carriage return, so an unterminated one is what that would be.
    var quoted: Iterator = .init("A=\"1\r\"");
    try testing.expectError(error.UnterminatedQuotedString, quoted.next());
}
