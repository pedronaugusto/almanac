//! almanac's copy of the IANA time zone database (`tzdb.bin`, written by `tools/generate.zig`
//! from the release vendored in `tzdata/`): each zone's TZif file under its name, links sharing
//! their target's. A program carries it only where it names `almanac.tzdb`, as a `Database`'s
//! `embedded` source: nothing in almanac does, so a program that reads only the system's files
//! compiles none of it.
const std = @import("std");

/// The embedded data, as a `Database` reads it.
pub const Embedded = struct {
    blob: []const u8,

    /// The IANA release, such as `2026f`.
    pub fn version(e: *const Embedded) []const u8 {
        var r: Reader = .{ .blob = e.blob, .at = 5 };
        const n = (r.take(1) orelse return "")[0];
        return r.take(n) orelse "";
    }

    /// The zone names and links the data holds.
    pub fn count(e: *const Embedded) usize {
        var r: Reader = .{ .blob = e.blob, .at = 5 };
        _ = r.take((r.take(1) orelse return 0)[0]);
        return r.int() orelse 0;
    }

    /// The TZif file of the zone or link named `name`, or null.
    pub fn find(e: *const Embedded, name: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, e.blob, "ATZB")) return null;
        var r: Reader = .{ .blob = e.blob, .at = 5 };
        _ = r.take((r.take(1) orelse return null)[0]) orelse return null;
        const names = r.int() orelse return null;
        var wanted: ?u32 = null;
        for (0..names) |_| {
            const n = (r.take(1) orelse return null)[0];
            const entry = r.take(n) orelse return null;
            const data = r.int() orelse return null;
            if (std.mem.eql(u8, entry, name)) wanted = data;
        }
        const index = wanted orelse return null;
        const files = r.int() orelse return null;
        if (index >= files) return null;
        for (0..index) |_| _ = r.take(r.int() orelse return null) orelse return null;
        return r.take(r.int() orelse return null);
    }
};

/// The data itself, about 280 KiB: compiled into a program only where it is named.
pub const tzdb: Embedded = .{ .blob = @embedFile("tzdb.bin") };

const Reader = struct {
    blob: []const u8,
    at: usize = 0,

    fn take(r: *Reader, n: usize) ?[]const u8 {
        if (n > r.blob.len - r.at) return null;
        defer r.at += n;
        return r.blob[r.at..][0..n];
    }

    fn int(r: *Reader) ?u32 {
        return std.mem.readInt(u32, (r.take(4) orelse return null)[0..4], .big);
    }
};
