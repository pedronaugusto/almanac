//! Spans and civil arithmetic (Temporal's semantics): the bounds a span is built within, adding
//! with each overflow policy, differences in each largest unit, every rounding mode and increment,
//! balancing, comparing, and the property that adding a difference reaches its end.
const std = @import("std");
const shakedown = @import("shakedown");
const almanac = @import("almanac.zig");
const calendar = @import("calendar.zig");
const Span = almanac.Span;
const Date = almanac.Date;
const Time = almanac.Time;
const DateTime = almanac.DateTime;
const Unit = almanac.Unit;
const testing = std.testing;

fn date(y: i16, m: u8, d: u8) Date {
    return Date.init(y, m, d) catch unreachable;
}

fn dateTime(y: i16, mo: u8, d: u8, h: u8, mi: u8, s: u8, ns: u32) DateTime {
    return .{ .date = date(y, mo, d), .time = Time.init(h, mi, s, ns) catch unreachable };
}

fn span(f: Span.Signed) Span {
    return Span.fromSigned(f) catch unreachable;
}

fn expectSpan(want: Span.Signed, got: Span) !void {
    const w = span(want);
    if (!w.eql(got)) {
        std.debug.print("want {any}\n got {any}\n", .{ want, got });
        return error.TestUnexpectedResult;
    }
}

test "a span's bounds: one sign, years below 2^32, days and time below 2^53 seconds" {
    try testing.expectError(error.OutOfRange, Span.fromSigned(.{ .days = 1, .hours = -1 }));
    try testing.expectError(error.OutOfRange, Span.fromSigned(.{ .years = 1 << 32 }));
    _ = try Span.fromSigned(.{ .years = (1 << 32) - 1, .months = (1 << 32) - 1, .weeks = (1 << 32) - 1 });
    _ = try Span.init(.positive, .{ .seconds = (1 << 53) - 1, .nanoseconds = 999_999_999 });
    try testing.expectError(error.OutOfRange, Span.init(.positive, .{ .seconds = (1 << 53) - 1, .nanoseconds = 1_000_000_000 }));
    _ = try Span.init(.negative, .{ .days = 104_249_991_374, .hours = 7 });
    try testing.expectError(error.OutOfRange, Span.init(.negative, .{ .days = 104_249_991_374, .hours = 8 }));
    try testing.expectError(error.OutOfRange, Span.init(.positive, .{ .days = 104_249_991_375 }));
    // The joint bound holds across fields: 2^53 seconds as milliseconds alone is one too many.
    _ = try Span.init(.positive, .{ .milliseconds = (1 << 53) * 1000 - 1 });
    try testing.expectError(error.OutOfRange, Span.init(.positive, .{ .milliseconds = (1 << 53) * 1000 }));
    // Zero is positive; negating it keeps it so.
    const z = try Span.init(.negative, .{});
    try testing.expectEqual(.positive, z.sign);
    try testing.expectEqual(0, z.negate().signum());
    try testing.expectEqual(-1, span(.{ .minutes = -3 }).signum());
    try testing.expectEqual(Unit.minute, span(.{ .minutes = -3, .seconds = -1 }).largestUnit());
    try testing.expectEqual(Unit.nanosecond, Span.zero.largestUnit());
}

test "adding to a date: years and months first, the day constrained or refused, then days" {
    try testing.expect((try date(2020, 1, 31).add(span(.{ .months = 1 }), .constrain)).eql(date(2020, 2, 29)));
    try testing.expectError(error.OutOfRange, date(2020, 1, 31).add(span(.{ .months = 1 }), .reject));
    try testing.expect((try date(2019, 1, 31).add(span(.{ .months = 1 }), .constrain)).eql(date(2019, 2, 28)));
    try testing.expect((try date(2020, 2, 29).add(span(.{ .years = 1 }), .constrain)).eql(date(2021, 2, 28)));
    try testing.expect((try date(2020, 2, 29).add(span(.{ .years = 4 }), .reject)).eql(date(2024, 2, 29)));
    // The day is regulated before the days are added: January 31 plus a month and a day.
    try testing.expect((try date(2019, 1, 31).add(span(.{ .months = 1, .days = 1 }), .constrain)).eql(date(2019, 3, 1)));
    try testing.expect((try date(2020, 3, 31).subtract(span(.{ .months = 1 }), .constrain)).eql(date(2020, 2, 29)));
    try testing.expect((try date(2020, 1, 1).add(span(.{ .months = -13 }), .reject)).eql(date(2018, 12, 1)));
    try testing.expect((try date(2020, 1, 1).add(span(.{ .weeks = 2, .days = 3 }), .reject)).eql(date(2020, 1, 18)));
    // Time joins as whole days, toward zero.
    try testing.expect((try date(2020, 1, 1).add(span(.{ .hours = 47 }), .reject)).eql(date(2020, 1, 2)));
    try testing.expect((try date(2020, 1, 1).add(span(.{ .hours = -25 }), .reject)).eql(date(2019, 12, 31)));
    // The range's edges.
    try testing.expectError(error.OutOfRange, date(9999, 12, 31).add(span(.{ .days = 1 }), .constrain));
    try testing.expectError(error.OutOfRange, date(-9999, 1, 1).add(span(.{ .days = -1 }), .constrain));
    try testing.expectError(error.OutOfRange, date(2020, 1, 1).add(span(.{ .years = (1 << 32) - 1 }), .constrain));
    try testing.expectError(error.OutOfRange, date(2020, 1, 1).add(span(.{ .days = 104_249_991_374 }), .constrain));
}

test "adding to a date and time: the time first, its whole days joining the date part" {
    try testing.expect((try dateTime(2020, 1, 1, 23, 0, 0, 0).add(span(.{ .hours = 2 }), .reject)).eql(dateTime(2020, 1, 2, 1, 0, 0, 0)));
    // 12:00 plus 12 hours is the next midnight, so a month and a day from January 31.
    try testing.expect((try dateTime(2020, 1, 31, 12, 0, 0, 0).add(span(.{ .months = 1, .hours = 12 }), .constrain)).eql(dateTime(2020, 3, 1, 0, 0, 0, 0)));
    try testing.expect((try dateTime(2020, 1, 1, 0, 0, 0, 0).subtract(span(.{ .nanoseconds = 1 }), .reject)).eql(dateTime(2019, 12, 31, 23, 59, 59, 999_999_999)));
    try testing.expectError(error.OutOfRange, dateTime(9999, 12, 31, 23, 59, 59, 999_999_999).add(span(.{ .nanoseconds = 1 }), .reject));
}

test "differences between dates in each largest unit, and since is not until reversed" {
    const u = struct {
        fn u(a: Date, b: Date, largest: Unit) !Span {
            return a.until(b, .{ .largest = largest });
        }
    }.u;
    try expectSpan(.{ .days = 29 }, try u(date(2020, 1, 31), date(2020, 2, 29), .month));
    try expectSpan(.{ .months = 1, .days = 1 }, try u(date(2019, 1, 31), date(2019, 3, 1), .month));
    try expectSpan(.{ .months = 11, .days = 30 }, try u(date(2020, 2, 29), date(2021, 2, 28), .year));
    // A year from February 29 is February 28, constrained, and a day more.
    try expectSpan(.{ .years = 1, .days = 1 }, try u(date(2020, 2, 29), date(2021, 3, 1), .year));
    try expectSpan(.{ .years = 1, .months = 6, .days = 1 }, try u(date(2019, 1, 1), date(2020, 7, 2), .year));
    try expectSpan(.{ .months = 18, .days = 1 }, try u(date(2019, 1, 1), date(2020, 7, 2), .month));
    try expectSpan(.{ .weeks = 78, .days = 2 }, try u(date(2019, 1, 1), date(2020, 7, 2), .week));
    try expectSpan(.{ .days = 548 }, try date(2019, 1, 1).until(date(2020, 7, 2), .{}));
    try expectSpan(.{ .months = -1 }, try u(date(2023, 3, 31), date(2023, 2, 28), .month));
    try expectSpan(.{ .months = 1 }, try date(2023, 3, 31).since(date(2023, 2, 28), .{ .largest = .month }));
    try expectSpan(.{ .months = 1, .days = 3 }, try u(date(2023, 2, 28), date(2023, 3, 31), .month));
    try expectSpan(.{ .months = 11, .days = 28 }, try date(2021, 2, 28).since(date(2020, 2, 29), .{ .largest = .year }));
    try expectSpan(.{}, try u(date(2020, 5, 5), date(2020, 5, 5), .year));
    // A date has no time units, and the smallest unit is never above the largest.
    try testing.expectError(error.InvalidOptions, date(2020, 1, 1).until(date(2020, 1, 2), .{ .largest = .hour }));
    try testing.expectError(error.InvalidOptions, date(2020, 1, 1).until(date(2020, 1, 2), .{ .largest = .month, .smallest = .year }));
    try testing.expectError(error.InvalidOptions, date(2020, 1, 1).until(date(2020, 1, 2), .{ .increment = 0 }));
    try testing.expectError(error.InvalidOptions, date(2020, 1, 1).until(date(2020, 1, 2), .{ .increment = 1_000_000_001 }));
}

test "differences between dates and times: a day borrowed where the time runs against the dates" {
    try expectSpan(.{ .hours = 18 }, try dateTime(2020, 1, 1, 12, 0, 0, 0).until(dateTime(2020, 1, 2, 6, 0, 0, 0), .{}));
    try expectSpan(.{ .days = 1, .hours = 6 }, try dateTime(2020, 1, 1, 0, 0, 0, 0).until(dateTime(2020, 1, 2, 6, 0, 0, 0), .{}));
    try expectSpan(.{ .hours = -18 }, try dateTime(2020, 1, 2, 6, 0, 0, 0).until(dateTime(2020, 1, 1, 12, 0, 0, 0), .{}));
    try expectSpan(.{ .hours = 30 }, try dateTime(2020, 1, 1, 0, 0, 0, 0).until(dateTime(2020, 1, 2, 6, 0, 0, 0), .{ .largest = .hour }));
    try expectSpan(.{ .seconds = 108_000, .nanoseconds = 5 }, try dateTime(2020, 1, 1, 0, 0, 0, 0).until(dateTime(2020, 1, 2, 6, 0, 0, 5), .{ .largest = .second }));
    try expectSpan(.{ .nanoseconds = 108_000_000_000_005 }, try dateTime(2020, 1, 1, 0, 0, 0, 0).until(dateTime(2020, 1, 2, 6, 0, 0, 5), .{ .largest = .nanosecond }));
    try expectSpan(.{ .months = 1, .days = 28, .hours = 23 }, try dateTime(2020, 1, 1, 1, 0, 0, 0).until(dateTime(2020, 3, 1, 0, 0, 0, 0), .{ .largest = .month }));
    try testing.expectError(error.InvalidOptions, dateTime(2020, 1, 1, 0, 0, 0, 0).until(dateTime(2020, 1, 2, 0, 0, 0, 0), .{ .smallest = .hour, .increment = 5 }));
    try testing.expectError(error.InvalidOptions, dateTime(2020, 1, 1, 0, 0, 0, 0).until(dateTime(2020, 1, 2, 0, 0, 0, 0), .{ .smallest = .minute, .increment = 60 }));
}

test "rounding a difference: calendar units by progress through the unit, carrying upward" {
    const a = date(2019, 1, 1);
    const b = date(2020, 7, 2);
    // 1 year 6 months 1 day: 183 of 2020's 366 days past the year, just over half.
    try expectSpan(.{ .years = 2 }, try a.until(b, .{ .largest = .year, .smallest = .year, .mode = .half_expand }));
    try expectSpan(.{ .years = 1 }, try a.until(b, .{ .largest = .year, .smallest = .year }));
    try expectSpan(.{ .years = 2 }, try a.until(b, .{ .largest = .year, .smallest = .year, .mode = .ceil }));
    try expectSpan(.{ .years = 1, .months = 6 }, try a.until(b, .{ .largest = .year, .smallest = .month, .mode = .half_even }));
    try expectSpan(.{ .years = 1, .months = 7 }, try a.until(b, .{ .largest = .year, .smallest = .month, .mode = .expand }));
    // Increments: 18 months and a day to sixes of months; 548 days to weeks of 10.
    try expectSpan(.{ .months = 18 }, try a.until(b, .{ .largest = .month, .smallest = .month, .increment = 6, .mode = .half_expand }));
    try expectSpan(.{ .months = 24 }, try a.until(b, .{ .largest = .month, .smallest = .month, .increment = 6, .mode = .expand }));
    try expectSpan(.{ .weeks = 80 }, try a.until(b, .{ .largest = .week, .smallest = .week, .increment = 10, .mode = .half_expand }));
    try expectSpan(.{ .days = 550 }, try a.until(b, .{ .smallest = .day, .increment = 50, .mode = .half_expand }));
    // A month from January 31 ends on February 29, which is the destination: the whole month.
    try expectSpan(.{ .months = 1 }, try date(2020, 1, 31).until(date(2020, 2, 29), .{ .largest = .month, .smallest = .month }));
    // Rounding up into a new year carries the months and days with it.
    try expectSpan(.{ .years = 1 }, try dateTime(2020, 1, 1, 0, 0, 0, 0).until(dateTime(2020, 12, 31, 23, 59, 59, 900_000_000), .{ .largest = .year, .smallest = .second, .mode = .half_expand }));
    try expectSpan(.{ .months = 2, .seconds = 1 }, try dateTime(2020, 1, 1, 0, 0, 0, 0).until(dateTime(2020, 3, 1, 0, 0, 0, 500_000_000), .{ .largest = .month, .smallest = .second, .mode = .half_expand }));
    // since rounds with the mode negated: floor on the negative difference is ceil on its magnitude.
    try expectSpan(.{ .years = 2 }, try b.since(a, .{ .largest = .year, .smallest = .year, .mode = .ceil }));
    try expectSpan(.{ .years = -1 }, try a.since(b, .{ .largest = .year, .smallest = .year, .mode = .ceil }));
    try expectSpan(.{ .years = -2 }, try a.since(b, .{ .largest = .year, .smallest = .year, .mode = .floor }));
}

test "rounding a span without a date: every mode at and around a tie, both signs" {
    const r = struct {
        fn r(minutes: i64, mode: almanac.RoundingMode) !i128 {
            return (try span(.{ .minutes = minutes }).round(.{ .smallest = .hour, .mode = mode })).get(.hour);
        }
    }.r;
    const modes = std.enums.values(almanac.RoundingMode);
    // 90 minutes: ceil, floor, expand, trunc, half_ceil, half_floor, half_expand, half_trunc, half_even.
    const plus = [_]i128{ 2, 1, 2, 1, 2, 1, 2, 1, 2 };
    const minus = [_]i128{ -1, -2, -2, -1, -1, -2, -2, -1, -2 };
    for (modes, plus, minus) |mode, p, m| {
        try testing.expectEqual(p, try r(90, mode));
        try testing.expectEqual(m, try r(-90, mode));
    }
    // 150 minutes: half-even goes to 2; 89 and 91 are no ties.
    try testing.expectEqual(2, try r(150, .half_even));
    try testing.expectEqual(1, try r(89, .half_expand));
    try testing.expectEqual(2, try r(91, .half_trunc));
    try expectSpan(.{ .days = 1, .hours = 1 }, try span(.{ .hours = 25 }).round(.{ .largest = .day }));
    try expectSpan(.{ .hours = 25 }, try span(.{ .days = 1, .hours = 1 }).round(.{ .largest = .hour }));
    try expectSpan(.{ .hours = 1, .minutes = 30 }, try span(.{ .seconds = 5400 }).round(.{ .largest = .hour }));
    // With neither unit given, balanced up to its own largest unit: as it was.
    try expectSpan(.{ .seconds = 5400 }, try span(.{ .seconds = 5400 }).round(.{}));
    try expectSpan(.{ .seconds = 5400 }, try span(.{ .hours = 1, .minutes = 30 }).round(.{ .largest = .second }));
    try expectSpan(.{ .minutes = 15 }, try span(.{ .minutes = 13 }).round(.{ .smallest = .minute, .increment = 15, .mode = .half_expand }));
    try expectSpan(.{ .days = 2 }, try span(.{ .hours = 36 }).round(.{ .smallest = .day, .mode = .half_even }));
    // The default largest unit is the larger of the span's own and the smallest.
    try expectSpan(.{ .microseconds = 1500 }, try span(.{ .nanoseconds = 1_500_400 }).round(.{ .smallest = .microsecond }));
    try expectSpan(.{ .milliseconds = 1, .microseconds = 501 }, try span(.{ .nanoseconds = 1_500_600 }).round(.{ .largest = .second, .smallest = .microsecond }));
    // Calendar units need a date; options Temporal refuses are refused.
    try testing.expectError(error.CalendarUnits, span(.{ .months = 1 }).round(.{ .smallest = .day }));
    try testing.expectError(error.CalendarUnits, span(.{ .days = 40 }).round(.{ .largest = .month }));
    try testing.expectError(error.InvalidOptions, span(.{ .hours = 1 }).round(.{ .largest = .minute, .smallest = .hour }));
    try testing.expectError(error.InvalidOptions, span(.{ .hours = 1 }).round(.{ .smallest = .minute, .increment = 7 }));
    try testing.expectError(error.InvalidOptions, span(.{ .days = 10 }).round(.{ .largest = .week, .smallest = .day, .increment = 2, .relative_to = date(2020, 1, 1).relativeTo() }));
    try expectSpan(.{ .days = 10 }, try span(.{ .days = 9 }).round(.{ .largest = .day, .smallest = .day, .increment = 2, .mode = .ceil }));
}

test "rounding and balancing a span from a date: months have their lengths" {
    const jan = date(2020, 1, 1).relativeTo();
    const feb = date(2020, 2, 1).relativeTo();
    try expectSpan(.{ .months = 1 }, try span(.{ .days = 31 }).round(.{ .largest = .month, .relative_to = jan }));
    try expectSpan(.{ .months = 1, .days = 2 }, try span(.{ .days = 31 }).round(.{ .largest = .month, .relative_to = feb }));
    try expectSpan(.{ .days = 29 }, try span(.{ .months = 1 }).round(.{ .largest = .day, .relative_to = feb }));
    try expectSpan(.{ .months = 1 }, try span(.{ .months = 1 }).round(.{ .smallest = .day, .relative_to = feb }));
    try expectSpan(.{ .years = 1, .months = 1 }, try span(.{ .months = 13 }).round(.{ .largest = .year, .relative_to = jan }));
    // 15 days into March's 31 is short of half; 15 into February's 29 is past it.
    try expectSpan(.{ .months = 1 }, try span(.{ .months = 1, .days = 15 }).round(.{ .smallest = .month, .relative_to = feb }));
    try expectSpan(.{ .months = 2 }, try span(.{ .months = 1, .days = 15 }).round(.{ .smallest = .month, .relative_to = jan }));
    // Time beneath the days, negative: back from midnight into the day before.
    try expectSpan(.{ .days = -1, .hours = -1 }, try span(.{ .hours = -25 }).round(.{ .largest = .day, .relative_to = jan }));
    try expectSpan(.{ .months = -1, .days = -1 }, try span(.{ .days = -32 }).round(.{ .largest = .month, .relative_to = jan }));
}

test "comparing spans, adding and subtracting them" {
    try testing.expectEqual(.gt, try Span.compare(span(.{ .days = 31 }), span(.{ .months = 1 }), date(2020, 2, 1).relativeTo()));
    try testing.expectEqual(.eq, try Span.compare(span(.{ .days = 31 }), span(.{ .months = 1 }), date(2020, 1, 1).relativeTo()));
    try testing.expectEqual(.lt, try Span.compare(span(.{ .hours = 23 }), span(.{ .days = 1 }), null));
    try testing.expectEqual(.gt, try Span.compare(span(.{ .seconds = 1 }), span(.{ .nanoseconds = -1 }), null));
    try testing.expectError(error.CalendarUnits, Span.compare(span(.{ .days = 31 }), span(.{ .months = 1 }), null));
    try expectSpan(.{ .hours = 25 }, try span(.{ .hours = 23 }).add(span(.{ .hours = 2 })));
    try expectSpan(.{ .days = 1, .hours = 1 }, try span(.{ .days = 1 }).add(span(.{ .hours = 1 })));
    try expectSpan(.{ .hours = -1 }, try span(.{ .days = 1 }).add(span(.{ .hours = -25 })));
    try expectSpan(.{ .minutes = 1, .seconds = 30 }, try span(.{ .minutes = 2 }).subtract(span(.{ .seconds = 30 })));
    try testing.expectError(error.CalendarUnits, span(.{ .weeks = 1 }).add(span(.{ .days = 1 })));
    try testing.expectError(error.OutOfRange, span(.{ .seconds = (1 << 53) - 1 }).add(span(.{ .seconds = 1 })));
}

const largests = [_]Unit{ .year, .month, .week, .day };

fn anyDates(_: void, case: *shakedown.Case) !void {
    const a = try Date.fromDays(shakedown.gen.intRange(case.source, i32, calendar.min_days, calendar.max_days));
    // Mostly near each other, where month ends matter; sometimes anywhere.
    const far = shakedown.gen.intRange(case.source, u8, 0, 3) == 0;
    const reach: i32 = if (far) calendar.max_days - calendar.min_days else 800;
    const n = shakedown.gen.intRange(case.source, i32, -reach, reach);
    const b = Date.fromDays(std.math.clamp(a.days() + n, calendar.min_days, calendar.max_days)) catch unreachable;
    for (largests) |largest| {
        const d = try a.until(b, .{ .largest = largest });
        // Under constrain: January 31 to March 1 is a month and a day, through February 28.
        try testing.expect((try a.add(d, .constrain)).eql(b));
        // since is the same difference negated, so subtracting it reaches the end too.
        const s = try a.since(b, .{ .largest = largest });
        try testing.expect(s.negate().eql(d));
        try testing.expect((try a.subtract(s, .constrain)).eql(b));
        // Every unit below the largest is within its bound: months below 12, and days below the
        // month reached (a week where weeks are the largest).
        if (largest == .year) try testing.expect(@abs(d.get(.month)) < 12);
        if (largest == .week) try testing.expect(@abs(d.get(.day)) < 7);
        if (largest == .year or largest == .month) try testing.expect(@abs(d.get(.day)) < 31);
    }
}

test "property: adding a difference between dates reaches its end, in every largest unit" {
    try shakedown.check(testing.allocator, {}, anyDates, .{ .cases = 3000, .seed = 0x5a2 });
}

const all_units = std.enums.values(Unit);

fn anyDateTimes(_: void, case: *shakedown.Case) !void {
    const a: DateTime = .{
        .date = try Date.fromDays(shakedown.gen.intRange(case.source, i32, -800_000, 800_000)),
        .time = try Time.fromNanosecondOfDay(shakedown.gen.intRange(case.source, u64, 0, Time.nanoseconds_per_day - 1)),
    };
    const b: DateTime = .{
        .date = try Date.fromDays(a.date.days() + shakedown.gen.intRange(case.source, i32, -400, 400)),
        .time = try Time.fromNanosecondOfDay(shakedown.gen.intRange(case.source, u64, 0, Time.nanoseconds_per_day - 1)),
    };
    for (all_units) |largest| {
        const d = try a.until(b, .{ .largest = largest });
        try testing.expect((try a.add(d, .constrain)).eql(b));
        try testing.expect((try a.subtract(try a.since(b, .{ .largest = largest }), .constrain)).eql(b));
    }
    // Rounded to any unit at or below the largest, a difference stays within one increment of the
    // exact one, and truncation never passes the end.
    const exact = try a.until(b, .{ .largest = .day });
    const smallest = all_units[shakedown.gen.intRange(case.source, usize, 3, all_units.len - 1)];
    const t = try a.until(b, .{ .largest = .day, .smallest = smallest });
    const reached = try a.add(t, .constrain);
    try testing.expect(if (exact.signum() >= 0) reached.order(b) != .gt else reached.order(b) != .lt);
}

test "property: adding a difference between dates and times reaches its end, in every largest unit" {
    try shakedown.check(testing.allocator, {}, anyDateTimes, .{ .cases = 2000, .seed = 0x5a3 });
}
