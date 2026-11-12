//! almanac: civil time. Calendar dates and times, instants, spans and their arithmetic, time zones,
//! the zone database, zoned times, and text (docs/design.md says what is built).
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
pub const Database = @import("Database.zig");
pub const text = @import("text.zig");
pub const Zone = Database.Zone;
pub const ZoneError = Database.ZoneError;

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

/// What glint replaces in a program that imports almanac: std's epoch arithmetic, which reads UTC
/// only and checks no range, by almanac's checked civil time.
pub const lint_rules = .{
    .version = 1,
    .replaces = .{
        .{ .std = "time.epoch.EpochSeconds", .with = toZoned, .why = "UTC only and no range check; almanac's civil time takes any zone and refuses out of range" },
        .{ .std = "time.epoch.EpochDay", .with = Date, .why = "a Date is checked against its month and range; EpochDay's arithmetic is unchecked" },
        .{ .std = "time.epoch.isLeapYear", .with = Date.init, .why = "a Date checks its day; leap years are the calendar's, not the caller's" },
        .{ .std = "time.epoch.getDaysInMonth", .with = Date.init, .why = "a Date checks its day against its month" },
    },
};
