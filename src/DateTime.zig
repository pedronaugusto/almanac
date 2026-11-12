//! A civil date and time with no zone: what a wall clock and calendar show.
const DateTime = @This();
const std = @import("std");
const Date = @import("Date.zig");
const Time = @import("Time.zig");

date: Date,
time: Time = .midnight,

pub fn order(a: DateTime, b: DateTime) std.math.Order {
    const by_date = a.date.order(b.date);
    return if (by_date != .eq) by_date else a.time.order(b.time);
}
