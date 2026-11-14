//! Instants. almanac's `Timestamp` is aegis's `Instant(.real, .nanosecond, i96)`, not a wrapper, and
//! every operation here takes any aegis instant of the real clock, at its own unit and
//! representation, read through its `aegis_scalar` declaration: chronicle's `Time` (milliseconds in
//! an `i64`), a `u64` count of seconds and a `Timestamp` meet without a conversion layer. An instant
//! of another clock (`.awake`, `.boot`) names no civil time and does not compile here.
//!
//! The range is almanac's calendar's, in UTC: -9999-01-01T00:00:00Z to 9999-12-31T23:59:59.999999999Z.
//! Arithmetic is Temporal's `Instant`'s: rounding on the timeline (a mode's direction ignores the
//! sign), differences in time units only, and spans of time units added.
const std = @import("std");
const aegis = @import("aegis");
const units = @import("units.zig");
const calendar = @import("calendar.zig");
const arithmetic = @import("arithmetic.zig");
const rounding = @import("round.zig");
const Date = @import("Date.zig");
const Time = @import("Time.zig");
const DateTime = @import("DateTime.zig");
const Span = @import("Span.zig");
const Unit = units.Unit;
const Offset = units.Offset;

pub const RangeError = units.RangeError;
pub const DifferenceError = units.DifferenceError;
pub const ArithmeticError = units.ArithmeticError;

/// Nanoseconds since 1970-01-01T00:00:00Z on the real clock: aegis's own type, so a `Timestamp` is
/// what `aegis.units.Instant(.real, .nanosecond, i96)` is everywhere in the family.
pub const Timestamp = aegis.units.Instant(.real, .nanosecond, i96);
/// An exact duration in nanoseconds.
pub const Exact = aegis.units.Duration(.nanosecond, i96);

const ns_per_day = arithmetic.ns_per_day;
const min_ns: i128 = @as(i128, calendar.min_days) * ns_per_day;
const max_ns: i128 = (@as(i128, calendar.max_days) + 1) * ns_per_day - 1;

/// The first and last instants almanac's calendar covers.
pub const min: Timestamp = .fromRaw(min_ns);
pub const max: Timestamp = .fromRaw(max_ns);

/// Refuses at compile time anything but an aegis instant of the real clock.
pub fn check(comptime T: type) void {
    comptime {
        if (!(@typeInfo(T) == .@"enum" or @typeInfo(T) == .@"struct") or !@hasDecl(T, "aegis_scalar"))
            @compileError("almanac takes an aegis instant of the real clock: " ++ @typeName(T) ++ " is no aegis scalar");
        const scalar = T.aegis_scalar;
        if (scalar.kind != .instant)
            @compileError("almanac takes an aegis instant of the real clock: " ++ @typeName(T) ++ " is an aegis " ++ @tagName(scalar.kind) ++ ", no instant");
        if (!std.mem.eql(u8, @tagName(scalar.clock), "real"))
            @compileError("almanac takes an instant of the real clock: " ++ @typeName(T) ++ " is of the " ++ @tagName(scalar.clock) ++ " clock, which names no civil time");
    }
}

fn step(comptime T: type) i128 {
    return T.aegis_scalar.unit.nanoseconds();
}

/// The instant's nanoseconds since 1970, or null past what an `i128` holds.
fn nanoseconds(instant: anytype) ?i128 {
    const T = @TypeOf(instant);
    comptime check(T);
    const wide = std.math.cast(i128, instant.raw()) orelse return null;
    return std.math.mul(i128, wide, step(T)) catch null;
}

/// The instant's nanoseconds since 1970, inside almanac's range.
fn inside(instant: anytype) RangeError!i128 {
    const ns = nanoseconds(instant) orelse return error.OutOfRange;
    return if (ns < min_ns or ns > max_ns) error.OutOfRange else ns;
}

/// An instant of type `T` at `ns`, which is a whole number of `T`'s unit.
fn fromNanoseconds(comptime T: type, ns: i128) RangeError!T {
    aegis.assert.invariant(@mod(ns, step(T)) == 0, "@mod(ns, step(T)) == 0");
    return T.fromRaw(std.math.cast(T.aegis_scalar.representation, @divExact(ns, step(T))) orelse return error.OutOfRange);
}

/// Nanoseconds since 1970-01-01T00:00:00Z of any real instant inside almanac's range.
pub fn epochNanoseconds(instant: anytype) RangeError!i128 {
    return inside(instant);
}

/// The real clock's instant now.
pub fn now(io: std.Io) Timestamp {
    return Timestamp.fromTimestamp(std.Io.Clock.real.now(io), .exact);
}

/// Whether the instant lies inside almanac's calendar.
pub fn inRange(instant: anytype) bool {
    _ = inside(instant) catch return false;
    return true;
}

/// The instant as a `Timestamp`, exactly: every real instant inside almanac's range has one.
pub fn timestamp(instant: anytype) RangeError!Timestamp {
    return .fromRaw(@intCast(try inside(instant)));
}

/// The instant as an instant of type `T` (another real-clock unit or representation), rounded on
/// the timeline by `mode` where `T`'s unit is coarser; refused where `T` cannot hold it.
pub fn convert(comptime T: type, instant: anytype, mode: units.RoundingMode) RangeError!T {
    comptime check(T);
    const ns = try inside(instant);
    return fromNanoseconds(T, rounding.toIncrementAsIfPositive(ns, step(T), mode));
}

/// The civil date and time at `offset` from UTC of an instant (UTC for `Offset.utc`), refused where
/// it falls outside almanac's calendar (the last instant at +01:00 is in the year 10000).
pub fn toDateTime(instant: anytype, offset: Offset) RangeError!DateTime {
    const local = try inside(instant) + @as(i128, offset.seconds.raw()) * std.time.ns_per_s;
    const days = @divFloor(local, ns_per_day);
    if (days < calendar.min_days or days > calendar.max_days) return error.OutOfRange;
    return .{
        .date = Date.fromDays(@intCast(days)) catch aegis.assert.never("an instant in range, at an offset under a day, falls on a date in range"),
        .time = Time.fromNanosecondOfDay(@intCast(@mod(local, ns_per_day))) catch aegis.assert.never("a count taken modulo a day is a time of day"),
    };
}

/// The instant at which the civil date and time at `offset` from UTC is `dt`, refused outside
/// almanac's range.
pub fn fromDateTime(dt: DateTime, offset: Offset) RangeError!Timestamp {
    const local = @as(i128, dt.date.days()) * ns_per_day + dt.time.nanosecondOfDay();
    const ns = local - @as(i128, offset.seconds.raw()) * std.time.ns_per_s;
    if (ns < min_ns or ns > max_ns) return error.OutOfRange;
    return .fromRaw(@intCast(ns));
}

pub const Round = struct {
    /// A time unit, the hour at most.
    smallest: Unit,
    /// A multiple of `smallest` that divides a day evenly.
    increment: u32 = 1,
    mode: units.RoundingMode = .half_expand,
};

/// Temporal's `Instant.prototype.round`: to a multiple of `increment` in `smallest`, counted from
/// 1970 on the timeline (so `.trunc` before 1970 goes back, as `.floor`). The result is of the
/// instant's own type; a length neither a multiple nor a divisor of that type's unit (1500
/// milliseconds on an instant counted in seconds) is refused as `InvalidOptions`.
pub fn round(instant: anytype, options: Round) DifferenceError!@TypeOf(instant) {
    const T = @TypeOf(instant);
    if (arithmetic.isDate(options.smallest)) return error.InvalidOptions;
    // ValidateTemporalRoundingIncrement against a day's length in the unit, inclusive.
    const per_day: i128 = @divExact(ns_per_day, arithmetic.nanoseconds(options.smallest));
    if (options.increment < 1 or options.increment > per_day or @mod(per_day, options.increment) != 0) return error.InvalidOptions;
    const length = arithmetic.nanoseconds(options.smallest) * options.increment;
    // A multiple of the type's unit, or a divisor of it (where rounding changes nothing).
    if (@mod(length, step(T)) != 0 and @mod(step(T), length) != 0) return error.InvalidOptions;
    const rounded = rounding.toIncrementAsIfPositive(try inside(instant), length, options.mode);
    if (rounded > max_ns) return error.OutOfRange;
    return fromNanoseconds(T, rounded);
}

/// Temporal's `Instant.prototype.until`: the span from `a` to `b` in time units up to
/// `options.largest` (the second by default), rounded to `options.smallest` (the nanosecond by
/// default). Days and calendar units are refused: an instant has no calendar.
pub fn until(a: anytype, b: anytype, options: units.Difference) DifferenceError!Span {
    return difference(.until, try inside(a), try inside(b), options);
}

/// Temporal's `Instant.prototype.since`: `until`'s difference from `a` to `b`, rounded with the
/// mode negated, then negated.
pub fn since(a: anytype, b: anytype, options: units.Difference) DifferenceError!Span {
    return difference(.since, try inside(a), try inside(b), options);
}

fn difference(operation: arithmetic.Operation, a: i128, b: i128, options: units.Difference) DifferenceError!Span {
    if (options.largest) |u| if (arithmetic.isDate(u)) return error.InvalidOptions;
    if (options.smallest) |u| if (arithmetic.isDate(u)) return error.InvalidOptions;
    const smallest = options.smallest orelse Unit.nanosecond;
    const largest = options.largest orelse arithmetic.larger(.second, smallest);
    if (arithmetic.larger(largest, smallest) != largest) return error.InvalidOptions;
    try arithmetic.checkIncrement(options.increment, smallest);
    const mode = if (operation == .since) rounding.negate(options.mode) else options.mode;
    const time = try arithmetic.checkTime(rounding.toIncrement(b - a, arithmetic.nanoseconds(smallest) * options.increment, mode));
    const span = try Span.fromInternal(.{ .time = time }, largest);
    return if (operation == .since) span.negate() else span;
}

/// Temporal's `Instant.prototype.add`: a span of time units (hours at most; days and calendar units
/// have no fixed length on a timeline and are refused as `CalendarUnits`). The result is a
/// `Timestamp`, exact; `convert` takes it to a coarser type under an explicit rounding.
pub fn add(instant: anytype, span: Span) ArithmeticError!Timestamp {
    if (arithmetic.isDate(span.largestUnit())) return error.CalendarUnits;
    const ns = try inside(instant) + (try span.toInternal()).time;
    if (ns < min_ns or ns > max_ns) return error.OutOfRange;
    return .fromRaw(@intCast(ns));
}

pub fn subtract(instant: anytype, span: Span) ArithmeticError!Timestamp {
    return add(instant, span.negate());
}
