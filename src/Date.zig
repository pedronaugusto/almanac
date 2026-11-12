//! A civil date of the proleptic Gregorian calendar, -9999-01-01 to 9999-12-31: its fields ranged
//! and its day checked against its month when it is made.
const Date = @This();
const std = @import("std");
const units = @import("units.zig");
const calendar = @import("calendar.zig");

year: units.Year,
month: units.Month,
day: units.Day,

pub const RangeError = units.RangeError;

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
    return @enumFromInt(calendar.weekday(d.days()));
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
