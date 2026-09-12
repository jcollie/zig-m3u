// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The one date format this file format uses.
//!
//! `#EXT-X-PROGRAM-DATE-TIME` and `#EXT-X-DATERANGE`'s `START-DATE` and
//! `END-DATE` all carry an ISO/IEC 8601:2004 date and time — RFC 8216
//! §4.3.2.6 gives `2010-02-19T14:54:23.031+08:00` as the example, and that
//! example has every part of it: a fraction of a second and an offset that is
//! not UTC.
//!
//! # Why this is not `std.time.epoch`
//!
//! `std.time.epoch` only decodes. It turns a second count into a date and has
//! nothing going the other way, and its `EpochSeconds.secs` is a `u64`, so it
//! cannot hold a date before 1970 — which a programme date certainly can, for
//! an archive of something broadcast in 1969. What is here instead is Howard
//! Hinnant's pair of calendar algorithms, `daysFromCivil` and `civilFromDays`,
//! which are exact over the whole proleptic Gregorian calendar in both
//! directions and are about fifteen lines each.
//!
//! # What a `DateTime` keeps, and why it keeps it
//!
//! More than an instant. A `DateTime` holds the fields as written, the number
//! of digits the fraction was written with, and how the zone was spelled, so
//! that a playlist read and written again says the same thing rather than the
//! same instant in a different notation. `2010-02-19T14:54:23.031+08:00` and
//! `2010-02-19T06:54:23.031Z` are the same moment, and a tool that rewrote one
//! into the other would be changing a file it was asked to leave alone.
//!
//! `toUnixNanoseconds` is there for when the instant is what is wanted.

const std = @import("std");
const Io = std.Io;

/// A date and time with an offset from UTC, as ISO 8601 writes one.
///
/// Every field is in the range its name implies once the value has come from
/// `parse`; a `DateTime` assembled by hand is checked by `validate`.
pub const DateTime = struct {
    /// The proleptic Gregorian year. `parse` accepts four digits, so from
    /// there this is 0 to 9999; the calendar arithmetic below is exact well
    /// outside that.
    year: i32,
    /// 1 to 12.
    month: u8,
    /// 1 to the length of `month` in `year`.
    day: u8,
    /// 0 to 23.
    hour: u8,
    /// 0 to 59.
    minute: u8,
    /// 0 to 60. Sixty is a leap second, which ISO 8601 allows and which
    /// `toUnixNanoseconds` reports as the first instant of the next minute —
    /// the same thing every other implementation does, since the alternative
    /// is a table of leap seconds that goes stale.
    second: u8,
    /// The fraction of a second, in nanoseconds: 0 to 999_999_999.
    nanosecond: u32 = 0,
    /// How many digits the fraction was written with, so that `format` can
    /// write it back the same width. Zero means there was no fraction at all,
    /// which is different from a fraction of zero: `...:23Z` and `...:23.000Z`
    /// are both read and both written back as they came.
    ///
    /// At most 9. A fraction written with more digits than that is truncated
    /// to nanoseconds, which is the one place `parse` loses information.
    fraction_digits: u8 = 0,
    /// Minutes east of UTC: `+08:00` is 480, `-05:30` is -330.
    offset_minutes: i16 = 0,
    /// How the offset was written, which `format` reproduces.
    zone: Zone = .utc,

    /// How the offset from UTC was spelled.
    pub const Zone = enum {
        /// `Z`. `offset_minutes` is zero.
        utc,
        /// `+HH:MM` or `-HH:MM`, including `+00:00` — which means the same
        /// instant as `Z` and is not the same six characters.
        offset,
        /// Nothing at all, which ISO 8601 reads as local time.
        ///
        /// RFC 8216 §4.3.2.6 requires a zone, so this only arrives from a
        /// lenient `parse`, and it is reported as a `Problem`. Treating it as
        /// UTC is a guess, so `toUnixNanoseconds` refuses it rather than
        /// making one.
        none,
    };

    pub const ParseError = error{
        /// The text is not `YYYY-MM-DDTHH:MM:SS` with an optional fraction
        /// and an optional zone: a separator is wrong, a field is the wrong
        /// width, or there is trailing rubbish.
        InvalidDateTime,
        /// Every field is a number and at least one of them is out of range:
        /// a thirteenth month, the thirtieth of February, an offset of more
        /// than a day.
        DateOutOfRange,
    };

    /// Read `YYYY-MM-DDTHH:MM:SS[.fraction][Z|±HH:MM]`.
    ///
    /// Lenient in three ways, each of which is something real playlists do
    /// and none of which loses information:
    ///
    /// * The date and time may be joined by `T`, `t` or a space. `format`
    ///   always writes `T`.
    /// * The offset may be written `±HHMM` or `±HH` as well as `±HH:MM`.
    ///   `format` always writes `±HH:MM`.
    /// * The zone may be left off entirely, which gives `zone == .none`.
    ///
    /// It is strict about the widths of the fields, because `2010-2-19` is
    /// ambiguous with nothing and is not what any tool writes; about the
    /// ranges, so that `2010-02-30` is an error here rather than a surprise
    /// in whatever does arithmetic on it; and about trailing text, so that a
    /// quoted date with a stray character in it does not parse to the date
    /// without it.
    pub fn parse(text: []const u8) ParseError!DateTime {
        // `YYYY-MM-DDTHH:MM:SS` is nineteen characters and nothing shorter
        // can be a date and a time.
        if (text.len < 19) return error.InvalidDateTime;
        if (text[4] != '-' or text[7] != '-') return error.InvalidDateTime;
        if (text[10] != 'T' and text[10] != 't' and text[10] != ' ') return error.InvalidDateTime;
        if (text[13] != ':' or text[16] != ':') return error.InvalidDateTime;

        // Read every field as a wide integer and narrow only after the range
        // check below: `@intCast` of a two-digit number into a field that
        // cannot hold it is a panic rather than an error, so a playlist
        // saying `2010-99-01` would crash whatever was listing it.
        const year = try digits(text[0..4]);
        const month = try digits(text[5..7]);
        const day = try digits(text[8..10]);
        const hour = try digits(text[11..13]);
        const minute = try digits(text[14..16]);
        const second = try digits(text[17..19]);

        var rest = text[19..];

        var nanosecond: u32 = 0;
        var fraction_digits: u8 = 0;
        if (rest.len > 0 and rest[0] == '.') {
            rest = rest[1..];
            var count: usize = 0;
            while (count < rest.len and rest[count] >= '0' and rest[count] <= '9') count += 1;
            if (count == 0) return error.InvalidDateTime;
            // Nanosecond resolution, so nine digits are kept and anything
            // beyond them is dropped. Rounding instead would let a date move
            // forwards every time a playlist was rewritten.
            const kept = @min(count, 9);
            var scale: u32 = 1_000_000_000;
            for (rest[0..kept]) |c| {
                scale /= 10;
                nanosecond += @as(u32, c - '0') * scale;
            }
            fraction_digits = @intCast(kept);
            rest = rest[count..];
        }

        var zone: Zone = .none;
        var offset_minutes: i32 = 0;
        if (rest.len > 0) {
            switch (rest[0]) {
                'Z', 'z' => {
                    zone = .utc;
                    rest = rest[1..];
                },
                '+', '-' => {
                    const negative = rest[0] == '-';
                    rest = rest[1..];
                    if (rest.len < 2) return error.InvalidDateTime;
                    const offset_hours = try digits(rest[0..2]);
                    rest = rest[2..];
                    var offset_mins: u64 = 0;
                    if (rest.len > 0 and rest[0] == ':') {
                        if (rest.len < 3) return error.InvalidDateTime;
                        offset_mins = try digits(rest[1..3]);
                        rest = rest[3..];
                    } else if (rest.len >= 2 and rest[0] >= '0' and rest[0] <= '9') {
                        offset_mins = try digits(rest[0..2]);
                        rest = rest[2..];
                    }
                    if (offset_hours > 23 or offset_mins > 59) return error.DateOutOfRange;
                    const total: i32 = @intCast(offset_hours * 60 + offset_mins);
                    offset_minutes = if (negative) -total else total;
                    zone = .offset;
                },
                else => return error.InvalidDateTime,
            }
        }
        if (rest.len != 0) return error.InvalidDateTime;

        if (month < 1 or month > 12) return error.DateOutOfRange;
        if (hour > 23 or minute > 59 or second > 60) return error.DateOutOfRange;
        const year_narrow: i32 = @intCast(year);
        if (day < 1 or day > daysInMonth(year_narrow, @intCast(month))) return error.DateOutOfRange;

        return .{
            .year = year_narrow,
            .month = @intCast(month),
            .day = @intCast(day),
            .hour = @intCast(hour),
            .minute = @intCast(minute),
            .second = @intCast(second),
            .nanosecond = nanosecond,
            .fraction_digits = fraction_digits,
            .offset_minutes = @intCast(offset_minutes),
            .zone = zone,
        };
    }

    pub const ValidateError = error{DateOutOfRange};

    /// Check a `DateTime` that was assembled rather than parsed. `format`
    /// would otherwise write something that does not parse back.
    pub fn validate(dt: DateTime) ValidateError!void {
        if (dt.month < 1 or dt.month > 12) return error.DateOutOfRange;
        if (dt.day < 1 or dt.day > daysInMonth(dt.year, dt.month)) return error.DateOutOfRange;
        if (dt.hour > 23 or dt.minute > 59 or dt.second > 60) return error.DateOutOfRange;
        if (dt.nanosecond > 999_999_999) return error.DateOutOfRange;
        if (dt.fraction_digits > 9) return error.DateOutOfRange;
        if (dt.offset_minutes <= -1440 or dt.offset_minutes >= 1440) return error.DateOutOfRange;
        if (dt.zone == .utc and dt.offset_minutes != 0) return error.DateOutOfRange;
        if (dt.year < 0 or dt.year > 9999) return error.DateOutOfRange;
    }

    /// Write the date back in the notation it was read in.
    ///
    /// Reached by `{f}`. The year is written with four digits, so a
    /// `DateTime` outside 0 to 9999 — which `parse` cannot produce and
    /// `validate` rejects — comes out wider than it went in.
    pub fn format(dt: DateTime, w: *Io.Writer) Io.Writer.Error!void {
        // The sign is written by hand and the year is made unsigned, because
        // Zig's `{d}` with a width prints a `+` in front of a non-negative
        // *signed* integer -- so `{d:0>4}` of `2020` is `+2020`.
        if (dt.year < 0) try w.writeByte('-');
        try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
            @abs(dt.year), dt.month, dt.day, dt.hour, dt.minute, dt.second,
        });
        if (dt.fraction_digits > 0) {
            try w.writeByte('.');
            const digit_count = @min(dt.fraction_digits, 9);
            var scale: u32 = 100_000_000;
            for (0..digit_count) |_| {
                try w.writeByte('0' + @as(u8, @intCast((dt.nanosecond / scale) % 10)));
                scale /= 10;
            }
        }
        switch (dt.zone) {
            .utc => try w.writeByte('Z'),
            .none => {},
            .offset => {
                const negative = dt.offset_minutes < 0;
                const total: u32 = @abs(dt.offset_minutes);
                try w.print("{c}{d:0>2}:{d:0>2}", .{
                    @as(u8, if (negative) '-' else '+'),
                    total / 60,
                    total % 60,
                });
            },
        }
    }

    pub const InstantError = error{
        /// The date has no zone, so which instant it names depends on where
        /// the reader is. Guessing UTC would be wrong somewhere.
        NoZone,
    };

    /// The instant this names, as nanoseconds since 1970-01-01T00:00:00Z.
    ///
    /// Negative for a date before 1970. A leap second — `second == 60` —
    /// lands on the first instant of the following minute, since the
    /// alternative is a leap-second table that needs maintaining.
    pub fn toUnixNanoseconds(dt: DateTime) InstantError!i128 {
        if (dt.zone == .none) return error.NoZone;
        const days = daysFromCivil(dt.year, dt.month, dt.day);
        const seconds = days * std.time.s_per_day +
            @as(i64, dt.hour) * 3600 +
            @as(i64, dt.minute) * 60 +
            @as(i64, dt.second) -
            @as(i64, dt.offset_minutes) * 60;
        return @as(i128, seconds) * std.time.ns_per_s + dt.nanosecond;
    }

    /// Seconds since 1970, discarding the fraction towards negative infinity.
    pub fn toUnixSeconds(dt: DateTime) InstantError!i64 {
        return @intCast(@divFloor(try dt.toUnixNanoseconds(), std.time.ns_per_s));
    }

    pub const FromInstantError = error{
        /// The instant is outside the years `format` can write, which is
        /// 0 to 9999.
        DateOutOfRange,
    };

    /// The UTC date and time at `nanoseconds` after 1970.
    ///
    /// `fraction_digits` comes out as 9 when there is a fraction and 0 when
    /// there is not, so that a date made this way and written is exact rather
    /// than rounded to the second.
    pub fn fromUnixNanoseconds(nanoseconds: i128) FromInstantError!DateTime {
        // `@divFloor` and `@mod` rather than a subtraction, because
        // `seconds - days * 86400` overflows one day below the bottom of the
        // range while the modulus does not.
        const seconds: i64 = @intCast(@divFloor(nanoseconds, std.time.ns_per_s));
        const nanosecond: u32 = @intCast(@mod(nanoseconds, std.time.ns_per_s));

        const days = @divFloor(seconds, std.time.s_per_day);
        const day_seconds: u64 = @intCast(@mod(seconds, std.time.s_per_day));

        const civil = civilFromDays(days);
        if (civil.year < 0 or civil.year > 9999) return error.DateOutOfRange;

        return .{
            .year = @intCast(civil.year),
            .month = civil.month,
            .day = civil.day,
            .hour = @intCast(day_seconds / 3600),
            .minute = @intCast((day_seconds % 3600) / 60),
            .second = @intCast(day_seconds % 60),
            .nanosecond = nanosecond,
            .fraction_digits = if (nanosecond == 0) 0 else 9,
            .offset_minutes = 0,
            .zone = .utc,
        };
    }

    /// Whether two dates name the same instant, whatever notation each is
    /// written in. `2010-02-19T14:54:23+08:00` and `2010-02-19T06:54:23Z`
    /// are equal by this and not by `std.meta.eql`.
    ///
    /// **False when either date has no zone**, even for a date compared with
    /// itself, because a date with no zone names no instant — which is what
    /// `toUnixNanoseconds` refuses to guess at. Check `zone` first if that
    /// matters; `sameText` is the reflexive comparison.
    pub fn sameInstant(a: DateTime, b: DateTime) bool {
        const an = a.toUnixNanoseconds() catch return false;
        const bn = b.toUnixNanoseconds() catch return false;
        return an == bn;
    }

    /// Exactly the same notation: every field, the width of the fraction and
    /// the spelling of the zone. This is what a round-trip test asserts,
    /// since `sameInstant` would pass while the file was being rewritten into
    /// a different notation each time.
    pub fn sameText(a: DateTime, b: DateTime) bool {
        return std.meta.eql(a, b);
    }
};

/// A date with no time on it, which is what the calendar algorithms deal in.
pub const Civil = struct {
    year: i64,
    month: u8,
    day: u8,
};

/// Howard Hinnant's `days_from_civil`: the number of days from 1970-01-01 to
/// the given proleptic Gregorian date, negative before that.
///
/// Exact for every year that fits the arithmetic. `era * 146097` is where it
/// would overflow, so a year beyond about 63 trillion is out of reach — far
/// outside anything `DateTime` accepts, and worth saying because the same
/// function with an `i32` era would break inside the range of a file's mtime.
pub fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    // March is treated as the first month, which is what puts the leap day
    // at the end of the year and makes the rest of this arithmetic exact.
    const y = year - @as(i64, @intFromBool(month <= 2));
    const era = @divFloor(y, 400);
    const year_of_era: u64 = @intCast(y - era * 400); // 0 to 399
    const shifted_month: u64 = if (month > 2) @as(u64, month) - 3 else @as(u64, month) + 9;
    const day_of_year = (153 * shifted_month + 2) / 5 + day - 1; // 0 to 365
    const day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    return era * 146097 + @as(i64, @intCast(day_of_era)) - 719468;
}

/// Howard Hinnant's `civil_from_days`, the inverse of `daysFromCivil`.
///
/// Exact for any day count reachable from an `i64` second count, which is
/// where the widths matter: the year it returns can be outside an `i32`, so
/// a caller that wants one has to check rather than cast.
pub fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const day_of_era: u64 = @intCast(z - era * 146097); // 0 to 146096
    const year_of_era = (day_of_era - day_of_era / 1460 + day_of_era / 36524 -
        day_of_era / 146096) / 365; // 0 to 399
    const day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    const shifted_month = (5 * day_of_year + 2) / 153; // 0 to 11
    const day = day_of_year - (153 * shifted_month + 2) / 5 + 1; // 1 to 31
    const month = if (shifted_month < 10) shifted_month + 3 else shifted_month - 9;
    return .{
        .year = @as(i64, @intCast(year_of_era)) + era * 400 + @intFromBool(month <= 2),
        .month = @intCast(month),
        .day = @intCast(day),
    };
}

/// Whether `year` is a leap year in the proleptic Gregorian calendar.
pub fn isLeapYear(year: i32) bool {
    if (@mod(year, 4) != 0) return false;
    if (@mod(year, 100) != 0) return true;
    return @mod(year, 400) == 0;
}

/// How many days `month` has in `year`. Zero for a month outside 1 to 12,
/// so that a range check written as `day > daysInMonth(...)` catches a bad
/// month as well as a bad day.
pub fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

/// Read exactly `text.len` decimal digits. Wide on purpose: the result is
/// range-checked by the caller and narrowed afterwards, never before.
fn digits(text: []const u8) error{InvalidDateTime}!u64 {
    var value: u64 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return error.InvalidDateTime;
        value = value * 10 + (c - '0');
    }
    return value;
}

// -- tests -----------------------------------------------------------------

const testing = std.testing;

/// Parse, write, and give back what was written, for the tests below.
fn roundTrip(text: []const u8, buffer: []u8) ![]const u8 {
    const dt = try DateTime.parse(text);
    var w: Io.Writer = .fixed(buffer);
    try w.print("{f}", .{dt});
    return w.buffered();
}

test "the example from RFC 8216" {
    const dt = try DateTime.parse("2010-02-19T14:54:23.031+08:00");
    try testing.expectEqual(@as(i32, 2010), dt.year);
    try testing.expectEqual(@as(u8, 2), dt.month);
    try testing.expectEqual(@as(u8, 19), dt.day);
    try testing.expectEqual(@as(u8, 14), dt.hour);
    try testing.expectEqual(@as(u8, 54), dt.minute);
    try testing.expectEqual(@as(u8, 23), dt.second);
    try testing.expectEqual(@as(u32, 31_000_000), dt.nanosecond);
    try testing.expectEqual(@as(u8, 3), dt.fraction_digits);
    try testing.expectEqual(@as(i16, 480), dt.offset_minutes);
    try testing.expectEqual(DateTime.Zone.offset, dt.zone);

    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("2010-02-19T14:54:23.031+08:00", try roundTrip("2010-02-19T14:54:23.031+08:00", &buffer));
}

test "the notation is preserved, not normalised" {
    var buffer: [64]u8 = undefined;
    // A fraction of zero is not the same text as no fraction at all, and
    // both come back as they went in.
    try testing.expectEqualStrings("2020-01-01T00:00:00Z", try roundTrip("2020-01-01T00:00:00Z", &buffer));
    try testing.expectEqualStrings("2020-01-01T00:00:00.000Z", try roundTrip("2020-01-01T00:00:00.000Z", &buffer));
    // `+00:00` means the same instant as `Z` and is not the same notation.
    try testing.expectEqualStrings("2020-01-01T00:00:00+00:00", try roundTrip("2020-01-01T00:00:00+00:00", &buffer));
}

test "the lenient spellings are accepted and then written canonically" {
    var buffer: [64]u8 = undefined;
    // A lower-case `t` and `z`.
    try testing.expectEqualStrings("2020-01-01T00:00:00Z", try roundTrip("2020-01-01t00:00:00z", &buffer));
    // A space where the `T` belongs.
    try testing.expectEqualStrings("2020-01-01T00:00:00Z", try roundTrip("2020-01-01 00:00:00Z", &buffer));
    // An offset with no colon, and one with no minutes.
    try testing.expectEqualStrings("2020-01-01T00:00:00-05:30", try roundTrip("2020-01-01T00:00:00-0530", &buffer));
    try testing.expectEqualStrings("2020-01-01T00:00:00+02:00", try roundTrip("2020-01-01T00:00:00+02", &buffer));
}

test "no zone is a zone of its own, and has no instant" {
    const dt = try DateTime.parse("2020-01-01T00:00:00");
    try testing.expectEqual(DateTime.Zone.none, dt.zone);
    try testing.expectError(error.NoZone, dt.toUnixNanoseconds());

    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("2020-01-01T00:00:00", try roundTrip("2020-01-01T00:00:00", &buffer));
}

test "a fraction wider than nanoseconds is truncated" {
    const dt = try DateTime.parse("2020-01-01T00:00:00.1234567891234Z");
    try testing.expectEqual(@as(u32, 123_456_789), dt.nanosecond);
    try testing.expectEqual(@as(u8, 9), dt.fraction_digits);

    var buffer: [64]u8 = undefined;
    // Written with the nine digits that were kept, which is the one place
    // the notation is not preserved -- and it is stable, so a second
    // round trip changes nothing.
    try testing.expectEqualStrings(
        "2020-01-01T00:00:00.123456789Z",
        try roundTrip("2020-01-01T00:00:00.1234567891234Z", &buffer),
    );
    var again: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "2020-01-01T00:00:00.123456789Z",
        try roundTrip(try roundTrip("2020-01-01T00:00:00.1234567891234Z", &buffer), &again),
    );
}

test "what is not a date" {
    // Fields of the wrong width.
    try testing.expectError(error.InvalidDateTime, DateTime.parse("2010-2-19T14:54:23Z"));
    try testing.expectError(error.InvalidDateTime, DateTime.parse("210-02-19T14:54:23Z"));
    // Truncated.
    try testing.expectError(error.InvalidDateTime, DateTime.parse("2010-02-19"));
    try testing.expectError(error.InvalidDateTime, DateTime.parse(""));
    // Wrong separators.
    try testing.expectError(error.InvalidDateTime, DateTime.parse("2010/02/19T14:54:23Z"));
    try testing.expectError(error.InvalidDateTime, DateTime.parse("2010-02-19T14-54-23Z"));
    // A fraction with no digits.
    try testing.expectError(error.InvalidDateTime, DateTime.parse("2010-02-19T14:54:23.Z"));
    // Trailing rubbish, which must not parse to the date without it.
    try testing.expectError(error.InvalidDateTime, DateTime.parse("2010-02-19T14:54:23Zx"));
    try testing.expectError(error.InvalidDateTime, DateTime.parse("2010-02-19T14:54:23+08:00 "));
    // A zone that is not one.
    try testing.expectError(error.InvalidDateTime, DateTime.parse("2010-02-19T14:54:23X"));
}

test "fields that are numbers and still wrong" {
    // The month check has to come before the narrowing cast, or this panics
    // instead of failing.
    try testing.expectError(error.DateOutOfRange, DateTime.parse("2010-99-01T00:00:00Z"));
    try testing.expectError(error.DateOutOfRange, DateTime.parse("2010-00-01T00:00:00Z"));
    try testing.expectError(error.DateOutOfRange, DateTime.parse("2010-02-30T00:00:00Z"));
    try testing.expectError(error.DateOutOfRange, DateTime.parse("2010-01-00T00:00:00Z"));
    try testing.expectError(error.DateOutOfRange, DateTime.parse("2010-01-01T24:00:00Z"));
    try testing.expectError(error.DateOutOfRange, DateTime.parse("2010-01-01T00:60:00Z"));
    try testing.expectError(error.DateOutOfRange, DateTime.parse("2010-01-01T00:00:61Z"));
    try testing.expectError(error.DateOutOfRange, DateTime.parse("2010-01-01T00:00:00+24:00"));
    try testing.expectError(error.DateOutOfRange, DateTime.parse("2010-01-01T00:00:00+00:60"));
}

test "February the twenty-ninth, when there is one" {
    _ = try DateTime.parse("2020-02-29T00:00:00Z");
    _ = try DateTime.parse("2000-02-29T00:00:00Z");
    try testing.expectError(error.DateOutOfRange, DateTime.parse("2021-02-29T00:00:00Z"));
    // 1900 is divisible by 4 and by 100 and not by 400.
    try testing.expectError(error.DateOutOfRange, DateTime.parse("1900-02-29T00:00:00Z"));
}

test "a leap second is accepted and lands on the next minute" {
    const dt = try DateTime.parse("2016-12-31T23:59:60Z");
    try testing.expectEqual(@as(u8, 60), dt.second);
    const at = try dt.toUnixNanoseconds();
    const next = try (try DateTime.parse("2017-01-01T00:00:00Z")).toUnixNanoseconds();
    try testing.expectEqual(next, at);
}

test "instants, in both directions" {
    try testing.expectEqual(
        @as(i128, 0),
        try (try DateTime.parse("1970-01-01T00:00:00Z")).toUnixNanoseconds(),
    );
    // The offset is subtracted, not added: 14:54 at +08:00 is 06:54 UTC.
    try testing.expect((try DateTime.parse("2010-02-19T14:54:23.031+08:00"))
        .sameInstant(try DateTime.parse("2010-02-19T06:54:23.031Z")));
    // ...and that is not the same notation.
    try testing.expect(!(try DateTime.parse("2010-02-19T14:54:23.031+08:00"))
        .sameText(try DateTime.parse("2010-02-19T06:54:23.031Z")));

    // Before 1970, which is the case `std.time.epoch` cannot represent at
    // all and the reason this file exists.
    const apollo = try DateTime.parse("1969-07-20T20:17:40Z");
    try testing.expectEqual(@as(i64, -14182940), try apollo.toUnixSeconds());
    const back = try DateTime.fromUnixNanoseconds(try apollo.toUnixNanoseconds());
    try testing.expect(apollo.sameText(back));
}

test "every day of four centuries survives the calendar round trip" {
    // 1900 to 2300, which covers both kinds of century: one that is a leap
    // year and one that is not.
    var day = daysFromCivil(1900, 1, 1);
    const last = daysFromCivil(2300, 1, 1);
    var expected: Civil = .{ .year = 1900, .month = 1, .day = 1 };
    while (day < last) : (day += 1) {
        const civil = civilFromDays(day);
        try testing.expectEqual(expected.year, civil.year);
        try testing.expectEqual(expected.month, civil.month);
        try testing.expectEqual(expected.day, civil.day);
        try testing.expectEqual(day, daysFromCivil(civil.year, civil.month, civil.day));

        expected.day += 1;
        if (expected.day > daysInMonth(@intCast(expected.year), expected.month)) {
            expected.day = 1;
            expected.month += 1;
            if (expected.month > 12) {
                expected.month = 1;
                expected.year += 1;
            }
        }
    }
}

test "the calendar is exact outside the years a DateTime can hold" {
    // `civilFromDays` returns an `i64` year on purpose: this is the range a
    // caller has to check rather than cast.
    try testing.expectEqual(@as(i64, -1), civilFromDays(daysFromCivil(-1, 3, 1)).year);
    try testing.expectEqual(@as(i64, 100000), civilFromDays(daysFromCivil(100000, 1, 1)).year);
    // And a `DateTime` refuses what it cannot write.
    try testing.expectError(
        error.DateOutOfRange,
        DateTime.fromUnixNanoseconds(@as(i128, daysFromCivil(10000, 1, 1)) * std.time.s_per_day * std.time.ns_per_s),
    );
}

test "fromUnixNanoseconds floors rather than truncating" {
    // Half a second before the epoch is 1969, not 1970 with a negative
    // fraction. `@mod` rather than a remainder is what makes this true.
    const dt = try DateTime.fromUnixNanoseconds(-500_000_000);
    try testing.expectEqual(@as(i32, 1969), dt.year);
    try testing.expectEqual(@as(u8, 12), dt.month);
    try testing.expectEqual(@as(u8, 31), dt.day);
    try testing.expectEqual(@as(u8, 23), dt.hour);
    try testing.expectEqual(@as(u8, 59), dt.minute);
    try testing.expectEqual(@as(u8, 59), dt.second);
    try testing.expectEqual(@as(u32, 500_000_000), dt.nanosecond);
}

test "validate refuses what format could not write back" {
    try testing.expectError(error.DateOutOfRange, (DateTime{
        .year = 2020,
        .month = 13,
        .day = 1,
        .hour = 0,
        .minute = 0,
        .second = 0,
    }).validate());
    // `Z` with a non-zero offset is a contradiction.
    try testing.expectError(error.DateOutOfRange, (DateTime{
        .year = 2020,
        .month = 1,
        .day = 1,
        .hour = 0,
        .minute = 0,
        .second = 0,
        .offset_minutes = 60,
        .zone = .utc,
    }).validate());
    try (DateTime{
        .year = 2020,
        .month = 1,
        .day = 1,
        .hour = 0,
        .minute = 0,
        .second = 0,
        .offset_minutes = 60,
        .zone = .offset,
    }).validate();
}
