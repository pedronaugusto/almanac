//! almanac's copy of the IANA time zone database (`tzdb.bin`, written by `tools/generate.zig`
//! from the release vendored in `tzdata/`): each zone's TZif file under its name, links sharing
//! their target's. Linked in only where the build asks for it (`-Dtzdb=embedded` or `both`).
const std = @import("std");
const options = @import("almanac_options");

/// Whether this build carries the data.
pub const available = options.embedded;

const blob: []const u8 = if (available) @embedFile("tzdb.bin") else "";

const Reader = struct {
    at: usize = 0,

    fn take(r: *Reader, n: usize) ?[]const u8 {
        if (n > blob.len - r.at) return null;
        defer r.at += n;
        return blob[r.at..][0..n];
    }

    fn int(r: *Reader) ?u32 {
        return std.mem.readInt(u32, (r.take(4) orelse return null)[0..4], .big);
    }
};

/// The IANA release, such as `2026f`; empty where the data is not linked.
pub fn version() []const u8 {
    if (!available) return "";
    var r: Reader = .{ .at = 5 };
    const n = (r.take(1) orelse return "")[0];
    return r.take(n) orelse "";
}

/// The zone names and links the data holds.
pub fn count() usize {
    if (!available) return 0;
    var r: Reader = .{ .at = 5 };
    _ = r.take((r.take(1) orelse return 0)[0]);
    return r.int() orelse 0;
}

/// The TZif file of the zone or link named `name`.
pub fn find(name: []const u8) ?[]const u8 {
    if (!available or !std.mem.startsWith(u8, blob, "ATZB")) return null;
    var r: Reader = .{ .at = 5 };
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
