//! A time zone: one compiled form for every source. A TZif file's transitions and local time
//! types, a POSIX TZ string's rule (alone, or as a file's footer for times past its table), a
//! fixed offset and UTC are all a `TimeZone`; a fixed offset is one with no transitions and no
//! rule, so no lookup branches on where a zone came from. A lookup is a binary search over the
//! transitions, then the footer rule in closed form.
//!
//! A zone is immutable once made and may be shared between threads, so it holds no hint of its
//! own; a caller converting a run of nearby instants passes a `Cursor` it owns.
const TimeZone = @This();
const std = @import("std");
const aegis = @import("aegis");
const units = @import("units.zig");
const instant = @import("instant.zig");
const arithmetic = @import("arithmetic.zig");
const posix_rule = @import("zone.zig").posix;
const tzif = @import("zone.zig").tzif;
const DateTime = @import("DateTime.zig");
const Offset = units.Offset;
const Allocator = std.mem.Allocator;
const Local = posix_rule.Local;

pub const RangeError = units.RangeError;
pub const PosixError = posix_rule.Error;
pub const TzifError = tzif.Error;

/// The IANA name, or null for a fixed offset or a POSIX string.
zone_name: ?[]const u8 = null,
/// The local time type before the first transition, and the only one of a fixed offset.
initial: Local,
/// Seconds since 1970, strictly ascending.
transitions: []const i64 = &.{},
/// The local time type each transition starts, an index into `types`.
kinds: []const u8 = &.{},
types: []const Local = &.{},
/// The rule past the last transition (or for all time, for a POSIX string).
footer: ?posix_rule.Rule = null,
/// The allocator that holds the tables, for a zone read from a file.
gpa: ?Allocator = null,

/// The offset, whether daylight saving is in force, and the abbreviation (`WEST`), borrowed from
/// the zone.
pub const Info = struct {
    offset: Offset,
    dst: bool,
    abbreviation: []const u8,
};

/// An instant at which the zone's offset changes, and what is in force from it.
pub const Transition = struct {
    at: instant.Timestamp,
    info: Info,
};

/// A caller's hint for a run of nearby lookups: the last transition found, tried with its
/// neighbour before a search. Any cursor gives the same answers; a fitting one gives them sooner.
pub const Cursor = struct {
    index: usize = 0,
};

pub const utc: TimeZone = .{ .initial = Local.init(.utc, false, "UTC") catch aegis.assert.never("UTC's abbreviation fits") };

/// A zone of one offset for all time, abbreviated as RFC 9557 writes it (`+05:30`, `-00:00:30`).
pub fn fixed(offset: Offset) TimeZone {
    const s = offset.seconds.raw();
    const a: u32 = @abs(s);
    var buffer: [posix_rule.max_abbreviation]u8 = undefined;
    const text = if (a % 60 == 0)
        std.mem.print(&buffer, "{c}{d:0>2}:{d:0>2}", .{ @as(u8, if (s < 0) '-' else '+'), a / 3600, (a / 60) % 60 }) catch aegis.assert.never("an offset under a day writes in an abbreviation's room")
    else
        std.mem.print(&buffer, "{c}{d:0>2}:{d:0>2}:{d:0>2}", .{ @as(u8, if (s < 0) '-' else '+'), a / 3600, (a / 60) % 60, a % 60 }) catch aegis.assert.never("an offset under a day writes in an abbreviation's room");
    return .{ .initial = Local.init(offset, false, text) catch aegis.assert.never("an offset's name fits an abbreviation") };
}

/// The zone a POSIX TZ string describes (`EST5EDT,M3.2.0,M11.1.0`). Daylight saving time without
/// a rule is refused rather than given an implementation's default.
pub fn posix(text: aegis.input.Untrusted([]const u8)) PosixError!TimeZone {
    const rule = try posix_rule.parse(text.readForParse());
    return .{ .initial = rule.std, .footer = rule };
}

/// The zone a TZif file describes, its tables and `iana_name` copied into `gpa`; `free` returns them.
pub fn fromTzif(gpa: Allocator, bytes: aegis.input.Untrusted([]const u8), iana_name: ?[]const u8) TzifError!TimeZone {
    var parsed = try tzif.parse(gpa, bytes.readForParse());
    errdefer parsed.deinit(gpa);
    const owned_name = if (iana_name) |n| try gpa.dupe(u8, n) else null;
    return .{
        .zone_name = owned_name,
        .initial = parsed.types[0],
        .transitions = parsed.transitions,
        .kinds = parsed.kinds,
        .types = parsed.types,
        .footer = parsed.footer,
        .gpa = gpa,
    };
}

/// Returns a file's tables to the allocator they came from; a no-op for any other zone.
pub fn free(zone: *TimeZone) void {
    const gpa = zone.gpa orelse return;
    gpa.free(zone.transitions);
    gpa.free(zone.kinds);
    gpa.free(zone.types);
    if (zone.zone_name) |n| gpa.free(n);
    zone.* = undefined;
}

pub fn name(zone: *const TimeZone) ?[]const u8 {
    return zone.zone_name;
}

/// The index of the last transition at or before `seconds`, the zone having one there.
fn search(zone: *const TimeZone, seconds: i64, cursor: ?*Cursor) usize {
    const t = zone.transitions;
    if (cursor) |c| {
        for ([_]usize{ c.index, c.index +% 1 }) |i| {
            if (i < t.len and t[i] <= seconds and (i + 1 == t.len or seconds < t[i + 1])) {
                c.index = i;
                return i;
            }
        }
    }
    var low: usize = 0;
    var high: usize = t.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (t[mid] <= seconds) low = mid + 1 else high = mid;
    }
    if (cursor) |c| c.index = low - 1;
    return low - 1;
}

/// The local time type in force at `seconds` since 1970.
fn localAt(zone: *const TimeZone, seconds: i64, cursor: ?*Cursor) *const Local {
    const t = zone.transitions;
    if (t.len == 0 or seconds < t[0]) {
        if (t.len == 0) if (zone.footer) |*f| return f.at(seconds);
        return &zone.initial;
    }
    const i = zone.search(seconds, cursor);
    if (i == t.len - 1 and seconds > t[i]) if (zone.footer) |*f| return f.at(seconds);
    return &zone.types[zone.kinds[i]];
}

/// The zone's table counts whole seconds since 1970, as TZif files and POSIX rules do.
const Seconds = aegis.units.Duration(.second, i64);
const Epoch = arithmetic.Epoch;

/// The second since 1970 a place on the timeline falls in.
fn floorSeconds(at: Epoch) i64 {
    return (at.sinceEpoch().convert(.second, i64, .down) catch aegis.assert.never("the seconds of an instant near almanac's range fit an i64")).raw();
}

/// The first second since 1970 at or after a place on the timeline.
fn ceilSeconds(at: Epoch) i64 {
    return (at.sinceEpoch().convert(.second, i64, .up) catch aegis.assert.never("the seconds of an instant near almanac's range fit an i64")).raw();
}

/// The second `seconds` since 1970 on the timeline.
fn atSeconds(seconds: i64) Epoch {
    return .fromSinceEpoch(Seconds.fromRaw(seconds).convert(.nanosecond, i128, .exact));
}

fn secondsOf(at: anytype) RangeError!i64 {
    return floorSeconds(try instant.inside(at));
}

fn info(l: *const Local) Info {
    return .{ .offset = l.offset, .dst = l.dst, .abbreviation = l.abbreviation() };
}

/// The zone's offset at any real instant inside almanac's range.
pub fn offsetAt(zone: *const TimeZone, at: anytype) RangeError!Offset {
    return zone.localAt(try secondsOf(at), null).offset;
}

/// `offsetAt` with the caller's hint.
pub fn offsetAtCursor(zone: *const TimeZone, cursor: *Cursor, at: anytype) RangeError!Offset {
    return zone.localAt(try secondsOf(at), cursor).offset;
}

/// The offset, daylight saving and abbreviation in force at an instant.
pub fn infoAt(zone: *const TimeZone, at: anytype) RangeError!Info {
    return info(zone.localAt(try secondsOf(at), null));
}

/// The instants at which the zone's wall clock reads a given civil time: none where the zone skips
/// it (a gap), two where it repeats it (a fold), one otherwise. Earliest first.
pub const Candidates = struct {
    /// How many there are. More than two is possible only for a zone whose offset changes several
    /// times within two days (no real zone's does); `instants` keeps the first four.
    count: usize = 0,
    /// Places on the timeline.
    instants: [4]Epoch = undefined,

    pub fn slice(c: *const Candidates) []const Epoch {
        return c.instants[0..@min(c.count, c.instants.len)];
    }

    pub fn earliest(c: *const Candidates) ?Epoch {
        return if (c.count == 0) null else c.instants[0];
    }

    pub fn latest(c: *const Candidates) ?Epoch {
        return if (c.count == 0) null else c.instants[@min(c.count, c.instants.len) - 1];
    }
};

/// The candidates for a wall clock given as nanoseconds since 1970 read as if UTC. Each offset in
/// force within two days either side (an offset is under 26 hours) is tried: the wall clock less
/// it is a candidate where that offset is the one in force there.
pub fn candidatesAt(zone: *const TimeZone, local: Epoch) Candidates {
    const day: i64 = (arithmetic.one_day.convert(.second, i64, .exact) catch aegis.assert.never("a day is whole seconds")).raw();
    const centre = floorSeconds(local);
    var offsets: [66]Offset = undefined;
    var n: usize = 0;
    var at = centre - 2 * day;
    offsets[n] = zone.localAt(at, null).offset;
    n += 1;
    // The changes within the window; a zone with more than 64 in four days has the rest passed over.
    while (n < offsets.len) {
        at = zone.nextSeconds(at) orelse break;
        if (at > centre + 2 * day) break;
        offsets[n] = zone.localAt(at, null).offset;
        n += 1;
    }
    var c: Candidates = .{};
    var found: [66]Epoch = undefined;
    var count: usize = 0;
    for (offsets[0..n], 0..) |o, i| {
        const seen = for (offsets[0..i]) |earlier| {
            if (earlier.eql(o)) break true;
        } else false;
        if (seen) continue;
        const candidate = local.sub(o.nanoseconds()) catch aegis.assert.never("a wall clock near almanac's range less an offset fits an i128");
        if (zone.localAt(floorSeconds(candidate), null).offset.eql(o)) {
            found[count] = candidate;
            count += 1;
        }
    }
    std.mem.sort(Epoch, found[0..count], {}, struct {
        fn earlier(_: void, a: Epoch, b: Epoch) bool {
            return a.compare(b) == .lt;
        }
    }.earlier);
    c.count = count;
    for (found[0..@min(count, c.instants.len)], 0..) |f, i| c.instants[i] = f;
    if (count > c.instants.len) c.instants[c.instants.len - 1] = found[count - 1];
    return c;
}

/// The candidates for a civil date and time in the zone.
pub fn candidates(zone: *const TimeZone, dt: DateTime) Candidates {
    return zone.candidatesAt((arithmetic.IsoDateTime{ .date = dt.date.iso(), .time = dt.time.sinceMidnight() }).epochNs());
}

/// The offset in force at a place on the timeline, inside or outside almanac's range.
pub fn offsetAtNanoseconds(zone: *const TimeZone, at: Epoch) Offset {
    return zone.localAt(floorSeconds(at), null).offset;
}

/// The first change of offset after a place on the timeline.
pub fn nextChange(zone: *const TimeZone, after: Epoch) ?Epoch {
    return atSeconds(zone.nextSeconds(floorSeconds(after)) orelse return null);
}

fn transitionAt(zone: *const TimeZone, seconds: ?i64) ?Transition {
    const s = seconds orelse return null;
    const at = instant.checked(atSeconds(s)) catch return null;
    return .{ .at = instant.timestamp(at) catch return null, .info = info(zone.localAt(s, null)) };
}

/// The first instant after `after` at which the zone's offset changes (Temporal's
/// `getTimeZoneTransition("next")`: a change of abbreviation or daylight saving alone is none), if
/// there is one inside almanac's range.
pub fn nextTransition(zone: *const TimeZone, after: anytype) RangeError!?Transition {
    return zone.transitionAt(zone.nextSeconds(try secondsOf(after)));
}

/// The last instant before `before` at which the zone's offset changed, if there is one inside
/// almanac's range.
pub fn previousTransition(zone: *const TimeZone, before: anytype) RangeError!?Transition {
    return zone.transitionAt(zone.previousSeconds(ceilSeconds(try instant.inside(before))));
}

fn nextSeconds(zone: *const TimeZone, seconds: i64) ?i64 {
    const t = zone.transitions;
    if (t.len > 0 and seconds < t[t.len - 1]) {
        const before = zone.localAt(seconds, null).offset;
        var i: usize = if (seconds < t[0]) 0 else zone.search(seconds, null) + 1;
        while (i < t.len) : (i += 1) {
            if (!zone.types[zone.kinds[i]].offset.eql(before)) return t[i];
        }
    }
    const f = &(zone.footer orelse return null);
    return f.next(if (t.len > 0) @max(seconds, t[t.len - 1]) else seconds);
}

fn previousSeconds(zone: *const TimeZone, seconds: i64) ?i64 {
    const t = zone.transitions;
    if (zone.footer) |*f| {
        if (t.len == 0 or seconds > t[t.len - 1]) {
            if (f.previous(seconds)) |p| if (t.len == 0 or p > t[t.len - 1]) return p;
        }
    }
    // The transitions before `seconds`, latest first.
    var i: usize = if (t.len == 0 or seconds <= t[0]) 0 else zone.search(seconds - 1, null) + 1;
    while (i > 0) {
        i -= 1;
        const before = if (i == 0) &zone.initial else &zone.types[zone.kinds[i - 1]];
        if (!zone.types[zone.kinds[i]].offset.eql(before.offset)) return t[i];
    }
    return null;
}
