//! Writing almanac's values as Temporal writes them: dates with four-digit years (six digits and a
//! sign outside 0000 to 9999), times to the second with the fraction's trailing zeros left off,
//! offsets as `±HH:MM` (with `:SS` where there are seconds). Plain values in, so every type can
//! use these without importing another.
const std = @import("std");
const aegis = @import("aegis");
const Writer = std.Io.Writer;

pub fn date(w: *Writer, year: i16, month: u8, day: u8) Writer.Error!void {
    if (year >= 0 and year <= 9999) {
        try w.print("{d:0>4}", .{@as(u16, @intCast(year))});
    } else {
        try w.print("{c}{d:0>6}", .{ @as(u8, if (year < 0) '-' else '+'), @abs(year) });
    }
    try w.print("-{d:0>2}-{d:0>2}", .{ month, day });
}

/// A fraction of a second, its trailing zeros left off; nothing for none.
pub fn fraction(w: *Writer, nanoseconds: u32) Writer.Error!void {
    if (nanoseconds == 0) return;
    var digits: [9]u8 = undefined;
    _ = std.mem.print(&digits, "{d:0>9}", .{nanoseconds}) catch aegis.assert.never("a fraction of a second has nine digits");
    var end: usize = 9;
    while (digits[end - 1] == '0') end -= 1;
    try w.print(".{s}", .{digits[0..end]});
}

pub fn time(w: *Writer, hour: u8, minute: u8, second: u8, nanosecond: u32) Writer.Error!void {
    try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ hour, minute, second });
    try fraction(w, nanosecond);
}

/// `±HH:MM`, or `±HH:MM:SS` where the offset has seconds.
pub fn offset(w: *Writer, seconds: i32) Writer.Error!void {
    const a: u32 = @abs(seconds);
    try w.print("{c}{d:0>2}:{d:0>2}", .{ @as(u8, if (seconds < 0) '-' else '+'), a / 3600, (a / 60) % 60 });
    if (a % 60 != 0) try w.print(":{d:0>2}", .{a % 60});
}

/// The most bytes `date` writes: a sign, six year digits, `-MM-DD`.
pub const date_len = 13;
/// `HH:MM:SS.fffffffff`.
pub const time_len = 18;
/// `±HH:MM:SS`.
pub const offset_len = 9;
