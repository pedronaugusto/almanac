//! POSIX TZ strings (POSIX.1-2024 §8.3, with RFC 8536 §3.3.1's extensions: rule times from -167
//! to 167 hours, and daylight saving all year): the rule a TZif file's footer and `$TZ` give for
//! times past any table. A string is parsed into a `Rule` of fixed size, and evaluated in closed
//! form: the transitions of the years around an instant, compared.
const std = @import("std");
const units = @import("../units.zig");
const calendar = @import("../calendar.zig");
const Offset = units.Offset;

/// The longest abbreviation kept (`WEST` is four bytes; RFC 8536 asks for 3 to 6).
pub const max_abbreviation = 16;

/// A local time type: an offset from UTC, whether it is daylight saving, and its abbreviation.
pub const Local = struct {
    offset: Offset,
    dst: bool = false,
    abbreviation_len: u8 = 0,
    abbreviation_bytes: [max_abbreviation]u8 = @splat(0),

    pub fn init(offset: Offset, dst: bool, name: []const u8) error{Invalid}!Local {
        if (name.len > max_abbreviation) return error.Invalid;
        var l: Local = .{ .offset = offset, .dst = dst, .abbreviation_len = @intCast(name.len) };
        @memcpy(l.abbreviation_bytes[0..name.len], name);
        return l;
    }

    /// Borrowed from the local time type, so from the zone that holds it.
    pub fn abbreviation(l: *const Local) []const u8 {
        return l.abbreviation_bytes[0..l.abbreviation_len];
    }
};

/// A day of the year a rule names.
pub const Day = union(enum) {
    /// `Jn`: 1 to 365, February 29 never counted.
    julian: u16,
    /// `n`: 0 to 365, February 29 counted in leap years.
    zero_based: u16,
    /// `Mm.w.d`: month 1 to 12, week 1 to 5 (5 is the last), weekday 0 (Sunday) to 6.
    month_week_day: struct { month: u8, week: u8, weekday: u8 },

    /// The day count of this day in `year`.
    fn days(d: Day, year: i64) i64 {
        const january_first = calendar.daysFromCivilWide(year, 1, 1);
        switch (d) {
            .julian => |n| return january_first + n - 1 + @intFromBool(calendar.isLeapYear(year) and n >= 60),
            .zero_based => |n| return january_first + n,
            .month_week_day => |m| {
                const first = calendar.daysFromCivilWide(year, m.month, 1);
                // calendar.weekday is ISO's (Monday 1, Sunday 7); POSIX counts Sunday as 0.
                const first_weekday: i64 = @mod(@as(i64, @intCast(calendar.weekday(@intCast(first)))), 7);
                var day = 1 + @mod(@as(i64, m.weekday) - first_weekday, 7) + 7 * (@as(i64, m.week) - 1);
                const last = calendar.daysInMonth(year, m.month);
                while (day > last) day -= 7;
                return first + day - 1;
            },
        }
    }
};

/// When a rule's transition happens: a day and a time of that day, in the local time in force
/// before it (standard time for the start, daylight saving time for the end).
pub const When = struct {
    day: Day,
    /// Seconds from the day's midnight: -167 to 167 hours.
    time: i32 = 2 * 3600,
};

pub const Dst = struct {
    local: Local,
    start: When,
    end: When,
};

/// A parsed TZ string: standard time, and daylight saving time with its rule where there is one.
pub const Rule = struct {
    std: Local,
    dst: ?Dst = null,

    /// The local time type in force at `seconds` since 1970 (UTC).
    pub fn at(r: *const Rule, seconds: i64) *const Local {
        const d = &(r.dst orelse return &r.std);
        return if (r.dstAt(seconds)) &d.local else &r.std;
    }

    fn dstAt(r: *const Rule, seconds: i64) bool {
        const year = r.yearOf(seconds);
        var events: Events = .{};
        r.collect(&events, year - 2, year + 1);
        var state = !events.items[0].dst;
        for (events.items[0..events.len]) |e| {
            if (e.at > seconds) break;
            state = e.dst;
        }
        return state;
    }

    /// The civil year, in standard time, of an instant.
    fn yearOf(r: *const Rule, seconds: i64) i64 {
        const days = @divFloor(seconds + r.std.offset.seconds.widen(i64), 86_400);
        return calendar.civilFromDays(@intCast(days)).year;
    }

    const Event = struct { at: i64, dst: bool };
    const Events = struct {
        items: [16]Event = undefined,
        len: usize = 0,
    };

    /// The transitions of years `first` to `last`, sorted, an end before a start at the same instant
    /// (so daylight saving all year, an end and the next start at once, stays in force).
    fn collect(r: *const Rule, events: *Events, first: i64, last: i64) void {
        const d = r.dst.?;
        var year = first;
        while (year <= last) : (year += 1) {
            events.items[events.len] = .{ .at = d.start.day.days(year) * 86_400 + d.start.time - r.std.offset.seconds.widen(i64), .dst = true };
            events.items[events.len + 1] = .{ .at = d.end.day.days(year) * 86_400 + d.end.time - d.local.offset.seconds.widen(i64), .dst = false };
            events.len += 2;
        }
        std.mem.sort(Event, events.items[0..events.len], {}, struct {
            fn less(_: void, a: Event, b: Event) bool {
                return a.at < b.at or (a.at == b.at and !a.dst and b.dst);
            }
        }.less);
    }

    /// The first instant after `seconds` at which the rule's offset changes, if it ever does.
    pub fn next(r: *const Rule, seconds: i64) ?i64 {
        const d = r.dst orelse return null;
        if (d.local.offset.eql(r.std.offset)) return null;
        const year = r.yearOf(seconds);
        var events: Events = .{};
        r.collect(&events, year - 2, year + 4);
        // An event of a year past those collected lies after the start of the last one (a rule's
        // time is within 167 hours and an offset within 26 of its day), so up to that start every
        // event, and every event at the same instant, is known.
        const known = calendar.daysFromCivilWide(year + 4, 1, 1) * 86_400;
        var state = r.dstAt(seconds);
        var i: usize = 0;
        while (i < events.len) {
            const when = events.items[i].at;
            if (when >= known) break;
            // Every event at one instant, the last deciding.
            var after = state;
            while (i < events.len and events.items[i].at == when) : (i += 1) after = events.items[i].dst;
            if (when > seconds and after != state) return when;
            if (when > seconds) state = after;
        }
        return null;
    }

    /// The last instant before `seconds` at which the rule's offset changed, if it ever did.
    pub fn previous(r: *const Rule, seconds: i64) ?i64 {
        const d = r.dst orelse return null;
        if (d.local.offset.eql(r.std.offset)) return null;
        const year = r.yearOf(seconds);
        var events: Events = .{};
        r.collect(&events, year - 5, year + 1);
        // The first instant's events set the state; each later one that changes it is a transition.
        var state: ?bool = null;
        var found: ?i64 = null;
        var i: usize = 0;
        while (i < events.len) {
            const when = events.items[i].at;
            if (when >= seconds) break;
            var after = false;
            while (i < events.len and events.items[i].at == when) : (i += 1) after = events.items[i].dst;
            if (state) |before| {
                if (after != before) found = when;
            }
            state = after;
        }
        return found;
    }
};

pub const Error = error{Invalid};

/// Parses a TZ string: `std offset [dst [offset] [,start[/time],end[/time]]]`. Daylight saving
/// time without a rule is refused, not given an implementation's default.
pub fn parse(text: []const u8) Error!Rule {
    var p: Parser = .{ .text = text };
    const rule = try p.rule();
    if (p.at != text.len) return error.Invalid;
    return rule;
}

const Parser = struct {
    text: []const u8,
    at: usize = 0,

    fn peek(p: *const Parser) ?u8 {
        return if (p.at < p.text.len) p.text[p.at] else null;
    }

    fn eat(p: *Parser, c: u8) bool {
        if (p.peek() != c) return false;
        p.at += 1;
        return true;
    }

    fn rule(p: *Parser) Error!Rule {
        const std_name = try p.name();
        const std_offset = try p.offset();
        var r: Rule = .{ .std = Local.init(std_offset, false, std_name) catch return error.Invalid };
        if (p.peek() == null) return r;
        const dst_name = try p.name();
        const dst_offset = if (p.peek() != null and p.peek() != ',') try p.offset() else Offset{ .seconds = std_offset.seconds.add(3600) catch return error.Invalid };
        if (!p.eat(',')) return error.Invalid;
        const start = try p.when();
        if (!p.eat(',')) return error.Invalid;
        const end = try p.when();
        r.dst = .{ .local = Local.init(dst_offset, true, dst_name) catch return error.Invalid, .start = start, .end = end };
        return r;
    }

    /// An abbreviation: three or more letters, or `<...>` of letters, digits, `+` and `-`.
    fn name(p: *Parser) Error![]const u8 {
        if (p.eat('<')) {
            const begin = p.at;
            while (p.peek()) |c| : (p.at += 1) {
                if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-')) break;
            }
            const n = p.text[begin..p.at];
            if (!p.eat('>') or n.len < 3 or n.len > max_abbreviation) return error.Invalid;
            return n;
        }
        const begin = p.at;
        while (p.peek()) |c| : (p.at += 1) {
            if (!std.ascii.isAlphabetic(c)) break;
        }
        const n = p.text[begin..p.at];
        if (n.len < 3 or n.len > max_abbreviation) return error.Invalid;
        return n;
    }

    /// `[+-]hh[:mm[:ss]]` hours 0 to `max_hours`, as seconds.
    fn clock(p: *Parser, max_hours: u32) Error!i32 {
        var negative = false;
        if (p.eat('-')) negative = true else _ = p.eat('+');
        const hours = try p.number(max_hours, 3);
        var seconds: i32 = @intCast(hours * 3600);
        if (p.eat(':')) {
            seconds += @intCast(try p.number(59, 2) * 60);
            if (p.eat(':')) seconds += @intCast(try p.number(59, 2));
        }
        return if (negative) -seconds else seconds;
    }

    /// An offset as POSIX writes it, west of Greenwich positive: the UTC offset is its negation.
    fn offset(p: *Parser) Error!Offset {
        return Offset.init(-(try p.clock(24))) catch error.Invalid;
    }

    fn when(p: *Parser) Error!When {
        var w: When = .{ .day = try p.day() };
        if (p.eat('/')) w.time = try p.clock(167);
        return w;
    }

    fn day(p: *Parser) Error!Day {
        if (p.eat('J')) {
            const n = try p.number(365, 3);
            if (n < 1) return error.Invalid;
            return .{ .julian = @intCast(n) };
        }
        if (p.eat('M')) {
            const month = try p.number(12, 2);
            if (month < 1 or !p.eat('.')) return error.Invalid;
            const week = try p.number(5, 1);
            if (week < 1 or !p.eat('.')) return error.Invalid;
            const weekday = try p.number(6, 1);
            return .{ .month_week_day = .{ .month = @intCast(month), .week = @intCast(week), .weekday = @intCast(weekday) } };
        }
        return .{ .zero_based = @intCast(try p.number(365, 3)) };
    }

    /// One to `digits` decimal digits, at most `max`.
    fn number(p: *Parser, max: u32, digits: usize) Error!u32 {
        var n: u32 = 0;
        var count: usize = 0;
        while (p.peek()) |c| {
            if (!std.ascii.isDigit(c) or count == digits) break;
            n = n * 10 + (c - '0');
            count += 1;
            p.at += 1;
        }
        if (count == 0 or n > max) return error.Invalid;
        return n;
    }
};
