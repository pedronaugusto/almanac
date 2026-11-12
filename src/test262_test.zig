//! test262's Temporal string cases (testdata/test262/temporal.json, transcribed as text from
//! test262 by testdata/test262/extract.py: each case with its source path), run through almanac's
//! readers. Every case passes, or is listed in `refused` with the Temporal feature almanac leaves
//! out by design; a listed case that passes fails the test, so the list stays exact.
const std = @import("std");
const aegis = @import("aegis");
const almanac = @import("almanac.zig");
const test262 = @import("test262");
const text = almanac.text;
const testing = std.testing;
const Untrusted = aegis.input.Untrusted([]const u8);

const Expect = union(enum) {
    throws,
    fields: []const i64,
    epoch_ns: []const u8,
};

const Case = struct { path: []const u8, type: []const u8, text: []const u8, expect: std.json.Value };
const File = struct { commit: []const u8, files_read: usize, files_with_cases: usize, cases: []const Case };

/// The cases almanac refuses by design, by source path and text, with the reason.
const Refused = struct { path: []const u8, text: []const u8, why: []const u8 };
const outside = "a year outside -9999 to 9999: almanac's range is jiff's, four-digit RFC 3339 years in an i16; Temporal's reaches -271821 to +275760";
const refused = [_]Refused{
    .{ .path = "test/built-ins/Temporal/PlainDate/from/argument-string.js", .text = "+010583-06-30", .why = outside },
    .{ .path = "test/built-ins/Temporal/PlainDate/from/argument-string.js", .text = "-010583-06-30", .why = outside },
    .{ .path = "test/built-ins/Temporal/PlainDate/from/limits.js", .text = "-271821-04-19", .why = outside },
    .{ .path = "test/built-ins/Temporal/PlainDate/from/limits.js", .text = "+275760-09-13", .why = outside },
    .{ .path = "test/built-ins/Temporal/PlainDateTime/from/limits.js", .text = "-271821-04-19T00:00:00.000000001", .why = outside },
    .{ .path = "test/built-ins/Temporal/PlainDateTime/from/limits.js", .text = "+275760-09-13T23:59:59.999999999", .why = outside },
};

fn isRefused(case: Case) ?[]const u8 {
    for (refused) |r| if (std.mem.eql(u8, r.path, case.path) and std.mem.eql(u8, r.text, case.text)) return r.why;
    return null;
}

/// The fields almanac read, in test262's order for the type; null where it refused the text.
fn read(db: *almanac.Database, case: Case, out: *[10]i64) !?[]const i64 {
    const s = Untrusted.init(case.text);
    const ty = case.type;
    if (std.mem.eql(u8, ty, "PlainDate")) {
        const d = text.parseDate(s, .{}) catch return null;
        out[0..3].* = .{ d.year.raw(), d.month.raw(), d.day.raw() };
        return out[0..3];
    }
    if (std.mem.eql(u8, ty, "PlainTime")) {
        const t = text.parseTime(s, .{}) catch return null;
        const ns = t.nanosecond.raw();
        out[0..6].* = .{ t.hour.raw(), t.minute.raw(), t.second.raw(), ns / 1_000_000, ns / 1000 % 1000, ns % 1000 };
        return out[0..6];
    }
    if (std.mem.eql(u8, ty, "PlainDateTime")) {
        const dt = text.parseDateTime(s, .{}) catch return null;
        const ns = dt.time.nanosecond.raw();
        out[0..9].* = .{ dt.date.year.raw(), dt.date.month.raw(), dt.date.day.raw(), dt.time.hour.raw(), dt.time.minute.raw(), dt.time.second.raw(), ns / 1_000_000, ns / 1000 % 1000, ns % 1000 };
        return out[0..9];
    }
    if (std.mem.eql(u8, ty, "Duration")) {
        const span = text.parseSpan(s, .{}) catch return null;
        for (std.enums.values(almanac.Unit), 0..) |unit, i| out[i] = @intCast(span.get(unit));
        return out[0..10];
    }
    if (std.mem.eql(u8, ty, "Instant")) {
        const t = text.parseTimestamp(s, .{}) catch return null;
        out[0] = 0;
        // Compared as text by the caller: the nanoseconds may pass an i64.
        instant_ns = t.raw();
        return out[0..1];
    }
    if (std.mem.eql(u8, ty, "ZonedDateTime")) {
        var p = text.parseZoned(db, testing.io, s, .{}) catch return null;
        p.release();
        return out[0..0];
    }
    unreachable;
}

var instant_ns: i96 = 0;

test "test262's Temporal string cases: each passes or is refused by design" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const file = try std.json.parseFromSliceLeaky(File, state.allocator(), test262.temporal, .{});
    try testing.expectEqualStrings("2e58f87", file.commit);
    var db = almanac.Database.init(testing.allocator, .{ .source = .embedded });
    defer db.deinit();
    var passed: usize = 0;
    var listed: usize = 0;
    var failed: usize = 0;
    for (file.cases) |case| {
        var buffer: [10]i64 = undefined;
        const got = try read(&db, case, &buffer);
        const ok = switch (case.expect) {
            .string => got == null,
            .object => |o| blk: {
                const g = got orelse break :blk false;
                if (o.get("epoch_ns")) |want| {
                    var digits: [40]u8 = undefined;
                    break :blk std.mem.eql(u8, want.string, std.fmt.bufPrint(&digits, "{d}", .{instant_ns}) catch unreachable);
                }
                const want = o.get("fields").?.array.items;
                if (want.len != g.len) break :blk false;
                for (want, g) |w, x| if (w.integer != x) break :blk false;
                break :blk true;
            },
            else => unreachable,
        };
        if (isRefused(case)) |_| {
            if (ok) {
                std.debug.print("listed as refused but passes: {s} \"{s}\"\n", .{ case.path, case.text });
                failed += 1;
            } else listed += 1;
            continue;
        }
        if (ok) {
            passed += 1;
        } else {
            failed += 1;
            std.debug.print("test262 {s} \"{s}\": {s}, almanac {any}\n", .{ case.path, case.text, if (case.expect == .string) "throws" else "a value", got });
        }
    }
    std.debug.print("test262 Temporal strings: {d} pass, {d} refused by design, {d} fail, of {d} from {d} files\n", .{ passed, listed, failed, file.cases.len, file.files_with_cases });
    try testing.expectEqual(0, failed);
}
