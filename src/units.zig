//! almanac's vocabulary: the ranged fields of a civil date and time, an offset from UTC, the
//! units a span counts in, and the policies an ambiguous operation is given explicitly. Each field
//! is an aegis `Ranged` integer, so no value outside its calendar exists.
const aegis = @import("aegis");
const Ranged = aegis.int.Ranged;

/// The proleptic Gregorian years almanac covers, jiff's range: a year has four digits in RFC 3339
/// text and fits an `i16`. Temporal's reaches further; almanac refuses what lies outside.
pub const Year = Ranged(i16, -9999, 9999);
pub const Month = Ranged(u8, 1, 12);
/// A day of the month; a `Date` checks it against its month.
pub const Day = Ranged(u8, 1, 31);
pub const Hour = Ranged(u8, 0, 23);
pub const Minute = Ranged(u8, 0, 59);
/// No leap second: almanac counts POSIX time, as Temporal, jiff, Go and java.time do.
pub const Second = Ranged(u8, 0, 59);
pub const Nanosecond = Ranged(u32, 0, 999_999_999);

/// A day of the year, 1 to 366.
pub const Ordinal = Ranged(u16, 1, 366);
/// An ISO week of its week-year, 1 to 53.
pub const Week = Ranged(u8, 1, 53);

/// A value outside almanac's calendar or a field's range.
pub const RangeError = error{OutOfRange};

/// What a difference refuses: a result out of range, or options Temporal refuses (a smallest unit
/// above the largest, a unit the type does not have, an increment that does not divide the unit
/// above it).
pub const DifferenceError = RangeError || error{InvalidOptions};

/// What arithmetic on spans refuses: a `DifferenceError`, or years, months or weeks where no date
/// gives them a length (Temporal's missing `relativeTo`).
pub const ArithmeticError = DifferenceError || error{CalendarUnits};

/// An offset from UTC in seconds, within RFC 9557's ±25:59:59 (Temporal's bound).
pub const Offset = struct {
    seconds: Ranged(i32, -93_599, 93_599),

    pub const utc: Offset = .{ .seconds = .literal(0) };

    pub fn init(seconds: i32) RangeError!Offset {
        return .{ .seconds = try .init(seconds) };
    }
};

/// ISO 8601's days of the week: Monday is 1, Sunday 7.
pub const Weekday = enum(u3) {
    monday = 1,
    tuesday,
    wednesday,
    thursday,
    friday,
    saturday,
    sunday,
};

/// The units a span counts in, largest first.
pub const Unit = enum {
    year,
    month,
    week,
    day,
    hour,
    minute,
    second,
    millisecond,
    microsecond,
    nanosecond,
};

/// Temporal's rounding modes.
pub const RoundingMode = enum {
    ceil,
    floor,
    expand,
    trunc,
    half_ceil,
    half_floor,
    half_expand,
    half_trunc,
    half_even,
};

/// How a difference (`until`, `since`) is measured and rounded: Temporal's options.
pub const Difference = struct {
    /// The largest unit of the result; null for the larger of the day and `smallest` (Temporal's
    /// `auto`).
    largest: ?Unit = null,
    /// The unit rounded to; null for the type's smallest (the day for a date, the nanosecond for a
    /// date and time).
    smallest: ?Unit = null,
    /// A multiple of `smallest` to round to: up to 10^9, and for a time unit a divisor of the unit
    /// above it, less than it.
    increment: u32 = 1,
    mode: RoundingMode = .trunc,
};

/// A day past the end of the target month (January 31 plus a month): clamped to the month's last
/// day, or refused.
pub const Overflow = enum { constrain, reject };

/// A civil time a zone skips (a gap) or repeats (a fold): Temporal's choices.
pub const Disambiguation = enum { compatible, earlier, later, reject };

/// A written offset against the zone's own at that time (Temporal).
pub const OffsetConflict = enum { use, ignore, prefer, reject };
