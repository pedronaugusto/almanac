//! almanac's README example, built and run with the tests.
const std = @import("std");
const almanac = @import("almanac");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // README-BEGIN
    // Zones come from a database: here the embedded IANA data (the system's files go through
    // `.zoneinfo`, a directory the caller opens).
    var db = almanac.Database.init(init.gpa, .{ .source = .embedded });
    defer db.deinit();
    var lisbon = try db.zone(io, .init("Europe/Lisbon"));
    defer lisbon.release();

    // An instant read from RFC 3339 text, seen in Lisbon.
    const t = try almanac.text.parseTimestamp(.init("2026-03-29T00:30:00Z"), .{});
    const before = try almanac.Zoned.init(t, lisbon.get());

    // A day later by the calendar is 23 hours later: the clocks went forward.
    const after = try before.add(try almanac.Span.fromSigned(.{ .days = 1 }), .constrain);
    const hours = try before.until(after, .{ .largest = .hour });

    var buffer: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try w.print("{f} -> {f}: {f}", .{ before, after, hours });
    std.debug.assert(std.mem.eql(u8, w.buffered(), "2026-03-29T00:30:00+00:00[Europe/Lisbon] -> 2026-03-30T00:30:00+01:00[Europe/Lisbon]: PT23H"));

    // Civil arithmetic: January 31 plus a month is February's last day, or refused.
    const jan31 = try almanac.Date.init(2024, 1, 31);
    const month = try almanac.Span.fromSigned(.{ .months = 1 });
    std.debug.assert((try jan31.add(month, .constrain)).eql(try almanac.Date.init(2024, 2, 29)));
    std.debug.assert(jan31.add(month, .reject) == error.OutOfRange);
    // README-END
}
