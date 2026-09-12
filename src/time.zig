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
//! [zig-datetime](https://git.jcollie.dev/jeff/zig-datetime) does the work:
//! the ISO 8601 grammar, the calendar, the range checking and the conversion
//! to and from instants. This file is the thin layer between it and the two
//! things a playlist needs that a date value cannot carry on its own.
//!
//! # Why this is not `std.time.epoch`
//!
//! It only decodes — it turns a second count into a date and has nothing
//! going the other way — and its `EpochSeconds.secs` is a `u64`, so it cannot
//! hold a date before 1970, which a programme date certainly can: an archive
//! of something broadcast in 1969 has one.
//!
//! # What this adds to a date, and why
//!
//! Two things, and both of them are about *notation* rather than about time.
//!
//! `2010-02-19T14:54:23.031+08:00` and `2010-02-19T06:54:23.031Z` are the
//! same moment written two ways, and a tool asked to change one tag in a
//! playlist must not rewrite every date in it into a different notation. So a
//! `DateTime` here records how the offset was spelled — `Z` is not `+00:00`,
//! though they mean the same instant — and how many digits the fraction was
//! written with, since `...:23Z`, `...:23.0Z` and `...:23.000Z` are three
//! spellings of one time. zig-datetime's `iso8601.ParseResult` reports
//! neither, having no reason to: they are the same date.
//!
//! Everything else comes from the value inside. `dt.value` is a
//! `datetime.DateTime`, so `add`, `toInstant`, `asDate`, `isoWeek`,
//! `dayOfThisYear` and the rest are all there, and `Month` is an enum rather
//! than a number.

const std = @import("std");
const Io = std.Io;

const datetime = @import("datetime");

/// zig-datetime itself, for a caller that wants more of it than this
/// re-exports — timezones, durations, locale-aware formatting.
pub const dt = datetime;

/// Re-exported so that reading a playlist's dates does not oblige a caller
/// to name zig-datetime as a dependency of their own.
pub const Month = datetime.Month;
pub const Date = datetime.Date;
pub const Instant = datetime.Instant;
pub const Duration = datetime.Duration;
pub const DayOfWeek = datetime.DayOfWeek;

/// The years `format` can write with four digits, which is every year a
/// playlist has any business carrying.
pub const min_year = 0;
pub const max_year = 9999;

/// A date and time as a playlist writes one: an instant, and the notation it
/// was written in.
pub const DateTime = struct {
    /// The date, the time and the offset from UTC. zig-datetime holds the
    /// offset in **seconds** east of UTC, because a historical local mean
    /// time offset is not a whole number of minutes; every offset a playlist
    /// carries is.
    value: datetime.DateTime,
    /// How many digits the fraction of a second was written with, so that
    /// `format` can write it back the same width. Zero means there was no
    /// fraction at all, which is not the same as a fraction of zero:
    /// `...:23Z` and `...:23.000Z` are both read and both written as they
    /// came.
    ///
    /// At most 9. A fraction written with more digits than that is truncated
    /// to nanoseconds, which is the one place `parse` loses information.
    fraction_digits: u8 = 0,
    /// How the offset was written, which `format` reproduces.
    zone: Zone = .utc,

    /// How the offset from UTC was spelled.
    pub const Zone = enum {
        /// `Z`, and `value.offset` is zero.
        utc,
        /// `+HH:MM` or `-HH:MM`, including `+00:00` — which names the same
        /// instant as `Z` and is not the same six characters.
        offset,
        /// Nothing at all, which ISO 8601 reads as local time.
        ///
        /// RFC 8216 §4.3.2.6 requires a zone, so this only arrives from a
        /// lenient `parse` and is reported as a `Problem`. Which instant it
        /// names depends on where the reader is, so `toInstant` refuses it
        /// rather than guessing.
        none,
    };

    pub const ParseError = error{
        /// The text is not an ISO 8601 date *and* time, or there is trailing
        /// rubbish after it.
        InvalidDateTime,
        /// Every field is a number and at least one of them is out of range:
        /// a thirteenth month, the thirtieth of February, a year `format`
        /// could not write back.
        DateOutOfRange,
    };

    /// Read an ISO 8601 date and time.
    ///
    /// Whatever zig-datetime accepts, which is more than RFC 8216 asks for
    /// and all of it harmless: `T`, `t` or a space between the date and the
    /// time; `Z`, `z`, `±HH:MM`, `±HHMM`, `±HH` or no zone at all; the basic
    /// form `20200101T000000Z` as well as the extended one; a week date;
    /// a fraction of any width. `format` writes the extended form with a
    /// calendar date, so a playlist written in one of the others comes back
    /// in this one — naming the same instant, which is why the round trip
    /// still settles.
    ///
    /// Two things are refused that zig-datetime allows on its own, because
    /// RFC 8216 needs them refused:
    ///
    /// * A date with no time on it. `2010-02-19` is a perfectly good ISO 8601
    ///   date and is not what §4.3.2.6 asks for, and reading it as midnight
    ///   would invent a time the playlist did not give.
    /// * Trailing text. zig-datetime parses a prefix and reports what it
    ///   consumed, which is right for a scanner and wrong here: a quoted
    ///   `START-DATE` with a stray character in it must not parse to the date
    ///   without it.
    pub fn parse(text: []const u8) ParseError!DateTime {
        const result = datetime.iso8601.parse(text) catch |err| return switch (err) {
            error.OutOfRange => error.DateOutOfRange,
            error.ParseError, error.MixedFormats, error.BadFraction => error.InvalidDateTime,
        };
        if (result.precision != .second) return error.InvalidDateTime;
        if (result.str.len != text.len) return error.InvalidDateTime;
        if (result.value.year < min_year or result.value.year > max_year) {
            return error.DateOutOfRange;
        }

        return .{
            .value = result.value,
            .fraction_digits = fractionDigits(text),
            .zone = if (!result.has_offset)
                .none
            else if (text[text.len - 1] == 'Z' or text[text.len - 1] == 'z')
                .utc
            else
                .offset,
        };
    }

    pub const ValidateError = error{DateOutOfRange};

    /// Check a `DateTime` that was assembled rather than parsed.
    ///
    /// zig-datetime's types carry most of this — `Month` is an enum, so a
    /// thirteenth month cannot be written down — and what is left is the day
    /// against the length of its month, the width of the fraction, and the
    /// one contradiction this file's own fields allow: a `Z` with an offset
    /// on it. Without the check `format` would write something `parse` would
    /// not read back.
    pub fn validate(self: DateTime) ValidateError!void {
        if (self.value.year < min_year or self.value.year > max_year) return error.DateOutOfRange;
        if (self.value.day < 1 or self.value.day > self.value.month.lastDay(self.value.year)) {
            return error.DateOutOfRange;
        }
        if (self.value.hour > 23 or self.value.minute > 59 or self.value.second > 60) {
            return error.DateOutOfRange;
        }
        if (self.value.nanosecond > 999_999_999) return error.DateOutOfRange;
        if (self.fraction_digits > 9) return error.DateOutOfRange;
        if (@abs(self.value.offset) >= std.time.s_per_day) return error.DateOutOfRange;
        if (self.zone == .utc and self.value.offset != 0) return error.DateOutOfRange;
    }

    /// Write the date back in the notation it was read in.
    ///
    /// Reached by `{f}`. The date and time come from zig-datetime's
    /// formatter; the zone is written here, because the difference between
    /// `Z` and `+00:00` is this file's to keep and not something a date value
    /// has an opinion about.
    pub fn format(self: DateTime, w: *Io.Writer) Io.Writer.Error!void {
        // The fraction's width is known only at run time and a format string
        // is comptime, so this is a switch rather than a loop. `[T]` because
        // a bare `T` in a format string is passed through as a literal only
        // by accident of matching no sequence; bracketing says so.
        const wrote = switch (@min(self.fraction_digits, 9)) {
            0 => self.value.format("YYYY-MM-DD[T]HH:mm:ss", w),
            1 => self.value.format("YYYY-MM-DD[T]HH:mm:ss.S", w),
            2 => self.value.format("YYYY-MM-DD[T]HH:mm:ss.SS", w),
            3 => self.value.format("YYYY-MM-DD[T]HH:mm:ss.SSS", w),
            4 => self.value.format("YYYY-MM-DD[T]HH:mm:ss.SSSS", w),
            5 => self.value.format("YYYY-MM-DD[T]HH:mm:ss.SSSSS", w),
            6 => self.value.format("YYYY-MM-DD[T]HH:mm:ss.SSSSSS", w),
            7 => self.value.format("YYYY-MM-DD[T]HH:mm:ss.SSSSSSS", w),
            8 => self.value.format("YYYY-MM-DD[T]HH:mm:ss.SSSSSSSS", w),
            else => self.value.format("YYYY-MM-DD[T]HH:mm:ss.SSSSSSSSS", w),
        };
        wrote catch return error.WriteFailed;

        switch (self.zone) {
            .utc => try w.writeByte('Z'),
            .none => {},
            .offset => self.value.format("Z", w) catch return error.WriteFailed,
        }
    }

    pub const InstantError = error{
        /// The date has no zone, so which instant it names depends on where
        /// the reader is. Guessing UTC would be wrong somewhere.
        NoZone,
    };

    /// The instant this names.
    ///
    /// A leap second — `second == 60` — lands on the first instant of the
    /// following minute, since the alternative is a leap-second table that
    /// needs maintaining.
    pub fn toInstant(self: DateTime) InstantError!Instant {
        if (self.zone == .none) return error.NoZone;
        return self.value.toInstant();
    }

    /// Nanoseconds since 1970-01-01T00:00:00Z, negative before it.
    pub fn toUnixNanoseconds(self: DateTime) InstantError!i128 {
        return (try self.toInstant()).timestamp;
    }

    /// Seconds since 1970, discarding the fraction towards negative infinity.
    pub fn toUnixSeconds(self: DateTime) InstantError!i64 {
        return @intCast(@divFloor(try self.toUnixNanoseconds(), std.time.ns_per_s));
    }

    pub const FromInstantError = error{
        /// The instant is outside the years `format` can write, which is
        /// `min_year` to `max_year`.
        DateOutOfRange,
    };

    /// The UTC date and time at `instant`.
    ///
    /// `fraction_digits` comes out as 9 when there is a fraction and 0 when
    /// there is not, so that a date made this way and written is exact rather
    /// than rounded to the second.
    pub fn fromInstant(instant: Instant) FromInstantError!DateTime {
        const value = instant.asDateTime();
        if (value.year < min_year or value.year > max_year) return error.DateOutOfRange;
        return .{
            .value = value,
            .fraction_digits = if (value.nanosecond == 0) 0 else 9,
            .zone = .utc,
        };
    }

    /// The UTC date and time at `nanoseconds` after 1970.
    pub fn fromUnixNanoseconds(nanoseconds: i128) FromInstantError!DateTime {
        return fromInstant(.fromNanoTimeStamp(nanoseconds));
    }

    /// Whether two dates name the same instant, whatever notation each is
    /// written in. `2010-02-19T14:54:23+08:00` and `2010-02-19T06:54:23Z`
    /// are equal by this and not by `std.meta.eql`.
    ///
    /// **False when either date has no zone**, even for a date compared with
    /// itself, because a date with no zone names no instant — which is what
    /// `toInstant` refuses to guess at. Check `zone` first if that matters;
    /// `sameText` is the reflexive comparison.
    pub fn sameInstant(a: DateTime, b: DateTime) bool {
        const an = a.toUnixNanoseconds() catch return false;
        const bn = b.toUnixNanoseconds() catch return false;
        return an == bn;
    }

    /// Exactly the same notation: every field, the width of the fraction and
    /// the spelling of the zone.
    ///
    /// This is what a round-trip test asserts, since `sameInstant` would
    /// pass while the file was being rewritten into a different notation
    /// every time a tool touched it.
    ///
    /// `value.weekday` and `value.designation` are not compared: the first is
    /// derived from the date and the second is a zone's name for itself,
    /// which no playlist carries.
    pub fn sameText(a: DateTime, b: DateTime) bool {
        return a.fraction_digits == b.fraction_digits and
            a.zone == b.zone and
            a.value.year == b.value.year and
            a.value.month == b.value.month and
            a.value.day == b.value.day and
            a.value.hour == b.value.hour and
            a.value.minute == b.value.minute and
            a.value.second == b.value.second and
            a.value.nanosecond == b.value.nanosecond and
            a.value.offset == b.value.offset;
    }

    /// Whether two dates are the same in every way a playlist can express,
    /// which is `sameText`.
    ///
    /// Named `eql` so that `Playlist.eql`'s deep comparison finds it and
    /// uses it, rather than reflecting over `value`'s fields and comparing
    /// two it should not: `weekday`, which is derived from the date, and
    /// `designation`, which is a zone's name for itself and which no
    /// playlist carries.
    pub fn eql(a: DateTime, b: DateTime) bool {
        return a.sameText(b);
    }

    /// The offset from UTC in whole minutes, which is the only shape a
    /// playlist's offset comes in. Truncates towards zero for the
    /// historical offsets that are not whole minutes and that no playlist
    /// has.
    pub fn offsetMinutes(self: DateTime) i32 {
        return @divTrunc(self.value.offset, 60);
    }
};

/// How many digits the fraction of a second in `text` was written with,
/// capped at the nine that fit a nanosecond count.
///
/// Read off the text rather than off the parse, because
/// `iso8601.ParseResult` does not report it — reasonably, since `.03` and
/// `.030` are the same date. Here they are two spellings that both have to
/// survive being written back out.
///
/// A valid ISO 8601 date and time has at most one decimal separator, and it
/// is the only `.` or `,` in the whole thing, so finding it needs no
/// knowledge of where the fields are.
fn fractionDigits(text: []const u8) u8 {
    const at = std.mem.findAny(u8, text, ".,") orelse return 0;
    var count: u8 = 0;
    for (text[at + 1 ..]) |c| {
        if (c < '0' or c > '9') break;
        count += 1;
        if (count == 9) break;
    }
    return count;
}

// -- tests -----------------------------------------------------------------

const testing = std.testing;

/// Parse, write, and give back what was written, for the tests below.
fn roundTrip(text: []const u8, buffer: []u8) ![]const u8 {
    const parsed = try DateTime.parse(text);
    var w: Io.Writer = .fixed(buffer);
    try w.print("{f}", .{parsed});
    return w.buffered();
}

test "the example from RFC 8216" {
    const parsed = try DateTime.parse("2010-02-19T14:54:23.031+08:00");
    try testing.expectEqual(@as(datetime.Year, 2010), parsed.value.year);
    try testing.expectEqual(Month.Feb, parsed.value.month);
    try testing.expectEqual(@as(datetime.Day, 19), parsed.value.day);
    try testing.expectEqual(@as(datetime.Hour, 14), parsed.value.hour);
    try testing.expectEqual(@as(datetime.Minute, 54), parsed.value.minute);
    try testing.expectEqual(@as(datetime.Second, 23), parsed.value.second);
    try testing.expectEqual(@as(datetime.Nanosecond, 31_000_000), parsed.value.nanosecond);
    try testing.expectEqual(@as(u8, 3), parsed.fraction_digits);
    // zig-datetime keeps the offset in seconds; eight hours is 28800.
    try testing.expectEqual(@as(i32, 28800), parsed.value.offset);
    try testing.expectEqual(@as(i32, 480), parsed.offsetMinutes());
    try testing.expectEqual(DateTime.Zone.offset, parsed.zone);

    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "2010-02-19T14:54:23.031+08:00",
        try roundTrip("2010-02-19T14:54:23.031+08:00", &buffer),
    );
}

test "the notation is preserved, not normalised" {
    var buffer: [64]u8 = undefined;
    // A fraction of zero is not the same text as no fraction at all, and
    // both come back as they went in.
    try testing.expectEqualStrings("2020-01-01T00:00:00Z", try roundTrip("2020-01-01T00:00:00Z", &buffer));
    try testing.expectEqualStrings("2020-01-01T00:00:00.000Z", try roundTrip("2020-01-01T00:00:00.000Z", &buffer));
    // `+00:00` names the same instant as `Z` and is not the same notation.
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
    // The basic form, and a week date: both name a calendar date, and that
    // is what comes back.
    try testing.expectEqualStrings("2020-01-01T00:00:00Z", try roundTrip("20200101T000000Z", &buffer));
    try testing.expectEqualStrings("2019-12-30T00:00:00Z", try roundTrip("2020-W01-1T00:00:00Z", &buffer));
}

test "writing what was written in another notation is still a fixed point" {
    // The round trip settles even where it does not preserve: a week date
    // comes back as a calendar date, and stays one.
    var once: [64]u8 = undefined;
    var twice: [64]u8 = undefined;
    const first = try roundTrip("2020-W01-1T00:00:00Z", &once);
    try testing.expectEqualStrings(first, try roundTrip(first, &twice));
}

test "no zone is a zone of its own, and has no instant" {
    const parsed = try DateTime.parse("2020-01-01T00:00:00");
    try testing.expectEqual(DateTime.Zone.none, parsed.zone);
    try testing.expectError(error.NoZone, parsed.toInstant());
    try testing.expectError(error.NoZone, parsed.toUnixNanoseconds());

    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("2020-01-01T00:00:00", try roundTrip("2020-01-01T00:00:00", &buffer));
}

test "a fraction wider than nanoseconds is truncated" {
    const parsed = try DateTime.parse("2020-01-01T00:00:00.1234567891234Z");
    try testing.expectEqual(@as(datetime.Nanosecond, 123_456_789), parsed.value.nanosecond);
    try testing.expectEqual(@as(u8, 9), parsed.fraction_digits);

    var buffer: [64]u8 = undefined;
    // Written with the nine digits that were kept, which is the one place
    // the notation is not preserved -- and it is stable, so a second round
    // trip changes nothing.
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
    // Truncated, and -- the case this file refuses on RFC 8216's behalf
    // rather than zig-datetime's -- a date with no time on it, which would
    // otherwise be read as midnight.
    try testing.expectError(error.InvalidDateTime, DateTime.parse("2010-02-19"));
    try testing.expectError(error.InvalidDateTime, DateTime.parse("2010-02"));
    try testing.expectError(error.InvalidDateTime, DateTime.parse("2010"));
    try testing.expectError(error.InvalidDateTime, DateTime.parse(""));
    // Wrong separators. `2010/02/19...` parses as the year 2010 and then
    // stops, which the trailing-text check refuses; `14-54-23` is read as
    // fields that are out of range rather than as a shape that is not a
    // date, so it comes back as the other error. Either way it is refused,
    // which is what a caller cares about.
    try testing.expectError(error.InvalidDateTime, DateTime.parse("2010/02/19T14:54:23Z"));
    try testing.expectError(error.DateOutOfRange, DateTime.parse("2010-02-19T14-54-23Z"));
    // A fraction with no digits.
    try testing.expectError(error.InvalidDateTime, DateTime.parse("2010-02-19T14:54:23.Z"));
    // Trailing rubbish, which must not parse to the date without it -- the
    // other thing refused here, since zig-datetime parses a prefix.
    try testing.expectError(error.InvalidDateTime, DateTime.parse("2010-02-19T14:54:23Zx"));
    try testing.expectError(error.InvalidDateTime, DateTime.parse("2010-02-19T14:54:23+08:00 "));
    try testing.expectError(error.InvalidDateTime, DateTime.parse("2010-02-19T14:54:23X"));
}

test "fields that are numbers and still wrong" {
    try testing.expectError(error.DateOutOfRange, DateTime.parse("2010-99-01T00:00:00Z"));
    try testing.expectError(error.DateOutOfRange, DateTime.parse("2010-00-01T00:00:00Z"));
    try testing.expectError(error.DateOutOfRange, DateTime.parse("2010-02-30T00:00:00Z"));
    try testing.expectError(error.DateOutOfRange, DateTime.parse("2010-01-00T00:00:00Z"));
    try testing.expectError(error.DateOutOfRange, DateTime.parse("2010-01-01T00:60:00Z"));
    // An offset of more than a day, either way round.
    try testing.expectError(error.DateOutOfRange, DateTime.parse("2010-01-01T00:00:00+24:00"));
    try testing.expectError(error.DateOutOfRange, DateTime.parse("2010-01-01T00:00:00+00:60"));
}

test "the forms ISO 8601 allows that are not the one the examples use" {
    // All of these are legal ISO 8601, all of them are accepted, and all of
    // them come back written the one way `format` writes -- which names the
    // same instant, so the round trip settles even where it does not
    // preserve. Worth a test because each one would otherwise look like a
    // bug the first time a playlist in the wild used it.
    var buffer: [64]u8 = undefined;

    // An hour of 24 is midnight at the *end* of the day, and is not an hour
    // out of range: it means the same instant as 00:00 the next morning.
    try testing.expectEqualStrings(
        "2010-01-02T00:00:00Z",
        try roundTrip("2010-01-01T24:00:00Z", &buffer),
    );

    // An ordinal date: the second day of 2010.
    try testing.expectEqualStrings(
        "2010-01-02T00:00:00Z",
        try roundTrip("2010-002T00:00:00Z", &buffer),
    );

    // A week date, and the basic form with no separators.
    try testing.expectEqualStrings(
        "2019-12-30T00:00:00Z",
        try roundTrip("2020-W01-1T00:00:00Z", &buffer),
    );
    try testing.expectEqualStrings(
        "2020-01-01T00:00:00Z",
        try roundTrip("20200101T000000Z", &buffer),
    );

    // A comma for the decimal separator, which is the form ISO 8601 lists
    // first and which almost nothing writes.
    try testing.expectEqualStrings(
        "2020-01-01T00:00:00.25Z",
        try roundTrip("2020-01-01T00:00:00,25Z", &buffer),
    );
}

test "February the twenty-ninth, when there is one" {
    _ = try DateTime.parse("2020-02-29T00:00:00Z");
    _ = try DateTime.parse("2000-02-29T00:00:00Z");
    try testing.expectError(error.DateOutOfRange, DateTime.parse("2021-02-29T00:00:00Z"));
    // 1900 is divisible by 4 and by 100 and not by 400.
    try testing.expectError(error.DateOutOfRange, DateTime.parse("1900-02-29T00:00:00Z"));
    // ...which `Month.lastDay` is what `validate` asks about.
    try testing.expectEqual(@as(datetime.Day, 29), Month.Feb.lastDay(2020));
    try testing.expectEqual(@as(datetime.Day, 28), Month.Feb.lastDay(1900));
}

test "a leap second is accepted and lands on the next minute" {
    const parsed = try DateTime.parse("2016-12-31T23:59:60Z");
    try testing.expectEqual(@as(datetime.Second, 60), parsed.value.second);
    const at = try parsed.toUnixNanoseconds();
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
    // all and half the reason this file exists.
    const apollo = try DateTime.parse("1969-07-20T20:17:40Z");
    try testing.expectEqual(@as(i64, -14182940), try apollo.toUnixSeconds());
    const back = try DateTime.fromUnixNanoseconds(try apollo.toUnixNanoseconds());
    try testing.expect(apollo.sameText(back));
}

test "every day of four centuries survives the calendar round trip" {
    // 1900 to 2300, which covers both kinds of century: one whose hundredth
    // year is a leap year and one whose is not. The calendar is
    // zig-datetime's; this is here because the dates a playlist carries are
    // the ones that matter, and a library swap that broke the calendar would
    // otherwise show up as a puzzling failure somewhere else.
    var day = (datetime.Date{ .year = 1900, .month = .Jan, .day = 1 }).toDaysSinceStartOfEra();
    const last = (datetime.Date{ .year = 2300, .month = .Jan, .day = 1 }).toDaysSinceStartOfEra();
    var expected: datetime.Date = .{ .year = 1900, .month = .Jan, .day = 1 };
    while (day < last) : (day += 1) {
        const date: datetime.Date = .fromDaysSinceStartOfEra(day);
        try testing.expectEqual(expected.year, date.year);
        try testing.expectEqual(expected.month, date.month);
        try testing.expectEqual(expected.day, date.day);
        try testing.expectEqual(day, date.toDaysSinceStartOfEra());

        expected.day += 1;
        if (expected.day > expected.month.lastDay(expected.year)) {
            expected.day = 1;
            if (expected.month == .Dec) {
                expected.month = .Jan;
                expected.year += 1;
            } else {
                expected.month = expected.month.next();
            }
        }
    }
}

test "an instant outside the years a playlist can write is refused" {
    // `format` writes four digits, so a date it could not write back is not
    // one to hand out.
    const year_10000 = (datetime.Date{ .year = 10000, .month = .Jan, .day = 1 })
        .toDaysSinceStartOfEra();
    _ = year_10000;
    try testing.expectError(
        error.DateOutOfRange,
        DateTime.fromUnixNanoseconds(@as(i128, 253_402_300_800) * std.time.ns_per_s),
    );
    // And one inside them is not.
    _ = try DateTime.fromUnixNanoseconds(0);
}

test "fromInstant floors rather than truncating" {
    // Half a second before the epoch is 1969, not 1970 with a negative
    // fraction.
    const parsed = try DateTime.fromUnixNanoseconds(-500_000_000);
    try testing.expectEqual(@as(datetime.Year, 1969), parsed.value.year);
    try testing.expectEqual(Month.Dec, parsed.value.month);
    try testing.expectEqual(@as(datetime.Day, 31), parsed.value.day);
    try testing.expectEqual(@as(datetime.Hour, 23), parsed.value.hour);
    try testing.expectEqual(@as(datetime.Minute, 59), parsed.value.minute);
    try testing.expectEqual(@as(datetime.Second, 59), parsed.value.second);
    try testing.expectEqual(@as(datetime.Nanosecond, 500_000_000), parsed.value.nanosecond);
}

test "validate refuses what format could not write back" {
    // The thirtieth of February, which the types cannot rule out.
    try testing.expectError(error.DateOutOfRange, (DateTime{
        .value = .{ .year = 2020, .month = .Feb, .day = 30 },
    }).validate());
    // `Z` with a non-zero offset is a contradiction between this file's
    // `zone` and zig-datetime's `offset`.
    try testing.expectError(error.DateOutOfRange, (DateTime{
        .value = .{ .year = 2020, .month = .Jan, .day = 1, .offset = 3600 },
        .zone = .utc,
    }).validate());
    try (DateTime{
        .value = .{ .year = 2020, .month = .Jan, .day = 1, .offset = 3600 },
        .zone = .offset,
    }).validate();
    // A year `format` writes with four digits and `parse` would not read.
    try testing.expectError(error.DateOutOfRange, (DateTime{
        .value = .{ .year = 12345, .month = .Jan, .day = 1 },
    }).validate());
}

test "counting the digits of a fraction" {
    try testing.expectEqual(@as(u8, 0), fractionDigits("2020-01-01T00:00:00Z"));
    try testing.expectEqual(@as(u8, 3), fractionDigits("2020-01-01T00:00:00.031Z"));
    try testing.expectEqual(@as(u8, 1), fractionDigits("2020-01-01T00:00:00.5"));
    // Capped at the nine that fit a nanosecond count.
    try testing.expectEqual(@as(u8, 9), fractionDigits("2020-01-01T00:00:00.1234567891234Z"));
    // ISO 8601 lets the comma be the decimal separator.
    try testing.expectEqual(@as(u8, 2), fractionDigits("2020-01-01T00:00:00,25Z"));
}
