//! A civil date and time with no zone: what a wall clock and calendar show.
const DateTime = @This();
const std = @import("std");
const units = @import("units.zig");
const arithmetic = @import("arithmetic.zig");
const Date = @import("Date.zig");
const Time = @import("Time.zig");
const Span = @import("Span.zig");

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
