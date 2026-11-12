//! A civil time of day, 00:00:00 to 23:59:59.999999999, with no zone and no leap second.
const Time = @This();
const std = @import("std");
const units = @import("units.zig");

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
