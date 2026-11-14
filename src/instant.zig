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

const Ns = arithmetic.Ns;
const Epoch = arithmetic.Epoch;

/// The first and last instants almanac's calendar covers, on the wide timeline.
const min_epoch: Epoch = .fromSinceEpoch(arithmetic.one_day.mul(calendar.min_days) catch aegis.assert.never("almanac's days fit an i128 of nanoseconds"));
const max_epoch: Epoch = .fromSinceEpoch(((arithmetic.one_day.mul(@as(i128, calendar.max_days) + 1) catch aegis.assert.never("almanac's days fit an i128 of nanoseconds")).sub(.fromRaw(1))) catch aegis.assert.never("the last day's end less a nanosecond is no overflow"));

/// A place on the wide timeline as a `Timestamp`, where it fits one.
fn narrow(at: Epoch) RangeError!Timestamp {
    return .fromSinceEpoch(at.sinceEpoch().convert(.nanosecond, i96, .exact) catch return error.OutOfRange);
}

/// The first and last instants almanac's calendar covers.
pub const min: Timestamp = narrow(min_epoch) catch aegis.assert.never("almanac's range fits a Timestamp");
pub const max: Timestamp = narrow(max_epoch) catch aegis.assert.never("almanac's range fits a Timestamp");

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

/// The unit `T` counts in: an instant of any aegis copy names it in its `aegis_scalar`.
fn unitOf(comptime T: type) aegis.units.Unit {
    return @field(aegis.units.Unit, @tagName(T.aegis_scalar.unit));
}

/// One tick of `T`'s unit.
fn step(comptime T: type) Ns {
    return arithmetic.toNs(unitOf(T), .fromRaw(1));
}

/// The instant on the wide timeline, or null past what it holds. An instant of another aegis copy
/// is read through its scalar contract: its count of its own unit since 1970.
fn wide(instant: anytype) ?Epoch {
    const T = @TypeOf(instant);
    comptime check(T);
    const count = std.math.cast(i128, instant.raw()) orelse return null;
    const counted = aegis.units.Duration(unitOf(T), i128).fromRaw(count);
    if (comptime unitOf(T) == .nanosecond) return .fromSinceEpoch(counted);
    return .fromSinceEpoch(counted.convert(.nanosecond, i128, .exact) catch return null);
}

/// The instant on the wide timeline, inside almanac's range.
pub fn inside(instant: anytype) RangeError!Epoch {
    return checked(wide(instant) orelse return error.OutOfRange);
}

/// `at` where it lies inside almanac's range.
pub fn checked(at: Epoch) RangeError!Epoch {
    return if (at.compare(min_epoch) == .lt or at.compare(max_epoch) == .gt) error.OutOfRange else at;
}

/// An instant of type `T` at `at`, which is a whole number of `T`'s unit from 1970.
fn fromNanoseconds(comptime T: type, at: Epoch) RangeError!T {
    const elapsed = at.sinceEpoch();
    aegis.assert.invariant((elapsed.mod(step(T)) catch aegis.assert.never("a unit has some length")).eql(arithmetic.zero), "the instant is a whole number of the type's unit");
    const count = elapsed.ratio(step(T)) catch aegis.assert.never("a unit has some length");
    return T.fromRaw(std.math.cast(T.aegis_scalar.representation, count) orelse return error.OutOfRange);
}

/// Nanoseconds since 1970-01-01T00:00:00Z of any real instant inside almanac's range.
pub fn epochNanoseconds(instant: anytype) RangeError!i128 {
    return (try inside(instant)).sinceEpoch().raw();
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
    return narrow(try inside(instant));
}

/// The instant as an instant of type `T` (another real-clock unit or representation), rounded on
/// the timeline by `mode` where `T`'s unit is coarser; refused where `T` cannot hold it.
pub fn convert(comptime T: type, instant: anytype, mode: units.RoundingMode) RangeError!T {
    comptime check(T);
    const elapsed = (try inside(instant)).sinceEpoch();
    return fromNanoseconds(T, .fromSinceEpoch(try rounding.toIncrementAsIfPositiveNs(elapsed, step(T), mode)));
}

/// The civil date and time at `offset` from UTC of an instant (UTC for `Offset.utc`), refused where
/// it falls outside almanac's calendar (the last instant at +01:00 is in the year 10000).
pub fn toDateTime(instant: anytype, offset: Offset) RangeError!DateTime {
    const local = (try inside(instant)).add(offset.nanoseconds()) catch return error.OutOfRange;
    const days = local.sinceEpoch().ratioFloor(arithmetic.one_day) catch aegis.assert.never("a day has some length");
    if (days < calendar.min_days or days > calendar.max_days) return error.OutOfRange;
    return .{
        .date = Date.fromDays(@intCast(days)) catch aegis.assert.never("an instant in range, at an offset under a day, falls on a date in range"),
        .time = Time.wrapped(local.sinceEpoch()),
    };
}

/// The instant at which the civil date and time at `offset` from UTC is `dt`, refused outside
/// almanac's range.
pub fn fromDateTime(dt: DateTime, offset: Offset) RangeError!Timestamp {
    const local = (arithmetic.IsoDateTime{ .date = dt.date.iso(), .time = dt.time.sinceMidnight() }).epochNs();
    return narrow(try checked(local.sub(offset.nanoseconds()) catch return error.OutOfRange));
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
    const per_day = arithmetic.one_day.ratio(arithmetic.length(options.smallest)) catch aegis.assert.never("a unit has some length");
    if (options.increment < 1 or options.increment > per_day or @mod(per_day, options.increment) != 0) return error.InvalidOptions;
    const length = arithmetic.lengthOf(options.smallest, options.increment);
    // A multiple of the type's unit, or a divisor of it (where rounding changes nothing).
    const multiple = (length.mod(step(T)) catch aegis.assert.never("a unit has some length")).eql(arithmetic.zero);
    const divisor = (step(T).mod(length) catch aegis.assert.never("an increment has some length")).eql(arithmetic.zero);
    if (!multiple and !divisor) return error.InvalidOptions;
    const rounded: Epoch = .fromSinceEpoch(try rounding.toIncrementAsIfPositiveNs((try inside(instant)).sinceEpoch(), length, options.mode));
    if (rounded.compare(max_epoch) == .gt) return error.OutOfRange;
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

fn difference(operation: arithmetic.Operation, a: Epoch, b: Epoch, options: units.Difference) DifferenceError!Span {
    if (options.largest) |u| if (arithmetic.isDate(u)) return error.InvalidOptions;
    if (options.smallest) |u| if (arithmetic.isDate(u)) return error.InvalidOptions;
    const smallest = options.smallest orelse Unit.nanosecond;
    const largest = options.largest orelse arithmetic.larger(.second, smallest);
    if (arithmetic.larger(largest, smallest) != largest) return error.InvalidOptions;
    try arithmetic.checkIncrement(options.increment, smallest);
    const mode = if (operation == .since) rounding.negate(options.mode) else options.mode;
    const elapsed = a.durationTo(b) catch return error.OutOfRange;
    const time = try arithmetic.checkTime(try rounding.toIncrementNs(elapsed, arithmetic.lengthOf(smallest, options.increment), mode));
    const span = try Span.fromInternal(.{ .time = time }, largest);
    return if (operation == .since) span.negate() else span;
}

/// Temporal's `Instant.prototype.add`: a span of time units (hours at most; days and calendar units
/// have no fixed length on a timeline and are refused as `CalendarUnits`). The result is a
/// `Timestamp`, exact; `convert` takes it to a coarser type under an explicit rounding.
pub fn add(instant: anytype, span: Span) ArithmeticError!Timestamp {
    if (arithmetic.isDate(span.largestUnit())) return error.CalendarUnits;
    const reached = (try inside(instant)).add((try span.toInternal()).time) catch return error.OutOfRange;
    return narrow(try checked(reached));
}

pub fn subtract(instant: anytype, span: Span) ArithmeticError!Timestamp {
    return add(instant, span.negate());
}
