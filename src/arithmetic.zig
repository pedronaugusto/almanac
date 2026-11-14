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
const aegis = @import("aegis");
const Unit = units.Unit;
const RoundingMode = units.RoundingMode;
const Overflow = units.Overflow;

pub const RangeError = units.RangeError;

/// An exact length of time in nanoseconds: a duration's time part, a difference of instants, the
/// length of a unit. Wide enough for Temporal's bound and any product the rounding forms.
pub const Ns = aegis.units.Duration(.nanosecond, i128);
/// A place on the timeline in nanoseconds since 1970-01-01T00:00:00Z; a wall clock read as if UTC
/// is one too.
pub const Epoch = aegis.units.Instant(.real, .nanosecond, i128);

/// A length counted in `unit` as nanoseconds, where it fits: every length almanac converts is
/// far inside an i128. Nanoseconds are already nanoseconds.
pub fn toNs(comptime unit: aegis.units.Unit, d: aegis.units.Duration(unit, i128)) Ns {
    if (comptime unit == .nanosecond) return d;
    return d.convert(.nanosecond, i128, .exact) catch aegis.assert.never("the length fits an i128 of nanoseconds");
}

/// One of `unit`, in nanoseconds.
fn unitLength(comptime unit: aegis.units.Unit) Ns {
    return toNs(unit, .fromRaw(1));
}

/// A day of 24 hours.
pub const one_day: Ns = unitLength(.day);
/// Temporal's bound on years, months and weeks: below 2^32.
pub const max_calendar: i64 = (1 << 32) - 1;
/// Temporal's bound on the days and time together: below 2^53 seconds (MaxTimeDuration).
pub const max_time: Ns = toNs(.second, .fromRaw(1 << 53)).sub(.fromRaw(1)) catch aegis.assert.never("2^53 seconds less a nanosecond is no overflow");
/// `max_time` as a count, for the ranges that bound a span's fields.
pub const max_time_count: u128 = (max_time.convert(.nanosecond, u128, .exact) catch aegis.assert.never("Temporal's bound is no negative length")).raw();
pub const max_days: i64 = @intCast(max_time.ratio(one_day) catch aegis.assert.never("a day is no zero"));
/// No time at all.
pub const zero: Ns = .fromRaw(0);

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
    time: Ns = zero,

    pub fn sign(d: Internal) i2 {
        const s = d.date.sign();
        return if (s != 0) s else signOfNs(d.time);
    }
};

pub fn signOf(v: anytype) i2 {
    return if (v < 0) -1 else if (v > 0) 1 else 0;
}

/// A length's sign: -1 before zero, 1 after.
pub fn signOfNs(t: Ns) i2 {
    return switch (t.compare(zero)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
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

pub fn checkTime(t: Ns) RangeError!Ns {
    const size = t.abs() catch return error.OutOfRange;
    return if (size.compare(max_time) == .gt) error.OutOfRange else t;
}

/// Add24HourDaysToTimeDuration.
pub fn addDays(t: Ns, days: i64) RangeError!Ns {
    const whole = one_day.mul(days) catch return error.OutOfRange;
    return checkTime(t.add(whole) catch return error.OutOfRange);
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
pub fn length(u: Unit) Ns {
    return switch (u) {
        .day => one_day,
        .hour => unitLength(.hour),
        .minute => unitLength(.minute),
        .second => unitLength(.second),
        .millisecond => unitLength(.millisecond),
        .microsecond => unitLength(.microsecond),
        .nanosecond => unitLength(.nanosecond),
        .year, .month, .week => aegis.assert.never("a calendar unit has no fixed length"),
    };
}

/// `increment` of a day or a time unit, as one length: an increment checked by `checkIncrement`
/// stays well inside an i128.
pub fn lengthOf(u: Unit, increment: u32) Ns {
    return length(u).mul(increment) catch aegis.assert.never("a checked increment of a unit fits an i128");
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
    /// The time since midnight, under a day.
    time: Ns = zero,

    /// The wall clock read as if UTC.
    pub fn epochNs(dt: IsoDateTime) Epoch {
        const days = one_day.mul(dt.date.epochDays()) catch aegis.assert.never("a date's days fit an i128 of nanoseconds");
        return .fromSinceEpoch(days.add(dt.time) catch aegis.assert.never("a date's days and a time of day fit an i128"));
    }
};

pub fn inRange(days: i64) bool {
    return days >= calendar.min_days and days <= calendar.max_days;
}

/// The date of a day count inside almanac's range.
pub fn fromEpochDays(days: i64) IsoDate {
    aegis.assert.invariant(inRange(days), "inRange(days)");
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
    aegis.assert.invariant(isDate(largest), "isDate(largest)");
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
    const constrained = regulate(balanceYearMonth(one.year + years, @as(i64, one.month) + months), one.day, .constrain) catch aegis.assert.never("constrain clamps the day to its month, and refuses nothing");
    const diff = two.epochDays() - constrained.epochDays();
    const weeks: i64 = if (largest == .week) @divTrunc(diff, 7) else 0;
    return .{ .years = years, .months = months, .weeks = weeks, .days = diff - 7 * weeks };
}

/// DifferenceISODateTime: the time difference borrows a day where its sign opposes the dates'.
pub fn dateTimeUntil(one: IsoDateTime, two: IsoDateTime, largest: Unit) RangeError!Internal {
    var time = two.time.sub(one.time) catch return error.OutOfRange;
    const time_sign = signOfNs(time);
    var adjusted = two.date;
    if (time_sign != 0 and time_sign == compare(one.date, two.date)) {
        adjusted = fromEpochDays(two.date.epochDays() + time_sign);
        time = time.sub(one_day.mul(time_sign) catch return error.OutOfRange) catch return error.OutOfRange;
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
    if (one.epochNs().eql(two.epochNs())) return .{};
    const diff = try dateTimeUntil(one, two, r.largest);
    if (r.smallest == .nanosecond and r.increment == 1) return diff;
    return roundRelative(diff, one.epochNs(), two.epochNs(), one, null, r);
}

/// What arithmetic in a zone asks of it: the wall clock at an instant (GetISODateTimeFor), and the
/// instant of a wall clock under Temporal's `compatible` resolution (GetEpochNanosecondsFor). The
/// zone sits above the arithmetic, so it is reached through these.
pub const Zone = struct {
    context: *const anyopaque,
    wall_clock: *const fn (context: *const anyopaque, at: Epoch) RangeError!IsoDateTime,
    instant_of: *const fn (context: *const anyopaque, dt: IsoDateTime) RangeError!Epoch,

    pub fn wallClock(z: Zone, at: Epoch) RangeError!IsoDateTime {
        return z.wall_clock(z.context, at);
    }

    fn instantOf(z: Zone, dt: IsoDateTime) RangeError!Epoch {
        return z.instant_of(z.context, dt);
    }
};

/// A wall clock's instant: in the zone, or read as UTC where there is none.
fn epochOf(zone: ?Zone, dt: IsoDateTime) RangeError!Epoch {
    return if (zone) |z| z.instantOf(dt) else dt.epochNs();
}

/// The day after or before a wall clock's date, at the same time.
fn nextDay(dt: IsoDateTime, sign: i2) RangeError!IsoDateTime {
    const days = dt.date.epochDays() + sign;
    if (!inRange(days)) return error.OutOfRange;
    return .{ .date = fromEpochDays(days), .time = dt.time };
}

/// AddZonedDateTime: the date part added to the wall clock and resolved, then the time on the
/// timeline. Without a date part, the time alone.
pub fn zonedAdd(zone: Zone, from: Epoch, d: Internal, overflow: Overflow) RangeError!Epoch {
    var at = from;
    if (d.date.sign() != 0) {
        const wall = try zone.wallClock(from);
        at = try zone.instantOf(.{ .date = try dateAdd(wall.date, d.date, overflow), .time = wall.time });
    }
    return at.add(d.time) catch error.OutOfRange;
}

/// DifferenceZonedDateTime: whole days by the wall clock, found by stepping back from the end's
/// date until the time left runs the same way as the whole; the date part by the calendar, the
/// rest on the timeline.
pub fn zonedUntil(zone: Zone, one: Epoch, two: Epoch, largest: Unit) RangeError!Internal {
    if (one.eql(two)) return .{};
    const start = try zone.wallClock(one);
    const end = try zone.wallClock(two);
    if (compare(start.date, end.date) == 0) return .{ .time = one.durationTo(two) catch return error.OutOfRange };
    const sign: i2 = if (two.compare(one) == .lt) -1 else 1;
    const max_correction: i64 = if (sign == 1) 2 else 1;
    var correction: i64 = 0;
    if (signOfNs(end.time.sub(start.time) catch return error.OutOfRange) == -sign) correction += 1;
    while (correction <= max_correction) : (correction += 1) {
        const days = end.date.epochDays() - correction * sign;
        if (!inRange(days)) return error.OutOfRange;
        const intermediate: IsoDateTime = .{ .date = fromEpochDays(days), .time = start.time };
        const time = (try zone.instantOf(intermediate)).durationTo(two) catch return error.OutOfRange;
        if (sign != -signOfNs(time)) {
            const date = dateUntil(start.date, intermediate.date, larger(largest, .day));
            return .{ .date = date, .time = time };
        }
    }
    // No real zone reaches here: its offsets change by less than a day at a time.
    return error.OutOfRange;
}

/// DifferenceZonedDateTimeWithRounding, `largest` a date unit.
pub fn zonedUntilRounded(zone: Zone, one: Epoch, two: Epoch, r: Rounding) RangeError!Internal {
    const diff = try zonedUntil(zone, one, two, r.largest);
    if (r.smallest == .nanosecond and r.increment == 1) return diff;
    return roundRelative(diff, one, two, try zone.wallClock(one), zone, r);
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
    nudged: Epoch,
    expanded: bool,
    /// NudgeToCalendarUnit's total: `numerator / denominator` of the unit.
    numerator: Ns = zero,
    denominator: Ns = .fromRaw(1),
};

/// A ratio of two lengths as the nearest f64, rounded once (ties to even): Temporal's 𝔽(total).
pub fn ratioToF64(numerator: Ns, denominator: Ns) f64 {
    aegis.assert.invariant(!denominator.eql(zero), "a total is of a unit of some length");
    if (numerator.eql(zero)) return 0;
    const negative = (numerator.compare(zero) == .lt) != (denominator.compare(zero) == .lt);
    // The units cancel: what is left is a ratio of two counts of nanoseconds.
    const n: u512 = @abs(numerator.raw());
    const d: u512 = @abs(denominator.raw());
    // The quotient scaled by 2^k to 55 bits (2^54 <= q < 2^55): 53 kept, a rounding bit, a guard.
    var k: i32 = 55 - @as(i32, 512 - @clz(n)) + @as(i32, 512 - @clz(d));
    var q: u512 = undefined;
    var sticky = false;
    while (true) {
        const num = if (k >= 0) n << @intCast(k) else n;
        const den = if (k >= 0) d else d << @intCast(-k);
        q = num / den;
        sticky = num % den != 0;
        if (q >= (@as(u512, 1) << 55)) {
            k -= 1;
        } else if (q < (@as(u512, 1) << 54)) {
            k += 1;
        } else break;
    }
    const low: u2 = @truncate(q);
    var m: u64 = @intCast(q >> 2);
    // Over half, or exactly half and odd (or a sticky bit past it): up.
    if (low == 3 or (low == 2 and (sticky or m & 1 == 1))) m += 1;
    const value = std.math.ldexp(@as(f64, @floatFromInt(m)), 2 - k);
    return if (negative) -value else value;
}

/// TotalRelativeDuration: `duration`, measured from `origin` to `dest`, in `unit` as a ratio.
pub fn totalRelative(duration: Internal, origin_ns: Epoch, dest: Epoch, origin: IsoDateTime, zone: ?Zone, unit: Unit) RangeError!f64 {
    if (isCalendar(unit) or (zone != null and unit == .day)) {
        const sign: i2 = if (duration.sign() < 0) -1 else 1;
        const r: Rounding = .{ .largest = unit, .smallest = unit, .increment = 1, .mode = .trunc };
        const nudge = try nudgeToCalendarUnit(sign, duration, origin_ns, dest, origin, zone, r);
        return ratioToF64(nudge.numerator, nudge.denominator);
    }
    const time = try addDays(duration.time, duration.date.days);
    return ratioToF64(time, length(unit));
}

/// RoundRelativeDuration: `duration` measured from `origin` (the instant `origin_ns`, the wall
/// clock `origin`) to `dest`, in `zone` or on a timeline without one.
pub fn roundRelative(duration: Internal, origin_ns: Epoch, dest: Epoch, origin: IsoDateTime, zone: ?Zone, r: Rounding) RangeError!Internal {
    const sign: i2 = if (duration.sign() < 0) -1 else 1;
    // A day in a zone may be 23 or 25 hours long: a calendar unit there.
    const irregular = isCalendar(r.smallest) or (zone != null and r.smallest == .day);
    const nudge = if (irregular)
        try nudgeToCalendarUnit(sign, duration, origin_ns, dest, origin, zone, r)
    else if (zone) |z|
        try nudgeToZonedTime(sign, duration, origin, z, r)
    else
        try nudgeToDayOrTime(duration, dest, r);
    if (nudge.expanded and r.smallest != .week)
        return bubble(sign, nudge.duration, nudge.nudged, origin, zone, r.largest, larger(r.smallest, .day));
    return nudge.duration;
}

/// NudgeToCalendarUnit: the duration truncated to a multiple of the increment in `unit`, and that
/// plus one increment, as dates from the origin; the destination's progress between them picks one.
fn nudgeToCalendarUnit(sign: i2, duration: Internal, origin_ns: Epoch, dest: Epoch, origin: IsoDateTime, zone: ?Zone, r: Rounding) RangeError!Nudge {
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
    // A start that is the origin itself is the origin's instant, not its wall clock resolved
    // again (which in a fold may be the other of its two instants).
    var start_ns = if (start.sign() == 0) origin_ns else try epochOf(zone, .{ .date = try dateAdd(origin.date, start, .constrain), .time = origin.time });
    var end_ns = try epochOf(zone, .{ .date = try dateAdd(origin.date, end, .constrain), .time = origin.time });
    // Where a month's end was constrained, the destination can lie past the window's end (a year
    // from February 29 ends on February 28): the window moves on by an increment until it holds it.
    var moved: usize = 0;
    while (signOfNs(end_ns.durationTo(dest) catch return error.OutOfRange) == sign and moved < 4) : (moved += 1) {
        r1 += increment * sign;
        start = end;
        start_ns = end_ns;
        end = switch (r.smallest) {
            .year => .{ .years = r1 + increment * sign },
            .month => .{ .years = d.years, .months = r1 + increment * sign },
            .week => .{ .years = d.years, .months = d.months, .weeks = r1 + increment * sign },
            .day => .{ .years = d.years, .months = d.months, .weeks = d.weeks, .days = r1 + increment * sign },
            else => unreachable,
        };
        try checkDate(end);
        end_ns = try epochOf(zone, .{ .date = try dateAdd(origin.date, end, .constrain), .time = origin.time });
    }
    var num = start_ns.durationTo(dest) catch return error.OutOfRange;
    var den = start_ns.durationTo(end_ns) catch return error.OutOfRange;
    if (sign < 0) {
        num = num.negate() catch return error.OutOfRange;
        den = den.negate() catch return error.OutOfRange;
    }
    if (!(den.compare(zero) == .gt and num.compare(zero) != .lt and num.compare(den) != .gt)) return error.OutOfRange;
    const r1_abs: i64 = @intCast(@abs(r1));
    const up = round.toSecondNs(num, den, round.unsignedMode(r.mode, sign < 0), @mod(@divTrunc(r1_abs, increment), 2) == 0);
    // The total: r1 + progress × increment × sign, as one ratio.
    const whole = den.mul(r1) catch return error.OutOfRange;
    const progress = num.mul(@as(i128, sign) * increment) catch return error.OutOfRange;
    const numerator = whole.add(progress) catch return error.OutOfRange;
    return if (up)
        .{ .duration = .{ .date = end }, .nudged = end_ns, .expanded = true, .numerator = numerator, .denominator = den }
    else
        .{ .duration = .{ .date = start }, .nudged = start_ns, .expanded = false, .numerator = numerator, .denominator = den };
}

fn truncate(x: i64, increment: i64) i64 {
    return @intCast(round.toIncrement(x, increment, .trunc));
}

/// NudgeToDayOrTime: the days and time as one exact count, rounded; whether that carried into a
/// new day (in the duration's direction) decides bubbling.
fn nudgeToDayOrTime(duration: Internal, dest: Epoch, r: Rounding) RangeError!Nudge {
    const time = try addDays(duration.time, duration.date.days);
    const rounded = try checkTime(try round.toIncrementNs(time, lengthOf(r.smallest, r.increment), r.mode));
    const whole_days = time.ratio(one_day) catch return error.OutOfRange;
    const rounded_days = rounded.ratio(one_day) catch return error.OutOfRange;
    const expanded = signOf(rounded_days - whole_days) == signOfNs(time);
    var date = duration.date;
    date.days = 0;
    var remainder = rounded;
    if (isDate(r.largest)) {
        date.days = @intCast(rounded_days);
        remainder = rounded.sub(one_day.mul(rounded_days) catch return error.OutOfRange) catch return error.OutOfRange;
    }
    try checkDate(date);
    const moved = rounded.sub(time) catch return error.OutOfRange;
    return .{ .duration = .{ .date = date, .time = remainder }, .nudged = dest.add(moved) catch return error.OutOfRange, .expanded = expanded };
}

/// NudgeToZonedTime: the time rounded within the day the date part reaches, that day as long as
/// the zone makes it; rounding past its end carries a day and rounds what lies beyond again.
fn nudgeToZonedTime(sign: i2, duration: Internal, origin: IsoDateTime, zone: Zone, r: Rounding) RangeError!Nudge {
    const start: IsoDateTime = .{ .date = try dateAdd(origin.date, duration.date, .constrain), .time = origin.time };
    const end = try nextDay(start, sign);
    const start_ns = try zone.instantOf(start);
    const end_ns = try zone.instantOf(end);
    const day_span = start_ns.durationTo(end_ns) catch return error.OutOfRange;
    const step = lengthOf(r.smallest, r.increment);
    var rounded = try checkTime(try round.toIncrementNs(duration.time, step, r.mode));
    const beyond = rounded.sub(day_span) catch return error.OutOfRange;
    var date = duration.date;
    var nudged: Epoch = undefined;
    var expanded = false;
    if (signOfNs(beyond) != -sign) {
        expanded = true;
        date.days += sign;
        rounded = try checkTime(try round.toIncrementNs(beyond, step, r.mode));
        nudged = end_ns.add(rounded) catch return error.OutOfRange;
    } else {
        nudged = start_ns.add(rounded) catch return error.OutOfRange;
    }
    try checkDate(date);
    return .{ .duration = .{ .date = date, .time = rounded }, .nudged = nudged, .expanded = expanded };
}

/// BubbleRelativeDuration: after rounding carried into a larger unit, each unit up to `largest`
/// takes one more where the rounded end reaches that unit's next boundary.
fn bubble(sign: i2, duration: Internal, nudged: Epoch, origin: IsoDateTime, zone: ?Zone, largest: Unit, smallest: Unit) RangeError!Internal {
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
        const end_ns = try epochOf(zone, .{ .date = try dateAdd(origin.date, end, .constrain), .time = origin.time });
        if (signOfNs(end_ns.durationTo(nudged) catch return error.OutOfRange) == -sign) break;
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
    const constrained = regulate(balanceYearMonth(one.year + years, @as(i64, one.month) + months), one.day, .constrain) catch aegis.assert.never("constrain clamps the day to its month, and refuses nothing");
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

test "a ratio to the nearest f64, rounded once" {
    const t = std.testing;
    try t.expectEqual(@as(f64, 1.5), ratioToF64(.fromRaw(3), .fromRaw(2)));
    try t.expectEqual(@as(f64, -0.1), ratioToF64(.fromRaw(-1), .fromRaw(10)));
    try t.expectEqual(@as(f64, 1.0 / 3.0), ratioToF64(.fromRaw(1), .fromRaw(3)));
    try t.expectEqual(@as(f64, 9007199254740992), ratioToF64(.fromRaw(9007199254740993), .fromRaw(1)));
    try t.expectEqual(@as(f64, 9007199254740996), ratioToF64(.fromRaw(9007199254740995), .fromRaw(1)));
    // Past an i64, and a ratio whose naive f64 division rounds twice.
    try t.expectEqual(@as(f64, 1e30), ratioToF64(.fromRaw(1_000_000_000_000_000_000_000_000_000_000), .fromRaw(1)));
    try t.expectEqual(@as(f64, 2.0 / 3.0), ratioToF64(.fromRaw(2 * 86_400_000_000_000), .fromRaw(3 * 86_400_000_000_000)));
}
