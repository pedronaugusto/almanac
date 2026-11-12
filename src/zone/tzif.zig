//! TZif files (RFC 8536, versions 1 to 4): a zone's transitions, its local time types and the TZ
//! string that rules past them. The bytes are untrusted (a file anyone may write under `$TZ`'s
//! path), so every count is bounded by what the file still holds before anything is read or
//! allocated, and every index, offset and abbreviation is checked.
const std = @import("std");
const units = @import("../units.zig");
const posix = @import("posix.zig");
const Offset = units.Offset;
const Allocator = std.mem.Allocator;

/// `Corrupt`: the bytes are no TZif file RFC 8536 allows. `LeapSeconds`: the file counts leap
/// seconds (a `right/` zone), which almanac's POSIX time does not.
pub const Error = error{ Corrupt, LeapSeconds, OutOfMemory };

/// A file's tables, allocated from the parser's allocator.
pub const Parsed = struct {
    transitions: []i64,
    kinds: []u8,
    types: []posix.Local,
    footer: ?posix.Rule,

    pub fn deinit(p: *Parsed, gpa: Allocator) void {
        gpa.free(p.transitions);
        gpa.free(p.kinds);
        gpa.free(p.types);
        p.* = undefined;
    }
};

const Header = struct {
    version: u8,
    isutcnt: u32,
    isstdcnt: u32,
    leapcnt: u32,
    timecnt: u32,
    typecnt: u32,
    charcnt: u32,

    /// The data block's length with times of `time_size` bytes, which may exceed any file.
    fn blockLen(h: Header, time_size: u64) u64 {
        return @as(u64, h.timecnt) * time_size + h.timecnt + @as(u64, h.typecnt) * 6 + h.charcnt +
            @as(u64, h.leapcnt) * (time_size + 4) + h.isstdcnt + h.isutcnt;
    }
};

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn take(r: *Reader, n: u64) Error![]const u8 {
        if (n > r.bytes.len - r.at) return error.Corrupt;
        const out = r.bytes[r.at..][0..@intCast(n)];
        r.at += @intCast(n);
        return out;
    }

    fn int(r: *Reader, comptime T: type) Error!T {
        return std.mem.readInt(T, (try r.take(@sizeOf(T)))[0..@sizeOf(T)], .big);
    }

    fn header(r: *Reader) Error!Header {
        if (!std.mem.eql(u8, try r.take(4), "TZif")) return error.Corrupt;
        const version = (try r.take(1))[0];
        if (version != 0 and (version < '2' or version > '4')) return error.Corrupt;
        _ = try r.take(15);
        const h: Header = .{
            .version = version,
            .isutcnt = try r.int(u32),
            .isstdcnt = try r.int(u32),
            .leapcnt = try r.int(u32),
            .timecnt = try r.int(u32),
            .typecnt = try r.int(u32),
            .charcnt = try r.int(u32),
        };
        // RFC 8536 §3.1; an index is one byte, so at most 256 types are reachable.
        if (h.typecnt == 0 or h.typecnt > 256 or h.charcnt == 0) return error.Corrupt;
        if (h.isutcnt != 0 and h.isutcnt != h.typecnt) return error.Corrupt;
        if (h.isstdcnt != 0 and h.isstdcnt != h.typecnt) return error.Corrupt;
        return h;
    }
};

/// Parses a TZif file into its tables.
pub fn parse(gpa: Allocator, bytes: []const u8) Error!Parsed {
    var r: Reader = .{ .bytes = bytes };
    const first = try r.header();
    if (first.version == 0) return block(gpa, &r, first, 4, false);
    // Version 2 and later: the version 1 block is skipped, then read again with 64-bit times.
    _ = try r.take(first.blockLen(4));
    const second = try r.header();
    if (second.version != first.version) return error.Corrupt;
    return block(gpa, &r, second, 8, true);
}

fn block(gpa: Allocator, r: *Reader, h: Header, comptime time_size: u8, footer: bool) Error!Parsed {
    // Every count is bounded by the bytes left before anything is allocated.
    if (h.blockLen(time_size) > r.bytes.len - r.at) return error.Corrupt;
    if (h.leapcnt != 0) return error.LeapSeconds;
    const Time = if (time_size == 4) i32 else i64;

    const transitions = try gpa.alloc(i64, h.timecnt);
    errdefer gpa.free(transitions);
    for (transitions, 0..) |*t, i| {
        t.* = try r.int(Time);
        if (i > 0 and t.* <= transitions[i - 1]) return error.Corrupt;
    }
    const kinds = try gpa.alloc(u8, h.timecnt);
    errdefer gpa.free(kinds);
    @memcpy(kinds, try r.take(h.timecnt));
    for (kinds) |k| if (k >= h.typecnt) return error.Corrupt;

    const records = try r.take(@as(u64, h.typecnt) * 6);
    const chars = try r.take(h.charcnt);
    const types = try gpa.alloc(posix.Local, h.typecnt);
    errdefer gpa.free(types);
    for (types, 0..) |*t, i| {
        const record = records[i * 6 ..][0..6];
        const utoff = std.mem.readInt(i32, record[0..4], .big);
        const isdst = record[4];
        const index = record[5];
        if (isdst > 1 or index >= chars.len) return error.Corrupt;
        const end = std.mem.findScalarPos(u8, chars, index, 0) orelse return error.Corrupt;
        const offset = Offset.init(utoff) catch return error.Corrupt;
        t.* = posix.Local.init(offset, isdst == 1, chars[index..end]) catch return error.Corrupt;
    }
    // The leap second table is empty; the standard/wall and UT/local indicators matter only to
    // a POSIX rule's defaults, which almanac does not take, so they are checked and passed over.
    for (try r.take(h.isstdcnt)) |b| if (b > 1) return error.Corrupt;
    for (try r.take(h.isutcnt)) |b| if (b > 1) return error.Corrupt;

    var rule: ?posix.Rule = null;
    if (footer) {
        if ((try r.take(1))[0] != '\n') return error.Corrupt;
        const rest = r.bytes[r.at..];
        const end = std.mem.findScalar(u8, rest, '\n') orelse return error.Corrupt;
        if (end + 1 != rest.len) return error.Corrupt;
        if (end > 0) rule = posix.parse(rest[0..end]) catch return error.Corrupt;
    } else if (r.at != r.bytes.len) return error.Corrupt;
    return .{ .transitions = transitions, .kinds = kinds, .types = types, .footer = rule };
}
