//! Temporal's arithmetic on ISO dates and date-times, its abstract operations transcribed over plain
//! records: adding a date duration (CalendarDateAdd), the difference of two dates
//! (CalendarDateUntil) and of two date-times (DifferenceISODateTime), and rounding a difference
//! against the timeline it was measured on (RoundRelativeDuration with its nudges and bubbling).
//! Each loop the specification writes is solved in closed form. The public types (`Date`,
//! `DateTime`, `Span`) convert to these records and back.
const std = @import("std");
const units = @import("units.zig");
const calendar = @import("calendar.zig");
const round = @import("round.zig");
const Unit = units.Unit;
const RoundingMode = units.RoundingMode;
const Overflow = units.Overflow;

pub const RangeError = units.RangeError;

pub const ns_per_day: i128 = 86_400 * std.time.ns_per_s;
/// Temporal's bound on years, months and weeks: below 2^32.
pub const max_calendar: i64 = (1 << 32) - 1;
/// Temporal's bound on the days and time together: below 2^53 seconds (MaxTimeDuration).
pub const max_time: i128 = (1 << 53) * std.time.ns_per_s - 1;
pub const max_days: i64 = @intCast(@divTrunc(max_time, ns_per_day));

/// The calendar part of a duration, each field signed and all of one sign.
pub const DateRec = struct {
    years: i64 = 0,
    months: i64 = 0,
    weeks: i64 = 0,
    days: i64 = 0,

    pub fn sign(d: DateRec) i2 {
        inline for (.{ d.years, d.months, d.weeks, d.days }) |v| if (v != 0) return signOf(v);
        return 0;
    }
};

/// Temporal's internal duration record: a date part and a time part in nanoseconds.
pub const Internal = struct {
    date: DateRec = .{},
    time: i128 = 0,

    pub fn sign(d: Internal) i2 {
        const s = d.date.sign();
        return if (s != 0) s else signOf(d.time);
    }
};

pub fn signOf(v: anytype) i2 {
    return if (v < 0) -1 else if (v > 0) 1 else 0;
}

/// IsValidDuration over a date part, as CreateDateDurationRecord checks it.
pub fn checkDate(d: DateRec) RangeError!void {
    if (@abs(d.years) > max_calendar or @abs(d.months) > max_calendar or @abs(d.weeks) > max_calendar) return error.OutOfRange;
    if (@abs(d.days) > max_days) return error.OutOfRange;
    var positive = false;
    var negative = false;
    inline for (.{ d.years, d.months, d.weeks, d.days }) |v| {
        positive = positive or v > 0;
        negative = negative or v < 0;
    }
    if (positive and negative) return error.OutOfRange;
}

pub fn checkTime(t: i128) RangeError!i128 {
    return if (@abs(t) > max_time) error.OutOfRange else t;
}

/// Add24HourDaysToTimeDuration.
pub fn addDays(t: i128, days: i64) RangeError!i128 {
    return checkTime(t + days * ns_per_day);
}

// Units.

pub fn larger(a: Unit, b: Unit) Unit {
    return if (@backingInt(a) <= @backingInt(b)) a else b;
}

/// Years, months and weeks: units only a date gives a length.
pub fn isCalendar(u: Unit) bool {
    return @backingInt(u) <= @backingInt(Unit.week);
}

/// Temporal's date category: the calendar units and the day.
pub fn isDate(u: Unit) bool {
    return @backingInt(u) <= @backingInt(Unit.day);
}

/// A day or a time unit's length.
pub fn nanoseconds(u: Unit) i128 {
    return switch (u) {
        .day => ns_per_day,
        .hour => 3600 * std.time.ns_per_s,
        .minute => 60 * std.time.ns_per_s,
        .second => std.time.ns_per_s,
        .millisecond => std.time.ns_per_ms,
        .microsecond => std.time.ns_per_us,
        .nanosecond => 1,
        .year, .month, .week => unreachable,
    };
}

/// GetRoundingIncrementOption's range, then MaximumTemporalDurationRoundingIncrement and
/// ValidateTemporalRoundingIncrement (exclusive): a time unit's increment divides the unit above.
pub fn checkIncrement(increment: u32, smallest: Unit) error{InvalidOptions}!void {
    if (increment < 1 or increment > 1_000_000_000) return error.InvalidOptions;
    const dividend: u32 = switch (smallest) {
        .year, .month, .week, .day => return,
        .hour => 24,
        .minute, .second => 60,
        .millisecond, .microsecond, .nanosecond => 1000,
    };
    if (increment > dividend - 1 or dividend % increment != 0) return error.InvalidOptions;
}

// ISO dates.

pub const IsoDate = struct {
    year: i64,
    month: u8,
    day: u8,

    pub fn epochDays(d: IsoDate) i64 {
        return calendar.daysFromCivilWide(d.year, d.month, d.day);
    }
};

pub const IsoDateTime = struct {
    date: IsoDate,
    /// Nanoseconds since midnight.
    time: i64 = 0,

    pub fn epochNs(dt: IsoDateTime) i128 {
        return @as(i128, dt.date.epochDays()) * ns_per_day + dt.time;
    }
};

pub fn inRange(days: i64) bool {
    return days >= calendar.min_days and days <= calendar.max_days;
}

/// The date of a day count inside almanac's range.
pub fn fromEpochDays(days: i64) IsoDate {
    std.debug.assert(inRange(days));
    const c = calendar.civilFromDays(@intCast(days));
    return .{ .year = c.year, .month = @intCast(c.month), .day = @intCast(c.day) };
}

/// CompareISODate.
pub fn compare(a: IsoDate, b: IsoDate) i2 {
    if (a.year != b.year) return signOf(a.year - b.year);
    if (a.month != b.month) return signOf(@as(i16, a.month) - b.month);
    return signOf(@as(i16, a.day) - b.day);
}

const YearMonth = struct { year: i64, month: u8 };

/// BalanceISOYearMonth.
fn balanceYearMonth(year: i64, month: i64) YearMonth {
    const m = month - 1;
    return .{ .year = year + @divFloor(m, 12), .month = @intCast(@mod(m, 12) + 1) };
}

/// RegulateISODate: a day past the month's end clamped or refused.
fn regulate(ym: YearMonth, day: u8, overflow: Overflow) RangeError!IsoDate {
    const last: u8 = @intCast(calendar.daysInMonth(ym.year, ym.month));
    if (day <= last) return .{ .year = ym.year, .month = ym.month, .day = day };
    return switch (overflow) {
        .constrain => .{ .year = ym.year, .month = ym.month, .day = last },
        .reject => error.OutOfRange,
    };
}

/// CalendarDateAdd for the ISO calendar: years and months first, the day regulated, then weeks and
/// days; the result inside almanac's range.
pub fn dateAdd(date: IsoDate, d: DateRec, overflow: Overflow) RangeError!IsoDate {
    const ym = balanceYearMonth(date.year + d.years, @as(i64, date.month) + d.months);
    const regulated = try regulate(ym, date.day, overflow);
    const days = regulated.epochDays() + d.days + 7 * d.weeks;
    if (!inRange(days)) return error.OutOfRange;
    return fromEpochDays(days);
}

/// ISODateSurpasses: whether (`year`, `month`, `day`), the day unregulated, lies past `two` in the
/// direction `sign`.
fn surpasses(sign: i2, year: i64, month: u8, day: u8, two: IsoDate) bool {
    const c: i2 = if (year != two.year) signOf(year - two.year) else if (month != two.month) signOf(@as(i16, month) - two.month) else signOf(@as(i16, day) - two.day);
    return @as(i4, sign) * c > 0;
}

/// CalendarDateUntil for the ISO calendar, `largest` a date unit. The specification counts each
/// unit up one at a time while the date reached does not surpass `two`; surpassing is monotone in
/// the count, so the count is the distance in that unit, less one where the day overshoots.
pub fn dateUntil(one: IsoDate, two: IsoDate, largest: Unit) DateRec {
    std.debug.assert(isDate(largest));
    const sign = -compare(one, two);
    if (sign == 0) return .{};
    var years: i64 = 0;
    if (largest == .year) {
        years = two.year - one.year;
        if (surpasses(sign, one.year + years, one.month, one.day, two)) years -= sign;
    }
    var months: i64 = 0;
    if (largest == .year or largest == .month) {
        const base = (one.year + years) * 12 + one.month - 1;
        months = two.year * 12 + two.month - 1 - base;
        const at = balanceYearMonth(one.year + years, @as(i64, one.month) + months);
        if (surpasses(sign, at.year, at.month, one.day, two)) months -= sign;
    }
    const constrained = regulate(balanceYearMonth(one.year + years, @as(i64, one.month) + months), one.day, .constrain) catch unreachable;
    const diff = two.epochDays() - constrained.epochDays();
    const weeks: i64 = if (largest == .week) @divTrunc(diff, 7) else 0;
    return .{ .years = years, .months = months, .weeks = weeks, .days = diff - 7 * weeks };
}

/// DifferenceISODateTime: the time difference borrows a day where its sign opposes the dates'.
pub fn dateTimeUntil(one: IsoDateTime, two: IsoDateTime, largest: Unit) RangeError!Internal {
    var time: i128 = two.time - one.time;
    const time_sign = signOf(time);
    var adjusted = two.date;
    if (time_sign != 0 and time_sign == compare(one.date, two.date)) {
        adjusted = fromEpochDays(two.date.epochDays() + time_sign);
        time -= time_sign * ns_per_day;
    }
    const date_largest = larger(.day, largest);
    var date = dateUntil(one.date, adjusted, date_largest);
    if (largest != date_largest) {
        time = try addDays(time, date.days);
        date.days = 0;
    }
    return .{ .date = date, .time = time };
}

pub const Rounding = struct {
    largest: Unit,
    smallest: Unit,
    increment: u32,
    mode: RoundingMode,
};

/// DifferencePlainDateTimeWithRounding: the difference, rounded unless to one nanosecond.
pub fn dateTimeUntilRounded(one: IsoDateTime, two: IsoDateTime, r: Rounding) RangeError!Internal {
    if (one.epochNs() == two.epochNs()) return .{};
    const diff = try dateTimeUntil(one, two, r.largest);
    if (r.smallest == .nanosecond and r.increment == 1) return diff;
    return roundRelative(diff, two.epochNs(), one, r);
}

pub const Operation = enum { until, since };

/// GetDifferenceSettings: the units checked against the type's (`date_only` for a date), the
/// defaults filled in, the increment checked, and `since`'s rounding mode negated (a `since` is the
/// same difference, negated after rounding).
pub fn differenceSettings(operation: Operation, options: units.Difference, date_only: bool) units.DifferenceError!Rounding {
    if (date_only) {
        if (options.largest) |u| if (!isDate(u)) return error.InvalidOptions;
        if (options.smallest) |u| if (!isDate(u)) return error.InvalidOptions;
    }
    const smallest = options.smallest orelse if (date_only) Unit.day else Unit.nanosecond;
    const largest = options.largest orelse larger(.day, smallest);
    if (larger(largest, smallest) != largest) return error.InvalidOptions;
    try checkIncrement(options.increment, smallest);
    return .{
        .largest = largest,
        .smallest = smallest,
        .increment = options.increment,
        .mode = if (operation == .since) round.negate(options.mode) else options.mode,
    };
}

const Nudge = struct {
    duration: Internal,
    nudged: i128,
    expanded: bool,
};

/// RoundRelativeDuration without a zone: `duration` measured from `origin` to `dest`.
pub fn roundRelative(duration: Internal, dest: i128, origin: IsoDateTime, r: Rounding) RangeError!Internal {
    const sign: i2 = if (duration.sign() < 0) -1 else 1;
    const nudge = if (isCalendar(r.smallest))
        try nudgeToCalendarUnit(sign, duration, dest, origin, r)
    else
        try nudgeToDayOrTime(duration, dest, r);
    if (nudge.expanded and r.smallest != .week)
        return bubble(sign, nudge.duration, nudge.nudged, origin, r.largest, larger(r.smallest, .day));
    return nudge.duration;
}

/// NudgeToCalendarUnit: the duration truncated to a multiple of the increment in `unit`, and that
/// plus one increment, as dates from the origin; the destination's progress between them picks one.
fn nudgeToCalendarUnit(sign: i2, duration: Internal, dest: i128, origin: IsoDateTime, r: Rounding) RangeError!Nudge {
    const d = duration.date;
    const increment: i64 = r.increment;
    var start: DateRec = undefined;
    var end: DateRec = undefined;
    var r1: i64 = undefined;
    switch (r.smallest) {
        .year => {
            r1 = truncate(d.years, increment);
            start = .{ .years = r1 };
            end = .{ .years = r1 + increment * sign };
        },
        .month => {
            r1 = truncate(d.months, increment);
            start = .{ .years = d.years, .months = r1 };
            end = .{ .years = d.years, .months = r1 + increment * sign };
        },
        .week => {
            // CalendarDateUntil from the years and months reached, over the days, in weeks: the
            // days' whole weeks. The date reached must still exist.
            _ = try dateAdd(origin.date, .{ .years = d.years, .months = d.months }, .constrain);
            r1 = truncate(d.weeks + @divTrunc(d.days, 7), increment);
            start = .{ .years = d.years, .months = d.months, .weeks = r1 };
            end = .{ .years = d.years, .months = d.months, .weeks = r1 + increment * sign };
        },
        .day => {
            r1 = truncate(d.days, increment);
            start = .{ .years = d.years, .months = d.months, .weeks = d.weeks, .days = r1 };
            end = .{ .years = d.years, .months = d.months, .weeks = d.weeks, .days = r1 + increment * sign };
        },
        else => unreachable,
    }
    try checkDate(start);
    try checkDate(end);
    const start_ns = (IsoDateTime{ .date = try dateAdd(origin.date, start, .constrain), .time = origin.time }).epochNs();
    const end_ns = (IsoDateTime{ .date = try dateAdd(origin.date, end, .constrain), .time = origin.time }).epochNs();
    var num = dest - start_ns;
    var den = end_ns - start_ns;
    if (sign < 0) {
        num = -num;
        den = -den;
    }
    std.debug.assert(den > 0 and num >= 0 and num <= den);
    const r1_abs: i64 = @intCast(@abs(r1));
    const up = round.toSecond(num, den, round.unsignedMode(r.mode, sign < 0), @mod(@divTrunc(r1_abs, increment), 2) == 0);
    return if (up)
        .{ .duration = .{ .date = end }, .nudged = end_ns, .expanded = true }
    else
        .{ .duration = .{ .date = start }, .nudged = start_ns, .expanded = false };
}

fn truncate(x: i64, increment: i64) i64 {
    return @intCast(round.toIncrement(x, increment, .trunc));
}

/// NudgeToDayOrTime: the days and time as one exact count, rounded; whether that carried into a
/// new day (in the duration's direction) decides bubbling.
fn nudgeToDayOrTime(duration: Internal, dest: i128, r: Rounding) RangeError!Nudge {
    const time = try addDays(duration.time, duration.date.days);
    const rounded = try checkTime(round.toIncrement(time, nanoseconds(r.smallest) * r.increment, r.mode));
    const whole_days = @divTrunc(time, ns_per_day);
    const rounded_days = @divTrunc(rounded, ns_per_day);
    const expanded = signOf(rounded_days - whole_days) == signOf(time);
    var date = duration.date;
    date.days = 0;
    var remainder = rounded;
    if (isDate(r.largest)) {
        date.days = @intCast(rounded_days);
        remainder = rounded - rounded_days * ns_per_day;
    }
    try checkDate(date);
    return .{ .duration = .{ .date = date, .time = remainder }, .nudged = dest + (rounded - time), .expanded = expanded };
}

/// BubbleRelativeDuration: after rounding carried into a larger unit, each unit up to `largest`
/// takes one more where the rounded end reaches that unit's next boundary.
fn bubble(sign: i2, duration: Internal, nudged: i128, origin: IsoDateTime, largest: Unit, smallest: Unit) RangeError!Internal {
    var out = duration;
    var index: usize = @backingInt(smallest);
    while (index > @backingInt(largest)) {
        index -= 1;
        const unit: Unit = @fromBackingInt(@intCast(index));
        if (unit == .week and largest != .week) continue;
        const d = out.date;
        const end: DateRec = switch (unit) {
            .year => .{ .years = d.years + sign },
            .month => .{ .years = d.years, .months = d.months + sign },
            .week => .{ .years = d.years, .months = d.months, .weeks = d.weeks + sign },
            else => unreachable,
        };
        try checkDate(end);
        const end_ns = (IsoDateTime{ .date = try dateAdd(origin.date, end, .constrain), .time = origin.time }).epochNs();
        if (signOf(nudged - end_ns) == -sign) break;
        out = .{ .date = end };
    }
    return out;
}

test "the closed forms agree with the specification's loops" {
    // CalendarDateUntil's loops, run as written, against the closed form, over pairs of dates around
    // month ends and leap days, in both directions and for every date unit.
    const days = [_]i64{ -1, 0, 27, 28, 29, 30, 31, 58, 59, 60, 89, 365, 366, 400, 790, 1460, 1461 };
    const starts = [_]IsoDate{ .{ .year = 2020, .month = 1, .day = 31 }, .{ .year = 2020, .month = 2, .day = 29 }, .{ .year = 2019, .month = 3, .day = 31 }, .{ .year = 2021, .month = 12, .day = 30 }, .{ .year = 1999, .month = 8, .day = 1 } };
    for (starts) |one| for (days) |n| for ([_]i64{ 1, -1 }) |s| {
        const two = fromEpochDays(one.epochDays() + s * n);
        for ([_]Unit{ .year, .month, .week, .day }) |largest|
            try std.testing.expectEqual(loops(one, two, largest), dateUntil(one, two, largest));
    };
}

/// CalendarDateUntil as the specification writes it, one step at a time.
fn loops(one: IsoDate, two: IsoDate, largest: Unit) DateRec {
    const sign = -compare(one, two);
    if (sign == 0) return .{};
    var years: i64 = 0;
    if (largest == .year) {
        var candidate: i64 = sign;
        while (!surpasses(sign, one.year + candidate, one.month, one.day, two)) : (candidate += sign) years = candidate;
    }
    var months: i64 = 0;
    if (largest == .year or largest == .month) {
        var candidate: i64 = sign;
        var at = balanceYearMonth(one.year + years, @as(i64, one.month) + candidate);
        while (!surpasses(sign, at.year, at.month, one.day, two)) {
            months = candidate;
            candidate += sign;
            at = balanceYearMonth(at.year, @as(i64, at.month) + sign);
        }
    }
    const constrained = regulate(balanceYearMonth(one.year + years, @as(i64, one.month) + months), one.day, .constrain) catch unreachable;
    var weeks: i64 = 0;
    if (largest == .week) {
        var candidate: i64 = sign;
        while (true) : (candidate += sign) {
            const at = fromEpochDays(constrained.epochDays() + 7 * candidate);
            if (surpasses(sign, at.year, at.month, at.day, two)) break;
            weeks = candidate;
        }
    }
    var count: i64 = 0;
    var candidate: i64 = sign;
    while (true) : (candidate += sign) {
        const at = fromEpochDays(constrained.epochDays() + 7 * weeks + candidate);
        if (surpasses(sign, at.year, at.month, at.day, two)) break;
        count = candidate;
    }
    return .{ .years = years, .months = months, .weeks = weeks, .days = count };
}
