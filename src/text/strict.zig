//! RFC 3339's grammar exactly, with no reading beyond it: whether a text is a `full-date`, a
//! `full-time`, a `date-time` (§5.6) or an Appendix A `duration`. The literals are case-insensitive
//! (`t`, `z`, `p1y`), as RFC 3339's ABNF is; the offset is required in a time; a leap second
//! (`:60`) only where the time with its offset taken off is 23:59:60 UTC, at any date (the rule is
//! the grammar's, not a leap second table); fractions of any length. JSON Schema's `date-time`,
//! `date`, `time` and `duration` formats are these checks.
const std = @import("std");
const calendar = @import("../calendar.zig");

fn number(s: []const u8, at: usize, n: usize) ?u32 {
    if (at + n > s.len) return null;
    var v: u32 = 0;
    for (s[at..][0..n]) |c| {
        if (!std.ascii.isDigit(c)) return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

/// `full-date` from `at`, its end; the day checked against its month and year.
fn date(s: []const u8, at: usize) ?usize {
    const y = number(s, at, 4) orelse return null;
    if (at + 4 >= s.len or s[at + 4] != '-') return null;
    const m = number(s, at + 5, 2) orelse return null;
    if (at + 7 >= s.len or s[at + 7] != '-') return null;
    const d = number(s, at + 8, 2) orelse return null;
    if (m < 1 or m > 12 or d < 1 or d > calendar.daysInMonth(y, m)) return null;
    return at + 10;
}

/// `full-time` from `at` to the end of `s`.
fn fullTime(s: []const u8, at: usize) bool {
    const h = number(s, at, 2) orelse return false;
    if (at + 2 >= s.len or s[at + 2] != ':') return false;
    const m = number(s, at + 3, 2) orelse return false;
    if (at + 5 >= s.len or s[at + 5] != ':') return false;
    const sec = number(s, at + 6, 2) orelse return false;
    if (h > 23 or m > 59 or sec > 60) return false;
    var i = at + 8;
    if (i < s.len and s[i] == '.') {
        i += 1;
        const start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i == start) return false;
    }
    if (i >= s.len) return false;
    var offset_minutes: i32 = 0;
    if (s[i] == 'Z' or s[i] == 'z') {
        i += 1;
    } else if (s[i] == '+' or s[i] == '-') {
        const oh = number(s, i + 1, 2) orelse return false;
        if (i + 3 >= s.len or s[i + 3] != ':') return false;
        const om = number(s, i + 4, 2) orelse return false;
        if (oh > 23 or om > 59) return false;
        offset_minutes = @intCast(oh * 60 + om);
        if (s[i] == '-') offset_minutes = -offset_minutes;
        i += 6;
    } else return false;
    if (i != s.len) return false;
    if (sec == 60) {
        // The minute in UTC must be 23:59.
        const utc = @mod(@as(i32, @intCast(h * 60 + m)) - offset_minutes, 24 * 60);
        if (utc != 23 * 60 + 59) return false;
    }
    return true;
}

/// RFC 3339's `full-date`: `2026-10-31`.
pub fn isDate(s: []const u8) bool {
    return (date(s, 0) orelse return false) == s.len;
}

/// RFC 3339's `full-time`: `09:00:00Z`, `09:00:00.5+05:30`.
pub fn isTime(s: []const u8) bool {
    return fullTime(s, 0);
}

/// RFC 3339's `date-time`: `2026-10-31T09:00:00Z`.
pub fn isDateTime(s: []const u8) bool {
    const end = date(s, 0) orelse return false;
    if (end >= s.len or (s[end] != 'T' and s[end] != 't')) return false;
    return fullTime(s, end + 1);
}

/// One or more digits then `letter`, from `at`; the index after the letter.
fn component(s: []const u8, at: usize, letter: u8) ?usize {
    var i = at;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i == at or i >= s.len or std.ascii.toUpper(s[i]) != letter) return null;
    return i + 1;
}

/// The end of `units` read in order from `at`, each optional only after the first given, and
/// each following the one before it immediately (`Y [M [D]]`, `H [M [S]]`): Appendix A's nesting.
fn chain(s: []const u8, at: usize, units: []const u8) ?usize {
    for (units, 0..) |u, k| {
        if (component(s, at, u)) |end| {
            var i = end;
            for (units[k + 1 ..]) |next| i = component(s, i, next) orelse break;
            return i;
        }
    }
    return null;
}

/// RFC 3339 Appendix A's `duration`: `P` then a date part (`Y [M [D]]`, `M [D]` or `D`) with an
/// optional time part, a time part alone (`T` then `H [M [S]]`, `M [S]` or `S`), or weeks alone.
/// No sign and no fractions.
pub fn isDuration(s: []const u8) bool {
    if (s.len < 2 or (s[0] != 'P' and s[0] != 'p')) return false;
    if (component(s, 1, 'W')) |end| return end == s.len;
    var i: usize = 1;
    if (s[i] != 'T' and s[i] != 't') {
        i = chain(s, 1, "YMD") orelse return false;
        if (i == s.len) return true;
    }
    if (s[i] != 'T' and s[i] != 't') return false;
    return (chain(s, i + 1, "HMS") orelse return false) == s.len;
}
