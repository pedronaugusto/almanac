//! Reading ISO 8601 and RFC 9557 text as Temporal reads it: dates (extended and basic, six-digit
//! signed years), times (fractions to the nanosecond, a leap second read as :59), UTC offsets,
//! bracketed annotations (a time zone, a calendar, others kept or refused), and durations. This is
//! the lenient reading; `strict.zig` answers whether a text is exactly RFC 3339.
const std = @import("std");
const units = @import("../units.zig");
const calendar = @import("../calendar.zig");
const Offset = units.Offset;

/// A date read and checked: its day against its month, its year in almanac's range.
pub const CivilDate = struct { year: i16, month: u8, day: u8 };
/// A time read and checked; a leap second already read as :59.
pub const CivilTime = struct { hour: u8 = 0, minute: u8 = 0, second: u8 = 0, nanosecond: u32 = 0 };

/// A duration read: one sign and its magnitudes, unbounded but by their types (the span checks
/// Temporal's bounds).
pub const DurationText = struct {
    negative: bool = false,
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

/// `Invalid`: the text is not what was asked for; `Diagnostic` says where and what was expected.
pub const ParseError = error{Invalid};

pub const Diagnostic = struct {
    /// The byte the reading stopped at.
    offset: usize = 0,
    expected: []const u8 = "",
};

pub const Options = struct {
    /// An annotation of a key almanac does not know (`[foo=bar]`): passed over, or refused. A
    /// critical one (`[!foo=bar]`) is always refused.
    unknown_annotations: enum { ignore, refuse } = .ignore,
    diagnostic: ?*Diagnostic = null,
};

/// A written UTC offset: `Z`, or a signed offset and whether it was written to the second.
pub const WrittenOffset = union(enum) {
    z,
    numeric: struct { offset: Offset, seconds: bool },
};

/// A time zone annotation: an IANA name or an offset (to the minute).
pub const ZoneAnnotation = union(enum) {
    name: []const u8,
    offset: Offset,
};

/// What a date-time text holds.
pub const DateTimeText = struct {
    date: CivilDate,
    time: ?CivilTime = null,
    offset: ?WrittenOffset = null,
    zone: ?ZoneAnnotation = null,
};

/// Records where reading stopped and refuses.
pub fn refuse(options: Options, offset: usize, expected: []const u8) ParseError {
    if (options.diagnostic) |d| d.* = .{ .offset = offset, .expected = expected };
    return error.Invalid;
}

const Reader = struct {
    text: []const u8,
    at: usize = 0,
    options: Options,

    fn fail(r: *Reader, expected: []const u8) ParseError {
        if (r.options.diagnostic) |d| d.* = .{ .offset = r.at, .expected = expected };
        return error.Invalid;
    }

    fn peek(r: *const Reader) ?u8 {
        return if (r.at < r.text.len) r.text[r.at] else null;
    }

    fn eat(r: *Reader, c: u8) bool {
        if (r.peek() != c) return false;
        r.at += 1;
        return true;
    }

    fn eatAny(r: *Reader, cs: []const u8) bool {
        const c = r.peek() orelse return false;
        if (std.mem.findScalar(u8, cs, c) == null) return false;
        r.at += 1;
        return true;
    }

    fn isDigit(r: *const Reader, ahead: usize) bool {
        return r.at + ahead < r.text.len and std.ascii.isDigit(r.text[r.at + ahead]);
    }

    /// Exactly `n` digits.
    fn digits(r: *Reader, n: usize, expected: []const u8) ParseError!u32 {
        var v: u32 = 0;
        for (0..n) |_| {
            const c = r.peek() orelse return r.fail(expected);
            if (!std.ascii.isDigit(c)) return r.fail(expected);
            v = v * 10 + (c - '0');
            r.at += 1;
        }
        return v;
    }

    /// One or more digits, as a u64.
    fn integer(r: *Reader) ParseError!u64 {
        var v: u64 = 0;
        var count: usize = 0;
        while (r.peek()) |c| {
            if (!std.ascii.isDigit(c)) break;
            v = std.math.mul(u64, v, 10) catch return r.fail("a smaller number");
            v = std.math.add(u64, v, c - '0') catch return r.fail("a smaller number");
            count += 1;
            r.at += 1;
        }
        if (count == 0) return r.fail("a digit");
        return v;
    }

    /// A sign: `+`, `-` or U+2212 MINUS SIGN.
    fn sign(r: *Reader) ?i2 {
        if (r.eat('+')) return 1;
        if (r.eat('-')) return -1;
        if (std.mem.startsWith(u8, r.text[r.at..], "\u{2212}")) {
            r.at += 3;
            return -1;
        }
        return null;
    }

    /// A decimal fraction after `.` or `,`: one to nine digits, as nanoseconds.
    fn fraction(r: *Reader) ParseError!?u32 {
        if (!r.eatAny(".,")) return null;
        var ns: u32 = 0;
        var count: usize = 0;
        while (r.peek()) |c| {
            if (!std.ascii.isDigit(c)) break;
            if (count == 9) return r.fail("at most nine fractional digits");
            ns = ns * 10 + (c - '0');
            count += 1;
            r.at += 1;
        }
        if (count == 0) return r.fail("a fractional digit");
        while (count < 9) : (count += 1) ns *= 10;
        return ns;
    }

    fn date(r: *Reader) ParseError!CivilDate {
        var y: i32 = undefined;
        if (r.sign()) |s| {
            const v: i32 = @intCast(try r.digits(6, "six year digits after a sign"));
            if (s < 0 and v == 0) return r.fail("a year other than -000000");
            y = s * v;
        } else y = @intCast(try r.digits(4, "a four-digit year"));
        const extended = r.eat('-');
        const m = try r.digits(2, "a two-digit month");
        if (extended and !r.eat('-')) return r.fail("'-' before the day");
        const d = try r.digits(2, "a two-digit day");
        if (y < -9999 or y > 9999) return r.fail("a year from -9999 to 9999");
        if (m < 1 or m > 12 or d < 1 or d > calendar.daysInMonth(y, m)) return r.fail("a day of that month");
        return .{ .year = @intCast(y), .month = @intCast(m), .day = @intCast(d) };
    }

    /// `HH[:MM[:SS[.f]]]` or `HH[MM[SS[.f]]]`; a second of 60 is read as 59.
    fn time(r: *Reader) ParseError!CivilTime {
        const h = try r.digits(2, "a two-digit hour");
        var m: u32 = 0;
        var s: u32 = 0;
        var ns: u32 = 0;
        const extended = r.peek() == ':';
        if ((extended and r.isDigit(1)) or (!extended and r.isDigit(0))) {
            if (extended) r.at += 1;
            m = try r.digits(2, "a two-digit minute");
            if ((extended and r.peek() == ':' and r.isDigit(1)) or (!extended and r.isDigit(0))) {
                if (extended) r.at += 1;
                s = try r.digits(2, "a two-digit second");
                ns = (try r.fraction()) orelse 0;
            }
        }
        if (s == 60) s = 59;
        if (h > 23 or m > 59 or s > 59) return r.fail("an hour to 23, a minute and second to 59");
        return .{ .hour = @intCast(h), .minute = @intCast(m), .second = @intCast(s), .nanosecond = ns };
    }

    /// `Z`, or `±HH[:MM[:SS[.f]]]` (or basic). Sub-second offsets are refused: almanac's offsets
    /// are whole seconds.
    fn offset(r: *Reader) ParseError!?WrittenOffset {
        if (r.eatAny("Zz")) return .z;
        const s = r.sign() orelse return null;
        const h = try r.digits(2, "a two-digit offset hour");
        var total: i32 = @intCast(h * 3600);
        var seconds = false;
        const extended = r.peek() == ':';
        if ((extended and r.isDigit(1)) or (!extended and r.isDigit(0))) {
            if (extended) r.at += 1;
            total += @intCast(try r.digits(2, "two offset minute digits") * 60);
            if ((extended and r.peek() == ':' and r.isDigit(1)) or (!extended and r.isDigit(0))) {
                if (extended) r.at += 1;
                total += @intCast(try r.digits(2, "two offset second digits"));
                seconds = true;
                if ((try r.fraction()) orelse 0 != 0) return r.fail("an offset in whole seconds");
            }
        }
        if (h > 23 or @mod(@divTrunc(total, 60), 60) > 59) return r.fail("an offset hour to 23 and minute to 59");
        return .{ .numeric = .{ .offset = Offset.init(s * total) catch return r.fail("an offset within a day"), .seconds = seconds } };
    }

    /// The bracketed annotations: a time zone first, at most once; `u-ca` naming `iso8601`; any
    /// other key passed over or refused.
    fn annotations(r: *Reader, out: *DateTimeText) ParseError!void {
        var first = true;
        var calendars: usize = 0;
        var critical_calendar = false;
        while (r.eat('[')) : (first = false) {
            const critical = r.eat('!');
            const close = std.mem.findScalarPos(u8, r.text, r.at, ']') orelse return r.fail("']'");
            const body = r.text[r.at..close];
            if (std.mem.findScalar(u8, body, '=')) |eq| {
                const key = body[0..eq];
                const value = body[eq + 1 ..];
                if (!validKey(key) or !validValue(value)) return r.fail("an annotation key=value");
                if (std.mem.eql(u8, key, "u-ca")) {
                    calendars += 1;
                    critical_calendar = critical_calendar or critical;
                    if (!std.ascii.eqlIgnoreCase(value, "iso8601")) return r.fail("the ISO 8601 calendar");
                } else if (critical or r.options.unknown_annotations == .refuse) {
                    return r.fail("an annotation almanac knows");
                }
            } else {
                if (!first or out.zone != null) return r.fail("one time zone annotation, first");
                out.zone = try zoneAnnotation(r, body);
            }
            r.at = close + 1;
        }
        if (calendars > 1 and critical_calendar) return r.fail("one critical calendar annotation");
    }

    fn zoneAnnotation(r: *Reader, body: []const u8) ParseError!ZoneAnnotation {
        if (body.len > 0 and (body[0] == '+' or body[0] == '-' or std.mem.startsWith(u8, body, "\u{2212}"))) {
            var inner: Reader = .{ .text = body, .options = r.options };
            const o = (try inner.offset()) orelse return r.fail("an offset");
            if (inner.at != body.len or o.numeric.seconds) return r.fail("an offset to the minute");
            return .{ .offset = o.numeric.offset };
        }
        if (!validZoneName(body)) return r.fail("a time zone name");
        return .{ .name = body };
    }
};

fn validKey(key: []const u8) bool {
    if (key.len == 0 or !(std.ascii.isLower(key[0]) or key[0] == '_')) return false;
    for (key) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_' or c == '-')) return false;
    return true;
}

fn validValue(value: []const u8) bool {
    var parts = std.mem.splitScalar(u8, value, '-');
    while (parts.next()) |part| {
        if (part.len < 3 or part.len > 8) return false;
        for (part) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    }
    return true;
}

/// Temporal's time zone identifier: components of letters, digits, `.`, `_`, `-` and `+`, none
/// starting with a digit, `-` or `+`, and none `.` or `..`.
fn validZoneName(name: []const u8) bool {
    if (name.len == 0) return false;
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        if (!(std.ascii.isAlphabetic(part[0]) or part[0] == '.' or part[0] == '_')) return false;
        for (part) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-' or c == '+')) return false;
    }
    return true;
}

/// A date, optionally a time after `T`, `t` or a space, optionally an offset, then annotations.
pub fn dateTime(text: []const u8, options: Options) ParseError!DateTimeText {
    var r: Reader = .{ .text = text, .options = options };
    var out: DateTimeText = .{ .date = try r.date() };
    if (r.eatAny("Tt ")) {
        out.time = try r.time();
        out.offset = try r.offset();
    }
    try r.annotations(&out);
    if (r.at != text.len) return r.fail("the end of the text");
    return out;
}

/// A time of day alone: `[T]HH:MM[:SS[.f]]` (with `T`, the basic form too), an offset and
/// annotations allowed after it; or a whole date-time, whose time is taken.
pub fn timeOfDay(text: []const u8, options: Options) ParseError!CivilTime {
    if (dateTime(text, options)) |dt| {
        return dt.time orelse error.Invalid;
    } else |_| {}
    var r: Reader = .{ .text = text, .options = options };
    const designated = r.eatAny("Tt");
    if (!designated and !(text.len > 2 and text[2] == ':')) return r.fail("a time with ':' or after 'T'");
    var out: DateTimeText = .{ .date = .{ .year = 1970, .month = 1, .day = 1 } };
    const t = try r.time();
    out.offset = try r.offset();
    if (out.offset != null and out.offset.? == .z) return r.fail("no 'Z' on a time without a date");
    try r.annotations(&out);
    if (r.at != text.len) return r.fail("the end of the text");
    return t;
}

/// An ISO 8601 duration as Temporal reads it: an optional sign, `P`, years, months, weeks and days,
/// then `T` and hours, minutes and seconds, each optional but one required; the last given may have
/// a fraction of up to nine digits, carried into the units below it.
pub fn duration(text: []const u8, options: Options) ParseError!DurationText {
    var r: Reader = .{ .text = text, .options = options };
    const negative = (r.sign() orelse 1) < 0;
    if (!r.eatAny("Pp")) return r.fail("'P'");
    var f: DurationText = .{ .negative = negative };
    var any = false;
    var fraction_ns: ?u64 = null;
    var fraction_unit: u8 = 0;
    const date_units = "YMWD";
    var next_date: usize = 0;
    while (r.isDigit(0)) {
        const v = try r.integer();
        const ns = try r.fraction();
        const c = std.ascii.toUpper(r.peek() orelse return r.fail("a unit"));
        const index = std.mem.findScalarPos(u8, date_units, next_date, c) orelse return r.fail("Y, M, W or D in order");
        if (ns != null) return r.fail("no fraction on a date unit");
        r.at += 1;
        next_date = index + 1;
        any = true;
        switch (c) {
            'Y' => f.years = std.math.cast(u32, v) orelse return r.fail("years below 2^32"),
            'M' => f.months = std.math.cast(u32, v) orelse return r.fail("months below 2^32"),
            'W' => f.weeks = std.math.cast(u32, v) orelse return r.fail("weeks below 2^32"),
            'D' => f.days = v,
            else => unreachable,
        }
    }
    if (r.eatAny("Tt")) {
        const time_units = "HMS";
        var next_time: usize = 0;
        var any_time = false;
        while (r.isDigit(0)) {
            if (fraction_ns != null) return r.fail("nothing after a fractional unit");
            const v = try r.integer();
            const ns = try r.fraction();
            const c = std.ascii.toUpper(r.peek() orelse return r.fail("a unit"));
            const index = std.mem.findScalarPos(u8, time_units, next_time, c) orelse return r.fail("H, M or S in order");
            r.at += 1;
            next_time = index + 1;
            any_time = true;
            switch (c) {
                'H' => f.hours = v,
                'M' => f.minutes = v,
                'S' => f.seconds = v,
                else => unreachable,
            }
            if (ns) |n| {
                fraction_ns = n;
                fraction_unit = c;
            }
        }
        if (!any_time) return r.fail("a time unit after 'T'");
        any = true;
    }
    if (!any) return r.fail("a unit");
    if (r.at != text.len) return r.fail("the end of the text");
    if (fraction_ns) |n| {
        // A fraction of the unit, in nanoseconds of it, then split into the units below.
        const scale: u128 = switch (fraction_unit) {
            'H' => 3600,
            'M' => 60,
            else => 1,
        };
        var rest: u128 = @as(u128, n) * scale;
        if (fraction_unit == 'H') {
            f.minutes = @intCast(rest / (60 * std.time.ns_per_s));
            rest %= 60 * std.time.ns_per_s;
        }
        if (fraction_unit != 'S') {
            f.seconds = @intCast(rest / std.time.ns_per_s);
            rest %= std.time.ns_per_s;
        } else rest %= std.time.ns_per_s;
        f.milliseconds = @intCast(rest / std.time.ns_per_ms);
        f.microseconds = rest / std.time.ns_per_us % 1000;
        f.nanoseconds = rest % 1000;
    }
    return f;
}
