//! Finding, loading and caching zones. The system's zone files are read beneath the caller's
//! `zoneinfo` directory handle, never by an absolute path, through the caller's `Io` on each call,
//! so a load is canceled at its reads. Each zone loaded is one `aegis.Shared` block, handed out as
//! counted `Zone` handles; the cache holds one handle per name under an `aegis.RwGuarded`, so a
//! lookup of a loaded zone is a shared read. `refresh` never frees a zone in use: a zone whose file
//! changed is loaded as a new block that replaces the cache's handle, and the old block lives until
//! its last holder releases it. There is no global database: a program keeps the one it makes.
const Database = @This();
const std = @import("std");
const aegis = @import("aegis");
const TimeZone = @import("TimeZone.zig");
const units = @import("units.zig");
const embedded = @import("zone/embedded.zig");
const windows_zones = @import("zone/windows.zig");
const target_os = @import("builtin").os.tag;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Untrusted = aegis.input.Untrusted([]const u8);

/// `ZoneNotFound`: no source has the zone (a name that climbs out of the zoneinfo directory names
/// none). `Corrupt`: its file is no TZif file. `LeapSeconds`: its file counts leap seconds (a
/// `right/` zone). `TooLarge`: its file is over `max_zone_bytes`. `Canceled`: the caller's `Io`
/// canceled a read. `ReadFailed`: the system refused a read.
pub const ZoneError = error{ ZoneNotFound, Corrupt, LeapSeconds, TooLarge, Canceled, ReadFailed, OutOfMemory };

pub const Source = enum {
    /// The system's zoneinfo.
    system,
    /// The data built into almanac (`-Dtzdb=embedded` or `both`).
    embedded,
    /// Made here: UTC when no source has it, a POSIX string from `$TZ`, a local zone with no name.
    builtin,
};

pub const Options = struct {
    source: enum { system, embedded, system_then_embedded } = .system_then_embedded,
    /// The system's zoneinfo, opened by the caller (`/usr/share/zoneinfo` on most systems); null
    /// where there is none (Windows) or only the embedded data is wanted.
    zoneinfo: ?Io.Dir = null,
    /// The directory holding the system's `localtime` link (`/etc` on most systems), opened by the
    /// caller; null where there is none.
    localtime: ?Io.Dir = null,
    max_zone_bytes: aegis.units.Bytes(u32) = .literal("1MiB"),
};

/// A counted handle to a zone: it stays valid until released, whatever `refresh` does.
pub const Zone = struct {
    shared: aegis.Shared(TimeZone, TimeZone.free),
    from: Source,

    pub fn get(z: *const Zone) *const TimeZone {
        return z.shared.get();
    }

    pub fn source(z: *const Zone) Source {
        return z.from;
    }

    /// Another handle to the same zone; release both.
    pub fn retain(z: *const Zone) Zone {
        return .{ .shared = z.shared.retain(), .from = z.from };
    }

    pub fn release(z: *Zone) void {
        z.shared.release();
    }

    /// Whether two handles hold the same loaded zone (a refreshed zone is a new one).
    pub fn same(a: *const Zone, b: *const Zone) bool {
        return a.get() == b.get();
    }
};

/// What identifies a file's contents for `refresh`: its inode, size and modification time.
const Stamp = struct {
    inode: Io.File.INode,
    size: u64,
    mtime: i96,

    fn of(s: Io.File.Stat) Stamp {
        return .{ .inode = s.inode, .size = s.size, .mtime = s.mtime.nanoseconds };
    }

    fn eql(a: Stamp, b: Stamp) bool {
        return a.inode == b.inode and a.size == b.size and a.mtime == b.mtime;
    }
};

const Entry = struct {
    zone: Zone,
    /// For a system file: the path read beneath `zoneinfo` (links followed) and its stamp.
    path: ?[]u8 = null,
    stamp: ?Stamp = null,
};

const Cache = struct {
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
};

gpa: Allocator,
options: Options,
cache: aegis.RwGuarded(Cache),

/// The IANA zone CLDR gives a Windows time zone name by default (`Eastern Standard Time` is
/// `America/New_York`), or null for a name CLDR does not map.
pub fn ianaForWindows(name: []const u8) ?[]const u8 {
    const pairs = &windows_zones.pairs;
    var low: usize = 0;
    var high: usize = pairs.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (std.mem.order(u8, pairs[mid].windows, name)) {
            .eq => return pairs[mid].iana,
            .lt => low = mid + 1,
            .gt => high = mid,
        }
    }
    return null;
}

/// The TZif bytes of a zone or link in the embedded data, or null.
pub fn embeddedBytes(name: []const u8) ?[]const u8 {
    return embedded.find(name);
}

/// The IANA release the embedded data is (`2026f`), or empty where it is not linked.
pub fn embeddedVersion() []const u8 {
    return embedded.version();
}

pub fn init(gpa: Allocator, options: Options) Database {
    return .{ .gpa = gpa, .options = options, .cache = .init(.{}) };
}

/// Releases the cache's handles. Handles held elsewhere stay valid: each zone is its own block.
pub fn deinit(db: *Database) void {
    const cache = db.cache.teardown();
    var it = cache.entries.iterator();
    while (it.next()) |e| db.dropEntry(e.key_ptr.*, e.value_ptr);
    cache.entries.deinit(db.gpa);
    db.* = undefined;
}

fn dropEntry(db: *Database, key: []const u8, e: *Entry) void {
    e.zone.release();
    if (e.path) |p| db.gpa.free(p);
    db.gpa.free(key);
}

/// An IANA zone name as almanac reads one: components of letters, digits, `_`, `-` and `+`,
/// separated by `/`, none empty, `.` or `..`, and no longer than 255 bytes. Anything else names no
/// zone, so no path outside the zoneinfo directory is ever formed from a name.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        for (part) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '+')) return false;
    }
    return true;
}

/// The zone `name` names, from the cache or loaded from the sources `options.source` allows.
/// `system_then_embedded` falls back to the embedded data only when the system has no such zone;
/// a damaged or unreadable system file is an error, never a silent second answer. "UTC" that no
/// source has is the built-in UTC.
pub fn zone(db: *Database, io: Io, name: Untrusted) ZoneError!Zone {
    const text = name.readForParse();
    if (!validName(text)) return error.ZoneNotFound;
    {
        var guard = db.cache.read(io) catch |err| return lockError(err);
        defer guard.deinit(io);
        if (guard.value().entries.get(text)) |e| return e.zone.retain();
    }
    var loaded = try db.load(io, text);
    errdefer loaded.zone.release();
    errdefer if (loaded.path) |p| db.gpa.free(p);
    var guard = db.cache.write(io) catch |err| return lockError(err);
    defer guard.deinit(io);
    const cache = guard.value();
    // Another caller may have loaded it meanwhile: theirs is kept.
    if (cache.entries.get(text)) |e| {
        loaded.zone.release();
        if (loaded.path) |p| db.gpa.free(p);
        return e.zone.retain();
    }
    const key = try db.gpa.dupe(u8, text);
    errdefer db.gpa.free(key);
    try cache.entries.put(db.gpa, key, loaded);
    return loaded.zone.retain();
}

fn lockError(err: anyerror) ZoneError {
    return switch (err) {
        error.Canceled => error.Canceled,
        else => error.ReadFailed,
    };
}

/// Loads a zone, its one handle the caller's.
fn load(db: *Database, io: Io, name: []const u8) ZoneError!Entry {
    const system = db.options.source != .embedded;
    if (system) if (db.options.zoneinfo) |dir| {
        if (try db.loadSystem(io, dir, name)) |e| return e;
    };
    if (db.options.source != .system) if (embedded.find(name)) |bytes| {
        var value = TimeZone.fromTzif(db.gpa, .init(bytes), name) catch |err| return switch (err) {
            // The embedded data is almanac's own, checked when it was generated.
            error.Corrupt, error.LeapSeconds => unreachable,
            error.OutOfMemory => error.OutOfMemory,
        };
        errdefer value.free();
        return .{ .zone = .{ .shared = try .createFrom(db.gpa, &value), .from = .embedded } };
    };
    if (std.mem.eql(u8, name, "UTC")) return .{ .zone = try db.builtin(TimeZone.utc) };
    return error.ZoneNotFound;
}

/// A zone of one offset for all time, as a handle (the zone an RFC 9557 `[+05:30]` names).
pub fn fixedZone(db: *Database, offset: units.Offset) ZoneError!Zone {
    return db.builtin(TimeZone.fixed(offset));
}

/// A zone made here, as a handle.
fn builtin(db: *Database, value: TimeZone) ZoneError!Zone {
    return .{ .shared = try .create(db.gpa, value), .from = .builtin };
}

/// The longest chain of links followed, and the deepest name reached through them.
const max_links = 8;

/// The path `name` reaches beneath `dir`, each link in it followed while it stays beneath; null
/// where it does not exist, `ZoneNotFound` where a link leaves the directory.
fn resolvePath(io: Io, dir: Io.Dir, name: []const u8, buffer: *[512]u8) ZoneError!?[]const u8 {
    var path: std.ArrayList(u8) = .initBuffer(buffer[0..256]);
    path.appendSliceAssumeCapacity(name);
    var hops: usize = 0;
    // Each prefix of the path, shortest first, is checked for a link.
    var end: usize = 0;
    while (end < path.items.len) {
        end = std.mem.findScalarPos(u8, path.items, end + 1, '/') orelse path.items.len;
        var target_buffer: [256]u8 = undefined;
        const n = dir.readLink(io, path.items[0..end], &target_buffer) catch |err| switch (err) {
            error.NotLink => continue,
            error.FileNotFound, error.NotDir => return null,
            error.Canceled => return error.Canceled,
            else => return error.ReadFailed,
        };
        hops += 1;
        if (hops > max_links) return error.ZoneNotFound;
        const target = target_buffer[0..n];
        if (target.len == 0 or target[0] == '/') return error.ZoneNotFound;
        // The target, relative to the link's own directory, joined and normalized; climbing above
        // the zoneinfo directory names no zone.
        var joined: [512]u8 = undefined;
        const parent = if (std.mem.findScalarLast(u8, path.items[0..end], '/')) |slash| path.items[0..slash] else "";
        const rest = path.items[end..];
        const raw = std.fmt.bufPrint(&joined, "{s}{s}{s}{s}", .{ parent, if (parent.len > 0) "/" else "", target, rest }) catch return error.ZoneNotFound;
        var parts: [64][]const u8 = undefined;
        var depth: usize = 0;
        var it = std.mem.splitScalar(u8, raw, '/');
        while (it.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
            if (std.mem.eql(u8, part, "..")) {
                if (depth == 0) return error.ZoneNotFound;
                depth -= 1;
                continue;
            }
            if (depth == parts.len) return error.ZoneNotFound;
            parts[depth] = part;
            depth += 1;
        }
        if (depth == 0) return error.ZoneNotFound;
        var next: std.ArrayList(u8) = .initBuffer(buffer[256..]);
        for (parts[0..depth], 0..) |part, i| {
            if (i > 0) next.appendBounded('/') catch return error.ZoneNotFound;
            next.appendSliceBounded(part) catch return error.ZoneNotFound;
        }
        path.clearRetainingCapacity();
        path.appendSliceAssumeCapacity(next.items);
        end = 0;
    }
    return path.items;
}

/// Loads `name` from the system's zoneinfo, or null where the system has no such zone.
fn loadSystem(db: *Database, io: Io, dir: Io.Dir, name: []const u8) ZoneError!?Entry {
    var buffer: [512]u8 = undefined;
    const path = try resolvePath(io, dir, name, &buffer) orelse return null;
    const read = try db.readZone(io, dir, path, name);
    return read;
}

/// Reads and parses one zone file beneath `dir`, its handle and owned path the caller's.
fn readZone(db: *Database, io: Io, dir: Io.Dir, path: []const u8, name: ?[]const u8) ZoneError!?Entry {
    const file = dir.openFile(io, path, .{ .allow_directory = false }) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir, error.IsDir => null,
        error.Canceled => error.Canceled,
        else => error.ReadFailed,
    };
    defer file.close(io);
    const stat = file.stat(io) catch |err| return if (err == error.Canceled) error.Canceled else error.ReadFailed;
    if (stat.size > db.options.max_zone_bytes.raw()) return error.TooLarge;
    const bytes = try db.gpa.alloc(u8, @intCast(stat.size));
    defer db.gpa.free(bytes);
    const n = file.readPositionalAll(io, bytes, 0) catch |err| return if (err == error.Canceled) error.Canceled else error.ReadFailed;
    var value = TimeZone.fromTzif(db.gpa, .init(bytes[0..n]), name) catch |err| return switch (err) {
        error.Corrupt => error.Corrupt,
        error.LeapSeconds => error.LeapSeconds,
        error.OutOfMemory => error.OutOfMemory,
    };
    errdefer value.free();
    const owned_path = try db.gpa.dupe(u8, path);
    errdefer db.gpa.free(owned_path);
    return .{ .zone = .{ .shared = try .createFrom(db.gpa, &value), .from = .system }, .path = owned_path, .stamp = .of(stat) };
}

/// The local zone. `tz` is the caller's `$TZ`, read as POSIX reads it: unset (null) is the
/// system's, empty is UTC, `:name` or a zone name is that zone, anything else a POSIX TZ string.
/// The system's is the zone the `localtime` link names (its target's path past `zoneinfo/`), or the
/// file it reaches where that names none; with no `localtime`, UTC. almanac reads no environment.
pub fn local(db: *Database, io: Io, tz: ?Untrusted) ZoneError!Zone {
    if (tz) |given| {
        const text = given.readForParse();
        if (text.len == 0) return db.zone(io, .init("UTC"));
        const name = if (text[0] == ':') text[1..] else text;
        if (validName(name)) {
            if (db.zone(io, .init(name))) |z| return z else |err| if (err != error.ZoneNotFound) return err;
        }
        const rule = TimeZone.posix(.init(text)) catch return error.ZoneNotFound;
        return db.builtin(rule);
    }
    if (target_os == .windows) return db.windowsLocal(io);
    const etc = db.options.localtime orelse return db.zone(io, .init("UTC"));
    var target: [512]u8 = undefined;
    if (etc.readLink(io, "localtime", &target)) |n| {
        const link = target[0..n];
        if (std.mem.findLast(u8, link, "zoneinfo/")) |at| {
            const name = link[at + "zoneinfo/".len ..];
            if (validName(name)) {
                if (db.zone(io, .init(name))) |z| return z else |err| if (err != error.ZoneNotFound) return err;
            }
        }
    } else |err| switch (err) {
        error.NotLink => {},
        error.FileNotFound => return db.zone(io, .init("UTC")),
        error.Canceled => return error.Canceled,
        else => return error.ReadFailed,
    }
    // A copy, or a link naming no zone: the file it reaches, with no name.
    var entry = try db.readZone(io, etc, "localtime", null) orelse return db.zone(io, .init("UTC"));
    if (entry.path) |p| db.gpa.free(p);
    entry.zone.from = .builtin;
    return entry.zone;
}

/// TIME_DYNAMIC_ZONE_INFORMATION (timezoneapi.h).
const DynamicZone = extern struct {
    bias: i32,
    standard_name: [32]u16,
    standard_date: [8]u16,
    standard_bias: i32,
    daylight_name: [32]u16,
    daylight_date: [8]u16,
    daylight_bias: i32,
    key_name: [128]u16,
    dynamic_daylight_time_disabled: u8,
};

extern "kernel32" fn GetDynamicTimeZoneInformation(info: *DynamicZone) callconv(.winapi) u32;

/// Windows' local zone: its time zone key name mapped to an IANA name through CLDR, read from the
/// embedded data (Windows has no zoneinfo). Where the user turned daylight saving adjustment off,
/// the clock keeps standard time all year: a fixed offset.
fn windowsLocal(db: *Database, io: Io) ZoneError!Zone {
    var info: DynamicZone = undefined;
    if (GetDynamicTimeZoneInformation(&info) == 0xFFFF_FFFF) return error.ReadFailed;
    if (info.dynamic_daylight_time_disabled != 0) {
        const offset = units.Offset.init(-info.bias * 60) catch return error.Corrupt;
        return db.builtin(TimeZone.fixed(offset));
    }
    const length = std.mem.findScalar(u16, &info.key_name, 0) orelse info.key_name.len;
    var name: [512]u8 = undefined;
    const n = std.unicode.utf16LeToUtf8(&name, info.key_name[0..length]) catch return error.ZoneNotFound;
    return db.zone(io, .init(ianaForWindows(name[0..n]) orelse return error.ZoneNotFound));
}

pub const Refreshed = struct {
    /// Zones whose files changed and were loaded again.
    replaced: usize = 0,
    /// Zones whose files are gone, dropped from the cache (their holders keep them).
    removed: usize = 0,
};

/// Re-reads the cached system zones whose files changed (by inode, size and modification time),
/// each as a new zone with a new identity; handles to the old ones keep them until released.
/// Nothing in use is freed. The cache is held for writing while files are checked.
pub fn refresh(db: *Database, io: Io) ZoneError!Refreshed {
    var out: Refreshed = .{};
    const dir = db.options.zoneinfo orelse return out;
    var guard = db.cache.write(io) catch |err| return lockError(err);
    defer guard.deinit(io);
    const cache = guard.value();
    var gone: std.ArrayList([]const u8) = .empty;
    defer gone.deinit(db.gpa);
    var it = cache.entries.iterator();
    while (it.next()) |e| {
        const path = e.value_ptr.path orelse continue;
        const old = e.value_ptr.stamp.?;
        const stat = dir.statFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                try gone.append(db.gpa, e.key_ptr.*);
                continue;
            },
            error.Canceled => return error.Canceled,
            else => return error.ReadFailed,
        };
        if (Stamp.of(stat).eql(old)) continue;
        const fresh = try db.loadSystem(io, dir, e.key_ptr.*) orelse {
            try gone.append(db.gpa, e.key_ptr.*);
            continue;
        };
        e.value_ptr.zone.release();
        db.gpa.free(path);
        e.value_ptr.* = fresh;
        out.replaced += 1;
    }
    for (gone.items) |key| {
        var removed = cache.entries.fetchRemove(key).?;
        db.dropEntry(removed.key, &removed.value);
        out.removed += 1;
    }
    return out;
}
