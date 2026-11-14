//! almanac's benchmark rows (design §8), timed: `bench [--smoke] [--json] [<row>...]`. CI only
//! compiles this file; timings are wall-clock on the machine that runs it, and none are claimed
//! from a development machine.
//!
//! - civil/from-days, civil/to-days: a date and its day count;
//! - zoned/from-timestamp/<zone>, zoned/from-datetime/<zone>: in UTC, New York and Lisbon;
//! - parse/rfc3339, format/rfc3339, parse/rfc9557;
//! - span/add-months, span/until-days;
//! - tz/load/<zone>: a zone from the embedded data.
const std = @import("std");
const almanac = @import("almanac");

const Report = struct {
    w: *std.Io.Writer,
    json: bool,
    io: std.Io,

    fn row(r: Report, name: []const u8, ns_per_op: f64) !void {
        if (r.json) {
            try r.w.print("{{\"name\":\"{s}\",\"metric\":\"time\",\"value\":{d:.3},\"unit\":\"ns/op\"}}\n", .{ name, ns_per_op });
        } else {
            try r.w.print("{s:<40} {d:>12.2} ns/op\n", .{ name, ns_per_op });
        }
    }

    fn now(r: Report) std.Io.Timestamp {
        return std.Io.Clock.awake.now(r.io);
    }

    /// Runs `body` `n` times and reports the mean.
    fn time(r: Report, name: []const u8, n: usize, context: anytype, comptime body: anytype) !void {
        const start = r.now();
        var i: usize = 0;
        while (i < n) : (i += 1) try body(context, i);
        const ns: f64 = @floatFromInt(start.durationTo(r.now()).nanoseconds);
        try r.row(name, ns / @as(f64, @floatFromInt(n)));
    }
};

var sink: i128 = 0;

fn wanted(selected: []const []const u8, name: []const u8) bool {
    if (selected.len == 0) return true;
    for (selected) |s| if (std.mem.startsWith(u8, name, s)) return true;
    return false;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    var smoke = false;
    var json = false;
    var selected: std.ArrayList([]const u8) = .empty;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--smoke")) smoke = true else if (std.mem.eql(u8, arg, "--json")) json = true else try selected.append(arena.allocator(), arg);
    }
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const r: Report = .{ .w = &stdout.interface, .json = json, .io = init.io };
    const n: usize = if (smoke) 100 else 1_000_000;
    const ran = rows(r, gpa, init.io, selected.items, n);
    const flushed = r.w.flush();
    try ran;
    try flushed;
}

fn rows(r: Report, gpa: std.mem.Allocator, io: std.Io, selected: []const []const u8, n: usize) !void {
    if (wanted(selected, "civil/from-days")) try r.time("civil/from-days", n, {}, struct {
        fn f(_: void, i: usize) !void {
            sink +%= (try almanac.Date.fromDays(@intCast(i % 2_000_000))).day.raw();
        }
    }.f);
    if (wanted(selected, "civil/to-days")) try r.time("civil/to-days", n, {}, struct {
        fn f(_: void, i: usize) !void {
            sink +%= (try almanac.Date.init(@intCast(1900 + i % 200), @intCast(1 + i % 12), @intCast(1 + i % 28))).days();
        }
    }.f);

    var db = almanac.Database.init(gpa, .{ .source = .embedded });
    defer db.deinit();
    for ([_][]const u8{ "UTC", "America/New_York", "Europe/Lisbon" }) |name| {
        var zone = try db.zone(io, .init(name));
        defer zone.release();
        const tz = zone.get();
        var label: [64]u8 = undefined;
        if (wanted(selected, "zoned/from-timestamp")) try r.time(try std.mem.print(&label, "zoned/from-timestamp/{s}", .{name}), n, tz, struct {
            fn f(z: *const almanac.TimeZone, i: usize) !void {
                const t = almanac.Timestamp.fromRaw(@as(i96, @intCast(i)) * 3_600_000_000_000);
                sink +%= (try almanac.Zoned.init(t, z)).dateTime().time.hour.raw();
            }
        }.f);
        if (wanted(selected, "zoned/from-datetime")) try r.time(try std.mem.print(&label, "zoned/from-datetime/{s}", .{name}), n, tz, struct {
            fn f(z: *const almanac.TimeZone, i: usize) !void {
                const dt: almanac.DateTime = .{ .date = try almanac.Date.fromDays(@intCast(i % 20_000)), .time = try almanac.Time.init(@intCast(i % 24), 30, 0, 0) };
                sink +%= (try almanac.Zoned.fromDateTime(dt, z, .compatible)).timestamp.raw();
            }
        }.f);
        if (wanted(selected, "tz/load")) try r.time(try std.mem.print(&label, "tz/load/{s}", .{name}), @max(n / 1000, 1), name, struct {
            fn f(zone_name: []const u8, _: usize) !void {
                var loaded = try almanac.TimeZone.fromTzif(std.heap.page_allocator, .init(almanac.Database.embeddedBytes(zone_name).?), zone_name);
                defer loaded.free();
                sink +%= loaded.transitions.len;
            }
        }.f);
    }

    if (wanted(selected, "parse/rfc3339")) try r.time("parse/rfc3339", n, {}, struct {
        fn f(_: void, _: usize) !void {
            sink +%= (try almanac.text.parseTimestamp(.init("2026-10-31T09:00:00.123456789+01:00"), .{})).raw();
        }
    }.f);
    if (wanted(selected, "format/rfc3339")) try r.time("format/rfc3339", n, {}, struct {
        fn f(_: void, i: usize) !void {
            var buffer: [almanac.text.timestamp_len]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buffer);
            try almanac.text.writeTimestamp(&w, almanac.Timestamp.fromRaw(@as(i96, @intCast(i)) * 1_000_000_007), null);
            sink +%= w.end;
        }
    }.f);
    if (wanted(selected, "parse/rfc9557")) {
        var parse_db = almanac.Database.init(gpa, .{ .source = .embedded });
        defer parse_db.deinit();
        const Context = struct { db: *almanac.Database, io: std.Io };
        try r.time("parse/rfc9557", n, Context{ .db = &parse_db, .io = io }, struct {
            fn f(c: Context, _: usize) !void {
                var p = try almanac.text.parseZoned(c.db, c.io, .init("2026-10-31T09:00:00+00:00[Europe/Lisbon]"), .{});
                defer p.release();
                sink +%= p.zoned.timestamp.raw();
            }
        }.f);
    }
    if (wanted(selected, "span/add-months")) try r.time("span/add-months", n, {}, struct {
        fn f(_: void, i: usize) !void {
            const d = try almanac.Date.init(2024, 1, 31);
            sink +%= (try d.add(try almanac.Span.fromSigned(.{ .months = @intCast(i % 120) }), .constrain)).days();
        }
    }.f);
    if (wanted(selected, "span/until-days")) try r.time("span/until-days", n, {}, struct {
        fn f(_: void, i: usize) !void {
            const a = try almanac.Date.init(2000, 2, 29);
            const b = try almanac.Date.fromDays(@intCast(i % 40_000));
            sink +%= (try a.until(b, .{ .largest = .year })).get(.day);
        }
    }.f);
}
