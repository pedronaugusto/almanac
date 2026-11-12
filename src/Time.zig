//! A civil time of day, 00:00:00 to 23:59:59.999999999, with no zone and no leap second.
const Time = @This();
const std = @import("std");
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

pub const nanoseconds_per_day: u64 = 86_400 * std.time.ns_per_s;

pub fn init(hour: u8, minute: u8, second: u8, nanosecond: u32) RangeError!Time {
    return .{ .hour = try .init(hour), .minute = try .init(minute), .second = try .init(second), .nanosecond = try .init(nanosecond) };
}

/// Nanoseconds since midnight.
pub fn nanosecondOfDay(t: Time) u64 {
    const seconds = @as(u64, t.hour.raw()) * 3600 + @as(u64, t.minute.raw()) * 60 + t.second.raw();
    return seconds * std.time.ns_per_s + t.nanosecond.raw();
}

/// The time `ns` nanoseconds after midnight, within a day.
pub fn fromNanosecondOfDay(ns: u64) RangeError!Time {
    if (ns >= nanoseconds_per_day) return error.OutOfRange;
    const seconds = ns / std.time.ns_per_s;
    return init(@intCast(seconds / 3600), @intCast(seconds / 60 % 60), @intCast(seconds % 60), @intCast(ns % std.time.ns_per_s)) catch unreachable;
}

pub fn order(a: Time, b: Time) std.math.Order {
    return std.math.order(a.nanosecondOfDay(), b.nanosecondOfDay());
}

pub fn eql(a: Time, b: Time) bool {
    return a.nanosecondOfDay() == b.nanosecondOfDay();
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
    return init(c.hour, c.minute, c.second, c.nanosecond) catch unreachable;
}

/// Temporal's `PlainTime.prototype.add`: the span's hours and smaller added, wrapping around
/// midnight; its years, months, weeks and days pass a time of day by.
pub fn add(t: Time, span: Span) RangeError!Time {
    const internal = try span.toInternal();
    const ns = @mod(@as(i128, t.nanosecondOfDay()) + internal.time, nanoseconds_per_day);
    return fromNanosecondOfDay(@intCast(ns)) catch unreachable;
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
    const time = @as(i128, other.nanosecondOfDay()) - t.nanosecondOfDay();
    const rounded = rounding.toIncrement(time, arithmetic.nanoseconds(r.smallest) * r.increment, r.mode);
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
    const rounded = rounding.toIncrement(t.nanosecondOfDay(), arithmetic.nanoseconds(options.smallest) * options.increment, options.mode);
    return fromNanosecondOfDay(@intCast(@mod(rounded, nanoseconds_per_day))) catch unreachable;
}
