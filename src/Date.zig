//! A civil date of the proleptic Gregorian calendar, -9999-01-01 to 9999-12-31: its fields ranged
//! and its day checked against its month when it is made.
const Date = @This();
const std = @import("std");
const units = @import("units.zig");
const calendar = @import("calendar.zig");
const arithmetic = @import("arithmetic.zig");
const Span = @import("Span.zig");

year: units.Year,
month: units.Month,
day: units.Day,

pub const RangeError = units.RangeError;
pub const DifferenceError = units.DifferenceError;

/// The date, its day checked against its month (February 29 only in a leap year).
pub fn init(year: i16, month: u8, day: u8) RangeError!Date {
    const y: units.Year = try .init(year);
    const m: units.Month = try .init(month);
    const d: units.Day = try .init(day);
    if (day > calendar.daysInMonth(year, month)) return error.OutOfRange;
    return .{ .year = y, .month = m, .day = d };
}

/// The date `days` after 1970-01-01, within almanac's years.
pub fn fromDays(count: i32) RangeError!Date {
    if (count < calendar.min_days or count > calendar.max_days) return error.OutOfRange;
    const c = calendar.civilFromDays(count);
    // In range by the bounds above, and a date by the kernel.
    return .{ .year = units.Year.init(@intCast(c.year)) catch unreachable, .month = units.Month.init(@intCast(c.month)) catch unreachable, .day = units.Day.init(@intCast(c.day)) catch unreachable };
}

/// Days since 1970-01-01.
pub fn days(d: Date) i32 {
    return calendar.daysFromCivil(d.year.raw(), d.month.raw(), d.day.raw());
}

pub fn weekday(d: Date) units.Weekday {
    return @fromBackingInt(@intCast(calendar.weekday(d.days())));
}

/// The day of the year, from 1.
pub fn ordinal(d: Date) units.Ordinal {
    return units.Ordinal.init(@intCast(calendar.ordinal(d.year.raw(), d.month.raw(), d.day.raw()))) catch unreachable;
}

pub const IsoWeek = struct { year: i32, week: units.Week };

/// ISO 8601's week date: the week-year (which may be the year before or after) and its week.
pub fn isoWeek(d: Date) IsoWeek {
    const w = calendar.isoWeek(d.days());
    return .{ .year = w.year, .week = units.Week.init(@intCast(w.week)) catch unreachable };
}

pub fn isLeapYear(d: Date) bool {
    return calendar.isLeapYear(d.year.raw());
}

pub fn daysInMonth(d: Date) u8 {
    return @intCast(calendar.daysInMonth(d.year.raw(), d.month.raw()));
}

pub fn order(a: Date, b: Date) std.math.Order {
    return std.math.order(a.days(), b.days());
}

pub fn eql(a: Date, b: Date) bool {
    return a.days() == b.days();
}

/// The date as the arithmetic's record.
pub fn iso(d: Date) arithmetic.IsoDate {
    return .{ .year = d.year.raw(), .month = d.month.raw(), .day = d.day.raw() };
}

/// The date of a record inside almanac's range.
pub fn fromIso(i: arithmetic.IsoDate) Date {
    return fromDays(@intCast(i.epochDays())) catch unreachable;
}

/// The date as what gives a span's calendar units their lengths (Temporal's `relativeTo`).
pub fn relativeTo(d: Date) Span.RelativeTo {
    return .{ .date = d.iso() };
}

/// Temporal's `PlainDate.prototype.add`: the span's days and time as whole days (toward zero);
/// then years and months, the day regulated by `overflow` (January 31 plus a month is February's
/// last day, or refused); then weeks and days.
pub fn add(d: Date, span: Span, overflow: units.Overflow) RangeError!Date {
    const internal = try span.toInternalDays();
    const date: arithmetic.DateRec = .{
        .years = internal.date.years,
        .months = internal.date.months,
        .weeks = internal.date.weeks,
        .days = @intCast(@divTrunc(internal.time, arithmetic.ns_per_day)),
    };
    return fromIso(try arithmetic.dateAdd(d.iso(), date, overflow));
}

pub fn subtract(d: Date, span: Span, overflow: units.Overflow) RangeError!Date {
    return d.add(span.negate(), overflow);
}

/// Temporal's `PlainDate.prototype.until`: the span from `d` to `other` in date units up to
/// `options.largest` (the day by default), each unit counted while the date reached does not pass
/// `other`, then rounded as the options say. `d.add(d.until(other))` is `other`.
pub fn until(d: Date, other: Date, options: units.Difference) DifferenceError!Span {
    return d.difference(.until, other, options);
}

/// Temporal's `PlainDate.prototype.since`: the difference `until` measures from `d` to `other`,
/// rounded with the mode negated, then negated. It is not `other.until(d)`: in 2023, from March 31
/// back to February 28 is a month, forward from February 28 to March 31 a month and three days.
pub fn since(d: Date, other: Date, options: units.Difference) DifferenceError!Span {
    return d.difference(.since, other, options);
}

fn difference(d: Date, operation: arithmetic.Operation, other: Date, options: units.Difference) DifferenceError!Span {
    const r = try arithmetic.differenceSettings(operation, options, true);
    if (d.eql(other)) return .zero;
    var result: arithmetic.Internal = .{ .date = arithmetic.dateUntil(d.iso(), other.iso(), r.largest) };
    if (r.smallest != .day or r.increment != 1) {
        const dest = (arithmetic.IsoDateTime{ .date = other.iso() }).epochNs();
        result = try arithmetic.roundRelative(result, dest, .{ .date = d.iso() }, r);
    }
    const span = try Span.fromInternal(result, .day);
    return if (operation == .since) span.negate() else span;
}
