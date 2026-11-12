//! Zones: POSIX TZ strings parsed and evaluated (both hemispheres, rule times past 24 hours,
//! daylight saving all year), TZif files of the IANA database read (testdata/zoneinfo, compiled by
//! zic from tzdata 2026f, public domain) and checked against zdump's account of them, transitions
//! that change only an abbreviation passed over, fixed offsets, the cursor, and the reader and the
//! rules on arbitrary bytes.
const std = @import("std");
const aegis = @import("aegis");
const shakedown = @import("shakedown");
const almanac = @import("almanac.zig");
const posix = @import("zone/posix.zig");
const tzif = @import("zone/tzif.zig");
const TimeZone = almanac.TimeZone;
const Timestamp = almanac.Timestamp;
const testing = std.testing;
const Untrusted = aegis.input.Untrusted([]const u8);

const zoneinfo = @import("zoneinfo");
const new_york = zoneinfo.America_New_York;
const lisbon = zoneinfo.Europe_Lisbon;
const lord_howe = zoneinfo.Australia_Lord_Howe;
const apia = zoneinfo.Pacific_Apia;
const files = [_][]const u8{ new_york, lisbon, lord_howe, apia };

/// An instant at a UTC civil time.
fn utc(y: i16, mo: u8, d: u8, h: u8, mi: u8, s: u8) Timestamp {
    const dt: almanac.DateTime = .{ .date = almanac.Date.init(y, mo, d) catch unreachable, .time = almanac.Time.init(h, mi, s, 0) catch unreachable };
    return almanac.instant.fromDateTime(dt, .utc) catch unreachable;
}

fn later(t: Timestamp, seconds: i96) Timestamp {
    return .fromRaw(t.raw() + seconds * std.time.ns_per_s);
}

fn expectInfo(zone: *const TimeZone, at: Timestamp, offset: i32, dst: bool, abbreviation: []const u8) !void {
    const i = try zone.infoAt(at);
    errdefer std.debug.print("at {d}: {d} {} {s}\n", .{ at.raw(), i.offset.seconds.raw(), i.dst, i.abbreviation });
    try testing.expectEqual(offset, i.offset.seconds.raw());
    try testing.expectEqual(dst, i.dst);
    try testing.expectEqualStrings(abbreviation, i.abbreviation);
}

fn zoneOf(text: []const u8) !TimeZone {
    return TimeZone.posix(Untrusted.init(text));
}

test "POSIX strings: what is refused" {
    const refused = [_][]const u8{
        "",                           "EST",                     "EST5EDT",                      "ES5",
        "<AB>5",                      "EST25",                   "EST5EDT,M3.2.0",               "EST5EDT,M13.1.0,M11.1.0",
        "EST5EDT,M3.6.0,M11.1.0",     "EST5EDT,M3.2.7,M11.1.0",  "EST5EDT,J0,J1",                "EST5EDT,366,0",
        "EST5EDT,M3.2.0/168,M11.1.0", "EST5EDT,M3.2.0,M11.1.0x", "EST5:60",                      "<ABCDEFGHIJKLMNOPQ>5",
        "EST5EDT,M3.2.0,M11.1.0,J1",  "EST+5EDT+4,,",            "EST5EDT4,M3.2.0/2:60,M11.1.0", "5EST",
    };
    for (refused) |text| {
        errdefer std.debug.print("accepted {s}\n", .{text});
        try testing.expectError(error.Invalid, zoneOf(text));
    }
}

test "POSIX strings: North America, both edges of each transition" {
    const z = try zoneOf("EST5EDT,M3.2.0,M11.1.0");
    try testing.expectEqual(null, z.name());
    try expectInfo(&z, utc(2024, 3, 10, 6, 59, 59), -18000, false, "EST");
    try expectInfo(&z, utc(2024, 3, 10, 7, 0, 0), -14400, true, "EDT");
    try expectInfo(&z, utc(2024, 11, 3, 5, 59, 59), -14400, true, "EDT");
    try expectInfo(&z, utc(2024, 11, 3, 6, 0, 0), -18000, false, "EST");
    const next = (try z.nextTransition(utc(2024, 1, 1, 0, 0, 0))).?;
    try testing.expectEqual(utc(2024, 3, 10, 7, 0, 0), next.at);
    try testing.expectEqualStrings("EDT", next.info.abbreviation);
    try testing.expectEqual(utc(2024, 11, 3, 6, 0, 0), (try z.nextTransition(next.at)).?.at);
    try testing.expectEqual(utc(2024, 3, 10, 7, 0, 0), (try z.previousTransition(utc(2024, 6, 1, 0, 0, 0))).?.at);
    // Strictly before and after: at a transition, the previous is the one before it.
    try testing.expectEqual(utc(2023, 11, 5, 6, 0, 0), (try z.previousTransition(next.at)).?.at);
    try testing.expectEqual(utc(2024, 3, 10, 7, 0, 0), (try z.previousTransition(Timestamp.fromRaw(next.at.raw() + 1))).?.at);
    // Far years, where the rule alone governs.
    try expectInfo(&z, utc(9999, 7, 1, 0, 0, 0), -14400, true, "EDT");
    try expectInfo(&z, utc(-9999, 7, 1, 0, 0, 0), -14400, true, "EDT");
    try testing.expectEqual(null, try z.nextTransition(almanac.instant.max));
}

test "POSIX strings: the south, quoted names, half hours, times past 24 hours" {
    const howe = try zoneOf("<+1030>-10:30<+11>-11,M10.1.0,M4.1.0");
    try expectInfo(&howe, utc(2024, 1, 15, 0, 0, 0), 39600, true, "+11");
    try expectInfo(&howe, utc(2024, 4, 6, 14, 59, 59), 39600, true, "+11");
    try expectInfo(&howe, utc(2024, 4, 6, 15, 0, 0), 37800, false, "+1030");
    try expectInfo(&howe, utc(2024, 10, 5, 15, 30, 0), 39600, true, "+11");
    try testing.expectEqual(utc(2024, 10, 5, 15, 30, 0), (try howe.nextTransition(utc(2024, 6, 1, 0, 0, 0))).?.at);
    // Israel: the Friday before the last Sunday, as Thursday at 26:00.
    const israel = try zoneOf("IST-2IDT,M3.4.4/26,M10.5.0");
    try expectInfo(&israel, utc(2024, 3, 28, 23, 59, 59), 7200, false, "IST");
    try expectInfo(&israel, utc(2024, 3, 29, 0, 0, 0), 10800, true, "IDT");
    try expectInfo(&israel, utc(2024, 10, 26, 23, 0, 0), 7200, false, "IST");
    // Greenland: a negative rule time.
    const nuuk = try zoneOf("<-02>2<-01>,M3.5.0/-1,M10.5.0/0");
    // The last Sunday of March 2024 is the 31st; an hour before its midnight, in -02, is 01:00Z.
    try expectInfo(&nuuk, utc(2024, 3, 31, 0, 59, 59), -7200, false, "-02");
    try expectInfo(&nuuk, utc(2024, 3, 31, 1, 0, 0), -3600, true, "-01");
    // Julian days never count February 29; zero-based days do.
    const j = try zoneOf("AAA0BBB,J60/0,J61/0");
    try expectInfo(&j, utc(2024, 3, 1, 0, 0, 0), 3600, true, "BBB");
    try expectInfo(&j, utc(2024, 2, 29, 23, 59, 59), 0, false, "AAA");
    const z = try zoneOf("AAA0BBB,59/0,60/0");
    try expectInfo(&z, utc(2024, 2, 29, 0, 0, 0), 3600, true, "BBB");
    try expectInfo(&z, utc(2023, 3, 1, 0, 0, 0), 3600, true, "BBB");
}

test "POSIX strings: daylight saving all year, and no daylight saving" {
    const always = try zoneOf("EST5EDT,0/0,J365/25");
    for ([_]Timestamp{ utc(2024, 1, 1, 0, 0, 0), utc(2024, 1, 1, 5, 0, 0), utc(2024, 7, 1, 0, 0, 0), utc(2023, 12, 31, 23, 59, 59) }) |t|
        try expectInfo(&always, t, -14400, true, "EDT");
    try testing.expectEqual(null, try always.nextTransition(utc(2024, 1, 1, 0, 0, 0)));
    try testing.expectEqual(null, try always.previousTransition(utc(2024, 1, 1, 0, 0, 0)));
    const plain = try zoneOf("<-03>3");
    try expectInfo(&plain, utc(2024, 7, 1, 0, 0, 0), -10800, false, "-03");
    try testing.expectEqual(null, try plain.nextTransition(utc(2024, 7, 1, 0, 0, 0)));
}

test "fixed offsets and UTC" {
    try expectInfo(&TimeZone.utc, utc(2024, 7, 1, 0, 0, 0), 0, false, "UTC");
    const india = TimeZone.fixed(try almanac.Offset.init(19800));
    try expectInfo(&india, utc(2024, 7, 1, 0, 0, 0), 19800, false, "+05:30");
    const odd = TimeZone.fixed(try almanac.Offset.init(-30));
    try expectInfo(&odd, utc(2024, 7, 1, 0, 0, 0), -30, false, "-00:00:30");
    try testing.expectEqual(null, try india.nextTransition(utc(2024, 7, 1, 0, 0, 0)));
}

test "TZif: New York from local mean time to the rule past the table" {
    var z = try TimeZone.fromTzif(testing.allocator, Untrusted.init(new_york), "America/New_York");
    defer z.free();
    try testing.expectEqualStrings("America/New_York", z.name().?);
    try expectInfo(&z, utc(1883, 11, 18, 16, 59, 59), -17762, false, "LMT");
    try expectInfo(&z, utc(1883, 11, 18, 17, 0, 0), -18000, false, "EST");
    try expectInfo(&z, utc(2024, 3, 10, 6, 59, 59), -18000, false, "EST");
    try expectInfo(&z, utc(2024, 3, 10, 7, 0, 0), -14400, true, "EDT");
    try expectInfo(&z, utc(2024, 11, 3, 6, 0, 0), -18000, false, "EST");
    try expectInfo(&z, utc(2100, 7, 1, 0, 0, 0), -14400, true, "EDT");
    try expectInfo(&z, utc(-9999, 1, 1, 0, 0, 0), -17762, false, "LMT");
    try testing.expectEqual(utc(1883, 11, 18, 17, 0, 0), (try z.nextTransition(utc(1800, 1, 1, 0, 0, 0))).?.at);
    try testing.expectEqual(utc(2024, 3, 10, 7, 0, 0), (try z.nextTransition(utc(2024, 1, 1, 0, 0, 0))).?.at);
    try testing.expectEqual(utc(2100, 3, 14, 7, 0, 0), (try z.nextTransition(utc(2100, 1, 1, 0, 0, 0))).?.at);
    try testing.expectEqual(utc(2099, 11, 1, 6, 0, 0), (try z.previousTransition(utc(2100, 1, 1, 0, 0, 0))).?.at);
    try testing.expectEqual(null, try z.previousTransition(utc(1883, 11, 18, 17, 0, 0)));
}

test "TZif: Lisbon's years on Central European time, where only the name changed" {
    var z = try TimeZone.fromTzif(testing.allocator, Untrusted.init(lisbon), null);
    defer z.free();
    try expectInfo(&z, utc(1992, 9, 27, 0, 59, 59), 3600, true, "WEST");
    try expectInfo(&z, utc(1992, 9, 27, 1, 0, 0), 3600, false, "CET");
    try expectInfo(&z, utc(1993, 7, 1, 0, 0, 0), 7200, true, "CEST");
    try expectInfo(&z, utc(1996, 3, 31, 1, 0, 0), 3600, true, "WEST");
    try expectInfo(&z, utc(1996, 10, 27, 1, 0, 0), 0, false, "WET");
    // WEST to CET keeps the offset: no transition, as Temporal counts them.
    try testing.expectEqual(utc(1993, 3, 28, 1, 0, 0), (try z.nextTransition(utc(1992, 9, 1, 0, 0, 0))).?.at);
    try testing.expectEqual(utc(1996, 10, 27, 1, 0, 0), (try z.nextTransition(utc(1995, 9, 24, 1, 0, 0))).?.at);
    try testing.expectEqual(utc(1992, 3, 29, 1, 0, 0), (try z.previousTransition(utc(1993, 3, 28, 1, 0, 0))).?.at);
}

test "TZif: Lord Howe's half hour, and Apia's lost day" {
    var howe = try TimeZone.fromTzif(testing.allocator, Untrusted.init(lord_howe), null);
    defer howe.free();
    try expectInfo(&howe, utc(2024, 4, 6, 14, 59, 59), 39600, true, "+11");
    try expectInfo(&howe, utc(2024, 4, 6, 15, 0, 0), 37800, false, "+1030");
    try expectInfo(&howe, utc(2024, 10, 5, 15, 30, 0), 39600, true, "+11");
    var samoa = try TimeZone.fromTzif(testing.allocator, Untrusted.init(apia), null);
    defer samoa.free();
    try expectInfo(&samoa, utc(2011, 12, 30, 9, 59, 59), -36000, true, "-10");
    try expectInfo(&samoa, utc(2011, 12, 30, 10, 0, 0), 50400, true, "+14");
    try expectInfo(&samoa, utc(2021, 4, 3, 14, 0, 0), 46800, false, "+13");
    try expectInfo(&samoa, utc(2200, 1, 1, 0, 0, 0), 46800, false, "+13");
    try testing.expectEqual(utc(2011, 12, 30, 10, 0, 0), (try samoa.nextTransition(utc(2011, 10, 1, 0, 0, 0))).?.at);
    try testing.expectEqual(null, try samoa.nextTransition(utc(2022, 1, 1, 0, 0, 0)));
}

test "TZif: what the reader refuses" {
    const gpa = testing.allocator;
    try testing.expectError(error.Corrupt, tzif.parse(gpa, ""));
    try testing.expectError(error.Corrupt, tzif.parse(gpa, "TZif"));
    try testing.expectError(error.Corrupt, tzif.parse(gpa, new_york[0 .. new_york.len - 1]));
    var extra: [new_york.len + 1]u8 = undefined;
    @memcpy(extra[0..new_york.len], new_york);
    extra[new_york.len] = 'x';
    try testing.expectError(error.Corrupt, tzif.parse(gpa, &extra));
    // A version byte past 4.
    var v5 = new_york.*;
    v5[4] = '5';
    try testing.expectError(error.Corrupt, tzif.parse(gpa, &v5));
    // A leap second table in the first header only: the block it describes no longer fits.
    var leap = new_york.*;
    std.mem.writeInt(u32, leap[28..32], 1, .big);
    try testing.expectError(error.Corrupt, tzif.parse(gpa, &leap));
    try testing.expectError(error.LeapSeconds, tzif.parse(gpa, leapSecondFile()));
}

/// A version 1 file of one type and one leap second.
fn leapSecondFile() []const u8 {
    const zeros: [16]u8 = @splat(0);
    const file = "TZif" ++ zeros ++
        // isutcnt, isstdcnt, leapcnt, timecnt, typecnt, charcnt
        [_]u8{ 0, 0, 0, 0 } ++ [_]u8{ 0, 0, 0, 0 } ++ [_]u8{ 0, 0, 0, 1 } ++ [_]u8{ 0, 0, 0, 0 } ++ [_]u8{ 0, 0, 0, 1 } ++ [_]u8{ 0, 0, 0, 4 } ++
        // one type: offset 0, not daylight saving, abbreviation at 0; "UTC\0"; one leap second record
        [_]u8{ 0, 0, 0, 0, 0, 0 } ++ "UTC\x00" ++ [_]u8{ 0x04, 0xb2, 0x6c, 0x00, 0, 0, 0, 1 };
    return file;
}

fn linear(zone: *const TimeZone, seconds: i64) almanac.Offset {
    var current = zone.initial.offset;
    var last: ?i64 = null;
    for (zone.transitions, zone.kinds) |t, k| {
        if (t > seconds) break;
        current = zone.types[k].offset;
        last = t;
    }
    if (zone.footer) |f| {
        if (zone.transitions.len == 0 or (last != null and last.? == zone.transitions[zone.transitions.len - 1] and seconds > last.?))
            return f.at(seconds).offset;
    }
    return current;
}

fn anyLookups(_: void, case: *shakedown.Case) !void {
    const which = shakedown.gen.intRange(case.source, usize, 0, files.len - 1);
    var z = try TimeZone.fromTzif(testing.allocator, Untrusted.init(files[which]), null);
    defer z.free();
    var cursor: TimeZone.Cursor = .{ .index = shakedown.gen.intRange(case.source, usize, 0, 1000) };
    // A run of nearby instants, as a caller with a cursor makes them.
    var seconds = shakedown.gen.intRange(case.source, i64, -4_000_000_000, 5_000_000_000);
    for (0..20) |_| {
        seconds += shakedown.gen.intRange(case.source, i64, -40_000_000, 40_000_000);
        const t: Timestamp = .fromRaw(@as(i96, seconds) * std.time.ns_per_s);
        const offset = try z.offsetAt(t);
        try testing.expectEqual(linear(&z, seconds), offset);
        try testing.expectEqual(offset, try z.offsetAtCursor(&cursor, t));
        // The next and previous transitions change the offset, and nothing between changes it.
        if (try z.nextTransition(t)) |n| {
            try testing.expect(n.at.raw() > t.raw());
            try testing.expect((try z.offsetAt(later(n.at, -1))).seconds.raw() != n.info.offset.seconds.raw());
            try testing.expectEqual(offset, try z.offsetAt(later(n.at, -1)));
        }
        if (try z.previousTransition(t)) |p| {
            try testing.expect(p.at.raw() < t.raw());
            try testing.expectEqual(offset, try z.offsetAt(p.at));
            try testing.expect((try z.offsetAt(later(p.at, -1))).seconds.raw() != offset.seconds.raw());
        }
    }
}

test "property: lookups agree with a linear scan, with any cursor, and transitions bound them" {
    try shakedown.check(testing.allocator, {}, anyLookups, .{ .cases = 400, .seed = 0x7a1 });
}

const rule_examples = [_][]const u8{
    "EST5EDT,M3.2.0,M11.1.0",          "<+1030>-10:30<+11>-11,M10.1.0,M4.1.0", "IST-2IDT,M3.4.4/26,M10.5.0",
    "<-02>2<-01>,M3.5.0/-1,M10.5.0/0", "EST5EDT,0/0,J365/25",                  "AAA0BBB,J60/0,J61/0",
    "WET0WEST,M3.5.0/1,M10.5.0",       "<-03>3",                               "AAA-24:59:59BBB,M1.1.0/-167,M12.5.6/167",
};

fn anyRule(_: void, case: *shakedown.Case) !void {
    var buffer: [64]u8 = undefined;
    const text = shakedown.gen.mutated(case.source, &buffer, &rule_examples);
    const z = zoneOf(text) catch return;
    const seconds = shakedown.gen.intRange(case.source, i64, -300_000_000_000, 250_000_000_000);
    const t: Timestamp = .fromRaw(@as(i96, seconds) * std.time.ns_per_s);
    const offset = try z.offsetAt(t);
    if (try z.nextTransition(t)) |n| {
        try testing.expect(n.at.raw() > t.raw());
        try testing.expectEqual(offset, try z.offsetAt(later(n.at, -1)));
        try testing.expect(n.info.offset.seconds.raw() != offset.seconds.raw());
    }
    if (try z.previousTransition(t)) |p| {
        try testing.expect(p.at.raw() < t.raw());
        try testing.expectEqual(offset, try z.offsetAt(p.at));
    }
}

test "fuzz: TZ strings on mutated rules parse or are refused, and what parses evaluates consistently" {
    try shakedown.check(testing.allocator, {}, anyRule, .{ .cases = 3000, .seed = 0x7a2 });
}

fn anyFile(_: void, case: *shakedown.Case) !void {
    var buffer: [4096]u8 = undefined;
    const bytes = shakedown.gen.mutated(case.source, &buffer, &files);
    var z = TimeZone.fromTzif(testing.allocator, Untrusted.init(bytes), "fuzzed") catch return;
    defer z.free();
    const seconds = shakedown.gen.intRange(case.source, i64, -300_000_000_000, 250_000_000_000);
    const t: Timestamp = .fromRaw(@as(i96, seconds) * std.time.ns_per_s);
    _ = try z.infoAt(t);
    if (try z.nextTransition(t)) |n| try testing.expect(n.at.raw() > t.raw());
    if (try z.previousTransition(t)) |p| try testing.expect(p.at.raw() < t.raw());
}

test "fuzz: the TZif reader on mutated files refuses or reads, and what it reads answers" {
    try shakedown.check(testing.allocator, {}, anyFile, .{ .cases = 3000, .seed = 0x7a3 });
}
