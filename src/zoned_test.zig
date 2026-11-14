//! Resolution and zoned values (Temporal's semantics): candidates in gaps and folds, every
//! disambiguation and offset conflict policy, the start of a day the zone skips midnight on,
//! arithmetic and differences across a change of offset, rounding by a day's own length, spans
//! measured from a zoned value, and resolution against a brute-force search of a zone's offsets.
const std = @import("std");
const aegis = @import("aegis");
const shakedown = @import("shakedown");
const almanac = @import("almanac.zig");
const zoneinfo = @import("zoneinfo");
const TimeZone = almanac.TimeZone;
const Zoned = almanac.Zoned;
const Span = almanac.Span;
const DateTime = almanac.DateTime;
const resolve = almanac.resolve;
const testing = std.testing;
const Untrusted = aegis.input.Untrusted([]const u8);
const ns_per_s = std.time.ns_per_s;

fn dt(y: i16, mo: u8, d: u8, h: u8, mi: u8, s: u8) DateTime {
    return .{ .date = almanac.Date.init(y, mo, d) catch unreachable, .time = almanac.Time.init(h, mi, s, 0) catch unreachable };
}

fn utc(y: i16, mo: u8, d: u8, h: u8, mi: u8, s: u8) i128 {
    return (almanac.instant.fromDateTime(dt(y, mo, d, h, mi, s), .utc) catch unreachable).raw();
}

fn offset(seconds: i32) almanac.Offset {
    return almanac.Offset.init(seconds) catch unreachable;
}

fn span(f: Span.Signed) Span {
    return Span.fromSigned(f) catch unreachable;
}

fn expectSpan(want: Span.Signed, got: Span) !void {
    if (!span(want).eql(got)) {
        std.debug.print("want {any}\n got {any}\n", .{ want, got });
        return error.TestUnexpectedResult;
    }
}

fn newYork() !TimeZone {
    return TimeZone.fromTzif(testing.allocator, Untrusted.init(zoneinfo.America_New_York), "America/New_York");
}

fn at(zone: *const TimeZone, d: DateTime) !Zoned {
    return Zoned.fromDateTime(d, zone, .reject);
}

test "candidates: none in a gap, two in a fold, one elsewhere" {
    var ny = try newYork();
    defer ny.free();
    try testing.expectEqual(0, ny.candidates(dt(2024, 3, 10, 2, 30, 0)).count);
    const fold = ny.candidates(dt(2024, 11, 3, 1, 30, 0));
    try testing.expectEqual(2, fold.count);
    try testing.expectEqual(utc(2024, 11, 3, 5, 30, 0), fold.earliest().?);
    try testing.expectEqual(utc(2024, 11, 3, 6, 30, 0), fold.latest().?);
    try testing.expectEqual(1, ny.candidates(dt(2024, 7, 1, 12, 0, 0)).count);
    try testing.expectEqual(1, TimeZone.utc.candidates(dt(2024, 7, 1, 12, 0, 0)).count);
}

test "disambiguation in a gap and a fold" {
    var ny = try newYork();
    defer ny.free();
    const gap = dt(2024, 3, 10, 2, 30, 0);
    try testing.expectEqual(utc(2024, 3, 10, 7, 30, 0), try resolve.resolve(&ny, gap, .compatible));
    try testing.expectEqual(utc(2024, 3, 10, 7, 30, 0), try resolve.resolve(&ny, gap, .later));
    try testing.expectEqual(utc(2024, 3, 10, 6, 30, 0), try resolve.resolve(&ny, gap, .earlier));
    try testing.expectError(error.Skipped, resolve.resolve(&ny, gap, .reject));
    const fold = dt(2024, 11, 3, 1, 30, 0);
    try testing.expectEqual(utc(2024, 11, 3, 5, 30, 0), try resolve.resolve(&ny, fold, .compatible));
    try testing.expectEqual(utc(2024, 11, 3, 5, 30, 0), try resolve.resolve(&ny, fold, .earlier));
    try testing.expectEqual(utc(2024, 11, 3, 6, 30, 0), try resolve.resolve(&ny, fold, .later));
    try testing.expectError(error.Ambiguous, resolve.resolve(&ny, fold, .reject));
    // The wall clock of the gap's resolution is moved past it.
    const z = try Zoned.fromDateTime(gap, &ny, .compatible);
    try testing.expect(z.dateTime().eql(dt(2024, 3, 10, 3, 30, 0)));
    try testing.expectEqualStrings("EDT", z.info().abbreviation);
    // The range's edge: a wall clock whose instant would precede it.
    try testing.expectError(error.OutOfRange, resolve.resolve(&TimeZone.fixed(offset(3600)), dt(-9999, 1, 1, 0, 0, 0), .compatible));
}

test "a written offset against the zone's: use, ignore, prefer, reject" {
    var ny = try newYork();
    defer ny.free();
    const fold = dt(2024, 11, 3, 1, 30, 0);
    try testing.expectEqual(utc(2024, 11, 3, 6, 30, 0), try resolve.resolveWithOffset(&ny, fold, offset(-18000), .prefer, .compatible, false));
    try testing.expectEqual(utc(2024, 11, 3, 5, 30, 0), try resolve.resolveWithOffset(&ny, fold, offset(-14400), .reject, .reject, false));
    try testing.expectEqual(utc(2024, 11, 3, 5, 30, 0), try resolve.resolveWithOffset(&ny, fold, offset(-10800), .prefer, .compatible, false));
    try testing.expectError(error.OffsetConflict, resolve.resolveWithOffset(&ny, fold, offset(-10800), .reject, .compatible, false));
    try testing.expectEqual(utc(2024, 11, 3, 4, 30, 0), try resolve.resolveWithOffset(&ny, fold, offset(-10800), .use, .compatible, false));
    try testing.expectEqual(utc(2024, 11, 3, 6, 30, 0), try resolve.resolveWithOffset(&ny, fold, offset(-10800), .ignore, .later, false));
    // Lisbon's local mean time, -0:36:45, written to the minute as -00:37.
    var lisbon = try TimeZone.fromTzif(testing.allocator, Untrusted.init(zoneinfo.Europe_Lisbon), null);
    defer lisbon.free();
    const old = dt(1900, 1, 1, 0, 0, 0);
    try testing.expectError(error.OffsetConflict, resolve.resolveWithOffset(&lisbon, old, offset(-2220), .reject, .compatible, false));
    try testing.expectEqual(utc(1900, 1, 1, 0, 36, 45), try resolve.resolveWithOffset(&lisbon, old, offset(-2220), .reject, .compatible, true));
}

test "the start of a day the zone skips midnight on" {
    // Brazil's old rule: daylight saving began at midnight.
    const brazil = try TimeZone.posix(Untrusted.init("<-03>3<-02>,M10.1.0/0,M2.3.0/0"));
    try testing.expectEqual(utc(2017, 10, 1, 3, 0, 0), try resolve.startOfDay(&brazil, dt(2017, 10, 1, 0, 0, 0).date));
    const z = try (try Zoned.fromDateTime(dt(2017, 10, 1, 12, 0, 0), &brazil, .reject)).startOfDay();
    try testing.expect(z.dateTime().eql(dt(2017, 10, 1, 1, 0, 0)));
    try testing.expectEqual(utc(2017, 10, 2, 2, 0, 0), try resolve.startOfDay(&brazil, dt(2017, 10, 2, 0, 0, 0).date));
}

test "adding across a change of offset: days by the wall clock, hours on the timeline" {
    var ny = try newYork();
    defer ny.free();
    const z = try at(&ny, dt(2024, 3, 9, 12, 0, 0));
    try testing.expect((try z.add(span(.{ .days = 1 }), .constrain)).dateTime().eql(dt(2024, 3, 10, 12, 0, 0)));
    try testing.expect((try z.add(span(.{ .hours = 24 }), .constrain)).dateTime().eql(dt(2024, 3, 10, 13, 0, 0)));
    const before_fold = try at(&ny, dt(2024, 11, 3, 0, 30, 0));
    const one = try before_fold.add(span(.{ .hours = 1 }), .constrain);
    const two = try before_fold.add(span(.{ .hours = 2 }), .constrain);
    try testing.expect(one.dateTime().eql(dt(2024, 11, 3, 1, 30, 0)) and two.dateTime().eql(dt(2024, 11, 3, 1, 30, 0)));
    try testing.expectEqualStrings("EDT", one.info().abbreviation);
    try testing.expectEqualStrings("EST", two.info().abbreviation);
    // A month into a gap: 2024-02-10 02:30 plus a month is skipped, so `compatible` moves past it.
    const feb = try at(&ny, dt(2024, 2, 10, 2, 30, 0));
    try testing.expect((try feb.add(span(.{ .months = 1 }), .constrain)).dateTime().eql(dt(2024, 3, 10, 3, 30, 0)));
    try testing.expectError(error.OutOfRange, (try at(&ny, dt(2024, 1, 31, 12, 0, 0))).add(span(.{ .months = 1 }), .reject));
    try testing.expect((try z.subtract(span(.{ .days = 1, .hours = 1 }), .constrain)).dateTime().eql(dt(2024, 3, 8, 11, 0, 0)));
}

test "differences across a change of offset, and rounding them" {
    var ny = try newYork();
    defer ny.free();
    const a = try at(&ny, dt(2024, 3, 9, 12, 0, 0));
    const b = try at(&ny, dt(2024, 3, 10, 12, 0, 0));
    try expectSpan(.{ .hours = 23 }, try a.until(b, .{}));
    try expectSpan(.{ .days = 1 }, try a.until(b, .{ .largest = .day }));
    try expectSpan(.{ .days = -1 }, try b.until(a, .{ .largest = .day }));
    try expectSpan(.{ .days = 1 }, try b.since(a, .{ .largest = .day }));
    const c = try at(&ny, dt(2024, 3, 10, 11, 30, 0));
    try expectSpan(.{ .hours = 22, .minutes = 30 }, try a.until(c, .{ .largest = .day }));
    // 22.5 hours of a 23-hour day rounds up to the whole day.
    try expectSpan(.{ .days = 1 }, try a.until(c, .{ .largest = .day, .smallest = .hour, .mode = .half_expand }));
    try expectSpan(.{ .days = 1 }, try a.until(c, .{ .largest = .month, .smallest = .day, .mode = .half_expand }));
    try expectSpan(.{}, try a.until(c, .{ .largest = .month, .smallest = .day, .mode = .trunc }));
    // A month across the change, and different zones refused in date units.
    const d = try at(&ny, dt(2024, 4, 9, 12, 0, 0));
    try expectSpan(.{ .months = 1 }, try a.until(d, .{ .largest = .year }));
    const other = TimeZone.fixed(offset(-18000));
    const e = try Zoned.init(d.timestamp, &other);
    try testing.expectError(error.InvalidOptions, a.until(e, .{ .largest = .day }));
    _ = try a.until(e, .{ .largest = .hour });
}

test "rounding a zoned value: by the day's own length, or by the wall clock" {
    var ny = try newYork();
    defer ny.free();
    const short = try at(&ny, dt(2024, 3, 10, 12, 0, 0));
    // 11 of the day's 23 hours: short of half.
    try testing.expect((try short.round(.{ .smallest = .day })).dateTime().eql(dt(2024, 3, 10, 0, 0, 0)));
    const plain = try at(&ny, dt(2024, 3, 12, 12, 0, 0));
    try testing.expect((try plain.round(.{ .smallest = .day })).dateTime().eql(dt(2024, 3, 13, 0, 0, 0)));
    try testing.expect((try plain.round(.{ .smallest = .hour, .increment = 6, .mode = .floor })).dateTime().eql(dt(2024, 3, 12, 12, 0, 0)));
    try testing.expectError(error.InvalidOptions, plain.round(.{ .smallest = .day, .increment = 2 }));
    try testing.expectError(error.InvalidOptions, plain.round(.{ .smallest = .month }));
    // In the fold, rounding keeps the offset in force: the second 01:30 stays the second.
    const second = try Zoned.fromDateTime(dt(2024, 11, 3, 1, 29, 50), &ny, .later);
    const rounded = try second.round(.{ .smallest = .minute });
    try testing.expect(rounded.dateTime().eql(dt(2024, 11, 3, 1, 30, 0)));
    try testing.expectEqualStrings("EST", rounded.info().abbreviation);
    try expectSpan(.{ .hours = 23 }, try short.hoursInDay());
    try expectSpan(.{ .hours = 25 }, try (try at(&ny, dt(2024, 11, 3, 12, 0, 0))).hoursInDay());
}

test "spans measured from a zoned value" {
    var ny = try newYork();
    defer ny.free();
    const rel = (try at(&ny, dt(2024, 3, 9, 12, 0, 0))).relativeTo();
    try expectSpan(.{ .days = 1, .hours = 1 }, try span(.{ .hours = 24 }).round(.{ .largest = .day, .relative_to = rel }));
    try expectSpan(.{ .hours = 23 }, try span(.{ .days = 1 }).round(.{ .largest = .hour, .relative_to = rel }));
    try expectSpan(.{ .days = 1 }, try span(.{ .hours = 23 }).round(.{ .largest = .day, .relative_to = rel }));
    try testing.expectEqual(.lt, try Span.compare(span(.{ .days = 1 }), span(.{ .hours = 24 }), rel));
    try testing.expectEqual(.eq, try Span.compare(span(.{ .days = 1 }), span(.{ .hours = 23 }), rel));
    try testing.expectEqual(.gt, try Span.compare(span(.{ .days = 1 }), span(.{ .hours = 24 }), (try at(&ny, dt(2024, 11, 2, 12, 0, 0))).relativeTo()));
}

/// Every offset the zone ever uses.
fn offsetsOf(zone: *const TimeZone, out: *std.ArrayList(i32)) !void {
    try out.append(testing.allocator, zone.initial.offset.seconds.raw());
    for (zone.types) |t| try out.append(testing.allocator, t.offset.seconds.raw());
    if (zone.footer) |f| {
        try out.append(testing.allocator, f.std.offset.seconds.raw());
        if (f.dst) |d| try out.append(testing.allocator, d.local.offset.seconds.raw());
    }
}

fn anyWallClock(_: void, case: *shakedown.Case) !void {
    const files = [_][]const u8{ zoneinfo.America_New_York, zoneinfo.Europe_Lisbon, zoneinfo.Australia_Lord_Howe, zoneinfo.Pacific_Apia };
    var zone = try TimeZone.fromTzif(testing.allocator, Untrusted.init(files[shakedown.gen.intRange(case.source, usize, 0, files.len - 1)]), null);
    defer zone.free();
    // Near a transition most of the time, where gaps and folds are.
    var base = shakedown.gen.intRange(case.source, i64, -3_000_000_000, 4_000_000_000);
    if (shakedown.gen.intRange(case.source, u8, 0, 3) != 0) {
        if (zone.nextChange(@as(i128, base) * ns_per_s)) |t| base = t;
    }
    const local: i128 = (@as(i128, base) + shakedown.gen.intRange(case.source, i64, -10_000, 10_000)) * ns_per_s;
    var offsets: std.ArrayList(i32) = .empty;
    defer offsets.deinit(testing.allocator);
    try offsetsOf(&zone, &offsets);
    // Brute force: each offset the zone uses, kept where it is the offset in force there.
    var brute: std.ArrayList(i128) = .empty;
    defer brute.deinit(testing.allocator);
    for (offsets.items, 0..) |o, i| {
        if (std.mem.findScalar(i32, offsets.items[0..i], o) != null) continue;
        const candidate = local - @as(i128, o) * ns_per_s;
        if (zone.offsetAtNanoseconds(candidate) == o) try brute.append(testing.allocator, candidate);
    }
    std.mem.sort(i128, brute.items, {}, std.sort.asc(i128));
    const c = zone.candidatesAt(local);
    try testing.expectEqual(brute.items.len, c.count);
    try testing.expectEqualSlices(i128, brute.items, c.slice());
    // `compatible` is the first candidate, or in a gap the wall clock at the offset before it.
    const want = if (brute.items.len > 0) brute.items[0] else local - @as(i128, zone.offsetAtNanoseconds(local - std.time.ns_per_day)) * ns_per_s;
    try testing.expectEqual(want, try resolve.resolveWallClock(&zone, local, .compatible));
}

test "property: resolution agrees with a brute-force search of the zone's offsets" {
    try shakedown.check(testing.allocator, {}, anyWallClock, .{ .cases = 2000, .seed = 0x2d1 });
}
