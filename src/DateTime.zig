//! A civil date and time with no zone: what a wall clock and calendar show.
const DateTime = @This();
const std = @import("std");
const units = @import("units.zig");
const arithmetic = @import("arithmetic.zig");
const Date = @import("Date.zig");
const Time = @import("Time.zig");
const Span = @import("Span.zig");
const reading = @import("text/iso.zig");
const rounding = @import("round.zig");

date: Date,
time: Time = .midnight,

pub const RangeError = units.RangeError;
pub const DifferenceError = units.DifferenceError;

pub fn order(a: DateTime, b: DateTime) std.math.Order {
    const by_date = a.date.order(b.date);
    return if (by_date != .eq) by_date else a.time.order(b.time);
}

pub fn eql(a: DateTime, b: DateTime) bool {
    return a.order(b) == .eq;
}

fn iso(dt: DateTime) arithmetic.IsoDateTime {
    return .{ .date = dt.date.iso(), .time = @intCast(dt.time.nanosecondOfDay()) };
}

/// Temporal's `PlainDateTime.prototype.add`: the span's days and time added to the time of day
/// first (a day is 24 hours), the whole days that carries joining the span's date part; then the
/// date part added as `Date.add` adds it, the day regulated by `overflow`.
pub fn add(dt: DateTime, span: Span, overflow: units.Overflow) RangeError!DateTime {
    const internal = try span.toInternalDays();
    const reached = @as(i128, dt.time.nanosecondOfDay()) + internal.time;
    var date = internal.date;
    date.days = @intCast(@divFloor(reached, arithmetic.ns_per_day));
    try arithmetic.checkDate(date);
    const added = try arithmetic.dateAdd(dt.date.iso(), date, overflow);
    return .{
        .date = Date.fromIso(added),
        .time = Time.fromNanosecondOfDay(@intCast(@mod(reached, arithmetic.ns_per_day))) catch unreachable,
    };
}

pub fn subtract(dt: DateTime, span: Span, overflow: units.Overflow) RangeError!DateTime {
    return dt.add(span.negate(), overflow);
}

/// Temporal's `PlainDateTime.prototype.until`: the span from `dt` to `other` up to
/// `options.largest` (the day by default), the time borrowing a day where its sign opposes the
/// dates', then rounded as the options say (to the nanosecond by default).
pub fn until(dt: DateTime, other: DateTime, options: units.Difference) DifferenceError!Span {
    return dt.difference(.until, other, options);
}

/// Temporal's `PlainDateTime.prototype.since`: `until`'s difference from `dt` to `other`, rounded
/// with the mode negated, then negated.
pub fn since(dt: DateTime, other: DateTime, options: units.Difference) DifferenceError!Span {
    return dt.difference(.since, other, options);
}

fn difference(dt: DateTime, operation: arithmetic.Operation, other: DateTime, options: units.Difference) DifferenceError!Span {
    const r = try arithmetic.differenceSettings(operation, options, false);
    if (dt.eql(other)) return .zero;
    const result = try arithmetic.dateTimeUntilRounded(dt.iso(), other.iso(), r);
    const span = try Span.fromInternal(result, r.largest);
    return if (operation == .since) span.negate() else span;
}

pub const max_text_len = Date.max_text_len + 1 + Time.max_text_len;

/// `2026-10-31T09:00:00`.
pub fn format(dt: DateTime, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try dt.date.format(w);
    try w.writeByte('T');
    try dt.time.format(w);
}

/// A civil date and time from text, as `text.parseDateTime` reads it (the time optional).
pub fn parse(text: []const u8) reading.ParseError!DateTime {
    return fromText(text, .{});
}

pub fn fromText(text: []const u8, options: reading.Options) reading.ParseError!DateTime {
    const dt = try reading.dateTime(text, options);
    if (dt.offset != null and dt.offset.? == .z) return reading.refuse(options, text.len, "no 'Z' on a civil value");
    return .{ .date = Date.fromCivil(dt.date), .time = if (dt.time) |t| Time.fromCivil(t) else .midnight };
}

pub const Round = struct {
    /// The day or a time unit.
    smallest: units.Unit,
    /// For the day, 1; for a time unit, a divisor of the unit above, less than it.
    increment: u32 = 1,
    mode: units.RoundingMode = .half_expand,
};

/// Temporal's `PlainDateTime.prototype.round`: the time of day rounded to a multiple of
/// `increment` in `smallest` (to the day, by its 24 hours), what carries past midnight carried
/// into the date.
pub fn round(dt: DateTime, options: Round) DifferenceError!DateTime {
    if (arithmetic.isCalendar(options.smallest)) return error.InvalidOptions;
    if (options.smallest == .day) {
        if (options.increment != 1) return error.InvalidOptions;
    } else try arithmetic.checkIncrement(options.increment, options.smallest);
    const rounded = rounding.toIncrement(dt.time.nanosecondOfDay(), arithmetic.nanoseconds(options.smallest) * options.increment, options.mode);
    const carry: i32 = @intCast(@divFloor(rounded, Time.nanoseconds_per_day));
    return .{
        .date = Date.fromDays(dt.date.days() + carry) catch return error.OutOfRange,
        .time = Time.fromNanosecondOfDay(@intCast(@mod(rounded, Time.nanoseconds_per_day))) catch unreachable,
    };
}
