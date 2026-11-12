//! almanac: civil time. Calendar dates and times, instants, spans and their arithmetic, time zones
//! and zoned times; text arrives stage by stage (docs/design.md says what is built).
pub const units = @import("units.zig");
pub const calendar = @import("calendar.zig");
pub const Date = @import("Date.zig");
pub const Time = @import("Time.zig");
pub const DateTime = @import("DateTime.zig");
pub const Span = @import("Span.zig");
pub const instant = @import("instant.zig");
pub const TimeZone = @import("TimeZone.zig");
pub const Zoned = @import("Zoned.zig");
pub const resolve = @import("resolve.zig");

/// An instant in a zone.
pub const toZoned = Zoned.init;

pub const Timestamp = instant.Timestamp;
pub const Exact = instant.Exact;
pub const now = instant.now;
pub const round = instant.round;
pub const inRange = instant.inRange;

pub const Year = units.Year;
pub const Month = units.Month;
pub const Day = units.Day;
pub const Offset = units.Offset;
pub const Weekday = units.Weekday;
pub const Unit = units.Unit;
pub const RoundingMode = units.RoundingMode;
pub const Overflow = units.Overflow;
pub const Disambiguation = units.Disambiguation;
pub const OffsetConflict = units.OffsetConflict;
pub const Difference = units.Difference;
pub const RangeError = units.RangeError;
pub const DifferenceError = units.DifferenceError;
pub const ArithmeticError = units.ArithmeticError;
pub const ResolveError = resolve.ResolveError;
pub const OffsetError = resolve.OffsetError;
