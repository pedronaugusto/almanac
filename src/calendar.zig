//! The proleptic Gregorian calendar's kernels: a date to its day count and back by Neri and
//! Schneider's Euclidean affine functions ("Euclidean affine functions and their application to
//! calendar algorithms", 2021: the fastest known conversions, as jiff and recent libstdc++ use),
//! the weekday, the ISO week, the day of the year, month and year lengths. Days count from
//! 1970-01-01, which is 0. Every function is total over almanac's years (-9999 to 9999) and
//! evaluable at `comptime`; ranges are the callers'.
const std = @import("std");

/// The first and last day almanac covers, as day counts: -9999-01-01 and 9999-12-31.
pub const min_days: i32 = -4_371_587;
pub const max_days: i32 = 2_932_896;

/// Neri and Schneider shift the calendar by `s` 400-year cycles so every year they read is
/// positive, and start the year in March, so February, with its leap day, comes last.
const shift_cycles = 82;
const shift_years: u32 = 400 * shift_cycles;
const shift_days: u32 = 719_468 + 146_097 * shift_cycles;

pub const Civil = struct { year: i32, month: u32, day: u32 };

/// The day count of `year`-`month`-`day`, which the caller has checked is a date.
pub fn daysFromCivil(year: i32, month: u32, day: u32) i32 {
    const january_or_february = month <= 2;
    const y: u32 = @intCast(year + @as(i32, @intCast(shift_years)) - @intFromBool(january_or_february));
    const m: u32 = if (january_or_february) month + 12 else month;
    const d: u32 = day - 1;
    const century = y / 100;
    const year_days = 1461 * y / 4 - century + century / 4;
    const month_days = (979 * m - 2919) / 32;
    const n = year_days + month_days + d;
    return @as(i32, @intCast(n)) - @as(i32, @intCast(shift_days));
}

/// The date whose day count is `days`.
pub fn civilFromDays(days: i32) Civil {
    const n: u32 = @intCast(days + @as(i32, @intCast(shift_days)));
    // The century, and the day within it.
    const n1 = 4 * n + 3;
    const century = n1 / 146_097;
    const n_century = n1 % 146_097 / 4;
    // The year within the century, and the day within the year (March first).
    const n2 = 4 * n_century + 3;
    const p2 = @as(u64, 2_939_745) * n2;
    const year_of_century: u32 = @intCast(p2 / (1 << 32));
    const n_year: u32 = @intCast(p2 % (1 << 32) / 2_939_745 / 4);
    // The month and day, March as month 3 and February as 14.
    const n3 = 2141 * n_year + 197_913;
    const month = n3 / (1 << 16);
    const day = n3 % (1 << 16) / 2141;
    const january_or_february = n_year >= 306;
    const year: i32 = @as(i32, @intCast(100 * century + year_of_century)) - @as(i32, @intCast(shift_years)) + @intFromBool(january_or_february);
    return .{ .year = year, .month = if (january_or_february) month - 12 else month, .day = day + 1 };
}

pub fn isLeapYear(year: i32) bool {
    // A year divisible by 100 is leap only where divisible by 400, which is by 16 then.
    const divisor: i32 = if (@rem(year, 100) == 0) 16 else 4;
    return @mod(year, divisor) == 0;
}

pub fn daysInMonth(year: i32, month: u32) u32 {
    if (month == 2) return if (isLeapYear(year)) 29 else 28;
    // 30 for April, June, September and November, else 31.
    return 30 | (month ^ (month >> 3));
}

pub fn daysInYear(year: i32) u32 {
    return if (isLeapYear(year)) 366 else 365;
}

/// ISO's weekday of a day count: Monday 1 to Sunday 7 (1970-01-01 was a Thursday).
pub fn weekday(days: i32) u32 {
    return @intCast(@mod(days + 3, 7) + 1);
}

/// The day of the year, from 1.
pub fn ordinal(year: i32, month: u32, day: u32) u32 {
    return @intCast(daysFromCivil(year, month, day) - daysFromCivil(year, 1, 1) + 1);
}

pub const IsoWeek = struct { year: i32, week: u32 };

/// ISO 8601's week date of a day count: the week-year is the year of that week's Thursday, and
/// week 1 the week holding its first Thursday.
pub fn isoWeek(days: i32) IsoWeek {
    const thursday = days + 4 - @as(i32, @intCast(weekday(days)));
    const c = civilFromDays(thursday);
    return .{ .year = c.year, .week = (ordinal(c.year, c.month, c.day) - 1) / 7 + 1 };
}

test "the kernels are evaluable at comptime" {
    comptime {
        std.debug.assert(daysFromCivil(1970, 1, 1) == 0);
        std.debug.assert(civilFromDays(0).year == 1970);
        std.debug.assert(daysFromCivil(-9999, 1, 1) == min_days);
        std.debug.assert(daysFromCivil(9999, 12, 31) == max_days);
    }
}
