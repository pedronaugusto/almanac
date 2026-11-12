//! The embedded database: regenerating it from the vendored release (tzdata/) by almanac's own zic
//! compiler reproduces `tzdb.bin` byte for byte; every name in it loads; and its zones agree with
//! zic's compiled output on the offset in force at every transition (and a second before) and at
//! every hour from 1800 to 2100, with the footers' transitions compared to 2400. The four zones
//! in testdata/zoneinfo are compared here; with `-Dzic-out=<directory of zic's output>` every zone
//! there is (a trial: run it in a release build).
const std = @import("std");
const aegis = @import("aegis");
const almanac = @import("almanac.zig");
const zic = @import("zic");
const tzdata = @import("tzdata");
const zoneinfo = @import("zoneinfo");
const embedded = @import("zone/embedded.zig");
const options = @import("almanac_options");
const TimeZone = almanac.TimeZone;
const testing = std.testing;
const Untrusted = aegis.input.Untrusted([]const u8);
const ns_per_s = std.time.ns_per_s;

test "regenerating the embedded database from tzdata/ reproduces it byte for byte" {
    var source: zic.Source = .init(testing.allocator);
    defer source.deinit();
    var diagnostic: zic.Diagnostic = .{};
    inline for (zic.files) |name| {
        source.parse(name, @field(tzdata, name), &diagnostic) catch |err| {
            std.debug.print("{s}:{d}: {s}\n", .{ diagnostic.file, diagnostic.line, @errorName(err) });
            return err;
        };
    }
    const blob = try zic.pack(testing.allocator, &source, std.mem.trim(u8, tzdata.version, " \n"));
    defer testing.allocator.free(blob);
    try testing.expect(std.mem.eql(u8, blob, @embedFile("zone/tzdb.bin")));
    try testing.expectEqualStrings("2026f", embedded.version());
    try testing.expectEqual(source.zones.items.len + source.links.items.len, embedded.count());
}

test "every name in the embedded database loads" {
    var source: zic.Source = .init(testing.allocator);
    defer source.deinit();
    var diagnostic: zic.Diagnostic = .{};
    inline for (zic.files) |name| try source.parse(name, @field(tzdata, name), &diagnostic);
    for (source.zones.items) |z| try loads(z.name);
    for (source.links.items) |l| try loads(l.name);
    try testing.expectEqual(null, embedded.find("Not/A_Zone"));
}

fn loads(name: []const u8) !void {
    errdefer std.debug.print("{s}\n", .{name});
    var z = try TimeZone.fromTzif(testing.allocator, Untrusted.init(embedded.find(name).?), name);
    defer z.free();
    _ = try z.offsetAt(almanac.instant.min);
    _ = try z.offsetAt(almanac.instant.max);
}

const year_seconds: i64 = 31_556_952;
const from_1800: i64 = -5_364_662_400;
const to_2100: i64 = 4_102_444_800;
const to_2400: i64 = 13_569_465_600;

/// Compares two compilations of one zone; the first disagreement is printed.
fn agree(name: []const u8, ours: *const TimeZone, theirs: *const TimeZone) !void {
    // Every transition of either, to 2400, and the second before it.
    for ([_]*const TimeZone{ ours, theirs }) |z| {
        var at: i128 = @as(i128, from_1800) * ns_per_s;
        while (z.nextChange(at)) |t| {
            if (t > to_2400) break;
            for ([_]i64{ t - 1, t }) |s| try same(name, ours, theirs, s);
            at = @as(i128, t) * ns_per_s;
        }
    }
    // Every hour from 1800 to 2100.
    var s = from_1800;
    while (s < to_2100) : (s += 3600) try same(name, ours, theirs, s);
}

fn same(name: []const u8, ours: *const TimeZone, theirs: *const TimeZone, seconds: i64) !void {
    const ns = @as(i128, seconds) * ns_per_s;
    const a = ours.offsetAtNanoseconds(ns);
    const b = theirs.offsetAtNanoseconds(ns);
    if (a != b) {
        std.debug.print("{s} at {d}: almanac {d}, zic {d}\n", .{ name, seconds, a, b });
        return error.TestUnexpectedResult;
    }
}

fn compareOne(name: []const u8, theirs_bytes: []const u8) !void {
    var ours = try TimeZone.fromTzif(testing.allocator, Untrusted.init(embedded.find(name) orelse {
        std.debug.print("{s}: not in the embedded data\n", .{name});
        return error.TestUnexpectedResult;
    }), name);
    defer ours.free();
    var theirs = try TimeZone.fromTzif(testing.allocator, Untrusted.init(theirs_bytes), name);
    defer theirs.free();
    try agree(name, &ours, &theirs);
}

test "the embedded zones agree with zic's (the four vendored)" {
    try compareOne("America/New_York", zoneinfo.America_New_York);
    try compareOne("Europe/Lisbon", zoneinfo.Europe_Lisbon);
    try compareOne("Australia/Lord_Howe", zoneinfo.Australia_Lord_Howe);
    try compareOne("Pacific/Apia", zoneinfo.Pacific_Apia);
}

test "trial: every zone agrees with zic's output in -Dzic-out" {
    const dir_path = options.zic_out orelse return;
    const io = testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();
    var compared: usize = 0;
    var failed: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const bytes = try dir.readFileAlloc(io, entry.path, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(bytes);
        // A zoneinfo directory also holds tables (zone.tab, tzdata.zi, +VERSION) and zic's
        // `posixrules`, which names no zone of the database.
        if (!std.mem.startsWith(u8, bytes, "TZif") or std.mem.eql(u8, entry.path, "posixrules")) continue;
        compareOne(entry.path, bytes) catch {
            failed += 1;
            continue;
        };
        compared += 1;
    }
    std.debug.print("zic comparison: {d} zones agree, {d} disagree\n", .{ compared, failed });
    try testing.expectEqual(0, failed);
}
