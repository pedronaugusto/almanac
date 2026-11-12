//! The calendar's kernels and the civil types: Neri and Schneider's conversions against Hinnant's
//! `days_from_civil` over every day of almanac's range, ISO weeks at their edges, and the
//! checks a date and time make when they are made.
const std = @import("std");
const shakedown = @import("shakedown");
const calendar = @import("calendar.zig");
const Date = @import("Date.zig");
const Time = @import("Time.zig");
const DateTime = @import("DateTime.zig");
const units = @import("units.zig");
const testing = std.testing;

/// Howard Hinnant's `days_from_civil` ("chrono-Compatible Low-Level Date Algorithms"): a second,
/// independent derivation the fast kernels are checked against.
fn reference(year: i32, month: u32, day: u32) i32 {
    const y = year - @intFromBool(month <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i32 = @intCast(month);
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + @as(i32, @intCast(day)) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

test "every day of the range: the date of a day count, and back, as an independent derivation says" {
    var days = calendar.min_days;
    var expect: calendar.Civil = .{ .year = -9999, .month = 1, .day = 1 };
    while (days <= calendar.max_days) : (days += 1) {
        const c = calendar.civilFromDays(days);
        try testing.expectEqual(expect, c);
        try testing.expectEqual(days, calendar.daysFromCivil(c.year, c.month, c.day));
        try testing.expectEqual(days, reference(c.year, c.month, c.day));
        // The next day, by counting.
        expect.day += 1;
        if (expect.day > calendar.daysInMonth(expect.year, expect.month)) {
            expect.day = 1;
            expect.month += 1;
            if (expect.month > 12) {
                expect.month = 1;
                expect.year += 1;
            }
        }
    }
}

test "leap years, month lengths and weekdays" {
    try testing.expect(calendar.isLeapYear(2000) and calendar.isLeapYear(2024) and calendar.isLeapYear(0) and calendar.isLeapYear(-4));
    try testing.expect(!calendar.isLeapYear(1900) and !calendar.isLeapYear(2023) and !calendar.isLeapYear(-1) and !calendar.isLeapYear(-100));
    const lengths = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    for (lengths, 1..) |n, m| try testing.expectEqual(n, calendar.daysInMonth(2023, @intCast(m)));
    try testing.expectEqual(29, calendar.daysInMonth(2024, 2));
    try testing.expectEqual(units.Weekday.thursday, (try Date.init(1970, 1, 1)).weekday());
    try testing.expectEqual(units.Weekday.thursday, (try Date.init(2026, 11, 12)).weekday());
    try testing.expectEqual(units.Weekday.saturday, (try Date.init(2000, 1, 1)).weekday());
    try testing.expectEqual(units.Weekday.monday, (try Date.init(-9999, 1, 1)).weekday());
}

test "ISO weeks at the year's edges, and days of the year" {
    const cases = [_]struct { [3]i32, i32, u32 }{
        .{ .{ 2026, 1, 1 }, 2026, 1 },
        .{ .{ 2020, 12, 31 }, 2020, 53 },
        .{ .{ 2021, 1, 3 }, 2020, 53 },
        .{ .{ 2021, 1, 4 }, 2021, 1 },
        .{ .{ 2024, 12, 30 }, 2025, 1 },
        .{ .{ 2008, 12, 29 }, 2009, 1 },
        .{ .{ 2010, 1, 3 }, 2009, 53 },
    };
    for (cases) |case| {
        const d = try Date.init(@intCast(case[0][0]), @intCast(case[0][1]), @intCast(case[0][2]));
        const w = d.isoWeek();
        try testing.expectEqual(case[1], w.year);
        try testing.expectEqual(case[2], w.week.raw());
    }
    try testing.expectEqual(1, (try Date.init(2026, 1, 1)).ordinal().raw());
    try testing.expectEqual(366, (try Date.init(2024, 12, 31)).ordinal().raw());
    try testing.expectEqual(316, (try Date.init(2026, 11, 12)).ordinal().raw());
}

test "a date checks its day against its month, and the range" {
    try testing.expectError(error.OutOfRange, Date.init(2023, 2, 29));
    _ = try Date.init(2024, 2, 29);
    try testing.expectError(error.OutOfRange, Date.init(2026, 4, 31));
    try testing.expectError(error.OutOfRange, Date.init(2026, 13, 1));
    try testing.expectError(error.OutOfRange, Date.init(2026, 1, 0));
    try testing.expectError(error.OutOfRange, Date.init(10000, 1, 1));
    try testing.expectError(error.OutOfRange, Date.fromDays(calendar.max_days + 1));
    try testing.expectError(error.OutOfRange, Date.fromDays(calendar.min_days - 1));
    try testing.expect((try Date.fromDays(calendar.max_days)).eql(try Date.init(9999, 12, 31)));
    try testing.expectEqual(std.math.Order.lt, (try Date.init(-1, 12, 31)).order(try Date.init(0, 1, 1)));
}

test "a time of day, to nanoseconds since midnight and back" {
    const t = try Time.init(23, 59, 59, 999_999_999);
    try testing.expectEqual(Time.nanoseconds_per_day - 1, t.nanosecondOfDay());
    try testing.expectEqual(t, try Time.fromNanosecondOfDay(t.nanosecondOfDay()));
    try testing.expectError(error.OutOfRange, Time.fromNanosecondOfDay(Time.nanoseconds_per_day));
    try testing.expectError(error.OutOfRange, Time.init(24, 0, 0, 0));
    try testing.expectError(error.OutOfRange, Time.init(0, 0, 60, 0));
    const a: DateTime = .{ .date = try Date.init(2026, 11, 12), .time = try Time.init(9, 0, 0, 0) };
    const b: DateTime = .{ .date = try Date.init(2026, 11, 12), .time = try Time.init(9, 0, 0, 1) };
    try testing.expectEqual(std.math.Order.lt, a.order(b));
}

fn anyDay(_: void, case: *shakedown.Case) !void {
    const days = shakedown.gen.intRange(case.source, i32, calendar.min_days, calendar.max_days);
    const d = try Date.fromDays(days);
    try testing.expectEqual(days, d.days());
    try testing.expectEqual(days, reference(d.year.raw(), d.month.raw(), d.day.raw()));
    const w = d.isoWeek();
    // The ISO week's Monday is at most three days from the date's year's edges.
    try testing.expect(w.year >= @as(i32, d.year.raw()) - 1 and w.year <= @as(i32, d.year.raw()) + 1);
    try testing.expectEqual(@as(u32, @backingInt(d.weekday())), calendar.weekday(days));
}

test "fuzz: any day count's date counts back to it, as the independent derivation does" {
    try shakedown.check(testing.allocator, {}, anyDay, .{ .cases = 5000, .seed = 0xa1a });
}
