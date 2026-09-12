// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The tags, one Zig type each.
//!
//! Every tag in RFC 8216 and in the low-latency extensions that followed it
//! is here, with the attributes its definition gives it as typed fields and
//! everything else kept in `extra` so that a playlist read and written again
//! does not lose what this library had not heard of.
//!
//! # Three things every attribute-bearing tag does the same way
//!
//! **A required attribute is a field with a default.** `StreamInf.bandwidth`
//! is required by §4.3.4.2 and is a `u64` that starts at zero, not an
//! optional. A playlist that leaves it out parses, gets a
//! `missing_required_attribute` problem, and carries on — because the
//! alternative is refusing a playlist that every player in the world plays.
//! The field's doc comment says which attributes are required.
//!
//! **An unknown attribute is kept, not dropped.** `extra` holds them in the
//! order they were written, with their values exactly as written, quotes and
//! all. `write` puts them back after the known ones.
//!
//! **An unknown *value* of a known attribute is kept too.** That is what
//! `Enumerated` is for: `METHOD=AES-256` is not in RFC 8216, and a field
//! typed `EncryptionMethod` could only either reject it or forget it.
//!
//! # What `write` normalises
//!
//! Attributes come out in the order this file lists them, which is the order
//! RFC 8216 lists them, rather than the order they were read; a
//! `quoted-string` attribute written without its quotes gains them; a
//! `YES`/`NO` attribute whose value is its default is left out. So writing a
//! playlist and reading it again gives an equal structure rather than
//! identical bytes, which is the property `tests/playlists.zig` asserts.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const attribute = @import("attribute.zig");
const time = @import("time.zig");
const Diagnostics = @import("Diagnostics.zig");

pub const Attribute = attribute.Attribute;
pub const Resolution = attribute.Resolution;
pub const DateTime = time.DateTime;

// -- reporting -------------------------------------------------------------

/// Where a parse writes down what it had to tolerate.
///
/// Carries the arena the parsed structures are built in, the line being
/// parsed, and somewhere to put problems. The count of `.invalid` problems
/// is kept here as well as in the `Diagnostics`, because
/// `ParseOptions.strict` has to work for a caller who asked for no
/// diagnostics at all.
pub const Reporter = struct {
    arena: Allocator,
    diagnostics: ?*Diagnostics = null,
    /// The line whose tag is being parsed, counting from one.
    line: u32 = 0,
    /// How many `.invalid` problems have been reported.
    invalid_count: u32 = 0,

    /// Understood, and not what the specification says.
    pub fn warn(r: *Reporter, kind: Diagnostics.Kind, detail: []const u8) void {
        if (r.diagnostics) |d| d.add(.{
            .line = r.line,
            .severity = .warning,
            .kind = kind,
            .detail = detail,
        });
    }

    /// Not understood: something was skipped or defaulted.
    pub fn invalid(r: *Reporter, kind: Diagnostics.Kind, detail: []const u8) void {
        r.invalid_count +|= 1;
        if (r.diagnostics) |d| d.add(.{
            .line = r.line,
            .severity = .invalid,
            .kind = kind,
            .detail = detail,
        });
    }

    /// A tag that needs a higher `#EXT-X-VERSION` than the playlist
    /// declares.
    ///
    /// A warning rather than an `.invalid`, because nothing was lost: the
    /// tag parsed and this library will act on it. It is worth saying all
    /// the same, since §7 tells a player to refuse such a playlist outright
    /// — so the file works here and fails in the field.
    pub fn versionConflict(
        r: *Reporter,
        tag_name: []const u8,
        needed: u64,
        declared: u64,
    ) void {
        if (r.diagnostics) |d| d.addPrint(
            r.line,
            .warning,
            .version_conflict,
            "{s} needs #EXT-X-VERSION:{d} and the playlist declares {d}",
            .{ tag_name, needed, declared },
        );
    }
};

// -- values that are not plain numbers or strings --------------------------

/// An `enumerated-string` whose known values are `E`, keeping anything else
/// as it was written.
///
/// The specification adds values to these lists as it goes — `SAMPLE-AES-CTR`
/// to `METHOD`, `PQ` to `VIDEO-RANGE`, `RAW` to `FORMAT` — and a playlist
/// using one this library has not heard of is a playlist that should still
/// survive being rewritten. A plain enum field could only reject such a value
/// or forget it; this keeps it.
///
/// ```
/// switch (key.method) {
///     .known => |m| if (m == .none) ...,
///     .unknown => |text| std.log.warn("unknown method {s}", .{text}),
/// }
/// ```
///
/// or, when only the known values matter, `if (key.method.value()) |m| ...`.
pub fn Enumerated(comptime E: type) type {
    return union(enum) {
        /// One of the values this library knows.
        known: E,
        /// A value it does not, borrowed from the playlist so that `write`
        /// can put it back.
        unknown: []const u8,

        const Self = @This();

        /// The enum this is an open version of, and the marker the generic
        /// attribute reader uses to recognise the type.
        pub const Known = E;

        /// Never fails: an unrecognised value becomes `.unknown`. The caller
        /// reports `unknown_enumerated_value` if it wants to.
        pub fn parse(text: []const u8) Self {
            if (attribute.parseEnumerated(E, text)) |known| {
                return .{ .known = known };
            } else |_| {
                return .{ .unknown = text };
            }
        }

        /// The known value, or null if the playlist used one this library
        /// does not know.
        pub fn value(self: Self) ?E {
            return switch (self) {
                .known => |e| e,
                .unknown => null,
            };
        }

        /// Whether this is exactly `e`. False for an unknown value, which is
        /// what makes `if (media.type.is(.audio))` safe to write.
        pub fn is(self: Self, e: E) bool {
            return switch (self) {
                .known => |known| known == e,
                .unknown => false,
            };
        }

        pub fn eql(a: Self, b: Self) bool {
            return switch (a) {
                .known => |x| switch (b) {
                    .known => |y| x == y,
                    .unknown => false,
                },
                .unknown => |x| switch (b) {
                    .known => false,
                    .unknown => |y| std.mem.eql(u8, x, y),
                },
            };
        }

        pub fn format(self: Self, w: *Io.Writer) Io.Writer.Error!void {
            switch (self) {
                .known => |e| try attribute.writeEnumerated(w, e),
                .unknown => |text| try w.writeAll(text),
            }
        }
    };
}

/// How a segment is encrypted: `#EXT-X-KEY`'s and `#EXT-X-SESSION-KEY`'s
/// `METHOD`, from §4.3.2.4.
pub const EncryptionMethod = enum {
    /// Not encrypted. The only value for which `URI` is absent, and a `KEY`
    /// with this method cancels the one before it.
    none,
    aes_128,
    sample_aes,
    /// Added after RFC 8216, for fMP4 with common encryption.
    sample_aes_ctr,
};

/// What a rendition carries: `#EXT-X-MEDIA`'s `TYPE`, from §4.3.4.1.
pub const MediaType = enum { audio, video, subtitles, closed_captions };

/// `#EXT-X-PLAYLIST-TYPE`, from §4.3.3.5.
pub const PlaylistType = enum {
    /// Segments may be added to the end and nothing already there will
    /// change.
    event,
    /// The playlist will not change at all.
    vod,
};

/// `HDCP-LEVEL`, from §4.3.4.2.
pub const HdcpLevel = enum {
    /// No output copy protection required.
    none,
    type_0,
    /// Added after RFC 8216.
    type_1,
};

/// `VIDEO-RANGE`, from RFC 8216 §4.3.4.2 and the versions after it.
pub const VideoRange = enum {
    /// Standard dynamic range.
    sdr,
    /// Hybrid log-gamma.
    hlg,
    /// Perceptual quantiser, which is HDR10 and Dolby Vision.
    pq,
};

/// What an `#EXT-X-PRELOAD-HINT` is hinting at.
pub const PreloadHintType = enum { part, map };

/// `#EXT-X-SESSION-DATA`'s `FORMAT`, which says how the resource at `URI` is
/// encoded.
pub const SessionDataFormat = enum { json, raw };

/// A range of bytes within a resource: `#EXT-X-BYTERANGE` from §4.3.2.2, and
/// the `BYTERANGE` attribute of `#EXT-X-MAP` and `#EXT-X-PART`.
pub const ByteRange = struct {
    /// How many bytes.
    length: u64,
    /// Where they start. Absent means "where the last range in this resource
    /// ended", which is only meaningful for a segment whose predecessor came
    /// from the same resource — §4.3.2.2 requires an offset otherwise.
    offset: ?u64 = null,

    pub const ParseError = error{InvalidByteRange};

    /// Read `<length>[@<offset>]`.
    pub fn parse(text: []const u8) ParseError!ByteRange {
        const at = std.mem.findScalar(u8, text, '@') orelse {
            return .{
                .length = attribute.decimalInteger(text) catch return error.InvalidByteRange,
                .offset = null,
            };
        };
        return .{
            .length = attribute.decimalInteger(text[0..at]) catch return error.InvalidByteRange,
            .offset = attribute.decimalInteger(text[at + 1 ..]) catch return error.InvalidByteRange,
        };
    }

    pub fn format(b: ByteRange, w: *Io.Writer) Io.Writer.Error!void {
        if (b.offset) |offset| {
            try w.print("{d}@{d}", .{ b.length, offset });
        } else {
            try w.print("{d}", .{b.length});
        }
    }

    /// Where this range ends, or null if it has no offset to end relative to.
    pub fn end(b: ByteRange) ?u64 {
        const offset = b.offset orelse return null;
        return std.math.add(u64, offset, b.length) catch null;
    }
};

/// `CLOSED-CAPTIONS`, which is the one attribute in the specification whose
/// value is either a `quoted-string` or an `enumerated-string`.
pub const ClosedCaptions = union(enum) {
    /// `CLOSED-CAPTIONS=NONE`, unquoted, which §4.3.4.2 says means the
    /// variant has no closed captions and that *no* variant may then have
    /// any.
    none,
    /// A quoted `GROUP-ID` of an `#EXT-X-MEDIA` with `TYPE=CLOSED-CAPTIONS`.
    group: []const u8,

    pub fn format(c: ClosedCaptions, w: *Io.Writer) Io.Writer.Error!void {
        switch (c) {
            .none => try w.writeAll("NONE"),
            .group => |g| try w.print("\"{s}\"", .{g}),
        }
    }

    pub fn eql(a: ClosedCaptions, b: ClosedCaptions) bool {
        return switch (a) {
            .none => b == .none,
            .group => |x| switch (b) {
                .none => false,
                .group => |y| std.mem.eql(u8, x, y),
            },
        };
    }
};

// -- the generic attribute reader and writer -------------------------------

/// How one attribute maps onto one field of a tag's struct.
///
/// The value's *type* comes from the field rather than from here, which is
/// what keeps the table short: a `?u64` field is a `decimal-integer`, a
/// `?f64` is a `decimal-floating-point`, a `bool` is `YES`/`NO`, an
/// `Enumerated(E)` is an `enumerated-string`, and so on. Only the things the
/// type cannot say are written down.
pub const Spec = struct {
    /// The name as RFC 8216 spells it.
    attribute: []const u8,
    /// The field of the tag struct it goes in.
    field: []const u8,
    /// Whether its absence is a `missing_required_attribute` problem. It
    /// does not stop the tag parsing: the field keeps its default.
    required: bool = false,
    /// Whether the value is a `quoted-string`. Affects `write`, which adds
    /// the quotes, and `parse`, which reports `missing_quotes` if they were
    /// not there.
    quoted: bool = false,
    /// Whether a floating-point value may be negative, which only
    /// `TIME-OFFSET` may be.
    signed: bool = false,
};

/// The default `special` for a tag with no attribute that needs hand
/// treatment: it consumes nothing.
pub const NoSpecial = struct {
    pub fn consume(_: anytype, _: *Reporter, _: Attribute) Allocator.Error!bool {
        return false;
    }
};

/// The type a field holds once an `?Optional` has been unwrapped.
fn Unwrapped(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

/// Read one attribute's value as `F`.
///
/// Returns null when the value is not of the type it should be, having
/// reported it: the field then keeps its default rather than the tag failing
/// to parse.
fn decode(comptime F: type, comptime spec: Spec, r: *Reporter, a: Attribute) ?F {
    if (F == []const u8) {
        if (spec.quoted and !a.isQuoted()) {
            // An unquoted value where a `quoted-string` belongs is
            // tolerated -- but only when it can be quoted on the way out.
            // §4.2 gives a quoted-string no escape sequence, so a value
            // holding a double quote or a carriage return cannot be written
            // back and read as itself, and accepting one here would mean
            // producing a playlist that cannot be written.
            //
            // A value that *was* quoted needs no such check: the closing
            // quote is the first one, and a carriage return inside the
            // quotes is what makes the string unterminated.
            if (!attribute.quotable(a.string())) {
                r.invalid(.invalid_attribute_value, a.name);
                return null;
            }
            r.warn(.missing_quotes, a.name);
        }
        return a.string();
    }
    if (F == u64) {
        return a.integer() catch {
            r.invalid(.invalid_attribute_value, a.name);
            return null;
        };
    }
    if (F == f64) {
        const parsed = if (spec.signed) a.signed() else a.float();
        return parsed catch {
            r.invalid(.invalid_attribute_value, a.name);
            return null;
        };
    }
    if (F == bool) {
        return a.boolean() catch {
            r.invalid(.invalid_attribute_value, a.name);
            return null;
        };
    }
    if (F == Resolution) {
        return a.resolution() catch {
            r.invalid(.invalid_attribute_value, a.name);
            return null;
        };
    }
    if (F == ByteRange) {
        if (spec.quoted and !a.isQuoted()) r.warn(.missing_quotes, a.name);
        return ByteRange.parse(a.string()) catch {
            r.invalid(.invalid_attribute_value, a.name);
            return null;
        };
    }
    if (F == DateTime) {
        if (spec.quoted and !a.isQuoted()) r.warn(.missing_quotes, a.name);
        return DateTime.parse(a.string()) catch {
            r.invalid(.invalid_attribute_value, a.name);
            return null;
        };
    }
    if (@typeInfo(F) == .@"union" and @hasDecl(F, "Known")) {
        const value = F.parse(a.string());
        if (value == .unknown) r.warn(.unknown_enumerated_value, a.name);
        return value;
    }
    @compileError("no attribute decoder for " ++ @typeName(F));
}

/// Write one attribute's value.
fn encode(comptime F: type, comptime spec: Spec, w: *Io.Writer, value: F) Io.Writer.Error!void {
    if (F == []const u8) {
        if (spec.quoted) {
            try w.print("\"{s}\"", .{value});
        } else {
            try w.writeAll(value);
        }
        return;
    }
    if (F == u64) return w.print("{d}", .{value});
    // `{d}` on a float is the shortest decimal that reads back as the same
    // `f64`, and never uses an exponent — so it always re-parses under the
    // grammar in §4.2, which has no exponent in it.
    if (F == f64) return w.print("{d}", .{value});
    if (F == bool) return w.writeAll(if (value) "YES" else "NO");
    if (F == Resolution) return w.print("{f}", .{value});
    if (F == ByteRange or F == DateTime) {
        if (spec.quoted) {
            try w.print("\"{f}\"", .{value});
        } else {
            try w.print("{f}", .{value});
        }
        return;
    }
    if (@typeInfo(F) == .@"union" and @hasDecl(F, "Known")) return w.print("{f}", .{value});
    @compileError("no attribute encoder for " ++ @typeName(F));
}

/// Read an attribute list into a `T`, by the table `specs`.
///
/// `Special` gets a look at every attribute before the table does, and
/// returns true for the ones it took — which is how `#EXT-X-DATERANGE`
/// collects its `X-` client attributes and how `CLOSED-CAPTIONS` is read as
/// either a quoted string or `NONE`.
///
/// Only ever fails for lack of memory. Everything else is reported and
/// defaulted, so that a tag always yields a `T`.
pub fn parseAttributes(
    comptime T: type,
    comptime specs: []const Spec,
    comptime Special: type,
    r: *Reporter,
    value: []const u8,
) Allocator.Error!T {
    var out: T = .{};
    var seen = [1]bool{false} ** specs.len;
    var extra: std.ArrayList(Attribute) = .empty;

    var it: attribute.Iterator = .init(value);
    attributes: while (true) {
        const next = it.next() catch |err| {
            r.invalid(.invalid_attribute_list, @errorName(err));
            break;
        };
        const a = next orelse break;

        if (try Special.consume(&out, r, a)) continue;

        inline for (specs, 0..) |spec, i| {
            if (eqlName(a.name, spec.attribute)) {
                const F = Unwrapped(@FieldType(T, spec.field));
                if (decode(F, spec, r, a)) |decoded| {
                    @field(out, spec.field) = decoded;
                    seen[i] = true;
                }
                continue :attributes;
            }
        }

        r.warn(.unknown_attribute, a.name);
        try extra.append(r.arena, a);
    }

    inline for (specs, 0..) |spec, i| {
        if (spec.required and !seen[i]) r.invalid(.missing_required_attribute, spec.attribute);
    }

    // `items` rather than `toOwnedSlice`: the list lives in the arena, so
    // shrinking it buys nothing, and `toOwnedSlice` can move the allocation
    // — which would dangle anything already pointing into it.
    out.extra = extra.items;
    return out;
}

/// Write an attribute list from a `T`, by the table `specs`.
///
/// Emits the fields in the order `specs` lists them, which is the order
/// RFC 8216 lists them in, and then everything in `extra`. Which fields are
/// emitted follows from their types: an optional one when it is not null, a
/// `bool` when it is true, and anything else always — so a required
/// attribute is always written and a `YES`/`NO` one at its default is left
/// out.
pub fn writeAttributes(
    comptime T: type,
    comptime specs: []const Spec,
    comptime Special: type,
    w: *Io.Writer,
    value: T,
) Io.Writer.Error!void {
    var wrote_any = false;

    inline for (specs) |spec| {
        const Field = @FieldType(T, spec.field);
        const F = Unwrapped(Field);
        const field = @field(value, spec.field);
        const present: ?F = if (Field != F)
            field
        else if (F == bool)
            (if (field) field else null)
        else
            field;
        if (present) |inner| {
            if (wrote_any) try w.writeByte(',');
            wrote_any = true;
            try w.print("{s}=", .{spec.attribute});
            try encode(F, spec, w, inner);
        }
    }

    if (@hasDecl(Special, "write")) {
        wrote_any = try Special.write(w, value, wrote_any);
    }

    for (value.extra) |a| {
        if (wrote_any) try w.writeByte(',');
        wrote_any = true;
        // `raw` rather than `string`, so an unknown attribute comes back
        // exactly as it went in: quotes if it had them, none if it did not.
        try w.print("{s}={s}", .{ a.name, a.raw });
    }
}

/// Grow an arena-allocated slice by one.
///
/// For the handful of places a tag collects values whose names cannot be
/// known in advance — `#EXT-X-DATERANGE`'s `X-` attributes — and so cannot
/// be counted before the list is walked. Reallocating for every item is
/// quadratic, which is the right trade for a list that is never more than a
/// few long and saves a second pass over the attribute list.
fn append(comptime T: type, arena: Allocator, slice: []const T, item: T) Allocator.Error![]const T {
    const grown = try arena.realloc(@constCast(slice), slice.len + 1);
    grown[slice.len] = item;
    return grown;
}

/// Whether an attribute list mentions `name` at all, however malformed the
/// rest of it is.
///
/// For the handful of rules that turn on an attribute being *present* rather
/// than on its value. §4.3.4.1's is the one that matters: "if the AUTOSELECT
/// attribute is present, its value MUST be YES if the value of the DEFAULT
/// attribute is YES" — so `DEFAULT=YES` with no `AUTOSELECT` at all is
/// perfectly legal, and RFC 8216's own §8.7 example is full of it, while
/// `DEFAULT=YES,AUTOSELECT=NO` is a rendition no player will pick. A `bool`
/// field cannot tell the two apart, and making it a `?bool` would put that
/// distinction in front of every caller for the sake of one rule.
pub fn hasAttribute(list: []const u8, name: []const u8) bool {
    var it: attribute.Iterator = .init(list);
    while (it.next() catch return false) |a| {
        if (eqlName(a.name, name)) return true;
    }
    return false;
}

/// Compare an attribute name with the specification's spelling, ignoring
/// case.
///
/// §4.2 says the name is upper case, and playlists that write `bandwidth`
/// exist; matching them costs nothing, and `write` emits the specification's
/// spelling either way.
pub fn eqlName(found: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(found, expected);
}

// -- the tags --------------------------------------------------------------

/// `#EXT-X-KEY` from §4.3.2.4, and `#EXT-X-SESSION-KEY` from §4.3.4.5, which
/// have the same attributes and differ only in where they may appear.
pub const Key = struct {
    /// `METHOD`, required. `.none` means the segments are not encrypted and
    /// cancels any key before it.
    method: Enumerated(EncryptionMethod) = .{ .known = .none },
    /// `URI`, required unless `method` is `.none`.
    uri: ?[]const u8 = null,
    /// `IV`, kept as the `0x…` text it was written as rather than as a
    /// number, so that the digit case and any leading zeroes survive a
    /// rewrite. `initialisationVector` decodes it.
    iv: ?[]const u8 = null,
    /// `KEYFORMAT`. Absent means `"identity"`, which §4.3.2.4 makes the
    /// default.
    keyformat: ?[]const u8 = null,
    keyformatversions: ?[]const u8 = null,
    extra: []const Attribute = &.{},

    pub const specs = [_]Spec{
        .{ .attribute = "METHOD", .field = "method", .required = true },
        .{ .attribute = "URI", .field = "uri", .quoted = true },
        .{ .attribute = "IV", .field = "iv" },
        .{ .attribute = "KEYFORMAT", .field = "keyformat", .quoted = true },
        .{ .attribute = "KEYFORMATVERSIONS", .field = "keyformatversions", .quoted = true },
    };

    pub fn parse(r: *Reporter, value: []const u8) Allocator.Error!Key {
        const key = try parseAttributes(Key, &specs, NoSpecial, r, value);
        // §4.3.2.4: URI is required unless the method is NONE, and is
        // meaningless when it is.
        if (key.method.is(.none)) {
            if (key.uri != null) r.warn(.attribute_not_allowed, "URI with METHOD=NONE");
        } else if (key.uri == null) {
            r.invalid(.missing_required_attribute, "URI");
        }
        return key;
    }

    pub fn write(k: Key, w: *Io.Writer) Io.Writer.Error!void {
        try writeAttributes(Key, &specs, NoSpecial, w, k);
    }

    /// `KEYFORMAT`, or the `"identity"` that §4.3.2.4 says its absence
    /// means.
    ///
    /// Not called `keyformat`, which is the field, nor `format`, which is
    /// what `{f}` looks for.
    pub fn effectiveKeyFormat(k: Key) []const u8 {
        return k.keyformat orelse "identity";
    }

    /// The `IV` as sixteen bytes, big-endian.
    ///
    /// Null when there is no `IV` at all — in which case §5.2 says the
    /// sequence number of the segment is used instead, which this library
    /// does not do for you because it does not know which segment you are
    /// asking about.
    pub fn initialisationVector(k: Key) ?error{InvalidHex}![16]u8 {
        const text = k.iv orelse return null;
        const a: Attribute = .{ .name = "IV", .raw = text };
        var out: [16]u8 = @splat(0);
        const bytes = a.hexBytes(&out) catch |err| return switch (err) {
            error.InvalidHex => error.InvalidHex,
            // Sixteen bytes is the whole buffer, so a sequence too long for
            // it is not an `IV`.
            error.NoSpaceLeft => error.InvalidHex,
        };
        if (bytes.len == 16) return out;
        // Shorter than sixteen bytes: right-align it, since the value is a
        // number.
        var padded: [16]u8 = @splat(0);
        @memcpy(padded[16 - bytes.len ..], bytes);
        return padded;
    }
};

/// `#EXT-X-MAP` from §4.3.2.5: where the initialisation section of the
/// following segments is.
pub const Map = struct {
    /// `URI`, required.
    uri: []const u8 = "",
    /// `BYTERANGE`, a quoted `<length>[@<offset>]`. Absent means the whole
    /// of the resource at `uri`, which §4.3.2.5 says explicitly — so a
    /// missing offset here is not the error it is on `#EXT-X-BYTERANGE`,
    /// where the offset's absence means "carry on from the last sub-range".
    byterange: ?ByteRange = null,
    extra: []const Attribute = &.{},

    pub const specs = [_]Spec{
        .{ .attribute = "URI", .field = "uri", .quoted = true, .required = true },
        .{ .attribute = "BYTERANGE", .field = "byterange", .quoted = true },
    };

    pub fn parse(r: *Reporter, value: []const u8) Allocator.Error!Map {
        return parseAttributes(Map, &specs, NoSpecial, r, value);
    }

    pub fn write(m: Map, w: *Io.Writer) Io.Writer.Error!void {
        try writeAttributes(Map, &specs, NoSpecial, w, m);
    }
};

/// `#EXT-X-DATERANGE` from §4.3.2.7: something that happens over an interval
/// of wall-clock time, which is how an advertisement break is marked.
pub const DateRange = struct {
    /// `ID`, required and unique within the playlist.
    id: []const u8 = "",
    /// `CLASS`, which names a set of attributes and semantics that several
    /// ranges can share.
    class: ?[]const u8 = null,
    /// `START-DATE`, required.
    start_date: ?DateTime = null,
    /// `CUE`, a space-separated list of `PRE`, `POST` and `ONCE`, added
    /// after RFC 8216.
    cue: ?[]const u8 = null,
    /// `END-DATE`. Must equal `start_date` plus `duration` when both are
    /// there, which this library does not check because a playlist whose
    /// arithmetic is a second out is not one to refuse.
    end_date: ?DateTime = null,
    /// `DURATION`, in seconds.
    duration: ?f64 = null,
    /// `PLANNED-DURATION`: what the duration was expected to be, for a range
    /// whose real one is not known yet.
    planned_duration: ?f64 = null,
    /// `SCTE35-CMD`, as the `0x…` text it was written as.
    scte35_cmd: ?[]const u8 = null,
    /// `SCTE35-OUT`, as written.
    scte35_out: ?[]const u8 = null,
    /// `SCTE35-IN`, as written.
    scte35_in: ?[]const u8 = null,
    /// `END-ON-NEXT=YES`: this range ends where the next one of the same
    /// `CLASS` begins.
    end_on_next: bool = false,
    /// The `X-<name>` attributes, which §4.3.2.7 reserves for whoever made
    /// the playlist, in the order they were written. Their values are as
    /// written, quotes and all.
    client: []const Attribute = &.{},
    extra: []const Attribute = &.{},

    pub const specs = [_]Spec{
        .{ .attribute = "ID", .field = "id", .quoted = true, .required = true },
        .{ .attribute = "CLASS", .field = "class", .quoted = true },
        // Not `.required`, although §4.3.2.7 says it is: see `parse`.
        .{ .attribute = "START-DATE", .field = "start_date", .quoted = true },
        .{ .attribute = "CUE", .field = "cue", .quoted = true },
        .{ .attribute = "END-DATE", .field = "end_date", .quoted = true },
        .{ .attribute = "DURATION", .field = "duration" },
        .{ .attribute = "PLANNED-DURATION", .field = "planned_duration" },
        .{ .attribute = "SCTE35-CMD", .field = "scte35_cmd" },
        .{ .attribute = "SCTE35-OUT", .field = "scte35_out" },
        .{ .attribute = "SCTE35-IN", .field = "scte35_in" },
        .{ .attribute = "END-ON-NEXT", .field = "end_on_next" },
    };

    /// The `X-` attributes are not in the table, because there is no
    /// knowing their names: anything beginning `X-` belongs to the playlist's
    /// author and is collected rather than matched.
    const Client = struct {
        pub fn consume(out: *DateRange, r: *Reporter, a: Attribute) Allocator.Error!bool {
            if (!std.ascii.startsWithIgnoreCase(a.name, "X-")) return false;
            out.client = try append(Attribute, r.arena, out.client, a);
            return true;
        }

        pub fn write(w: *Io.Writer, value: DateRange, wrote_any: bool) Io.Writer.Error!bool {
            var any = wrote_any;
            for (value.client) |a| {
                if (any) try w.writeByte(',');
                any = true;
                try w.print("{s}={s}", .{ a.name, a.raw });
            }
            return any;
        }
    };

    pub fn parse(r: *Reporter, value: []const u8) Allocator.Error!DateRange {
        const range = try parseAttributes(DateRange, &specs, Client, r, value);

        // §4.3.2.7 says `START-DATE` is REQUIRED, and RFC 8216's own §8.10
        // example leaves it off: the second of its two tags updates the Date
        // Range that the first one identified by `ID`, and that range's start
        // date is already known. The specification contradicts itself here,
        // so this is a warning rather than an `.invalid` — nothing was lost,
        // there was nothing there to lose, and `strict` should not refuse a
        // playlist the RFC prints as an example.
        if (range.start_date == null) r.warn(.missing_required_attribute, "START-DATE");

        // §4.3.2.7: END-ON-NEXT requires a CLASS, and forbids DURATION and
        // END-DATE, because the next range of that class is what ends it.
        if (range.end_on_next) {
            if (range.class == null) r.invalid(.missing_required_attribute, "CLASS with END-ON-NEXT=YES");
            if (range.duration != null) r.warn(.attribute_not_allowed, "DURATION with END-ON-NEXT=YES");
            if (range.end_date != null) r.warn(.attribute_not_allowed, "END-DATE with END-ON-NEXT=YES");
        }
        return range;
    }

    pub fn write(d: DateRange, w: *Io.Writer) Io.Writer.Error!void {
        try writeAttributes(DateRange, &specs, Client, w, d);
    }

    /// The value of one of the `X-` client attributes, by name, ignoring
    /// case. The quotes are taken off if it had any.
    pub fn clientAttribute(d: DateRange, name: []const u8) ?[]const u8 {
        for (d.client) |a| {
            if (eqlName(a.name, name)) return a.string();
        }
        return null;
    }
};

/// `#EXT-X-PART`: one piece of a segment that is still being produced, from
/// the low-latency extensions to RFC 8216.
pub const Part = struct {
    /// `URI`, required.
    uri: []const u8 = "",
    /// `DURATION`, required, in seconds.
    duration: f64 = 0,
    /// `INDEPENDENT=YES`: this part starts with an independent frame, so a
    /// player may begin here.
    independent: bool = false,
    /// `BYTERANGE`, a quoted `<length>[@<offset>]`.
    byterange: ?ByteRange = null,
    /// `GAP=YES`: the part is not available and must not be fetched.
    gap: bool = false,
    extra: []const Attribute = &.{},

    pub const specs = [_]Spec{
        .{ .attribute = "URI", .field = "uri", .quoted = true, .required = true },
        .{ .attribute = "DURATION", .field = "duration", .required = true },
        .{ .attribute = "INDEPENDENT", .field = "independent" },
        .{ .attribute = "BYTERANGE", .field = "byterange", .quoted = true },
        .{ .attribute = "GAP", .field = "gap" },
    };

    pub fn parse(r: *Reporter, value: []const u8) Allocator.Error!Part {
        return parseAttributes(Part, &specs, NoSpecial, r, value);
    }

    pub fn write(p: Part, w: *Io.Writer) Io.Writer.Error!void {
        try writeAttributes(Part, &specs, NoSpecial, w, p);
    }
};

/// `#EXT-X-PART-INF`: how long the parts in this playlist are, which a
/// player needs before it has seen one.
pub const PartInf = struct {
    /// `PART-TARGET`, required: the length every part but the last is at
    /// most.
    part_target: f64 = 0,
    extra: []const Attribute = &.{},

    pub const specs = [_]Spec{
        .{ .attribute = "PART-TARGET", .field = "part_target", .required = true },
    };

    pub fn parse(r: *Reporter, value: []const u8) Allocator.Error!PartInf {
        return parseAttributes(PartInf, &specs, NoSpecial, r, value);
    }

    pub fn write(p: PartInf, w: *Io.Writer) Io.Writer.Error!void {
        try writeAttributes(PartInf, &specs, NoSpecial, w, p);
    }
};

/// `#EXT-X-SERVER-CONTROL`: what the server will do for a client that asks,
/// from the low-latency extensions.
pub const ServerControl = struct {
    /// `CAN-SKIP-UNTIL`: how far back a delta update may skip, in seconds.
    /// Its presence is what says delta updates are available at all.
    can_skip_until: ?f64 = null,
    /// `CAN-SKIP-DATERANGES=YES`: a delta update may leave out
    /// `#EXT-X-DATERANGE` tags as well as segments.
    can_skip_dateranges: bool = false,
    /// `HOLD-BACK`: how far from the end of the playlist a player should
    /// start, in seconds. Absent means three times the target duration.
    hold_back: ?f64 = null,
    /// `PART-HOLD-BACK`: the same for a player playing parts. Required when
    /// there is an `#EXT-X-PART-INF`.
    part_hold_back: ?f64 = null,
    /// `CAN-BLOCK-RELOAD=YES`: the server will hold a request for the
    /// playlist open until the segment asked for exists.
    can_block_reload: bool = false,
    extra: []const Attribute = &.{},

    pub const specs = [_]Spec{
        .{ .attribute = "CAN-SKIP-UNTIL", .field = "can_skip_until" },
        .{ .attribute = "CAN-SKIP-DATERANGES", .field = "can_skip_dateranges" },
        .{ .attribute = "HOLD-BACK", .field = "hold_back" },
        .{ .attribute = "PART-HOLD-BACK", .field = "part_hold_back" },
        .{ .attribute = "CAN-BLOCK-RELOAD", .field = "can_block_reload" },
    };

    pub fn parse(r: *Reporter, value: []const u8) Allocator.Error!ServerControl {
        const control = try parseAttributes(ServerControl, &specs, NoSpecial, r, value);
        if (control.can_skip_dateranges and control.can_skip_until == null) {
            r.invalid(.missing_required_attribute, "CAN-SKIP-UNTIL with CAN-SKIP-DATERANGES=YES");
        }
        return control;
    }

    pub fn write(s: ServerControl, w: *Io.Writer) Io.Writer.Error!void {
        try writeAttributes(ServerControl, &specs, NoSpecial, w, s);
    }
};

/// `#EXT-X-SKIP`: the segments a delta update left out.
pub const Skip = struct {
    /// `SKIPPED-SEGMENTS`, required: how many segments are missing from the
    /// start of this playlist.
    skipped_segments: u64 = 0,
    /// `RECENTLY-REMOVED-DATERANGES`: the `ID`s of ranges the client should
    /// forget, separated by tab characters.
    recently_removed_dateranges: ?[]const u8 = null,
    extra: []const Attribute = &.{},

    pub const specs = [_]Spec{
        .{ .attribute = "SKIPPED-SEGMENTS", .field = "skipped_segments", .required = true },
        .{
            .attribute = "RECENTLY-REMOVED-DATERANGES",
            .field = "recently_removed_dateranges",
            .quoted = true,
        },
    };

    pub fn parse(r: *Reporter, value: []const u8) Allocator.Error!Skip {
        return parseAttributes(Skip, &specs, NoSpecial, r, value);
    }

    pub fn write(s: Skip, w: *Io.Writer) Io.Writer.Error!void {
        try writeAttributes(Skip, &specs, NoSpecial, w, s);
    }

    /// The `ID`s in `recently_removed_dateranges`, which are separated by
    /// tabs rather than by commas or spaces — the one list in the
    /// specification that is.
    pub fn removedDateRanges(s: Skip) std.mem.SplitIterator(u8, .scalar) {
        return std.mem.splitScalar(u8, s.recently_removed_dateranges orelse "", '\t');
    }
};

/// `#EXT-X-PRELOAD-HINT`: a resource the client should start fetching before
/// the playlist says it exists.
pub const PreloadHint = struct {
    /// `TYPE`, required.
    type: Enumerated(PreloadHintType) = .{ .known = .part },
    /// `URI`, required.
    uri: []const u8 = "",
    /// `BYTERANGE-START`. Note that this tag spells its range as two
    /// attributes rather than as `#EXT-X-PART`'s single `BYTERANGE`, because
    /// the length may not be known yet.
    byterange_start: ?u64 = null,
    /// `BYTERANGE-LENGTH`. Absent means the rest of the resource.
    byterange_length: ?u64 = null,
    extra: []const Attribute = &.{},

    pub const specs = [_]Spec{
        .{ .attribute = "TYPE", .field = "type", .required = true },
        .{ .attribute = "URI", .field = "uri", .quoted = true, .required = true },
        .{ .attribute = "BYTERANGE-START", .field = "byterange_start" },
        .{ .attribute = "BYTERANGE-LENGTH", .field = "byterange_length" },
    };

    pub fn parse(r: *Reporter, value: []const u8) Allocator.Error!PreloadHint {
        return parseAttributes(PreloadHint, &specs, NoSpecial, r, value);
    }

    pub fn write(p: PreloadHint, w: *Io.Writer) Io.Writer.Error!void {
        try writeAttributes(PreloadHint, &specs, NoSpecial, w, p);
    }
};

/// `#EXT-X-RENDITION-REPORT`: how far another rendition of the same content
/// has got, so that a client switching to it does not have to fetch its
/// playlist first.
pub const RenditionReport = struct {
    /// `URI`, required: the other Media Playlist, which must be a relative
    /// URI.
    uri: []const u8 = "",
    /// `LAST-MSN`: the media sequence number of the last segment in it.
    last_msn: ?u64 = null,
    /// `LAST-PART`: the part index of the last part of that segment.
    last_part: ?u64 = null,
    extra: []const Attribute = &.{},

    pub const specs = [_]Spec{
        .{ .attribute = "URI", .field = "uri", .quoted = true, .required = true },
        .{ .attribute = "LAST-MSN", .field = "last_msn" },
        .{ .attribute = "LAST-PART", .field = "last_part" },
    };

    pub fn parse(r: *Reporter, value: []const u8) Allocator.Error!RenditionReport {
        return parseAttributes(RenditionReport, &specs, NoSpecial, r, value);
    }

    pub fn write(rr: RenditionReport, w: *Io.Writer) Io.Writer.Error!void {
        try writeAttributes(RenditionReport, &specs, NoSpecial, w, rr);
    }
};

/// `#EXT-X-MEDIA` from §4.3.4.1: one rendition of one kind of content — an
/// audio language, a subtitle track — within a group that the variants
/// choose between.
pub const Rendition = struct {
    /// `TYPE`, required.
    type: Enumerated(MediaType) = .{ .known = .audio },
    /// `URI`, which a rendition with `TYPE=CLOSED-CAPTIONS` must not have,
    /// and which a `SUBTITLES` rendition must.
    uri: ?[]const u8 = null,
    /// `GROUP-ID`, required: which group of renditions this belongs to.
    group_id: []const u8 = "",
    /// `LANGUAGE`, an RFC 5646 tag.
    language: ?[]const u8 = null,
    /// `ASSOC-LANGUAGE`: a second language, for content associated with the
    /// first — a Japanese dub with romanised subtitles, say.
    assoc_language: ?[]const u8 = null,
    /// `NAME`, required: what to show in a menu.
    name: []const u8 = "",
    /// `STABLE-RENDITION-ID`, added after RFC 8216: the same rendition keeps
    /// this across playlist reloads and across content-steering pathways.
    stable_rendition_id: ?[]const u8 = null,
    /// `DEFAULT=YES`: play this one if the user has expressed no preference.
    default: bool = false,
    /// `AUTOSELECT=YES`: this one may be chosen from the user's system
    /// preferences. §4.3.4.1 requires it to be `YES` where `DEFAULT` is.
    autoselect: bool = false,
    /// `FORCED=YES`, only meaningful for subtitles: play these without being
    /// asked when they carry translation of on-screen text.
    forced: bool = false,
    /// `INSTREAM-ID`, required for `TYPE=CLOSED-CAPTIONS` and forbidden
    /// otherwise: `CC1` to `CC4`, or `SERVICE1` to `SERVICE63`.
    instream_id: ?[]const u8 = null,
    /// `BIT-DEPTH`, added after RFC 8216.
    bit_depth: ?u64 = null,
    /// `SAMPLE-RATE`, in hertz, added after RFC 8216.
    sample_rate: ?u64 = null,
    /// `CHARACTERISTICS`: Uniform Type Identifiers, comma-separated inside
    /// the quotes. `Attribute.commaWords` splits them.
    characteristics: ?[]const u8 = null,
    /// `CHANNELS`: slash-separated parameters of which the first is the
    /// count of audio channels.
    channels: ?[]const u8 = null,
    extra: []const Attribute = &.{},

    pub const specs = [_]Spec{
        .{ .attribute = "TYPE", .field = "type", .required = true },
        .{ .attribute = "URI", .field = "uri", .quoted = true },
        .{ .attribute = "GROUP-ID", .field = "group_id", .quoted = true, .required = true },
        .{ .attribute = "LANGUAGE", .field = "language", .quoted = true },
        .{ .attribute = "ASSOC-LANGUAGE", .field = "assoc_language", .quoted = true },
        .{ .attribute = "NAME", .field = "name", .quoted = true, .required = true },
        .{ .attribute = "STABLE-RENDITION-ID", .field = "stable_rendition_id", .quoted = true },
        .{ .attribute = "DEFAULT", .field = "default" },
        .{ .attribute = "AUTOSELECT", .field = "autoselect" },
        .{ .attribute = "FORCED", .field = "forced" },
        .{ .attribute = "INSTREAM-ID", .field = "instream_id", .quoted = true },
        .{ .attribute = "BIT-DEPTH", .field = "bit_depth" },
        .{ .attribute = "SAMPLE-RATE", .field = "sample_rate" },
        .{ .attribute = "CHARACTERISTICS", .field = "characteristics", .quoted = true },
        .{ .attribute = "CHANNELS", .field = "channels", .quoted = true },
    };

    pub fn parse(r: *Reporter, value: []const u8) Allocator.Error!Rendition {
        const rendition = try parseAttributes(Rendition, &specs, NoSpecial, r, value);
        // §4.3.4.1 has four rules that are worth checking because getting
        // any of them wrong makes a rendition a player will not select, and
        // the playlist looks fine until then.
        if (rendition.type.is(.closed_captions)) {
            if (rendition.uri != null) r.warn(.attribute_not_allowed, "URI on TYPE=CLOSED-CAPTIONS");
            if (rendition.instream_id == null) r.invalid(.missing_required_attribute, "INSTREAM-ID");
        } else if (rendition.instream_id != null) {
            r.warn(.attribute_not_allowed, "INSTREAM-ID without TYPE=CLOSED-CAPTIONS");
        }
        // Only when `AUTOSELECT` is actually there: §4.3.4.1 puts the rule
        // that way round, and the RFC's own §8.7 example has `DEFAULT=YES`
        // with no `AUTOSELECT` on every one of its nine renditions.
        if (rendition.default and !rendition.autoselect and hasAttribute(value, "AUTOSELECT")) {
            r.warn(.invalid_attribute_value, "DEFAULT=YES with AUTOSELECT=NO");
        }
        if (rendition.forced and !rendition.type.is(.subtitles)) {
            r.warn(.attribute_not_allowed, "FORCED without TYPE=SUBTITLES");
        }
        return rendition;
    }

    pub fn write(m: Rendition, w: *Io.Writer) Io.Writer.Error!void {
        try writeAttributes(Rendition, &specs, NoSpecial, w, m);
    }

    /// The number of audio channels, being the first of the slash-separated
    /// parameters of `CHANNELS`.
    pub fn channelCount(m: Rendition) ?u64 {
        const channels = m.channels orelse return null;
        const first = channels[0 .. std.mem.findScalar(u8, channels, '/') orelse channels.len];
        return attribute.decimalInteger(first) catch null;
    }
};

/// `#EXT-X-STREAM-INF` from §4.3.4.2 and `#EXT-X-I-FRAME-STREAM-INF` from
/// §4.3.4.3, which take the same attributes.
///
/// The two differ in two ways, and the parser checks both: an
/// `#EXT-X-I-FRAME-STREAM-INF` carries its playlist's address in a `URI`
/// attribute where an `#EXT-X-STREAM-INF` has it on the line after, and it
/// must not have `FRAME-RATE`, `AUDIO`, `SUBTITLES` or `CLOSED-CAPTIONS`.
pub const StreamInf = struct {
    /// `BANDWIDTH`, required: the peak bit rate of the variant, in bits per
    /// second.
    bandwidth: u64 = 0,
    /// `AVERAGE-BANDWIDTH`, in bits per second.
    average_bandwidth: ?u64 = null,
    /// `SCORE`, added after RFC 8216: how good this variant is thought to
    /// be, for choosing between two of the same bandwidth.
    score: ?f64 = null,
    /// `CODECS`, comma-separated RFC 6381 identifiers inside the quotes.
    codecs: ?[]const u8 = null,
    /// `SUPPLEMENTAL-CODECS`, added after RFC 8216: codecs that enhance the
    /// ones in `CODECS` for a player that understands them.
    supplemental_codecs: ?[]const u8 = null,
    resolution: ?Resolution = null,
    /// `FRAME-RATE`, in frames per second. Not allowed on an
    /// `#EXT-X-I-FRAME-STREAM-INF`.
    frame_rate: ?f64 = null,
    hdcp_level: ?Enumerated(HdcpLevel) = null,
    /// `ALLOWED-CPC`, added after RFC 8216: which content protection
    /// configurations may play this variant.
    allowed_cpc: ?[]const u8 = null,
    video_range: ?Enumerated(VideoRange) = null,
    /// `REQ-VIDEO-LAYOUT`, added after RFC 8216: `CH-STEREO`, `CH-MONO` and
    /// the projection, space-separated inside the quotes.
    req_video_layout: ?[]const u8 = null,
    /// `STABLE-VARIANT-ID`, added after RFC 8216.
    stable_variant_id: ?[]const u8 = null,
    /// `AUDIO`: the `GROUP-ID` of the audio renditions this variant uses.
    /// Not allowed on an `#EXT-X-I-FRAME-STREAM-INF`.
    audio: ?[]const u8 = null,
    video: ?[]const u8 = null,
    /// Not allowed on an `#EXT-X-I-FRAME-STREAM-INF`.
    subtitles: ?[]const u8 = null,
    /// `CLOSED-CAPTIONS`, which is either a quoted `GROUP-ID` or the
    /// unquoted `NONE`. Not allowed on an `#EXT-X-I-FRAME-STREAM-INF`.
    closed_captions: ?ClosedCaptions = null,
    /// `PATHWAY-ID`, added after RFC 8216 with content steering.
    pathway_id: ?[]const u8 = null,
    /// `URI`, which only an `#EXT-X-I-FRAME-STREAM-INF` has: an
    /// `#EXT-X-STREAM-INF`'s address is the line after it.
    uri: ?[]const u8 = null,
    extra: []const Attribute = &.{},

    pub const specs = [_]Spec{
        .{ .attribute = "BANDWIDTH", .field = "bandwidth", .required = true },
        .{ .attribute = "AVERAGE-BANDWIDTH", .field = "average_bandwidth" },
        .{ .attribute = "SCORE", .field = "score" },
        .{ .attribute = "CODECS", .field = "codecs", .quoted = true },
        .{ .attribute = "SUPPLEMENTAL-CODECS", .field = "supplemental_codecs", .quoted = true },
        .{ .attribute = "RESOLUTION", .field = "resolution" },
        .{ .attribute = "FRAME-RATE", .field = "frame_rate" },
        .{ .attribute = "HDCP-LEVEL", .field = "hdcp_level" },
        .{ .attribute = "ALLOWED-CPC", .field = "allowed_cpc", .quoted = true },
        .{ .attribute = "VIDEO-RANGE", .field = "video_range" },
        .{ .attribute = "REQ-VIDEO-LAYOUT", .field = "req_video_layout", .quoted = true },
        .{ .attribute = "STABLE-VARIANT-ID", .field = "stable_variant_id", .quoted = true },
        .{ .attribute = "AUDIO", .field = "audio", .quoted = true },
        .{ .attribute = "VIDEO", .field = "video", .quoted = true },
        .{ .attribute = "SUBTITLES", .field = "subtitles", .quoted = true },
        .{ .attribute = "PATHWAY-ID", .field = "pathway_id", .quoted = true },
        .{ .attribute = "URI", .field = "uri", .quoted = true },
    };

    /// `CLOSED-CAPTIONS` cannot go in the table: it is the one attribute in
    /// the specification whose value is a `quoted-string` or an
    /// `enumerated-string` depending on which it is.
    const Captions = struct {
        pub fn consume(out: *StreamInf, r: *Reporter, a: Attribute) Allocator.Error!bool {
            if (!eqlName(a.name, "CLOSED-CAPTIONS")) return false;
            if (!a.isQuoted() and std.mem.eql(u8, a.raw, "NONE")) {
                out.closed_captions = .none;
                return true;
            }
            // A group id is written back inside quotes, so it has to be
            // something that can go inside them; see `decode`.
            if (!attribute.quotable(a.string())) {
                r.invalid(.invalid_attribute_value, a.name);
                return true;
            }
            out.closed_captions = .{ .group = a.string() };
            return true;
        }

        pub fn write(w: *Io.Writer, value: StreamInf, wrote_any: bool) Io.Writer.Error!bool {
            const captions = value.closed_captions orelse return wrote_any;
            if (wrote_any) try w.writeByte(',');
            try w.print("CLOSED-CAPTIONS={f}", .{captions});
            return true;
        }
    };

    pub fn parse(r: *Reporter, value: []const u8) Allocator.Error!StreamInf {
        return parseAttributes(StreamInf, &specs, Captions, r, value);
    }

    pub fn write(s: StreamInf, w: *Io.Writer) Io.Writer.Error!void {
        try writeAttributes(StreamInf, &specs, Captions, w, s);
    }

    /// Check the rules that depend on which of the two tags this came from.
    ///
    /// Called by the parser once it knows; separate from `parse` because the
    /// attributes are identical and only the tag name says which set of
    /// rules applies.
    pub fn checkKind(s: StreamInf, r: *Reporter, iframe: bool) void {
        if (iframe) {
            if (s.uri == null) r.invalid(.missing_required_attribute, "URI");
            if (s.frame_rate != null) r.warn(.attribute_not_allowed, "FRAME-RATE");
            if (s.audio != null) r.warn(.attribute_not_allowed, "AUDIO");
            if (s.subtitles != null) r.warn(.attribute_not_allowed, "SUBTITLES");
            if (s.closed_captions != null) r.warn(.attribute_not_allowed, "CLOSED-CAPTIONS");
        } else if (s.uri != null) {
            r.warn(.attribute_not_allowed, "URI on #EXT-X-STREAM-INF");
        }
    }

    /// The RFC 6381 codec identifiers in `CODECS`.
    pub fn codecList(s: StreamInf) std.mem.SplitIterator(u8, .scalar) {
        return std.mem.splitScalar(u8, s.codecs orelse "", ',');
    }
};

/// `#EXT-X-SESSION-DATA` from §4.3.4.4: arbitrary data carried in a
/// Multivariant Playlist, so that a player has it without fetching a Media
/// Playlist.
pub const SessionData = struct {
    /// `DATA-ID`, required: a reverse-DNS identifier for what this is.
    data_id: []const u8 = "",
    /// `VALUE`. Exactly one of this and `uri` must be there.
    value: ?[]const u8 = null,
    /// `URI` of a resource holding the data.
    uri: ?[]const u8 = null,
    /// `FORMAT`, added after RFC 8216, which says how the resource at `URI`
    /// is encoded. Absent means `JSON`.
    format: ?Enumerated(SessionDataFormat) = null,
    language: ?[]const u8 = null,
    extra: []const Attribute = &.{},

    pub const specs = [_]Spec{
        .{ .attribute = "DATA-ID", .field = "data_id", .quoted = true, .required = true },
        .{ .attribute = "VALUE", .field = "value", .quoted = true },
        .{ .attribute = "URI", .field = "uri", .quoted = true },
        .{ .attribute = "FORMAT", .field = "format" },
        .{ .attribute = "LANGUAGE", .field = "language", .quoted = true },
    };

    pub fn parse(r: *Reporter, value: []const u8) Allocator.Error!SessionData {
        const data = try parseAttributes(SessionData, &specs, NoSpecial, r, value);
        // §4.3.4.4: exactly one of VALUE and URI.
        if (data.value == null and data.uri == null) {
            r.invalid(.missing_required_attribute, "one of VALUE or URI");
        } else if (data.value != null and data.uri != null) {
            r.invalid(.attribute_not_allowed, "both VALUE and URI");
        }
        return data;
    }

    pub fn write(s: SessionData, w: *Io.Writer) Io.Writer.Error!void {
        try writeAttributes(SessionData, &specs, NoSpecial, w, s);
    }
};

/// `#EXT-X-CONTENT-STEERING`, added after RFC 8216: where to ask which
/// pathway through the content delivery networks to use.
pub const ContentSteering = struct {
    /// `SERVER-URI`, required.
    server_uri: []const u8 = "",
    /// `PATHWAY-ID`: which pathway to start on, matching the `PATHWAY-ID` of
    /// some variants. Absent means the first pathway in the manifest.
    pathway_id: ?[]const u8 = null,
    extra: []const Attribute = &.{},

    pub const specs = [_]Spec{
        .{ .attribute = "SERVER-URI", .field = "server_uri", .quoted = true, .required = true },
        .{ .attribute = "PATHWAY-ID", .field = "pathway_id", .quoted = true },
    };

    pub fn parse(r: *Reporter, value: []const u8) Allocator.Error!ContentSteering {
        return parseAttributes(ContentSteering, &specs, NoSpecial, r, value);
    }

    pub fn write(c: ContentSteering, w: *Io.Writer) Io.Writer.Error!void {
        try writeAttributes(ContentSteering, &specs, NoSpecial, w, c);
    }
};

/// `#EXT-X-START` from §4.3.5.2: where a player should begin.
pub const Start = struct {
    /// `TIME-OFFSET`, required, in seconds. Negative means from the end of
    /// the playlist, which is the only place the specification uses a signed
    /// floating-point value.
    time_offset: f64 = 0,
    /// `PRECISE=YES`: start exactly there rather than at the segment
    /// boundary before it.
    precise: bool = false,
    extra: []const Attribute = &.{},

    pub const specs = [_]Spec{
        .{ .attribute = "TIME-OFFSET", .field = "time_offset", .required = true, .signed = true },
        .{ .attribute = "PRECISE", .field = "precise" },
    };

    pub fn parse(r: *Reporter, value: []const u8) Allocator.Error!Start {
        return parseAttributes(Start, &specs, NoSpecial, r, value);
    }

    pub fn write(s: Start, w: *Io.Writer) Io.Writer.Error!void {
        try writeAttributes(Start, &specs, NoSpecial, w, s);
    }
};

/// `#EXT-X-DEFINE`, added after RFC 8216: a variable that `{$name}` in a URI
/// or an attribute value stands for.
///
/// It has three shapes, and exactly one of them must hold: `NAME` with
/// `VALUE` declares a variable; `IMPORT` takes one from the Multivariant
/// Playlist that referred to this one; `QUERYPARAM` takes one from the query
/// string of the URI this playlist was fetched with.
pub const Define = struct {
    name: ?[]const u8 = null,
    value: ?[]const u8 = null,
    import: ?[]const u8 = null,
    queryparam: ?[]const u8 = null,
    extra: []const Attribute = &.{},

    pub const specs = [_]Spec{
        .{ .attribute = "NAME", .field = "name", .quoted = true },
        .{ .attribute = "VALUE", .field = "value", .quoted = true },
        .{ .attribute = "IMPORT", .field = "import", .quoted = true },
        .{ .attribute = "QUERYPARAM", .field = "queryparam", .quoted = true },
    };

    pub fn parse(r: *Reporter, value: []const u8) Allocator.Error!Define {
        const define = try parseAttributes(Define, &specs, NoSpecial, r, value);
        var shapes: u8 = 0;
        if (define.name != null) shapes += 1;
        if (define.import != null) shapes += 1;
        if (define.queryparam != null) shapes += 1;
        if (shapes != 1) {
            r.invalid(.invalid_define, "exactly one of NAME, IMPORT or QUERYPARAM");
        } else if (define.name != null and define.value == null) {
            // §4.2's `VALUE` is required alongside `NAME`; an empty string
            // is a legal value and a missing one is not.
            r.invalid(.missing_required_attribute, "VALUE with NAME");
        } else if (define.name == null and define.value != null) {
            r.warn(.attribute_not_allowed, "VALUE without NAME");
        }
        return define;
    }

    pub fn write(d: Define, w: *Io.Writer) Io.Writer.Error!void {
        try writeAttributes(Define, &specs, NoSpecial, w, d);
    }

    /// What this defines, whichever shape it took.
    pub fn variableName(d: Define) ?[]const u8 {
        return d.name orelse d.import orelse d.queryparam;
    }
};

// -- tag names -------------------------------------------------------------

/// Every tag this library knows by name.
///
/// Not every one of them is modelled: the `ext` ones at the end are
/// extended-M3U directives that predate HLS and are carried through
/// unchanged rather than given types. Being in this list is what stops them
/// being reported as `unknown_tag`, which they are not — a playlist with an
/// `#EXTALB` in it is a well-formed extended M3U.
pub const Name = enum {
    // The basic tags, §4.3.1.
    extm3u,
    ext_x_version,

    // Media Segment tags, §4.3.2, plus the ones added after RFC 8216.
    extinf,
    ext_x_byterange,
    ext_x_discontinuity,
    ext_x_key,
    ext_x_map,
    ext_x_program_date_time,
    ext_x_daterange,
    ext_x_gap,
    ext_x_bitrate,
    ext_x_part,

    // Media Playlist tags, §4.3.3, plus the low-latency ones.
    ext_x_targetduration,
    ext_x_media_sequence,
    ext_x_discontinuity_sequence,
    ext_x_endlist,
    ext_x_playlist_type,
    ext_x_i_frames_only,
    ext_x_part_inf,
    ext_x_server_control,
    ext_x_skip,
    ext_x_preload_hint,
    ext_x_rendition_report,

    // Multivariant Playlist tags, §4.3.4.
    ext_x_media,
    ext_x_stream_inf,
    ext_x_i_frame_stream_inf,
    ext_x_session_data,
    ext_x_session_key,
    ext_x_content_steering,

    // Tags for either kind, §4.3.5.
    ext_x_independent_segments,
    ext_x_start,
    ext_x_define,

    // Extended M3U, which is older than HLS and still what most `.m3u`
    // files are. Recognised and carried through rather than modelled.
    extgrp,
    extalb,
    extart,
    extgenre,
    extimg,
    extbyt,
    extbin,
    extenc,
    extvlcopt,

    /// The tag as RFC 8216 spells it, without the `#`.
    pub fn text(n: Name) []const u8 {
        return switch (n) {
            .extm3u => "EXTM3U",
            .ext_x_version => "EXT-X-VERSION",
            .extinf => "EXTINF",
            .ext_x_byterange => "EXT-X-BYTERANGE",
            .ext_x_discontinuity => "EXT-X-DISCONTINUITY",
            .ext_x_key => "EXT-X-KEY",
            .ext_x_map => "EXT-X-MAP",
            .ext_x_program_date_time => "EXT-X-PROGRAM-DATE-TIME",
            .ext_x_daterange => "EXT-X-DATERANGE",
            .ext_x_gap => "EXT-X-GAP",
            .ext_x_bitrate => "EXT-X-BITRATE",
            .ext_x_part => "EXT-X-PART",
            .ext_x_targetduration => "EXT-X-TARGETDURATION",
            .ext_x_media_sequence => "EXT-X-MEDIA-SEQUENCE",
            .ext_x_discontinuity_sequence => "EXT-X-DISCONTINUITY-SEQUENCE",
            .ext_x_endlist => "EXT-X-ENDLIST",
            .ext_x_playlist_type => "EXT-X-PLAYLIST-TYPE",
            .ext_x_i_frames_only => "EXT-X-I-FRAMES-ONLY",
            .ext_x_part_inf => "EXT-X-PART-INF",
            .ext_x_server_control => "EXT-X-SERVER-CONTROL",
            .ext_x_skip => "EXT-X-SKIP",
            .ext_x_preload_hint => "EXT-X-PRELOAD-HINT",
            .ext_x_rendition_report => "EXT-X-RENDITION-REPORT",
            .ext_x_media => "EXT-X-MEDIA",
            .ext_x_stream_inf => "EXT-X-STREAM-INF",
            .ext_x_i_frame_stream_inf => "EXT-X-I-FRAME-STREAM-INF",
            .ext_x_session_data => "EXT-X-SESSION-DATA",
            .ext_x_session_key => "EXT-X-SESSION-KEY",
            .ext_x_content_steering => "EXT-X-CONTENT-STEERING",
            .ext_x_independent_segments => "EXT-X-INDEPENDENT-SEGMENTS",
            .ext_x_start => "EXT-X-START",
            .ext_x_define => "EXT-X-DEFINE",
            .extgrp => "EXTGRP",
            .extalb => "EXTALB",
            .extart => "EXTART",
            .extgenre => "EXTGENRE",
            .extimg => "EXTIMG",
            .extbyt => "EXTBYT",
            .extbin => "EXTBIN",
            .extenc => "EXTENC",
            .extvlcopt => "EXTVLCOPT",
        };
    }

    /// Which part of the specification defines this tag, which is how the
    /// parser decides what kind of playlist it is reading.
    pub fn scope(n: Name) Scope {
        return switch (n) {
            .extinf,
            .ext_x_byterange,
            .ext_x_discontinuity,
            .ext_x_key,
            .ext_x_map,
            .ext_x_program_date_time,
            .ext_x_daterange,
            .ext_x_gap,
            .ext_x_bitrate,
            .ext_x_part,
            => .segment,

            .ext_x_targetduration,
            .ext_x_media_sequence,
            .ext_x_discontinuity_sequence,
            .ext_x_endlist,
            .ext_x_playlist_type,
            .ext_x_i_frames_only,
            .ext_x_part_inf,
            .ext_x_server_control,
            .ext_x_skip,
            .ext_x_preload_hint,
            .ext_x_rendition_report,
            => .media_playlist,

            .ext_x_media,
            .ext_x_stream_inf,
            .ext_x_i_frame_stream_inf,
            .ext_x_session_data,
            .ext_x_session_key,
            .ext_x_content_steering,
            => .multivariant,

            else => .either,
        };
    }

    /// Which part of the specification a tag comes from.
    pub const Scope = enum {
        /// A basic tag from §4.3.1, one of §4.3.5's that may appear in
        /// either kind of playlist, or an extended-M3U directive. Says
        /// nothing about which kind of playlist this is.
        either,
        /// A Media Segment tag, §4.3.2: it describes the URI on the line
        /// after it.
        segment,
        /// A Media Playlist tag, §4.3.3: it describes the playlist.
        media_playlist,
        /// A Multivariant — once Master — Playlist tag, §4.3.4.
        multivariant,
    };

    /// Whether this tag's presence settles which kind of playlist this is,
    /// and if so which kind it settles on: `.media_playlist` or
    /// `.multivariant`.
    ///
    /// Every tag that belongs to one kind settles it, with one exception
    /// that matters enormously in practice. `#EXTINF` is a Media Segment tag
    /// *and* is the whole of an extended M3U — an `#EXTM3U`, a run of
    /// `#EXTINF` lines and their URIs is what every IPTV channel list and
    /// every music player's `.m3u` looks like, and none of them is an HLS
    /// Media Playlist. So `#EXTINF` alone settles nothing, and a playlist
    /// with nothing else in it is `Playlist.Kind.basic`.
    pub fn settlesKind(n: Name) ?Scope {
        return switch (n.scope()) {
            .multivariant => .multivariant,
            .media_playlist => .media_playlist,
            .segment => if (n == .extinf) null else .media_playlist,
            .either => null,
        };
    }

    /// The lowest `#EXT-X-VERSION` that allows this tag, from §7.
    ///
    /// Zero for a tag with no such requirement. Used to report a
    /// `version_conflict`, which is worth reporting because a player obeying
    /// §7 will refuse the playlist while the playlist looks fine.
    pub fn minimumVersion(n: Name) u64 {
        return switch (n) {
            .ext_x_byterange, .ext_x_i_frames_only => 4,
            .ext_x_key => 2,
            .ext_x_map => 5,
            .ext_x_independent_segments, .ext_x_start => 4,
            .ext_x_daterange => 6,
            .ext_x_gap, .ext_x_part, .ext_x_part_inf, .ext_x_server_control, .ext_x_skip => 9,
            .ext_x_preload_hint, .ext_x_rendition_report => 9,
            .ext_x_define => 8,
            .ext_x_content_steering => 12,
            else => 0,
        };
    }
};

/// The tag names, for `fromText`. Upper case, because that is what the
/// specification uses and what `fromText` folds its argument to.
const names = blk: {
    const values = std.enums.values(Name);
    var pairs: [values.len]struct { []const u8, Name } = undefined;
    for (values, 0..) |name, i| pairs[i] = .{ name.text(), name };
    break :blk std.StaticStringMap(Name).initComptime(pairs);
};

/// The longest tag name there is, which is what `fromText` needs a buffer
/// for.
pub const max_name_len = blk: {
    var longest = 0;
    for (std.enums.values(Name)) |name| longest = @max(longest, name.text().len);
    break :blk longest;
};

/// The tag called `text`, or null if this library has never heard of it.
///
/// Case-insensitive: §4.1 writes every tag in upper case, and a tool that
/// wrote `#EXT-X-Endlist` has written a tag rather than a puzzle. `write`
/// emits the specification's spelling whatever came in.
pub fn fromText(text: []const u8) ?Name {
    if (text.len > max_name_len) return null;
    var upper: [max_name_len]u8 = undefined;
    for (text, 0..) |c, i| upper[i] = std.ascii.toUpper(c);
    return names.get(upper[0..text.len]);
}

// -- tests -----------------------------------------------------------------

const testing = std.testing;

/// Parse one tag's attribute list against the testing allocator, reporting
/// into a `Diagnostics` the caller owns.
fn parseTag(
    comptime T: type,
    arena: Allocator,
    diagnostics: ?*Diagnostics,
    value: []const u8,
) !T {
    var reporter: Reporter = .{ .arena = arena, .diagnostics = diagnostics, .line = 1 };
    return T.parse(&reporter, value);
}

/// Write a tag and give back the text, for the tests below.
fn writeTag(value: anytype, buffer: []u8) ![]const u8 {
    var w: Io.Writer = .fixed(buffer);
    try value.write(&w);
    return w.buffered();
}

test "an enumerated value that is known, and one that is not" {
    const known = Enumerated(EncryptionMethod).parse("AES-128");
    try testing.expectEqual(EncryptionMethod.aes_128, known.value().?);
    try testing.expect(known.is(.aes_128));
    try testing.expect(!known.is(.none));

    const unknown = Enumerated(EncryptionMethod).parse("AES-256");
    try testing.expectEqual(@as(?EncryptionMethod, null), unknown.value());
    try testing.expect(!unknown.is(.aes_128));
    try testing.expectEqualStrings("AES-256", unknown.unknown);

    // And it survives being written back out, which is the whole point.
    var buffer: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try w.print("{f}", .{unknown});
    try testing.expectEqualStrings("AES-256", w.buffered());
}

test "byte ranges" {
    try testing.expectEqual(ByteRange{ .length = 75232, .offset = 0 }, try ByteRange.parse("75232@0"));
    try testing.expectEqual(ByteRange{ .length = 82112, .offset = null }, try ByteRange.parse("82112"));
    try testing.expectError(error.InvalidByteRange, ByteRange.parse("75232@"));
    try testing.expectError(error.InvalidByteRange, ByteRange.parse("@0"));
    try testing.expectError(error.InvalidByteRange, ByteRange.parse("a@b"));

    try testing.expectEqual(@as(?u64, 75232), (ByteRange{ .length = 75232, .offset = 0 }).end());
    try testing.expectEqual(@as(?u64, null), (ByteRange{ .length = 1, .offset = null }).end());
    // An end that does not fit a `u64` is no end at all rather than a panic.
    try testing.expectEqual(
        @as(?u64, null),
        (ByteRange{ .length = 2, .offset = std.math.maxInt(u64) - 1 }).end(),
    );

    var buffer: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try w.print("{f}", .{ByteRange{ .length = 75232, .offset = 0 }});
    try testing.expectEqualStrings("75232@0", w.buffered());

    var no_offset: Io.Writer = .fixed(&buffer);
    try no_offset.print("{f}", .{ByteRange{ .length = 82112 }});
    try testing.expectEqualStrings("82112", no_offset.buffered());
}

test "a key, and what it writes back as" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    const key = try parseTag(
        Key,
        arena.allocator(),
        &diagnostics,
        "METHOD=AES-128,URI=\"https://e.com/k\",IV=0x1F,KEYFORMAT=\"identity\"",
    );
    try testing.expect(key.method.is(.aes_128));
    try testing.expectEqualStrings("https://e.com/k", key.uri.?);
    try testing.expectEqualStrings("0x1F", key.iv.?);
    try testing.expectEqual(@as(usize, 0), diagnostics.count());

    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "METHOD=AES-128,URI=\"https://e.com/k\",IV=0x1F,KEYFORMAT=\"identity\"",
        try writeTag(key, &buffer),
    );
}

test "the IV keeps its text and decodes to sixteen bytes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const key = try parseTag(
        Key,
        arena.allocator(),
        null,
        "METHOD=AES-128,URI=\"k\",IV=0x9c7db8778570d05c3f4a0e6e0bcc5b5c",
    );
    const iv = try key.initialisationVector().?;
    try testing.expectEqual(@as(u8, 0x9c), iv[0]);
    try testing.expectEqual(@as(u8, 0x5c), iv[15]);

    // A short IV is right-aligned, since the value is a number.
    const short = try parseTag(Key, arena.allocator(), null, "METHOD=AES-128,URI=\"k\",IV=0x01");
    const short_iv = try short.initialisationVector().?;
    try testing.expectEqual(@as(u8, 0), short_iv[0]);
    try testing.expectEqual(@as(u8, 1), short_iv[15]);

    const none = try parseTag(Key, arena.allocator(), null, "METHOD=NONE");
    try testing.expectEqual(@as(?(error{InvalidHex}![16]u8), null), none.initialisationVector());
}

test "a key with METHOD=NONE must not have a URI, and one without must" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    _ = try parseTag(Key, arena.allocator(), &diagnostics, "METHOD=AES-128");
    try testing.expect(diagnostics.has(.missing_required_attribute));

    diagnostics.clear();
    _ = try parseTag(Key, arena.allocator(), &diagnostics, "METHOD=NONE,URI=\"k\"");
    try testing.expect(diagnostics.has(.attribute_not_allowed));

    diagnostics.clear();
    _ = try parseTag(Key, arena.allocator(), &diagnostics, "METHOD=NONE");
    try testing.expectEqual(@as(usize, 0), diagnostics.count());
}

test "an unknown attribute is kept and written back exactly" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    const key = try parseTag(
        Key,
        arena.allocator(),
        &diagnostics,
        "METHOD=AES-128,URI=\"k\",X-VENDOR=\"a,b\",X-FLAG=3",
    );
    try testing.expectEqual(@as(usize, 2), key.extra.len);
    try testing.expectEqualStrings("X-VENDOR", key.extra[0].name);
    // The quotes are kept, so the comma inside them survives.
    try testing.expectEqualStrings("\"a,b\"", key.extra[0].raw);
    try testing.expect(diagnostics.has(.unknown_attribute));

    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "METHOD=AES-128,URI=\"k\",X-VENDOR=\"a,b\",X-FLAG=3",
        try writeTag(key, &buffer),
    );
}

test "a quoted-string attribute written without quotes is warned about and gains them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    const map = try parseTag(Map, arena.allocator(), &diagnostics, "URI=init.mp4");
    try testing.expectEqualStrings("init.mp4", map.uri);
    try testing.expect(diagnostics.has(.missing_quotes));

    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings("URI=\"init.mp4\"", try writeTag(map, &buffer));
}

test "a map's byterange does not need an offset" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    // §4.3.2.5 says that with no `BYTERANGE` the range is the whole
    // resource, and says nothing requiring an offset when there is one --
    // which makes this the opposite of `#EXT-X-BYTERANGE`, where a missing
    // offset means "carry on from the last sub-range" and so needs one to
    // carry on from.
    const whole = try parseTag(Map, arena.allocator(), &diagnostics, "URI=\"i.mp4\",BYTERANGE=\"1000\"");
    try testing.expectEqual(@as(?u64, null), whole.byterange.?.offset);
    try testing.expectEqual(@as(usize, 0), diagnostics.count());

    diagnostics.clear();
    const map = try parseTag(Map, arena.allocator(), &diagnostics, "URI=\"i.mp4\",BYTERANGE=\"1000@0\"");
    try testing.expectEqual(@as(usize, 0), diagnostics.count());

    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings("URI=\"i.mp4\",BYTERANGE=\"1000@0\"", try writeTag(map, &buffer));
    try testing.expectEqualStrings("URI=\"i.mp4\",BYTERANGE=\"1000\"", try writeTag(whole, &buffer));
}

test "a daterange, with its dates and its client attributes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    const range = try parseTag(
        DateRange,
        arena.allocator(),
        &diagnostics,
        "ID=\"ad1\",CLASS=\"com.example.ad\",START-DATE=\"2010-02-19T14:54:23.031+08:00\"," ++
            "DURATION=30.5,X-AD-ID=\"1234\",X-PRICE=9.99,SCTE35-OUT=0xFC002F",
    );
    try testing.expectEqualStrings("ad1", range.id);
    try testing.expectEqual(@as(i32, 2010), range.start_date.?.year);
    try testing.expectEqual(@as(f64, 30.5), range.duration.?);
    try testing.expectEqualStrings("0xFC002F", range.scte35_out.?);
    try testing.expectEqual(@as(usize, 2), range.client.len);
    try testing.expectEqualStrings("1234", range.clientAttribute("X-AD-ID").?);
    try testing.expectEqualStrings("9.99", range.clientAttribute("x-price").?);
    try testing.expectEqual(@as(?[]const u8, null), range.clientAttribute("X-NOPE"));
    // An `X-` attribute is the playlist author's, not an unknown one.
    try testing.expect(!diagnostics.has(.unknown_attribute));

    var buffer: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "ID=\"ad1\",CLASS=\"com.example.ad\",START-DATE=\"2010-02-19T14:54:23.031+08:00\"," ++
            "DURATION=30.5,SCTE35-OUT=0xFC002F,X-AD-ID=\"1234\",X-PRICE=9.99",
        try writeTag(range, &buffer),
    );
}

test "END-ON-NEXT needs a CLASS and forbids a DURATION" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    _ = try parseTag(
        DateRange,
        arena.allocator(),
        &diagnostics,
        "ID=\"a\",START-DATE=\"2020-01-01T00:00:00Z\",END-ON-NEXT=YES,DURATION=1",
    );
    try testing.expect(diagnostics.has(.missing_required_attribute));
    try testing.expect(diagnostics.has(.attribute_not_allowed));
}

test "a stream-inf with everything on it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    const stream = try parseTag(
        StreamInf,
        arena.allocator(),
        &diagnostics,
        "BANDWIDTH=1280000,AVERAGE-BANDWIDTH=1000000,CODECS=\"avc1.4d401e,mp4a.40.2\"," ++
            "RESOLUTION=1280x720,FRAME-RATE=29.97,VIDEO-RANGE=PQ,HDCP-LEVEL=TYPE-0," ++
            "AUDIO=\"aac\",CLOSED-CAPTIONS=NONE",
    );
    try testing.expectEqual(@as(u64, 1280000), stream.bandwidth);
    try testing.expectEqual(Resolution{ .width = 1280, .height = 720 }, stream.resolution.?);
    try testing.expectEqual(@as(f64, 29.97), stream.frame_rate.?);
    try testing.expect(stream.video_range.?.is(.pq));
    try testing.expect(stream.hdcp_level.?.is(.type_0));
    try testing.expectEqual(ClosedCaptions.none, stream.closed_captions.?);
    try testing.expectEqual(@as(usize, 0), diagnostics.count());

    var codecs = stream.codecList();
    try testing.expectEqualStrings("avc1.4d401e", codecs.next().?);
    try testing.expectEqualStrings("mp4a.40.2", codecs.next().?);
}

test "CLOSED-CAPTIONS is a group when it is quoted and NONE when it is not" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const group = try parseTag(StreamInf, arena.allocator(), null, "BANDWIDTH=1,CLOSED-CAPTIONS=\"cc\"");
    try testing.expectEqualStrings("cc", group.closed_captions.?.group);

    const none = try parseTag(StreamInf, arena.allocator(), null, "BANDWIDTH=1,CLOSED-CAPTIONS=NONE");
    try testing.expectEqual(ClosedCaptions.none, none.closed_captions.?);

    // A quoted `"NONE"` is a group called NONE, which is what §4.3.4.2 says
    // and is worth a test because the two look alike.
    const quoted_none = try parseTag(StreamInf, arena.allocator(), null, "BANDWIDTH=1,CLOSED-CAPTIONS=\"NONE\"");
    try testing.expectEqualStrings("NONE", quoted_none.closed_captions.?.group);

    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings("BANDWIDTH=1,CLOSED-CAPTIONS=NONE", try writeTag(none, &buffer));
    try testing.expectEqualStrings("BANDWIDTH=1,CLOSED-CAPTIONS=\"cc\"", try writeTag(group, &buffer));
}

test "the rules that tell the two stream-inf tags apart" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();
    var reporter: Reporter = .{ .arena = arena.allocator(), .diagnostics = &diagnostics, .line = 1 };

    // An I-frame variant needs a URI attribute and allows no FRAME-RATE.
    const iframe = try parseTag(StreamInf, arena.allocator(), null, "BANDWIDTH=1,FRAME-RATE=30");
    iframe.checkKind(&reporter, true);
    try testing.expect(diagnostics.has(.missing_required_attribute));
    try testing.expect(diagnostics.has(.attribute_not_allowed));

    // An ordinary variant must not have one, since its address is the next
    // line.
    diagnostics.clear();
    const ordinary = try parseTag(StreamInf, arena.allocator(), null, "BANDWIDTH=1,URI=\"v.m3u8\"");
    ordinary.checkKind(&reporter, false);
    try testing.expect(diagnostics.has(.attribute_not_allowed));

    diagnostics.clear();
    const good = try parseTag(StreamInf, arena.allocator(), null, "BANDWIDTH=1,FRAME-RATE=30");
    good.checkKind(&reporter, false);
    try testing.expectEqual(@as(usize, 0), diagnostics.count());
}

test "a rendition, and the four rules §4.3.4.1 has about them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    const rendition = try parseTag(
        Rendition,
        arena.allocator(),
        &diagnostics,
        "TYPE=AUDIO,GROUP-ID=\"aac\",NAME=\"English\",LANGUAGE=\"en\"," ++
            "DEFAULT=YES,AUTOSELECT=YES,CHANNELS=\"6/-/-\"",
    );
    try testing.expect(rendition.type.is(.audio));
    try testing.expectEqualStrings("aac", rendition.group_id);
    try testing.expectEqual(@as(?u64, 6), rendition.channelCount());
    try testing.expectEqual(@as(usize, 0), diagnostics.count());

    // Closed captions need an INSTREAM-ID and must not have a URI.
    diagnostics.clear();
    _ = try parseTag(
        Rendition,
        arena.allocator(),
        &diagnostics,
        "TYPE=CLOSED-CAPTIONS,GROUP-ID=\"cc\",NAME=\"CC\",URI=\"x\"",
    );
    try testing.expect(diagnostics.has(.missing_required_attribute));
    try testing.expect(diagnostics.has(.attribute_not_allowed));

    // DEFAULT=YES with AUTOSELECT=NO is a rendition no player will pick.
    // With AUTOSELECT *absent* there is nothing to contradict, which is what
    // the test below this one is about.
    diagnostics.clear();
    _ = try parseTag(
        Rendition,
        arena.allocator(),
        &diagnostics,
        "TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"n\",DEFAULT=YES,AUTOSELECT=NO",
    );
    try testing.expect(diagnostics.has(.invalid_attribute_value));

    // FORCED is only for subtitles.
    diagnostics.clear();
    _ = try parseTag(
        Rendition,
        arena.allocator(),
        &diagnostics,
        "TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"n\",FORCED=YES",
    );
    try testing.expect(diagnostics.has(.attribute_not_allowed));
}

test "session data takes exactly one of VALUE and URI" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    _ = try parseTag(SessionData, arena.allocator(), &diagnostics, "DATA-ID=\"com.e.title\"");
    try testing.expect(diagnostics.has(.missing_required_attribute));

    diagnostics.clear();
    _ = try parseTag(
        SessionData,
        arena.allocator(),
        &diagnostics,
        "DATA-ID=\"com.e.title\",VALUE=\"A\",URI=\"a.json\"",
    );
    try testing.expect(diagnostics.has(.attribute_not_allowed));

    diagnostics.clear();
    const good = try parseTag(
        SessionData,
        arena.allocator(),
        &diagnostics,
        "DATA-ID=\"com.e.title\",VALUE=\"A\"",
    );
    try testing.expectEqual(@as(usize, 0), diagnostics.count());
    try testing.expectEqualStrings("A", good.value.?);
}

test "a define has three shapes and must be exactly one of them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    const declared = try parseTag(Define, arena.allocator(), &diagnostics, "NAME=\"host\",VALUE=\"e.com\"");
    try testing.expectEqualStrings("host", declared.variableName().?);
    try testing.expectEqual(@as(usize, 0), diagnostics.count());

    diagnostics.clear();
    const imported = try parseTag(Define, arena.allocator(), &diagnostics, "IMPORT=\"host\"");
    try testing.expectEqualStrings("host", imported.variableName().?);
    try testing.expectEqual(@as(usize, 0), diagnostics.count());

    // Two shapes at once.
    diagnostics.clear();
    _ = try parseTag(Define, arena.allocator(), &diagnostics, "NAME=\"a\",VALUE=\"b\",IMPORT=\"c\"");
    try testing.expect(diagnostics.has(.invalid_define));

    // None at all.
    diagnostics.clear();
    _ = try parseTag(Define, arena.allocator(), &diagnostics, "VALUE=\"b\"");
    try testing.expect(diagnostics.has(.invalid_define));

    // A NAME with no VALUE. An *empty* value is legal, so this is about
    // absence rather than emptiness.
    diagnostics.clear();
    _ = try parseTag(Define, arena.allocator(), &diagnostics, "NAME=\"a\"");
    try testing.expect(diagnostics.has(.missing_required_attribute));

    diagnostics.clear();
    _ = try parseTag(Define, arena.allocator(), &diagnostics, "NAME=\"a\",VALUE=\"\"");
    try testing.expectEqual(@as(usize, 0), diagnostics.count());
}

test "a negative TIME-OFFSET is allowed where a negative DURATION is not" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    const start = try parseTag(Start, arena.allocator(), &diagnostics, "TIME-OFFSET=-25.5,PRECISE=YES");
    try testing.expectEqual(@as(f64, -25.5), start.time_offset);
    try testing.expect(start.precise);
    try testing.expectEqual(@as(usize, 0), diagnostics.count());

    diagnostics.clear();
    _ = try parseTag(Part, arena.allocator(), &diagnostics, "URI=\"p\",DURATION=-1");
    try testing.expect(diagnostics.has(.invalid_attribute_value));

    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("TIME-OFFSET=-25.5,PRECISE=YES", try writeTag(start, &buffer));
}

test "a YES/NO attribute at its default is left out when written" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const start = try parseTag(Start, arena.allocator(), null, "TIME-OFFSET=5,PRECISE=NO");
    var buffer: [64]u8 = undefined;
    // `PRECISE=NO` means the same as no `PRECISE` at all, so it goes.
    try testing.expectEqualStrings("TIME-OFFSET=5", try writeTag(start, &buffer));
}

test "server control, and the one dependency between its attributes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    const control = try parseTag(
        ServerControl,
        arena.allocator(),
        &diagnostics,
        "CAN-SKIP-UNTIL=36,CAN-SKIP-DATERANGES=YES,PART-HOLD-BACK=3,CAN-BLOCK-RELOAD=YES",
    );
    try testing.expectEqual(@as(f64, 36), control.can_skip_until.?);
    try testing.expect(control.can_block_reload);
    try testing.expectEqual(@as(usize, 0), diagnostics.count());

    diagnostics.clear();
    _ = try parseTag(ServerControl, arena.allocator(), &diagnostics, "CAN-SKIP-DATERANGES=YES");
    try testing.expect(diagnostics.has(.missing_required_attribute));
}

test "a skip's removed dateranges are separated by tabs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const skip = try parseTag(
        Skip,
        arena.allocator(),
        null,
        "SKIPPED-SEGMENTS=100,RECENTLY-REMOVED-DATERANGES=\"a\tb\tc\"",
    );
    try testing.expectEqual(@as(u64, 100), skip.skipped_segments);
    var removed = skip.removedDateRanges();
    try testing.expectEqualStrings("a", removed.next().?);
    try testing.expectEqualStrings("b", removed.next().?);
    try testing.expectEqualStrings("c", removed.next().?);
    try testing.expectEqual(@as(?[]const u8, null), removed.next());
}

test "an attribute list that cannot be read to the end keeps what came before" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    const stream = try parseTag(
        StreamInf,
        arena.allocator(),
        &diagnostics,
        "BANDWIDTH=1000,CODECS=\"unterminated",
    );
    try testing.expectEqual(@as(u64, 1000), stream.bandwidth);
    try testing.expectEqual(@as(?[]const u8, null), stream.codecs);
    try testing.expect(diagnostics.has(.invalid_attribute_list));
}

test "a lower-case attribute name is matched and written back upper-case" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const stream = try parseTag(StreamInf, arena.allocator(), null, "bandwidth=1000,resolution=640x360");
    try testing.expectEqual(@as(u64, 1000), stream.bandwidth);
    try testing.expectEqual(Resolution{ .width = 640, .height = 360 }, stream.resolution.?);

    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings("BANDWIDTH=1000,RESOLUTION=640x360", try writeTag(stream, &buffer));
}

test "tag names, in both directions" {
    try testing.expectEqual(Name.extm3u, fromText("EXTM3U").?);
    try testing.expectEqual(Name.ext_x_stream_inf, fromText("EXT-X-STREAM-INF").?);
    // Case-insensitive.
    try testing.expectEqual(Name.ext_x_endlist, fromText("EXT-X-Endlist").?);
    try testing.expectEqual(@as(?Name, null), fromText("EXT-X-NOT-A-TAG"));
    // Longer than any tag there is, which must not overrun the buffer.
    try testing.expectEqual(@as(?Name, null), fromText("EXT-X-" ++ "A" ** 200));
    try testing.expectEqual(@as(?Name, null), fromText(""));

    try testing.expectEqualStrings("EXT-X-I-FRAME-STREAM-INF", Name.ext_x_i_frame_stream_inf.text());
}

test "every name round-trips through its own text" {
    for (std.enums.values(Name)) |name| {
        try testing.expectEqual(name, fromText(name.text()).?);
    }
}

test "which part of the specification each tag comes from" {
    try testing.expectEqual(Name.Scope.segment, Name.extinf.scope());
    try testing.expectEqual(Name.Scope.media_playlist, Name.ext_x_endlist.scope());
    try testing.expectEqual(Name.Scope.multivariant, Name.ext_x_stream_inf.scope());
    try testing.expectEqual(Name.Scope.multivariant, Name.ext_x_session_key.scope());
    try testing.expectEqual(Name.Scope.either, Name.extm3u.scope());
    try testing.expectEqual(Name.Scope.either, Name.ext_x_start.scope());
    try testing.expectEqual(Name.Scope.either, Name.ext_x_define.scope());
    try testing.expectEqual(Name.Scope.either, Name.extgrp.scope());
    // `#EXT-X-KEY` is a Media Segment tag and `#EXT-X-SESSION-KEY` is a
    // Multivariant one, which is the pair most easily got backwards.
    try testing.expectEqual(Name.Scope.segment, Name.ext_x_key.scope());
}

test "what settles which kind of playlist this is" {
    // `#EXTINF` is the exception: it is a Media Segment tag and it is also
    // the whole of an extended M3U, so on its own it settles nothing.
    try testing.expectEqual(@as(?Name.Scope, null), Name.extinf.settlesKind());
    try testing.expectEqual(@as(?Name.Scope, null), Name.extm3u.settlesKind());
    try testing.expectEqual(@as(?Name.Scope, null), Name.ext_x_version.settlesKind());
    try testing.expectEqual(@as(?Name.Scope, null), Name.ext_x_start.settlesKind());
    try testing.expectEqual(@as(?Name.Scope, null), Name.extgrp.settlesKind());

    // Every other segment tag does settle it, because none of them means
    // anything outside a Media Playlist.
    try testing.expectEqual(Name.Scope.media_playlist, Name.ext_x_key.settlesKind().?);
    try testing.expectEqual(Name.Scope.media_playlist, Name.ext_x_targetduration.settlesKind().?);
    try testing.expectEqual(Name.Scope.multivariant, Name.ext_x_media.settlesKind().?);
}

test "the version each tag needs" {
    try testing.expectEqual(@as(u64, 4), Name.ext_x_byterange.minimumVersion());
    try testing.expectEqual(@as(u64, 5), Name.ext_x_map.minimumVersion());
    try testing.expectEqual(@as(u64, 6), Name.ext_x_daterange.minimumVersion());
    try testing.expectEqual(@as(u64, 9), Name.ext_x_part.minimumVersion());
    try testing.expectEqual(@as(u64, 0), Name.extinf.minimumVersion());
}

test "a value that could not be written back inside quotes is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    // `URI=\xffinit.mp4"` is an unquoted value holding a double quote.
    // Quoting it on the way out would give `URI="\xffinit.mp4""`, which
    // reads back as something else -- so it is refused here instead, and
    // the field keeps its default.
    const map = try parseTag(Map, arena.allocator(), &diagnostics, "URI=init.mp4\"");
    try testing.expectEqualStrings("", map.uri);
    try testing.expect(diagnostics.has(.invalid_attribute_value));

    // A carriage return is the same problem: §4.2 says a quoted-string
    // holds neither.
    diagnostics.clear();
    const cr = try parseTag(Map, arena.allocator(), &diagnostics, "URI=a\rb");
    try testing.expectEqualStrings("", cr.uri);
    try testing.expect(diagnostics.has(.invalid_attribute_value));

    // A quoted value needs no check, because the quotes could not have
    // contained either character in the first place.
    diagnostics.clear();
    const quoted = try parseTag(Map, arena.allocator(), &diagnostics, "URI=\"init.mp4\"");
    try testing.expectEqualStrings("init.mp4", quoted.uri);
    try testing.expectEqual(@as(usize, 0), diagnostics.count());

    // ...and the same rule applies to a `CLOSED-CAPTIONS` group id, which
    // does not go through `decode`.
    diagnostics.clear();
    const captions = try parseTag(StreamInf, arena.allocator(), &diagnostics, "BANDWIDTH=1,CLOSED-CAPTIONS=a\"b");
    try testing.expectEqual(@as(?ClosedCaptions, null), captions.closed_captions);
    try testing.expect(diagnostics.has(.invalid_attribute_value));
}

test "a rule that turns on an attribute being present, not on its value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    // §4.3.4.1 says `AUTOSELECT`, *if present*, must be YES where `DEFAULT`
    // is. With no `AUTOSELECT` at all there is nothing to contradict --
    // which is how all nine renditions in the RFC's own §8.7 example are
    // written.
    _ = try parseTag(
        Rendition,
        arena.allocator(),
        &diagnostics,
        "TYPE=VIDEO,GROUP-ID=\"low\",NAME=\"Main\",DEFAULT=YES,URI=\"low/main.m3u8\"",
    );
    try testing.expectEqual(@as(usize, 0), diagnostics.count());

    // Present and NO is the rendition no player will pick.
    diagnostics.clear();
    _ = try parseTag(
        Rendition,
        arena.allocator(),
        &diagnostics,
        "TYPE=VIDEO,GROUP-ID=\"low\",NAME=\"Main\",DEFAULT=YES,AUTOSELECT=NO",
    );
    try testing.expect(diagnostics.has(.invalid_attribute_value));

    try testing.expect(hasAttribute("A=1,AUTOSELECT=NO", "AUTOSELECT"));
    try testing.expect(hasAttribute("autoselect=no", "AUTOSELECT"));
    try testing.expect(!hasAttribute("A=1", "AUTOSELECT"));
    try testing.expect(!hasAttribute("", "AUTOSELECT"));
    // A list that cannot be read says no rather than guessing.
    try testing.expect(!hasAttribute("A=\"unterminated", "AUTOSELECT"));
}

test "a date range with no START-DATE is a warning, not a loss" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostics: Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();

    // §4.3.2.7 makes it REQUIRED and §8.10's second tag has none, because it
    // updates the range the first tag identified. `strict` must not refuse a
    // playlist the specification prints as an example.
    _ = try parseTag(
        DateRange,
        arena.allocator(),
        &diagnostics,
        "ID=\"splice-6FFFFFF0\",DURATION=59.993,SCTE35-IN=0xFC002A",
    );
    try testing.expect(diagnostics.has(.missing_required_attribute));
    try testing.expectEqual(@as(usize, 0), diagnostics.invalidCount());
}
