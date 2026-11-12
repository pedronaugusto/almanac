//! Instants: any aegis instant of the real clock read at its own unit and representation, the
//! range's edges, civil time at an offset and back, conversion and rounding on the timeline,
//! differences and adding (Temporal's `Instant`), and chronicle's `Time` agreeing with a
//! `Timestamp` of the same instant.
const std = @import("std");
const aegis = @import("aegis");
const shakedown = @import("shakedown");
const almanac = @import("almanac.zig");
const calendar = @import("calendar.zig");
const instant = almanac.instant;
const Timestamp = almanac.Timestamp;
const Offset = almanac.Offset;
const Span = almanac.Span;
const DateTime = almanac.DateTime;
const testing = std.testing;

/// chronicle's `Time` (src/journal/values.zig): the same aegis instantiation, so the same type.
const ChronicleTime = aegis.units.Instant(.real, .millisecond, i64);
const UnsignedMillis = aegis.units.Instant(.real, .millisecond, u64);
const Seconds = aegis.units.Instant(.real, .second, i64);
const UnsignedSeconds = aegis.units.Instant(.real, .second, u64);

fn dateTime(y: i16, mo: u8, d: u8, h: u8, mi: u8, s: u8, ns: u32) DateTime {
    return .{ .date = almanac.Date.init(y, mo, d) catch unreachable, .time = almanac.Time.init(h, mi, s, ns) catch unreachable };
}

fn offset(seconds: i32) Offset {
    return Offset.init(seconds) catch unreachable;
}

fn ts(ns: i96) Timestamp {
    return .fromRaw(ns);
}

const sample_s: i64 = 1_700_000_000; // 2023-11-14T22:13:20Z

test "the range's edges, in UTC and at offsets" {
    try testing.expect((try instant.toDateTime(instant.min, .utc)).eql(dateTime(-9999, 1, 1, 0, 0, 0, 0)));
    try testing.expect((try instant.toDateTime(instant.max, .utc)).eql(dateTime(9999, 12, 31, 23, 59, 59, 999_999_999)));
    try testing.expectError(error.OutOfRange, instant.toDateTime(instant.max, offset(3600)));
    try testing.expectError(error.OutOfRange, instant.toDateTime(instant.min, offset(-1)));
    try testing.expect(instant.inRange(instant.max) and !instant.inRange(ts(instant.max.raw() + 1)));
    try testing.expect(!instant.inRange(ts(instant.min.raw() - 1)));
    try testing.expectError(error.OutOfRange, instant.fromDateTime(dateTime(-9999, 1, 1, 0, 0, 0, 0), offset(1)));
    try testing.expectEqual(instant.min, try instant.fromDateTime(dateTime(-9999, 1, 1, 0, 0, 1, 0), offset(1)));
    // A u64 of seconds past i128's nanoseconds is simply out of range, not an overflow.
    try testing.expect(!instant.inRange(aegis.units.Instant(.real, .day, i128).fromRaw(std.math.maxInt(i128))));
}

test "civil time at an offset, and back" {
    const s = Seconds.fromRaw(sample_s);
    try testing.expect((try instant.toDateTime(s, .utc)).eql(dateTime(2023, 11, 14, 22, 13, 20, 0)));
    try testing.expect((try instant.toDateTime(s, offset(5 * 3600 + 1800))).eql(dateTime(2023, 11, 15, 3, 43, 20, 0)));
    try testing.expect((try instant.toDateTime(s, offset(-10 * 3600))).eql(dateTime(2023, 11, 14, 12, 13, 20, 0)));
    try testing.expectEqual(try instant.timestamp(s), try instant.fromDateTime(dateTime(2023, 11, 15, 3, 43, 20, 0), offset(5 * 3600 + 1800)));
    try testing.expect((try instant.toDateTime(ts(-1), .utc)).eql(dateTime(1969, 12, 31, 23, 59, 59, 999_999_999)));
    try testing.expect((try instant.toDateTime(ts(0), offset(-93_599))).eql(dateTime(1969, 12, 30, 22, 0, 1, 0)));
}

test "conversion between units rounds on the timeline" {
    const a = ts(1_500_000_000);
    try testing.expectEqual(ChronicleTime.fromRaw(1500), try instant.convert(ChronicleTime, a, .trunc));
    try testing.expectEqual(Seconds.fromRaw(1), try instant.convert(Seconds, a, .trunc));
    try testing.expectEqual(Seconds.fromRaw(2), try instant.convert(Seconds, a, .half_expand));
    try testing.expectEqual(Seconds.fromRaw(2), try instant.convert(Seconds, a, .half_even));
    const b = ts(-1_500_000_000);
    try testing.expectEqual(Seconds.fromRaw(-2), try instant.convert(Seconds, b, .trunc));
    try testing.expectEqual(Seconds.fromRaw(-1), try instant.convert(Seconds, b, .half_expand));
    try testing.expectEqual(Seconds.fromRaw(-2), try instant.convert(Seconds, b, .half_even));
    try testing.expectEqual(Seconds.fromRaw(-1), try instant.convert(Seconds, b, .ceil));
    // An unsigned type holds no instant before 1970.
    try testing.expectError(error.OutOfRange, instant.convert(UnsignedSeconds, b, .trunc));
    try testing.expectEqual(ts(sample_s * std.time.ns_per_s), try instant.timestamp(UnsignedSeconds.fromRaw(sample_s)));
    try testing.expectError(error.OutOfRange, instant.timestamp(UnsignedSeconds.fromRaw(std.math.maxInt(u64))));
}

test "rounding: every unit up to the hour, increments dividing a day, the type kept" {
    const base = sample_s * std.time.ns_per_s;
    const a = ts(base + 500_000_000); // 22:13:20.5
    try testing.expectEqual(ts(base + std.time.ns_per_s), try instant.round(a, .{ .smallest = .second }));
    try testing.expectEqual(ts(base), try instant.round(a, .{ .smallest = .second, .mode = .half_even }));
    try testing.expectEqual(ts(base - 13 * 60 * std.time.ns_per_s - 20 * std.time.ns_per_s), try instant.round(a, .{ .smallest = .hour, .mode = .floor }));
    // 13 minutes 20 seconds is past half of 15.
    try testing.expectEqual(ts(base + 100 * std.time.ns_per_s), try instant.round(a, .{ .smallest = .minute, .increment = 15 }));
    // An increment of 24 hours rounds to days from 1970: 22:13 goes to the next midnight.
    try testing.expect((try instant.toDateTime(try instant.round(a, .{ .smallest = .hour, .increment = 24 }), .utc)).eql(dateTime(2023, 11, 15, 0, 0, 0, 0)));
    try testing.expectError(error.InvalidOptions, instant.round(a, .{ .smallest = .hour, .increment = 5 }));
    try testing.expectError(error.InvalidOptions, instant.round(a, .{ .smallest = .hour, .increment = 25 }));
    try testing.expectError(error.InvalidOptions, instant.round(a, .{ .smallest = .day }));
    try testing.expect((try instant.toDateTime(try instant.round(a, .{ .smallest = .minute, .increment = 1440, .mode = .trunc }), .utc)).eql(dateTime(2023, 11, 14, 0, 0, 0, 0)));
    // Before 1970, trunc goes back.
    try testing.expectEqual(ts(-std.time.ns_per_s), try instant.round(ts(-1), .{ .smallest = .second, .mode = .trunc }));
    // The instant's own type comes back; a length its unit cannot hold is refused.
    const c = ChronicleTime.fromRaw(sample_s * 1000 + 1500);
    try testing.expectEqual(ChronicleTime.fromRaw(sample_s * 1000 + 2000), try instant.round(c, .{ .smallest = .second }));
    try testing.expectEqual(ChronicleTime.fromRaw(sample_s * 1000 + 1500), try instant.round(c, .{ .smallest = .microsecond }));
    try testing.expectError(error.InvalidOptions, instant.round(Seconds.fromRaw(sample_s), .{ .smallest = .millisecond, .increment = 1500 }));
    try testing.expectEqual(Seconds.fromRaw(sample_s), try instant.round(Seconds.fromRaw(sample_s), .{ .smallest = .millisecond, .increment = 500 }));
    try testing.expectError(error.OutOfRange, instant.round(instant.max, .{ .smallest = .second }));
}

test "differences in time units, and adding spans of them" {
    const a = Seconds.fromRaw(sample_s);
    const b = ts(sample_s * std.time.ns_per_s + 5400 * std.time.ns_per_s + 500_000_000);
    try testing.expect((try instant.until(a, b, .{})).eql(try Span.fromSigned(.{ .seconds = 5400, .milliseconds = 500 })));
    try testing.expect((try instant.until(a, b, .{ .largest = .hour })).eql(try Span.fromSigned(.{ .hours = 1, .minutes = 30, .milliseconds = 500 })));
    try testing.expect((try instant.until(a, b, .{ .largest = .hour, .smallest = .minute, .mode = .half_expand })).eql(try Span.fromSigned(.{ .hours = 1, .minutes = 30 })));
    try testing.expect((try instant.since(a, b, .{ .largest = .hour, .smallest = .second, .mode = .ceil })).eql(try Span.fromSigned(.{ .hours = -1, .minutes = -30 })));
    try testing.expect((try instant.since(b, a, .{ .smallest = .second, .mode = .ceil })).eql(try Span.fromSigned(.{ .seconds = 5401 })));
    try testing.expectError(error.InvalidOptions, instant.until(a, b, .{ .largest = .day }));
    try testing.expectError(error.InvalidOptions, instant.until(a, b, .{ .smallest = .minute, .increment = 7 }));
    // The whole range's difference fits a span.
    _ = try instant.until(instant.min, instant.max, .{ .largest = .hour });

    try testing.expectEqual(ts((sample_s + 25 * 3600) * std.time.ns_per_s), try instant.add(a, try Span.fromSigned(.{ .hours = 25 })));
    try testing.expectEqual(ts(sample_s * std.time.ns_per_s - 1), try instant.subtract(a, try Span.fromSigned(.{ .nanoseconds = 1 })));
    try testing.expectError(error.CalendarUnits, instant.add(a, try Span.fromSigned(.{ .days = 1 })));
    try testing.expectError(error.CalendarUnits, instant.add(a, try Span.fromSigned(.{ .months = 1 })));
    try testing.expectError(error.OutOfRange, instant.add(instant.max, try Span.fromSigned(.{ .nanoseconds = 1 })));
}

test "chronicle's Time and a u64 of milliseconds agree with a Timestamp of the same instant" {
    const ms: i64 = sample_s * 1000 + 250;
    const c = ChronicleTime.fromRaw(ms);
    const u = UnsignedMillis.fromRaw(@intCast(ms));
    const t = ts(@as(i96, ms) * std.time.ns_per_ms);
    try testing.expectEqual(t, try instant.timestamp(c));
    try testing.expectEqual(t, try instant.timestamp(u));
    for ([_]i32{ 0, 3600, -12 * 3600, 5 * 3600 + 2700 }) |o| {
        const dc = try instant.toDateTime(c, offset(o));
        try testing.expect(dc.eql(try instant.toDateTime(u, offset(o))));
        try testing.expect(dc.eql(try instant.toDateTime(t, offset(o))));
    }
    const rc = try instant.round(c, .{ .smallest = .second });
    try testing.expectEqual(try instant.timestamp(rc), try instant.round(t, .{ .smallest = .second }));
    try testing.expectEqual(try instant.timestamp(try instant.round(u, .{ .smallest = .minute })), try instant.round(t, .{ .smallest = .minute }));
    try testing.expect((try instant.until(c, u, .{})).isZero());
    try testing.expectEqual(c, try instant.convert(ChronicleTime, t, .trunc));
}

test "now is inside the range" {
    const n = almanac.now(testing.io);
    try testing.expect(almanac.inRange(n));
    try testing.expect((try instant.toDateTime(n, .utc)).date.year.raw() >= 2026);
}

fn anyInstant(_: void, case: *shakedown.Case) !void {
    const days = shakedown.gen.intRange(case.source, i32, calendar.min_days, calendar.max_days);
    const of_day = shakedown.gen.intRange(case.source, u64, 0, std.time.ns_per_day - 1);
    const ns: i96 = @as(i96, days) * std.time.ns_per_day + of_day;
    const o = offset(shakedown.gen.intRange(case.source, i32, -93_599, 93_599));
    const t = ts(ns);
    const local = @as(i128, ns) + @as(i128, o.seconds.raw()) * std.time.ns_per_s;
    const dt = instant.toDateTime(t, o) catch |err| {
        // Only where the offset carries it past the calendar's edge.
        try testing.expectEqual(error.OutOfRange, err);
        try testing.expect(local < instant.min.raw() or local > instant.max.raw());
        return;
    };
    try testing.expectEqual(t, try instant.fromDateTime(dt, o));
    try testing.expectEqual(@divFloor(local, std.time.ns_per_day), dt.date.days());
    // Through chronicle's milliseconds, floored, and back is the instant floored to the millisecond.
    const c = try instant.convert(ChronicleTime, t, .floor);
    try testing.expectEqual(try instant.round(t, .{ .smallest = .millisecond, .mode = .floor }), try instant.timestamp(c));
}

test "property: civil time at any offset and back is the instant" {
    try shakedown.check(testing.allocator, {}, anyInstant, .{ .cases = 3000, .seed = 0x157 });
}
