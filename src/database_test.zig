//! The zone database: names read beneath the caller's zoneinfo directory and nothing else, links
//! followed while they stay beneath it, damaged and oversized files refused, the cache's handles,
//! the local zone from `$TZ` and the `localtime` link, a refresh that frees nothing in use (under
//! a quarantine allocator, where a use after free faults), and every read's failure and cancel
//! under shakedown's FaultIo.
const std = @import("std");
const shakedown = @import("shakedown");
const almanac = @import("almanac.zig");
const zoneinfo = @import("zoneinfo");
const Database = almanac.Database;
const testing = std.testing;

/// A zoneinfo tree in a temporary directory, and an `etc` beside it.
const Tree = struct {
    tmp: testing.TmpDir,
    zones: std.Io.Dir,
    etc: std.Io.Dir,

    fn init() !Tree {
        const io = testing.io;
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "zoneinfo/America");
        try tmp.dir.createDirPath(io, "zoneinfo/Europe");
        try tmp.dir.createDirPath(io, "zoneinfo/US");
        try tmp.dir.createDirPath(io, "zoneinfo/Bad");
        try tmp.dir.createDirPath(io, "etc");
        try tmp.dir.writeFile(io, .{ .sub_path = "zoneinfo/America/New_York", .data = zoneinfo.America_New_York });
        try tmp.dir.writeFile(io, .{ .sub_path = "zoneinfo/Europe/Lisbon", .data = zoneinfo.Europe_Lisbon });
        try tmp.dir.writeFile(io, .{ .sub_path = "zoneinfo/Bad/Zone", .data = "TZif2 but nothing more" });
        try tmp.dir.writeFile(io, .{ .sub_path = "outside", .data = zoneinfo.Europe_Lisbon });
        const big: [2 << 20]u8 = @splat('x');
        try tmp.dir.writeFile(io, .{ .sub_path = "zoneinfo/Big", .data = &big });
        try tmp.dir.symLink(io, "../America/New_York", "zoneinfo/US/Eastern", .{});
        try tmp.dir.symLink(io, "../../outside", "zoneinfo/US/Escape", .{});
        try tmp.dir.symLink(io, "/etc/passwd", "zoneinfo/US/Absolute", .{});
        try tmp.dir.symLink(io, "Loop", "zoneinfo/Loop", .{});
        try tmp.dir.symLink(io, "/var/db/timezone/zoneinfo/Europe/Lisbon", "etc/localtime", .{});
        const zones = try tmp.dir.openDir(io, "zoneinfo", .{});
        const etc = try tmp.dir.openDir(io, "etc", .{});
        return .{ .tmp = tmp, .zones = zones, .etc = etc };
    }

    fn deinit(t: *Tree) void {
        t.zones.close(testing.io);
        t.etc.close(testing.io);
        t.tmp.cleanup();
    }
};

fn offsetAt(z: *const Database.Zone, y: i16, m: u8, d: u8) !i32 {
    const dt: almanac.DateTime = .{ .date = try almanac.Date.init(y, m, d) };
    return (try z.get().offsetAt(try almanac.instant.fromDateTime(dt, .utc))).seconds.raw();
}

test "names: read beneath the directory, links followed while they stay beneath it" {
    var tree = try Tree.init();
    defer tree.deinit();
    const io = testing.io;
    var db = Database.init(testing.allocator, .{ .zoneinfo = tree.zones });
    defer db.deinit();
    var ny = try db.zone(io, .init("America/New_York"));
    defer ny.release();
    try testing.expectEqual(.system, ny.source());
    try testing.expectEqualStrings("America/New_York", ny.get().name().?);
    try testing.expectEqual(-14400, try offsetAt(&ny, 2024, 7, 1));
    // A second lookup is the cache's zone.
    var again = try db.zone(io, .init("America/New_York"));
    defer again.release();
    try testing.expect(ny.same(&again));
    var eastern = try db.zone(io, .init("US/Eastern"));
    defer eastern.release();
    try testing.expectEqual(-18000, try offsetAt(&eastern, 2024, 1, 1));
    for ([_][]const u8{ "../outside", "/etc/passwd", "America//New_York", "", "America/./New_York", "US/Escape", "US/Absolute", "Loop", "Nowhere/Zone", "America", "a b" }) |name| {
        errdefer std.debug.print("{s}\n", .{name});
        try testing.expectError(error.ZoneNotFound, db.zone(io, .init(name)));
    }
    try testing.expectError(error.Corrupt, db.zone(io, .init("Bad/Zone")));
    try testing.expectError(error.TooLarge, db.zone(io, .init("Big")));
    // UTC that no source has is the built-in one.
    var utc = try db.zone(io, .init("UTC"));
    defer utc.release();
    try testing.expectEqual(.builtin, utc.source());
    // Only the embedded data: none yet, so no zone but UTC.
    var embedded = Database.init(testing.allocator, .{ .zoneinfo = tree.zones, .source = .embedded });
    defer embedded.deinit();
    try testing.expectError(error.ZoneNotFound, embedded.zone(io, .init("America/New_York")));
}

test "the local zone: $TZ as POSIX reads it, else the localtime link" {
    var tree = try Tree.init();
    defer tree.deinit();
    const io = testing.io;
    var db = Database.init(testing.allocator, .{ .zoneinfo = tree.zones, .localtime = tree.etc });
    defer db.deinit();
    var named = try db.local(io, .init("Europe/Lisbon"));
    defer named.release();
    try testing.expectEqualStrings("Europe/Lisbon", named.get().name().?);
    var colon = try db.local(io, .init(":America/New_York"));
    defer colon.release();
    try testing.expectEqualStrings("America/New_York", colon.get().name().?);
    var rule = try db.local(io, .init("EST5EDT,M3.2.0,M11.1.0"));
    defer rule.release();
    try testing.expectEqual(.builtin, rule.source());
    try testing.expectEqual(-14400, try offsetAt(&rule, 2024, 7, 1));
    var empty = try db.local(io, .init(""));
    defer empty.release();
    try testing.expectEqualStrings("UTC", (try empty.get().infoAt(almanac.instant.min)).abbreviation);
    try testing.expectError(error.ZoneNotFound, db.local(io, .init("Not a zone")));
    // Unset: the localtime link's target, past "zoneinfo/".
    var system = try db.local(io, null);
    defer system.release();
    try testing.expectEqualStrings("Europe/Lisbon", system.get().name().?);
    // With no localtime at all, UTC.
    var bare = Database.init(testing.allocator, .{ .zoneinfo = tree.zones });
    defer bare.deinit();
    var none = try bare.local(io, null);
    defer none.release();
    try testing.expectEqual(.builtin, none.source());
}

test "refresh: a changed file is a new zone, and the old one lives while held" {
    var tree = try Tree.init();
    defer tree.deinit();
    const io = testing.io;
    var quarantine = shakedown.alloc.Quarantine.init(.{});
    defer quarantine.deinit();
    var db = Database.init(quarantine.allocator(), .{ .zoneinfo = tree.zones });
    defer db.deinit();
    var old = try db.zone(io, .init("America/New_York"));
    defer old.release();
    try testing.expectEqual(Database.Refreshed{}, try db.refresh(io));
    // The file now holds Lisbon's rules.
    try tree.zones.deleteFile(io, "America/New_York");
    try tree.zones.writeFile(io, .{ .sub_path = "America/New_York", .data = zoneinfo.Europe_Lisbon });
    try testing.expectEqual(Database.Refreshed{ .replaced = 1 }, try db.refresh(io));
    var fresh = try db.zone(io, .init("America/New_York"));
    defer fresh.release();
    try testing.expect(!old.same(&fresh));
    try testing.expectEqual(3600, try offsetAt(&fresh, 2024, 7, 1));
    // The old block was not freed: under the quarantine a freed one would fault here.
    try testing.expectEqual(-14400, try offsetAt(&old, 2024, 7, 1));
    try tree.zones.deleteFile(io, "America/New_York");
    try testing.expectEqual(Database.Refreshed{ .removed = 1 }, try db.refresh(io));
    try testing.expectEqual(3600, try offsetAt(&fresh, 2024, 7, 1));
}

test "every read's failure and cancel, and the cache left as it was" {
    var tree = try Tree.init();
    defer tree.deinit();
    const fio = try shakedown.FaultIo.init(testing.allocator, testing.io, .{});
    defer fio.deinit();
    const io = fio.io();
    var db = Database.init(testing.allocator, .{ .zoneinfo = tree.zones });
    defer db.deinit();
    try fio.setPlan(&.{.{ .at = .{ .nth = .{ .call = .dirOpenFile, .n = 1 } }, .fault = .{ .fail = error.AccessDenied } }});
    try testing.expectError(error.ReadFailed, db.zone(io, .init("America/New_York")));
    try fio.setPlan(&.{.{ .at = .{ .nth = .{ .call = .dirOpenFile, .n = 1 } }, .fault = .cancel }});
    try testing.expectError(error.Canceled, db.zone(io, .init("America/New_York")));
    try fio.setPlan(&.{.{ .at = .{ .nth = .{ .call = .fileReadPositional, .n = 1 } }, .fault = .{ .fail = error.InputOutput } }});
    try testing.expectError(error.ReadFailed, db.zone(io, .init("America/New_York")));
    // A short read is read on; a read that makes no progress ends the file there: truncated.
    try fio.setPlan(&.{.{ .at = .{ .nth = .{ .call = .fileReadPositional, .n = 1 } }, .fault = .{ .short = 0 } }});
    try testing.expectError(error.Corrupt, db.zone(io, .init("America/New_York")));
    try fio.setPlan(&.{});
    var ny = try db.zone(io, .init("America/New_York"));
    defer ny.release();
    try testing.expectEqual(-14400, try offsetAt(&ny, 2024, 7, 1));
}
