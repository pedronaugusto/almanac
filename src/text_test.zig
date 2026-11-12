//! Text: Temporal's reading of RFC 3339 and RFC 9557 (forms, annotations, refusals), ISO 8601
//! durations, writing and reading back, the strict RFC 3339 checks against JSON-Schema-Test-Suite's
//! format cases (testdata/json-schema, release 23.2.0), the strict grammar within the lenient one,
//! and every parser on mutated text.
const std = @import("std");
const aegis = @import("aegis");
const shakedown = @import("shakedown");
const almanac = @import("almanac.zig");
const json_schema = @import("json_schema");
const text = almanac.text;
const strict = text.strict;
const Span = almanac.Span;
const Date = almanac.Date;
const DateTime = almanac.DateTime;
const Timestamp = almanac.Timestamp;
const testing = std.testing;
const Untrusted = aegis.input.Untrusted([]const u8);

fn u(s: []const u8) Untrusted {
    return .init(s);
}

fn utc(y: i16, mo: u8, d: u8, h: u8, mi: u8, s: u8, ns: u32) Timestamp {
    const dt: DateTime = .{ .date = Date.init(y, mo, d) catch unreachable, .time = almanac.Time.init(h, mi, s, ns) catch unreachable };
    return almanac.instant.fromDateTime(dt, .utc) catch unreachable;
}

fn written(value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try value.format(&out.writer);
    return out.toOwnedSlice();
}

fn expectWritten(want: []const u8, value: anytype) !void {
    const got = try written(value);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "instants: RFC 3339 and Temporal's wider reading" {
    const want = utc(2026, 10, 31, 9, 0, 0, 0);
    for ([_][]const u8{
        "2026-10-31T09:00:00Z",               "2026-10-31t09:00:00z",              "2026-10-31 09:00:00Z",
        "2026-10-31T10:00:00+01:00",          "2026-10-31T10:00+01",               "20261031T090000Z",
        "2026-10-31T09:00Z",                  "2026-10-31T09Z",                    "2026-10-31T04:00:00-05:00[America/New_York]",
        "2026-10-31T09:00:00Z[u-ca=iso8601]", "2026-10-31T09:00:00Z[foo=bar-baz]", "+002026-10-31T09:00:00Z",
        "2026-10-31T08:00:00\u{2212}01:00",
    }) |s| {
        errdefer std.debug.print("{s}\n", .{s});
        try testing.expectEqual(want, try text.parseTimestamp(u(s), .{}));
    }
    try testing.expectEqual(utc(2026, 10, 31, 9, 0, 0, 123_000_000), try text.parseTimestamp(u("2026-10-31T09:00:00,123Z"), .{}));
    try testing.expectEqual(utc(2016, 12, 31, 23, 59, 59, 0), try text.parseTimestamp(u("2016-12-31T23:59:60Z"), .{}));
    var diagnostic: text.Diagnostic = .{};
    for ([_][]const u8{
        "2026-10-31T09:00:00",                "2026-10-31",                      "2026-10-31T24:00:00Z",
        "2026-02-29T00:00:00Z",               "2026-10-31T09:00:00.1234567890Z", "2026-10-31T09:00:00Z[!foo=bar]",
        "2026-10-31T09:00:00Z[u-ca=gregory]", "-000000-01-01T00:00:00Z",         "+010000-01-01T00:00:00Z",
        "2026-1031T09:00:00Z",                "2026-10-31T09:00:00+24:00",       "2026-10-31T09:00:00Z[Europe/Lisbon][America/New_York]",
        "2026-10-31T09:00:00Z ",              "",                                "2026-10-31T09:00:00+01:00:00.5",
    }) |s| {
        errdefer std.debug.print("accepted {s}\n", .{s});
        try testing.expectError(error.Invalid, text.parseTimestamp(u(s), .{ .diagnostic = &diagnostic }));
    }
    try testing.expectError(error.Invalid, text.parseTimestamp(u("2026-10-31T09:00:00Z[foo=bar]"), .{ .unknown_annotations = .refuse }));
    _ = try text.parseTimestamp(u("2026-10-31T09:00:00Z[foo=bar]"), .{ .unknown_annotations = .ignore });
    // The diagnostic says where.
    try testing.expectError(error.Invalid, text.parseTimestamp(u("2026-13-01T00:00:00Z"), .{ .diagnostic = &diagnostic }));
    try testing.expectEqual(10, diagnostic.offset);
}

test "dates, times, date-times: the civil forms" {
    try testing.expect((try text.parseDate(u("2026-10-31"), .{})).eql(try Date.init(2026, 10, 31)));
    try testing.expect((try text.parseDate(u("20261031"), .{})).eql(try Date.init(2026, 10, 31)));
    try testing.expect((try text.parseDate(u("2026-10-31T09:00+01:00[Europe/Lisbon]"), .{})).eql(try Date.init(2026, 10, 31)));
    try testing.expect((try text.parseDate(u("-009999-01-01"), .{})).eql(try Date.init(-9999, 1, 1)));
    try testing.expectError(error.Invalid, text.parseDate(u("2026-10-31T09:00Z"), .{}));
    const dt = try text.parseDateTime(u("2026-10-31T09:30:15.5"), .{});
    try testing.expect(dt.eql(.{ .date = try Date.init(2026, 10, 31), .time = try almanac.Time.init(9, 30, 15, 500_000_000) }));
    try testing.expect((try text.parseDateTime(u("2026-10-31"), .{})).eql(.{ .date = try Date.init(2026, 10, 31) }));
    try testing.expectEqual(try almanac.Time.init(9, 30, 0, 0), try text.parseTime(u("09:30"), .{}));
    try testing.expectEqual(try almanac.Time.init(9, 30, 15, 0), try text.parseTime(u("T093015"), .{}));
    try testing.expectEqual(try almanac.Time.init(9, 30, 0, 0), try text.parseTime(u("2026-10-31T09:30"), .{}));
    try testing.expectError(error.Invalid, text.parseTime(u("0930"), .{}));
    try testing.expectError(error.Invalid, text.parseTime(u("09:30Z"), .{}));
}

test "durations: Temporal's reading" {
    const cases = [_]struct { []const u8, Span.Signed }{
        .{ "P1Y2M3W4DT5H6M7.008009010S", .{ .years = 1, .months = 2, .weeks = 3, .days = 4, .hours = 5, .minutes = 6, .seconds = 7, .milliseconds = 8, .microseconds = 9, .nanoseconds = 10 } },
        .{ "-PT1H", .{ .hours = -1 } },
        .{ "PT1.5H", .{ .hours = 1, .minutes = 30 } },
        .{ "PT0.5M", .{ .seconds = 30 } },
        .{ "pt1,25s", .{ .seconds = 1, .milliseconds = 250 } },
        .{ "P1Y2D", .{ .years = 1, .days = 2 } },
        .{ "+P1D", .{ .days = 1 } },
        .{ "PT0S", .{} },
        .{ "\u{2212}P2W", .{ .weeks = -2 } },
    };
    for (cases) |c| {
        errdefer std.debug.print("{s}\n", .{c[0]});
        try testing.expect((try text.parseSpan(u(c[0]), .{})).eql(try Span.fromSigned(c[1])));
    }
    for ([_][]const u8{ "P", "PT", "P1H", "PT1D", "P1.5D", "PT1.5H1M", "P1D2Y", "1D", "P-1D", "P4294967296Y", "PT9007199254740992S", "P1DT" }) |s| {
        errdefer std.debug.print("accepted {s}\n", .{s});
        try testing.expectError(error.Invalid, text.parseSpan(u(s), .{}));
    }
}

test "zoned text: the zone, the offset weighed, the day's start" {
    const io = testing.io;
    var db = almanac.Database.init(testing.allocator, .{ .source = .embedded });
    defer db.deinit();
    var a = try text.parseZoned(&db, io, u("2024-11-03T01:30:00-05:00[America/New_York]"), .{});
    defer a.release();
    try testing.expectEqual(utc(2024, 11, 3, 6, 30, 0, 0), a.zoned.timestamp);
    // Without an offset, the fold resolves `compatible`: the first.
    var b = try text.parseZoned(&db, io, u("2024-11-03T01:30:00[America/New_York]"), .{});
    defer b.release();
    try testing.expectEqual(utc(2024, 11, 3, 5, 30, 0, 0), b.zoned.timestamp);
    try testing.expectError(error.OffsetConflict, text.parseZoned(&db, io, u("2024-07-01T12:00:00+01:00[America/New_York]"), .{}));
    var c = try text.parseZoned(&db, io, u("2024-07-01T12:00:00+01:00[America/New_York]"), .{ .offset = .use });
    defer c.release();
    try testing.expectEqual(utc(2024, 7, 1, 11, 0, 0, 0), c.zoned.timestamp);
    var d = try text.parseZoned(&db, io, u("2024-07-01T12:00:00Z[America/New_York]"), .{});
    defer d.release();
    try testing.expectEqual(utc(2024, 7, 1, 12, 0, 0, 0), d.zoned.timestamp);
    var e = try text.parseZoned(&db, io, u("2024-07-01[+05:30]"), .{});
    defer e.release();
    try testing.expectEqual(utc(2024, 6, 30, 18, 30, 0, 0), e.zoned.timestamp);
    // Lisbon's local mean time written to the minute matches its -0:36:45.
    var f = try text.parseZoned(&db, io, u("1900-01-01T00:00:00-00:37[Europe/Lisbon]"), .{});
    defer f.release();
    try testing.expectEqual(utc(1900, 1, 1, 0, 36, 45, 0), f.zoned.timestamp);
    try testing.expectError(error.Invalid, text.parseZoned(&db, io, u("2024-07-01T12:00:00Z"), .{}));
    try testing.expectError(error.ZoneNotFound, text.parseZoned(&db, io, u("2024-07-01T12:00:00Z[Mars/Olympus]"), .{}));
    try expectWritten("2024-11-03T01:30:00-05:00[America/New_York]", a.zoned);
    try expectWritten("2024-07-01T00:00:00+05:30[+05:30]", e.zoned);
    try expectWritten("1900-01-01T00:00:00-00:37[Europe/Lisbon]", f.zoned);
}

test "writing, and reading back what is written" {
    try expectWritten("2026-10-31", try Date.init(2026, 10, 31));
    try expectWritten("-009999-01-01", try Date.init(-9999, 1, 1));
    try expectWritten("0000-01-01", try Date.init(0, 1, 1));
    try expectWritten("09:00:00.25", try almanac.Time.init(9, 0, 0, 250_000_000));
    try expectWritten("P1Y2M3W4DT5H6M7.00800901S", try Span.fromSigned(.{ .years = 1, .months = 2, .weeks = 3, .days = 4, .hours = 5, .minutes = 6, .seconds = 7, .milliseconds = 8, .microseconds = 9, .nanoseconds = 10 }));
    try expectWritten("PT0S", Span.zero);
    try expectWritten("P1D", try Span.fromSigned(.{ .days = 1 }));
    try expectWritten("-PT1.5S", try Span.fromSigned(.{ .seconds = -1, .milliseconds = -500 }));
    try expectWritten("PT90M", try Span.fromSigned(.{ .minutes = 90 }));
    var buffer: [text.timestamp_len]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try text.writeTimestamp(&w, utc(2026, 10, 31, 9, 0, 0, 5), null);
    try testing.expectEqualStrings("2026-10-31T09:00:00.000000005Z", w.buffered());
    w = .fixed(&buffer);
    try text.writeTimestamp(&w, utc(2026, 10, 31, 9, 0, 0, 0), try almanac.Offset.init(-12_600));
    try testing.expectEqualStrings("2026-10-31T05:30:00-03:30", w.buffered());
}

const Case = struct { description: []const u8, data: std.json.Value, valid: bool };
const Group = struct { description: []const u8, schema: std.json.Value, tests: []const Case };

fn suite(bytes: []const u8, check: *const fn ([]const u8) bool) !usize {
    const parsed = try std.json.parseFromSlice([]const Group, testing.allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var count: usize = 0;
    for (parsed.value) |group| for (group.tests) |case| {
        // A format asserts nothing of a value that is no string.
        if (case.data != .string) continue;
        if (check(case.data.string) != case.valid) {
            std.debug.print("{s}: \"{s}\" should be {s}\n", .{ case.description, case.data.string, if (case.valid) "valid" else "invalid" });
            return error.TestUnexpectedResult;
        }
        count += 1;
    };
    return count;
}

test "the strict checks against JSON-Schema-Test-Suite's format cases" {
    try testing.expectEqualStrings("23.2.0\n", json_schema.version);
    const n = try suite(json_schema.@"date-time", strict.isDateTime) + try suite(json_schema.date, strict.isDate) +
        try suite(json_schema.time, strict.isTime) + try suite(json_schema.duration, strict.isDuration);
    try testing.expect(n > 100);
    // RFC 3339's own: a leap second only at 23:59:60 UTC, case-insensitive literals, no space.
    try testing.expect(strict.isDateTime("1998-12-31T23:59:60Z") and strict.isDateTime("1998-12-31T15:59:60-08:00"));
    try testing.expect(!strict.isDateTime("1998-12-31T23:58:60Z") and !strict.isDateTime("1998-12-31 23:59:59Z"));
    try testing.expect(strict.isDateTime("1998-12-31t23:59:59.123456789012z"));
    try testing.expect(strict.isDuration("p1y2m3dt4h5m6s") and !strict.isDuration("P1Y2D") and !strict.isDuration("P1.5D"));
}

fn anyStrictText(_: void, case: *shakedown.Case) !void {
    const g = shakedown.gen;
    var buffer: [96]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    // A date-time RFC 3339 allows, written by its grammar, and its value.
    const days = g.intRange(case.source, i32, -719_528, 2_932_896); // years 0000 to 9999
    const date = try Date.fromDays(days);
    var hour = g.intRange(case.source, u8, 0, 23);
    var minute = g.intRange(case.source, u8, 0, 59);
    var second = g.intRange(case.source, u8, 0, 59);
    const digits = g.intRange(case.source, u8, 0, 9);
    const offset_minutes: i32 = if (g.boolean(case.source)) 0 else g.intRange(case.source, i32, -1439, 1439);
    const leap = g.intRange(case.source, u8, 0, 7) == 0;
    if (leap) {
        // 23:59 in UTC, at the offset.
        const local = @mod(23 * 60 + 59 + offset_minutes, 1440);
        hour = @intCast(@divTrunc(local, 60));
        minute = @intCast(@mod(local, 60));
        second = 60;
    }
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}{c}{d:0>2}:{d:0>2}:{d:0>2}", .{ @as(u16, @intCast(date.year.raw())), date.month.raw(), date.day.raw(), g.oneOf(case.source, u8, "Tt"), hour, minute, second });
    var ns: u32 = 0;
    if (digits > 0) {
        try w.writeByte('.');
        for (0..digits) |k| {
            const d = g.intRange(case.source, u8, 0, 9);
            try w.writeByte('0' + d);
            ns += @as(u32, d) * std.math.pow(u32, 10, @intCast(8 - k));
        }
    }
    if (offset_minutes == 0 and g.boolean(case.source)) try w.writeByte(g.oneOf(case.source, u8, "Zz")) else {
        const a: u32 = @abs(offset_minutes);
        try w.print("{c}{d:0>2}:{d:0>2}", .{ @as(u8, if (offset_minutes < 0) '-' else '+'), a / 60, a % 60 });
    }
    const s = w.buffered();
    try testing.expect(strict.isDateTime(s));
    // Read leniently to the same instant, a leap second as the second before it.
    const local: almanac.DateTime = .{ .date = date, .time = try almanac.Time.init(hour, minute, @min(second, 59), ns) };
    const want = (try almanac.instant.fromDateTime(local, .utc)).raw() - @as(i96, offset_minutes) * 60 * std.time.ns_per_s;
    const got = text.parseTimestamp(u(s), .{}) catch |err| {
        // Only an instant RFC 3339 can write that almanac's range cannot hold: year 0000 at a
        // positive offset, or 9999 at a negative one, is inside; nothing else is refused.
        if (want < almanac.instant.min.raw() or want > almanac.instant.max.raw()) return;
        return err;
    };
    try testing.expectEqual(want, got.raw());
}

test "property: every date-time the strict check accepts is read leniently to the same instant" {
    try shakedown.check(testing.allocator, {}, anyStrictText, .{ .cases = 3000, .seed = 0x3339 });
}

fn anyStrictDuration(_: void, case: *shakedown.Case) !void {
    const g = shakedown.gen;
    var buffer: [96]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    var f: Span.Fields = .{};
    try w.writeByte('P');
    if (g.intRange(case.source, u8, 0, 5) == 0) {
        f.weeks = g.intRange(case.source, u32, 0, 100_000);
        try w.print("{d}W", .{f.weeks});
    } else {
        // Appendix A's nesting: a date part from Y, M or D, consecutive; a time part from H, M or S.
        const date_from = g.intRange(case.source, u8, 0, 3);
        const date_to = g.intRange(case.source, u8, date_from, 3);
        var k = date_from;
        while (k < date_to) : (k += 1) switch (k) {
            0 => {
                f.years = g.intRange(case.source, u32, 0, 100_000);
                try w.print("{d}Y", .{f.years});
            },
            1 => {
                f.months = g.intRange(case.source, u32, 0, 100_000);
                try w.print("{d}M", .{f.months});
            },
            else => {
                f.days = g.intRange(case.source, u32, 0, 100_000);
                try w.print("{d}D", .{f.days});
            },
        };
        const time_from = g.intRange(case.source, u8, 0, 3);
        const time_to = g.intRange(case.source, u8, time_from, 3);
        if (time_to > time_from or date_to == date_from) {
            const from = if (time_to > time_from) time_from else 2;
            const to = if (time_to > time_from) time_to else 3;
            try w.writeByte(g.oneOf(case.source, u8, "Tt"));
            k = from;
            while (k < to) : (k += 1) switch (k) {
                0 => {
                    f.hours = g.intRange(case.source, u32, 0, 100_000);
                    try w.print("{d}H", .{f.hours});
                },
                1 => {
                    f.minutes = g.intRange(case.source, u32, 0, 100_000);
                    try w.print("{d}M", .{f.minutes});
                },
                else => {
                    f.seconds = g.intRange(case.source, u32, 0, 100_000);
                    try w.print("{d}S", .{f.seconds});
                },
            };
        }
    }
    const s = w.buffered();
    try testing.expect(strict.isDuration(s));
    try testing.expect((try text.parseSpan(u(s), .{})).eql(try Span.init(.positive, f)));
}

test "property: every duration the strict check accepts is read leniently to the same span" {
    try shakedown.check(testing.allocator, {}, anyStrictDuration, .{ .cases = 3000, .seed = 0x3340 });
}

fn anyRoundTrip(_: void, case: *shakedown.Case) !void {
    const g = shakedown.gen;
    const date = try Date.fromDays(g.intRange(case.source, i32, almanac.calendar.min_days, almanac.calendar.max_days));
    const time = try almanac.Time.fromNanosecondOfDay(g.intRange(case.source, u64, 0, almanac.Time.nanoseconds_per_day - 1));
    const dt: DateTime = .{ .date = date, .time = time };
    const s = try written(dt);
    defer testing.allocator.free(s);
    try testing.expect((try text.parseDateTime(u(s), .{})).eql(dt));
    const sign: Span.Sign = if (g.boolean(case.source)) .negative else .positive;
    const span = try Span.init(sign, .{
        .years = g.intRange(case.source, u32, 0, 5000),
        .days = g.intRange(case.source, u64, 0, 5000),
        .hours = g.intRange(case.source, u64, 0, 50),
        .seconds = g.intRange(case.source, u64, 0, 59),
        .nanoseconds = g.intRange(case.source, u64, 0, 999_999_999),
    });
    const t = try written(span);
    defer testing.allocator.free(t);
    // Read back, the same length in each unit once balanced below the second.
    const back = try text.parseSpan(u(t), .{});
    try testing.expectEqual(span.get(.year), back.get(.year));
    try testing.expectEqual(span.get(.day), back.get(.day));
    try testing.expectEqual(span.get(.hour), back.get(.hour));
    try testing.expectEqual(span.get(.second) * std.time.ns_per_s + span.get(.nanosecond), back.get(.second) * std.time.ns_per_s + back.get(.millisecond) * std.time.ns_per_ms + back.get(.microsecond) * std.time.ns_per_us + back.get(.nanosecond));
}

test "property: what is written reads back" {
    try shakedown.check(testing.allocator, {}, anyRoundTrip, .{ .cases = 2000, .seed = 0x3341 });
}

const examples = [_][]const u8{
    "2026-10-31T09:00:00Z", "2026-10-31T09:00:00.123456789+05:30[Asia/Kolkata][u-ca=iso8601]", "20261031T0900-0300",
    "P1Y2M3W4DT5H6M7.5S",   "-PT1.5H",                                                         "1998-12-31T23:59:60Z",
    "2026-10-31",           "T09:30",                                                          "+002026-10-31T09:00Z[!u-ca=iso8601]",
};

fn anyText(_: void, case: *shakedown.Case) !void {
    var buffer: [128]u8 = undefined;
    const s = shakedown.gen.mutated(case.source, &buffer, &examples);
    _ = text.parseTimestamp(u(s), .{}) catch {};
    _ = text.parseDate(u(s), .{}) catch {};
    _ = text.parseDateTime(u(s), .{}) catch {};
    _ = text.parseTime(u(s), .{}) catch {};
    _ = text.parseSpan(u(s), .{}) catch {};
    // The strict grammar within the lenient one, past the lenient reading's two limits: nine
    // fractional digits, and Temporal's bounds on a span.
    if (strict.isDateTime(s)) {
        const dot = std.mem.findScalar(u8, s, '.');
        const short_fraction = if (dot) |d| blk: {
            var e = d + 1;
            while (e < s.len and std.ascii.isDigit(s[e])) e += 1;
            break :blk e - d - 1 <= 9;
        } else true;
        if (short_fraction) _ = try text.parseTimestamp(u(s), .{});
    }
    if (strict.isDate(s)) _ = try text.parseDate(u(s), .{});
    _ = strict.isTime(s);
    if (strict.isDuration(s) and s.len < 12) _ = try text.parseSpan(u(s), .{});
}

test "fuzz: every parser and check on mutated text, the strict grammar within the lenient" {
    try shakedown.check(testing.allocator, {}, anyText, .{ .cases = 5000, .seed = 0x3342 });
}

test "each type publishes the text-form contract: parse, format, max_text_len" {
    inline for (.{ .{ Date, "-009999-01-01" }, .{ almanac.Time, "23:59:59.999999999" }, .{ DateTime, "+009999-12-31T23:59:59.999999999" }, .{ Span, "-P4294967295Y4294967295M4294967295W104249991374DT7H" } }) |c| {
        const T = c[0];
        const value = try T.parse(c[1]);
        var buffer: [T.max_text_len]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buffer);
        try value.format(&w);
        try testing.expect(w.buffered().len <= T.max_text_len);
        const back = try T.parse(w.buffered());
        try testing.expect(back.eql(value));
    }
}
