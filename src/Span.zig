//! A span of calendar and clock units: Temporal's `Duration`. One sign and unsigned magnitudes, so a
//! mixed-sign span cannot be built; each field bounded as Temporal's IsValidDuration bounds it:
//! years, months and weeks below 2^32, and the days and time fields together below 2^53 seconds.
//! Years, months and weeks have no fixed length, so comparing, rounding or adding spans that hold
//! them takes a date to measure from (`RelativeTo`).
const Span = @This();
const std = @import("std");
const aegis = @import("aegis");
const Ranged = aegis.int.Ranged;
const units = @import("units.zig");
const arithmetic = @import("arithmetic.zig");
const rounding = @import("round.zig");
const write = @import("text/write.zig");
const reading = @import("text/iso.zig");
const Unit = units.Unit;

pub const RangeError = units.RangeError;
pub const ArithmeticError = units.ArithmeticError;

const Ns = arithmetic.Ns;
const max_seconds: u128 = (1 << 53) - 1;

pub const Calendar = Ranged(u32, 0, std.math.maxInt(u32));

sign: Sign = .positive,
years: Calendar = .literal(0),
months: Calendar = .literal(0),
weeks: Calendar = .literal(0),
days: Ranged(u64, 0, arithmetic.max_days) = .literal(0),
hours: Ranged(u64, 0, max_seconds / 3600) = .literal(0),
minutes: Ranged(u64, 0, max_seconds / 60) = .literal(0),
seconds: Ranged(u64, 0, max_seconds) = .literal(0),
milliseconds: Ranged(u64, 0, (max_seconds + 1) * 1000 - 1) = .literal(0),
microseconds: Ranged(u128, 0, (max_seconds + 1) * 1_000_000 - 1) = .literal(0),
nanoseconds: Ranged(u128, 0, arithmetic.max_time_count) = .literal(0),

pub const Sign = enum { positive, negative };

pub const zero: Span = .{};

/// A span's magnitudes; `init` checks each and the joint bound.
pub const Fields = struct {
    years: u32 = 0,
    months: u32 = 0,
    weeks: u32 = 0,
    days: u64 = 0,
    hours: u64 = 0,
    minutes: u64 = 0,
    seconds: u64 = 0,
    milliseconds: u64 = 0,
    microseconds: u128 = 0,
    nanoseconds: u128 = 0,
};

/// A span from signed fields, as Temporal's `Duration` constructor takes them: all of one sign.
pub const Signed = struct {
    years: i64 = 0,
    months: i64 = 0,
    weeks: i64 = 0,
    days: i64 = 0,
    hours: i64 = 0,
    minutes: i64 = 0,
    seconds: i64 = 0,
    milliseconds: i64 = 0,
    microseconds: i128 = 0,
    nanoseconds: i128 = 0,
};

/// The span, each field within its range and the days and time fields together below 2^53
/// seconds. A span of zero is positive.
pub fn init(sign: Sign, fields: Fields) RangeError!Span {
    var out: Span = .{
        .sign = sign,
        // Every u32 is in range.
        .years = Calendar.init(fields.years) catch aegis.assert.never("every u32 is in a calendar unit's range"),
        .months = Calendar.init(fields.months) catch aegis.assert.never("every u32 is in a calendar unit's range"),
        .weeks = Calendar.init(fields.weeks) catch aegis.assert.never("every u32 is in a calendar unit's range"),
        .days = try .init(fields.days),
        .hours = try .init(fields.hours),
        .minutes = try .init(fields.minutes),
        .seconds = try .init(fields.seconds),
        .milliseconds = try .init(fields.milliseconds),
        .microseconds = try .init(fields.microseconds),
        .nanoseconds = try .init(fields.nanoseconds),
    };
    if (out.magnitude().compare(arithmetic.max_time) == .gt) return error.OutOfRange;
    if (out.isZero()) out.sign = .positive;
    return out;
}

/// The span of signed fields, refused if they mix signs (Temporal's IsValidDuration).
pub fn fromSigned(f: Signed) RangeError!Span {
    var positive = false;
    var negative = false;
    inline for (@typeInfo(Signed).@"struct".field_names) |name| {
        const v = @field(f, name);
        positive = positive or v > 0;
        negative = negative or v < 0;
    }
    if (positive and negative) return error.OutOfRange;
    var fields: Fields = .{};
    inline for (@typeInfo(Signed).@"struct".field_names) |name| {
        const size = @abs(@field(f, name));
        if (size > std.math.maxInt(@FieldType(Fields, name))) return error.OutOfRange;
        @field(fields, name) = @intCast(size);
    }
    return init(if (negative) .negative else .positive, fields);
}

/// A field counted in `unit`, as nanoseconds: each field's range does, and the seven together.
fn inNs(comptime unit: aegis.units.Unit, field: anytype) Ns {
    return arithmetic.toNs(unit, .fromRanged(field));
}

/// The sum of lengths each under Temporal's bound, a few of them: no i128 overflows.
fn sum(parts: []const Ns) Ns {
    var out = arithmetic.zero;
    for (parts) |part| out = out.add(part) catch aegis.assert.never("a few lengths under Temporal's bound sum inside an i128");
    return out;
}

/// The days and time fields as one length, unsigned.
fn magnitude(s: Span) Ns {
    return sum(&.{ inNs(.day, s.days), s.time() });
}

/// The time fields, from the hours down, as one length, unsigned.
fn time(s: Span) Ns {
    return sum(&.{ inNs(.hour, s.hours), inNs(.minute, s.minutes), s.second() });
}

/// The seconds and their fractions as one length, unsigned: what `format` writes as seconds.
fn second(s: Span) Ns {
    return sum(&.{ inNs(.second, s.seconds), inNs(.millisecond, s.milliseconds), inNs(.microsecond, s.microseconds), inNs(.nanosecond, s.nanoseconds) });
}

/// A field's value with the span's sign.
pub fn get(s: Span, unit: Unit) i128 {
    const v: i128 = switch (unit) {
        .year => s.years.raw(),
        .month => s.months.raw(),
        .week => s.weeks.raw(),
        .day => s.days.raw(),
        .hour => s.hours.raw(),
        .minute => s.minutes.raw(),
        .second => s.seconds.raw(),
        .millisecond => s.milliseconds.raw(),
        .microsecond => s.microseconds.widen(i128),
        .nanosecond => s.nanoseconds.widen(i128),
    };
    return if (s.sign == .negative) -v else v;
}

pub fn isZero(s: Span) bool {
    return s.years.eql(.literal(0)) and s.months.eql(.literal(0)) and s.weeks.eql(.literal(0)) and s.magnitude().eql(arithmetic.zero);
}

/// -1, 0 or 1.
pub fn signum(s: Span) i2 {
    if (s.isZero()) return 0;
    return if (s.sign == .negative) -1 else 1;
}

pub fn negate(s: Span) Span {
    if (s.isZero()) return s;
    var out = s;
    out.sign = if (s.sign == .negative) .positive else .negative;
    return out;
}

pub fn abs(s: Span) Span {
    var out = s;
    out.sign = .positive;
    return out;
}

/// The largest unit with a nonzero field, or the nanosecond (DefaultTemporalLargestUnit).
pub fn largestUnit(s: Span) Unit {
    for (std.enums.values(Unit)) |u| if (s.get(u) != 0) return u;
    return .nanosecond;
}

pub fn eql(a: Span, b: Span) bool {
    for (std.enums.values(Unit)) |u| if (a.get(u) != b.get(u)) return false;
    return true;
}

// Temporal's internal records.

/// ToInternalDurationRecord. A span built as a literal past the joint bound is refused here.
pub fn toInternal(s: Span) RangeError!arithmetic.Internal {
    if (s.magnitude().compare(arithmetic.max_time) == .gt) return error.OutOfRange;
    const negative = s.sign == .negative;
    const t = s.time();
    const date: arithmetic.DateRec = .{
        .years = s.years.widen(i64),
        .months = s.months.widen(i64),
        .weeks = s.weeks.widen(i64),
        .days = s.days.widen(i64),
    };
    return if (negative)
        .{ .date = .{ .years = -date.years, .months = -date.months, .weeks = -date.weeks, .days = -date.days }, .time = t.negate() catch aegis.assert.never("a length under Temporal's bound negates") }
    else
        .{ .date = date, .time = t };
}

/// ToInternalDurationRecordWith24HourDays: the days counted into the time.
pub fn toInternalDays(s: Span) RangeError!arithmetic.Internal {
    var d = try s.toInternal();
    d.time = try arithmetic.addDays(d.time, d.date.days);
    d.date.days = 0;
    return d;
}

/// TemporalDurationFromInternal: the time balanced up to `largest` (to days when that is a date
/// unit), each field signed as the time is.
pub fn fromInternal(d: arithmetic.Internal, largest: Unit) RangeError!Span {
    const sign: i128 = arithmetic.signOfNs(d.time);
    if ((d.time.abs() catch return error.OutOfRange).compare(arithmetic.max_time) == .gt) return error.OutOfRange;
    var rest = d.time.abs() catch return error.OutOfRange;
    var out: [7]i128 = @splat(0); // days, hours, minutes, seconds, ms, µs, ns
    const lengths = [_]Ns{ arithmetic.one_day, arithmetic.length(.hour), arithmetic.length(.minute), arithmetic.length(.second), arithmetic.length(.millisecond), arithmetic.length(.microsecond), arithmetic.length(.nanosecond) };
    // How many of the fields from the day down are kept: date units keep all seven.
    const kept: usize = switch (largest) {
        .year, .month, .week, .day => 7,
        .hour => 6,
        .minute => 5,
        .second => 4,
        .millisecond => 3,
        .microsecond => 2,
        .nanosecond => 1,
    };
    // The largest field kept takes all the whole units of it; each below takes what is left.
    for (7 - kept..7) |i| {
        out[i] = rest.ratio(lengths[i]) catch aegis.assert.never("a unit has some length");
        rest = rest.mod(lengths[i]) catch aegis.assert.never("a unit has some length");
    }
    // The time is within 2^53 seconds, so every field but the microseconds and nanoseconds fits an
    // i64 at any balance.
    const signed = struct {
        fn f(v: i128, s: i128) i128 {
            return v * s;
        }
    }.f;
    return fromSigned(.{
        .years = d.date.years,
        .months = d.date.months,
        .weeks = d.date.weeks,
        .days = d.date.days + @as(i64, @intCast(signed(out[0], sign))),
        .hours = @intCast(signed(out[1], sign)),
        .minutes = @intCast(signed(out[2], sign)),
        .seconds = @intCast(signed(out[3], sign)),
        .milliseconds = @intCast(signed(out[4], sign)),
        .microseconds = signed(out[5], sign),
        .nanoseconds = signed(out[6], sign),
    });
}

/// What gives calendar units a length: made by `Date.relativeTo` or `Zoned.relativeTo`. The span
/// sits beneath the types it is added to, so it holds their records, not them.
pub const RelativeTo = union(enum) {
    date: arithmetic.IsoDate,
    /// An instant and its zone: days as the zone makes them.
    zoned: struct { ns: arithmetic.Epoch, zone: arithmetic.Zone },
};

/// Temporal's `Duration.prototype.add`: spans of days and time only (a day is 24 hours), the sum
/// balanced up to the larger of the two largest units.
pub fn add(a: Span, b: Span) ArithmeticError!Span {
    const largest = arithmetic.larger(a.largestUnit(), b.largestUnit());
    if (arithmetic.isCalendar(largest)) return error.CalendarUnits;
    const total_time = (try a.toInternalDays()).time.add((try b.toInternalDays()).time) catch return error.OutOfRange;
    return fromInternal(.{ .time = try arithmetic.checkTime(total_time) }, largest);
}

pub fn subtract(a: Span, b: Span) ArithmeticError!Span {
    return add(a, b.negate());
}

/// Temporal's `Duration.compare`: by length, calendar units measured from `relative_to`.
pub fn compare(a: Span, b: Span, relative_to: ?RelativeTo) ArithmeticError!std.math.Order {
    if (a.eql(b)) return .eq;
    const calendar_units = arithmetic.isCalendar(a.largestUnit()) or arithmetic.isCalendar(b.largestUnit());
    const ia = try a.toInternal();
    const ib = try b.toInternal();
    var days_a = ia.date.days;
    var days_b = ib.date.days;
    if (relative_to) |rel| switch (rel) {
        .zoned => |z| if (arithmetic.isDate(a.largestUnit()) or arithmetic.isDate(b.largestUnit())) {
            const after_a = try arithmetic.zonedAdd(z.zone, z.ns, ia, .constrain);
            const after_b = try arithmetic.zonedAdd(z.zone, z.ns, ib, .constrain);
            return after_a.compare(after_b);
        },
        .date => {},
    };
    if (calendar_units) {
        const rel = relative_to orelse return error.CalendarUnits;
        days_a = try dateDurationDays(ia.date, rel.date);
        days_b = try dateDurationDays(ib.date, rel.date);
    }
    const ta = try arithmetic.addDays(ia.time, days_a);
    const tb = try arithmetic.addDays(ib.time, days_b);
    return ta.compare(tb);
}

/// DateDurationDays: a date part's length in days from `origin`.
fn dateDurationDays(d: arithmetic.DateRec, origin: arithmetic.IsoDate) RangeError!i64 {
    const calendar_part: arithmetic.DateRec = .{ .years = d.years, .months = d.months, .weeks = d.weeks };
    if (calendar_part.sign() == 0) return d.days;
    const later = try arithmetic.dateAdd(origin, calendar_part, .constrain);
    return d.days + later.epochDays() - origin.epochDays();
}

pub const Round = struct {
    /// The largest unit of the result; null for the larger of the span's own and `smallest`
    /// (Temporal's `auto`).
    largest: ?Unit = null,
    /// The unit rounded to; null for the nanosecond. With neither unit given, the span is balanced
    /// up to its own largest unit.
    smallest: ?Unit = null,
    increment: u32 = 1,
    mode: units.RoundingMode = .half_expand,
    relative_to: ?RelativeTo = null,
};

/// Temporal's `Duration.prototype.round`: rounded to a multiple of `increment` in `smallest` and
/// balanced up to `largest`. Rounding to the nanosecond balances.
pub fn round(s: Span, options: Round) ArithmeticError!Span {
    const smallest = options.smallest orelse .nanosecond;
    const existing = s.largestUnit();
    const largest = options.largest orelse arithmetic.larger(existing, smallest);
    if (arithmetic.larger(largest, smallest) != largest) return error.InvalidOptions;
    try arithmetic.checkIncrement(options.increment, smallest);
    if (options.increment > 1 and largest != smallest and arithmetic.isDate(smallest)) return error.InvalidOptions;
    const r: arithmetic.Rounding = .{ .largest = largest, .smallest = smallest, .increment = options.increment, .mode = options.mode };

    if (options.relative_to) |rel| if (rel == .zoned) {
        const z = rel.zoned;
        const target = try arithmetic.zonedAdd(z.zone, z.ns, try s.toInternal(), .constrain);
        if (!arithmetic.isDate(largest)) {
            const elapsed = z.ns.durationTo(target) catch return error.OutOfRange;
            const rounded = try arithmetic.checkTime(try rounding.toIncrementNs(elapsed, arithmetic.lengthOf(smallest, options.increment), options.mode));
            return fromInternal(.{ .time = rounded }, largest);
        }
        return fromInternal(try arithmetic.zonedUntilRounded(z.zone, z.ns, target, r), .hour);
    };

    if (options.relative_to) |rel| {
        const d = try s.toInternalDays();
        // The time reached from midnight, its whole days carried into the date part.
        const carried: i64 = @intCast(d.time.ratioFloor(arithmetic.one_day) catch return error.OutOfRange);
        const of_day = d.time.mod(arithmetic.one_day) catch return error.OutOfRange;
        var date = d.date;
        date.days = carried;
        try arithmetic.checkDate(date);
        const origin = rel.date;
        const target = try arithmetic.dateAdd(origin, date, .constrain);
        const result = try arithmetic.dateTimeUntilRounded(.{ .date = origin }, .{ .date = target, .time = of_day }, r);
        return fromInternal(result, largest);
    }

    if (arithmetic.isCalendar(existing) or arithmetic.isCalendar(largest)) return error.CalendarUnits;
    const d = try s.toInternalDays();
    if (smallest == .day) {
        const rounded = try rounding.toIncrementNs(d.time, arithmetic.lengthOf(.day, options.increment), options.mode);
        const days: arithmetic.DateRec = .{ .days = @intCast(rounded.ratio(arithmetic.one_day) catch return error.OutOfRange) };
        try arithmetic.checkDate(days);
        return fromInternal(.{ .date = days }, largest);
    }
    const rounded = try arithmetic.checkTime(try rounding.toIncrementNs(d.time, arithmetic.lengthOf(smallest, options.increment), options.mode));
    return fromInternal(.{ .time = rounded }, largest);
}

/// The most bytes `format` writes: a sign, `P`, three calendar fields of ten digits and days of
/// twelve with their letters, `T`, hours, minutes and seconds with nine fractional digits.
pub const max_text_len = 2 + 3 * 11 + 13 + 1 + 14 + 16 + 27;

/// ISO 8601's duration as Temporal writes it (`P1Y2M3DT4H5M6.5S`, `-PT1H`, `PT0S` for zero): the
/// seconds, milliseconds, microseconds and nanoseconds together as seconds with a fraction.
pub fn format(s: Span, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (s.signum() < 0) try w.writeByte('-');
    try w.writeByte('P');
    const letters = "YMWD";
    for ([_]u64{ s.years.raw(), s.months.raw(), s.weeks.raw(), s.days.raw() }, letters) |v, c| {
        if (v != 0) try w.print("{d}{c}", .{ v, c });
    }
    const sub = s.second();
    const date_zero = s.years.eql(.literal(0)) and s.months.eql(.literal(0)) and s.weeks.eql(.literal(0)) and s.days.eql(.literal(0));
    const no_hours = s.hours.eql(.literal(0));
    const no_minutes = s.minutes.eql(.literal(0));
    if (no_hours and no_minutes and sub.eql(arithmetic.zero)) {
        if (date_zero) try w.writeAll("T0S");
        return;
    }
    try w.writeByte('T');
    if (!no_hours) try w.print("{d}H", .{s.hours.raw()});
    if (!no_minutes) try w.print("{d}M", .{s.minutes.raw()});
    if (!sub.eql(arithmetic.zero)) {
        const one_second = arithmetic.length(.second);
        try w.print("{d}", .{sub.ratio(one_second) catch aegis.assert.never("a second has some length")});
        const fraction = sub.mod(one_second) catch aegis.assert.never("a second has some length");
        try write.fraction(w, (fraction.convert(.nanosecond, u32, .exact) catch aegis.assert.never("what is left of a second fits a u32")).raw());
        try w.writeByte('S');
    }
}

/// A span from an ISO 8601 duration, as `text.parseSpan` reads it.
pub fn parse(text: []const u8) reading.ParseError!Span {
    return fromText(text, .{});
}

pub fn fromText(text: []const u8, options: reading.Options) reading.ParseError!Span {
    const d = try reading.duration(text, options);
    return init(if (d.negative) .negative else .positive, .{
        .years = d.years,
        .months = d.months,
        .weeks = d.weeks,
        .days = d.days,
        .hours = d.hours,
        .minutes = d.minutes,
        .seconds = d.seconds,
        .milliseconds = d.milliseconds,
        .microseconds = d.microseconds,
        .nanoseconds = d.nanoseconds,
    }) catch reading.refuse(options, text.len, "a span within Temporal's bounds");
}

/// Temporal's `Duration.prototype.total`: the span's length in `unit`, as the nearest f64 to the
/// exact value. Calendar units (and, in a zone, days) are measured from `relative_to`.
pub fn total(s: Span, unit: Unit, relative_to: ?RelativeTo) ArithmeticError!f64 {
    if (relative_to) |rel| switch (rel) {
        .zoned => |z| {
            const target = try arithmetic.zonedAdd(z.zone, z.ns, try s.toInternal(), .constrain);
            if (!arithmetic.isDate(unit)) return arithmetic.ratioToF64(z.ns.durationTo(target) catch return error.OutOfRange, arithmetic.length(unit));
            const diff = try arithmetic.zonedUntil(z.zone, z.ns, target, unit);
            return arithmetic.totalRelative(diff, z.ns, target, try z.zone.wallClock(z.ns), z.zone, unit);
        },
        .date => |origin_date| {
            const d = try s.toInternalDays();
            const carried: i64 = @intCast(d.time.ratioFloor(arithmetic.one_day) catch return error.OutOfRange);
            const of_day = d.time.mod(arithmetic.one_day) catch return error.OutOfRange;
            var date = d.date;
            date.days = carried;
            try arithmetic.checkDate(date);
            const target_date = try arithmetic.dateAdd(origin_date, date, .constrain);
            const origin: arithmetic.IsoDateTime = .{ .date = origin_date };
            const target: arithmetic.IsoDateTime = .{ .date = target_date, .time = of_day };
            if (origin.epochNs().eql(target.epochNs())) return 0;
            const diff = try arithmetic.dateTimeUntil(origin, target, unit);
            if (unit == .nanosecond) return arithmetic.ratioToF64(diff.time, arithmetic.length(.nanosecond));
            return arithmetic.totalRelative(diff, origin.epochNs(), target.epochNs(), origin, null, unit);
        },
    };
    if (arithmetic.isCalendar(s.largestUnit()) or arithmetic.isCalendar(unit)) return error.CalendarUnits;
    return arithmetic.ratioToF64((try s.toInternalDays()).time, arithmetic.length(unit));
}
