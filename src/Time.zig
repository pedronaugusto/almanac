//! A civil time of day, 00:00:00 to 23:59:59.999999999, with no zone and no leap second.
const Time = @This();
const std = @import("std");
const aegis = @import("aegis");
const units = @import("units.zig");
const arithmetic = @import("arithmetic.zig");
const rounding = @import("round.zig");
const Span = @import("Span.zig");
const write = @import("text/write.zig");
const reading = @import("text/iso.zig");

hour: units.Hour = .literal(0),
minute: units.Minute = .literal(0),
second: units.Second = .literal(0),
nanosecond: units.Nanosecond = .literal(0),

pub const RangeError = units.RangeError;

pub const midnight: Time = .{};

pub const nanoseconds_per_day: u64 = (arithmetic.one_day.convert(.nanosecond, u64, .exact) catch aegis.assert.never("a day of nanoseconds fits a u64")).raw();
const Ns = arithmetic.Ns;

pub fn init(hour: u8, minute: u8, second: u8, nanosecond: u32) RangeError!Time {
    return .{ .hour = try .init(hour), .minute = try .init(minute), .second = try .init(second), .nanosecond = try .init(nanosecond) };
}

/// A field counted in `unit`, as nanoseconds.
fn inNs(comptime unit: aegis.units.Unit, field: anytype) Ns {
    return arithmetic.toNs(unit, .fromRanged(field));
}

/// The time since midnight.
pub fn sinceMidnight(t: Time) Ns {
    var out = inNs(.hour, t.hour);
    for ([_]Ns{ inNs(.minute, t.minute), inNs(.second, t.second), inNs(.nanosecond, t.nanosecond) }) |part| {
        out = out.add(part) catch aegis.assert.never("a time of day's fields sum to under a day");
    }
    return out;
}

/// The time `since` after midnight, within a day.
pub fn fromSinceMidnight(since_midnight: Ns) RangeError!Time {
    if (since_midnight.compare(arithmetic.zero) == .lt or since_midnight.compare(arithmetic.one_day) != .lt) return error.OutOfRange;
    var rest = since_midnight;
    var fields: [3]i128 = undefined;
    for ([_]units.Unit{ .hour, .minute, .second }, &fields) |unit, *field| {
        field.* = rest.ratio(arithmetic.length(unit)) catch aegis.assert.never("a unit has some length");
        rest = rest.mod(arithmetic.length(unit)) catch aegis.assert.never("a unit has some length");
    }
    const nanosecond = rest.convert(.nanosecond, u32, .exact) catch aegis.assert.never("what is left of a second fits a u32");
    return init(@intCast(fields[0]), @intCast(fields[1]), @intCast(fields[2]), nanosecond.raw()) catch aegis.assert.never("a length under a day is a time of day");
}

/// The time of day `d` lands on: `d` taken modulo a day.
pub fn wrapped(d: Ns) Time {
    const of_day = d.mod(arithmetic.one_day) catch aegis.assert.never("a day has some length");
    return fromSinceMidnight(of_day) catch aegis.assert.never("a length taken modulo a day is a time of day");
}

/// Nanoseconds since midnight.
pub fn nanosecondOfDay(t: Time) u64 {
    return (t.sinceMidnight().convert(.nanosecond, u64, .exact) catch aegis.assert.never("under a day of nanoseconds fits a u64")).raw();
}

/// The time `ns` nanoseconds after midnight, within a day.
pub fn fromNanosecondOfDay(ns: u64) RangeError!Time {
    return fromSinceMidnight(.fromRaw(ns));
}

pub fn order(a: Time, b: Time) std.math.Order {
    return a.sinceMidnight().compare(b.sinceMidnight());
}

pub fn eql(a: Time, b: Time) bool {
    return a.sinceMidnight().eql(b.sinceMidnight());
}

pub const max_text_len = write.time_len;

/// `09:00:00`, with the fraction of the second where there is one (`09:00:00.25`).
pub fn format(t: Time, w: *std.Io.Writer) std.Io.Writer.Error!void {
    return write.time(w, t.hour.raw(), t.minute.raw(), t.second.raw(), t.nanosecond.raw());
}

/// A time of day from text, as `text.parseTime` reads it.
pub fn parse(text: []const u8) reading.ParseError!Time {
    return fromText(text, .{});
}

pub fn fromText(text: []const u8, options: reading.Options) reading.ParseError!Time {
    return fromCivil(try reading.timeOfDay(text, options));
}

/// A time the reader checked.
pub fn fromCivil(c: reading.CivilTime) Time {
    return init(c.hour, c.minute, c.second, c.nanosecond) catch aegis.assert.never("the reader checked the time");
}

/// Temporal's `PlainTime.prototype.add`: the span's hours and smaller added, wrapping around
/// midnight; its years, months, weeks and days pass a time of day by.
pub fn add(t: Time, span: Span) RangeError!Time {
    const internal = try span.toInternal();
    return wrapped(t.sinceMidnight().add(internal.time) catch return error.OutOfRange);
}

pub fn subtract(t: Time, span: Span) RangeError!Time {
    return t.add(span.negate());
}

/// Temporal's `PlainTime.prototype.until`: the span from `t` to `other` the same day, in time units
/// up to `options.largest` (the hour by default), rounded as the options say.
pub fn until(t: Time, other: Time, options: units.Difference) units.DifferenceError!Span {
    return t.difference(.until, other, options);
}

/// Temporal's `PlainTime.prototype.since`: `until`'s difference, rounded with the mode negated,
/// then negated.
pub fn since(t: Time, other: Time, options: units.Difference) units.DifferenceError!Span {
    return t.difference(.since, other, options);
}

fn difference(t: Time, operation: arithmetic.Operation, other: Time, options: units.Difference) units.DifferenceError!Span {
    if (options.largest) |u| if (arithmetic.isDate(u)) return error.InvalidOptions;
    if (options.smallest) |u| if (arithmetic.isDate(u)) return error.InvalidOptions;
    var o = options;
    if (o.largest == null) o.largest = arithmetic.larger(.hour, o.smallest orelse .nanosecond);
    const r = try arithmetic.differenceSettings(operation, o, false);
    const elapsed = other.sinceMidnight().sub(t.sinceMidnight()) catch return error.OutOfRange;
    const rounded = try rounding.toIncrementNs(elapsed, arithmetic.lengthOf(r.smallest, r.increment), r.mode);
    const span = try Span.fromInternal(.{ .time = rounded }, r.largest);
    return if (operation == .since) span.negate() else span;
}

pub const Round = struct {
    /// A time unit, the hour at most.
    smallest: units.Unit,
    /// A divisor of the unit above, less than it.
    increment: u32 = 1,
    mode: units.RoundingMode = .half_expand,
};

/// Temporal's `PlainTime.prototype.round`: to a multiple of `increment` in `smallest`, wrapping at
/// midnight (23:59:59.5 to the second, half expanding, is 00:00:00).
pub fn round(t: Time, options: Round) units.DifferenceError!Time {
    if (arithmetic.isDate(options.smallest)) return error.InvalidOptions;
    try arithmetic.checkIncrement(options.increment, options.smallest);
    return wrapped(try rounding.toIncrementNs(t.sinceMidnight(), arithmetic.lengthOf(options.smallest, options.increment), options.mode));
}
