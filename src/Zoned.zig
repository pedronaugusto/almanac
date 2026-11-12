//! An instant in a zone: Temporal's `ZonedDateTime`. It holds the instant, the zone it is read in
//! (borrowed: the caller keeps the zone, or its `Database` handle, alive while the value is used)
//! and the offset in force there. Arithmetic follows Temporal: calendar units (days among them)
//! through the zone's wall clock, time units on the timeline.
const Zoned = @This();
const std = @import("std");
const units = @import("units.zig");
const arithmetic = @import("arithmetic.zig");
const rounding = @import("round.zig");
const instant = @import("instant.zig");
const resolve = @import("resolve.zig");
const TimeZone = @import("TimeZone.zig");
const Span = @import("Span.zig");
const Date = @import("Date.zig");
const Time = @import("Time.zig");
const DateTime = @import("DateTime.zig");
const write = @import("text/write.zig");
const Offset = units.Offset;
const Unit = units.Unit;
const Timestamp = instant.Timestamp;

pub const RangeError = units.RangeError;
pub const DifferenceError = units.DifferenceError;
pub const ArithmeticError = units.ArithmeticError;
pub const ResolveError = resolve.ResolveError;
pub const OffsetError = resolve.OffsetError;

timestamp: Timestamp,
zone: *const TimeZone,
offset: Offset,

const ns_per_day: i128 = std.time.ns_per_day;

/// The instant in `zone`, refused where its wall clock there falls outside almanac's calendar.
pub fn init(at: anytype, zone: *const TimeZone) RangeError!Zoned {
    return fromNanoseconds(try instant.epochNanoseconds(at), zone);
}

fn fromNanoseconds(ns: i128, zone: *const TimeZone) RangeError!Zoned {
    const t: Timestamp = .fromRaw(@intCast(try resolve.checked(ns)));
    const offset = try zone.offsetAt(t);
    _ = try instant.toDateTime(t, offset);
    return .{ .timestamp = t, .zone = zone, .offset = offset };
}

/// The civil date and time in `zone`, resolved by `disambiguation` where the zone skips or repeats it.
pub fn fromDateTime(dt: DateTime, zone: *const TimeZone, disambiguation: units.Disambiguation) ResolveError!Zoned {
    return fromNanoseconds(try resolve.resolve(zone, dt, disambiguation), zone);
}

/// The civil date and time written with an offset, in `zone`, the written offset weighed against
/// the zone's by `conflict` (`resolve.resolveWithOffset`).
pub fn fromDateTimeOffset(dt: DateTime, offset: Offset, zone: *const TimeZone, conflict: units.OffsetConflict, disambiguation: units.Disambiguation) OffsetError!Zoned {
    return fromNanoseconds(try resolve.resolveWithOffset(zone, dt, offset, conflict, disambiguation, false), zone);
}

fn nanoseconds(z: Zoned) i128 {
    return z.timestamp.raw();
}

/// The wall clock: the civil date and time in the zone.
pub fn dateTime(z: Zoned) DateTime {
    // Checked when the value was made.
    return instant.toDateTime(z.timestamp, z.offset) catch unreachable;
}

/// The offset, daylight saving and abbreviation in force.
pub fn info(z: Zoned) TimeZone.Info {
    return z.zone.infoAt(z.timestamp) catch unreachable;
}

pub fn order(a: Zoned, b: Zoned) std.math.Order {
    return std.math.order(a.nanoseconds(), b.nanoseconds());
}

/// The same instant and an equal zone.
pub fn eql(a: Zoned, b: Zoned) bool {
    return a.nanoseconds() == b.nanoseconds() and sameZone(a.zone, b.zone);
}

fn sameZone(a: *const TimeZone, b: *const TimeZone) bool {
    if (a == b) return true;
    const an = a.name() orelse return false;
    const bn = b.name() orelse return false;
    return std.mem.eql(u8, an, bn);
}

fn wallClockOf(context: *const anyopaque, ns: i128) RangeError!arithmetic.IsoDateTime {
    const zone: *const TimeZone = @ptrCast(@alignCast(context));
    const local = ns + @as(i128, zone.offsetAtNanoseconds(ns)) * std.time.ns_per_s;
    const days = @divFloor(local, ns_per_day);
    if (!arithmetic.inRange(@intCast(days))) return error.OutOfRange;
    return .{ .date = arithmetic.fromEpochDays(@intCast(days)), .time = @intCast(@mod(local, ns_per_day)) };
}

fn instantOf(context: *const anyopaque, dt: arithmetic.IsoDateTime) RangeError!i128 {
    const zone: *const TimeZone = @ptrCast(@alignCast(context));
    return resolve.resolveWallClock(zone, dt.epochNs(), .compatible) catch |err| switch (err) {
        error.OutOfRange => error.OutOfRange,
        // `.compatible` neither refuses a gap nor a fold.
        error.Skipped, error.Ambiguous => unreachable,
    };
}

fn hooks(zone: *const TimeZone) arithmetic.Zone {
    return .{ .context = zone, .wall_clock = wallClockOf, .instant_of = instantOf };
}

/// The value as what gives a span's calendar units their lengths (Temporal's `relativeTo`): days
/// as the zone makes them, 23 or 25 hours across a change of offset.
pub fn relativeTo(z: Zoned) Span.RelativeTo {
    return .{ .zoned = .{ .ns = z.nanoseconds(), .zone = hooks(z.zone) } };
}

/// Temporal's `ZonedDateTime.prototype.add`: years, months, weeks and days added to the wall clock
/// (the day regulated by `overflow`) and resolved `.compatible`, then hours and smaller on the
/// timeline.
pub fn add(z: Zoned, span: Span, overflow: units.Overflow) ArithmeticError!Zoned {
    const ns = try arithmetic.zonedAdd(hooks(z.zone), z.nanoseconds(), try span.toInternal(), overflow);
    return fromNanoseconds(ns, z.zone);
}

pub fn subtract(z: Zoned, span: Span, overflow: units.Overflow) ArithmeticError!Zoned {
    return z.add(span.negate(), overflow);
}

/// Temporal's `ZonedDateTime.prototype.until`: up to `options.largest` (the hour by default). In
/// time units it is the instants' difference; in date units, whole days by the wall clock in the
/// zone the two share (refused as `InvalidOptions` where the zones differ), then the time left.
pub fn until(z: Zoned, other: Zoned, options: units.Difference) DifferenceError!Span {
    return z.difference(.until, other, options);
}

/// Temporal's `ZonedDateTime.prototype.since`: `until`'s difference, rounded with the mode
/// negated, then negated.
pub fn since(z: Zoned, other: Zoned, options: units.Difference) DifferenceError!Span {
    return z.difference(.since, other, options);
}

fn difference(z: Zoned, operation: arithmetic.Operation, other: Zoned, options: units.Difference) DifferenceError!Span {
    var o = options;
    if (o.largest == null) o.largest = arithmetic.larger(.hour, o.smallest orelse .nanosecond);
    const r = try arithmetic.differenceSettings(operation, o, false);
    if (!arithmetic.isDate(r.largest)) {
        return if (operation == .until) instant.until(z.timestamp, other.timestamp, o) else instant.since(z.timestamp, other.timestamp, o);
    }
    if (!sameZone(z.zone, other.zone)) return error.InvalidOptions;
    if (z.nanoseconds() == other.nanoseconds()) return .zero;
    const result = try arithmetic.zonedUntilRounded(hooks(z.zone), z.nanoseconds(), other.nanoseconds(), r);
    const span = try Span.fromInternal(result, .hour);
    return if (operation == .since) span.negate() else span;
}

pub const Round = struct {
    /// The day or a time unit.
    smallest: Unit,
    /// For a time unit, a divisor of the unit above, less than it; for the day, 1.
    increment: u32 = 1,
    mode: units.RoundingMode = .half_expand,
};

/// Temporal's `ZonedDateTime.prototype.round`: to the day by the day's own length in the zone
/// (from its start to the next day's), or a time unit by the wall clock, resolved again keeping
/// the offset where it still applies.
pub fn round(z: Zoned, options: Round) DifferenceError!Zoned {
    if (arithmetic.isCalendar(options.smallest)) return error.InvalidOptions;
    if (options.smallest == .day) {
        if (options.increment != 1) return error.InvalidOptions;
    } else try arithmetic.checkIncrement(options.increment, options.smallest);
    if (options.smallest == .nanosecond and options.increment == 1) return z;
    const dt = z.dateTime();
    if (options.smallest == .day) {
        const start = try resolve.startOfDay(z.zone, dt.date);
        const next = Date.fromDays(dt.date.days() + 1) catch return error.OutOfRange;
        const end = try resolve.startOfDay(z.zone, next);
        const rounded = rounding.toIncrementAsIfPositive(z.nanoseconds() - start, end - start, options.mode);
        return fromNanoseconds(start + rounded, z.zone);
    }
    const length = arithmetic.nanoseconds(options.smallest) * options.increment;
    const time = rounding.toIncrement(dt.time.nanosecondOfDay(), length, options.mode);
    const days = dt.date.days() + @as(i32, @intCast(@divFloor(time, ns_per_day)));
    const rounded: DateTime = .{
        .date = Date.fromDays(days) catch return error.OutOfRange,
        .time = Time.fromNanosecondOfDay(@intCast(@mod(time, ns_per_day))) catch unreachable,
    };
    const ns = resolve.resolveWithOffset(z.zone, rounded, z.offset, .prefer, .compatible, false) catch |err| switch (err) {
        error.OutOfRange => return error.OutOfRange,
        error.Skipped, error.Ambiguous, error.OffsetConflict => unreachable,
    };
    return fromNanoseconds(ns, z.zone);
}

/// The first instant of the value's date in its zone (midnight, or where the zone skips midnight,
/// the instant it skips to).
pub fn startOfDay(z: Zoned) RangeError!Zoned {
    return fromNanoseconds(try resolve.startOfDay(z.zone, z.dateTime().date), z.zone);
}

/// The length of the value's day in its zone, in hours (23 or 25 across a change of offset).
pub fn hoursInDay(z: Zoned) RangeError!Span {
    const date = z.dateTime().date;
    const start = try resolve.startOfDay(z.zone, date);
    const end = try resolve.startOfDay(z.zone, Date.fromDays(date.days() + 1) catch return error.OutOfRange);
    return Span.fromInternal(.{ .time = end - start }, .hour);
}

/// The most bytes `format` writes: the date and time, an offset, and a bracketed zone name of up to
/// 255 bytes.
pub const max_text_len = DateTime.max_text_len + 6 + 2 + 255;

/// RFC 9557's form, as Temporal writes it: `2026-10-31T09:00:00+00:00[Europe/Lisbon]`, the offset
/// rounded to the minute, then the zone's IANA name, or a fixed zone's offset. A zone with neither
/// (a POSIX string) has no annotation RFC 9557 can write, so none is written.
pub fn format(z: Zoned, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try z.dateTime().format(w);
    const seconds = z.offset.seconds.raw();
    try write.offset(w, @intCast(rounding.toIncrement(seconds, 60, .half_expand)));
    if (z.zone.name()) |n| {
        try w.print("[{s}]", .{n});
    } else if (z.zone.transitions.len == 0 and z.zone.footer == null) {
        try w.writeByte('[');
        try write.offset(w, @intCast(rounding.toIncrement(seconds, 60, .half_expand)));
        try w.writeByte(']');
    }
}
