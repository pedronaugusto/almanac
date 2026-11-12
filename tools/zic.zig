//! A compiler of the zic language (the IANA time zone database's source: `Rule`, `Zone` and `Link`
//! lines, zic.8), written for almanac's embedded data: it reads the release's files, computes each
//! zone's transitions as zic's `outzone` does, writes each zone as a TZif file (RFC 8536) with the
//! POSIX TZ string for the years past its table, and packs them with their names and links into one
//! blob. It is a development tool, not shipped; its output is checked against zic's own.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ Syntax, UnknownRule, UnknownLinkTarget, NoAbbreviation, OutOfMemory };

/// Where a `Syntax` error was found.
pub const Diagnostic = struct {
    file: []const u8 = "",
    line: usize = 0,
};

const Suffix = enum { wall, standard, ut };

const Day = union(enum) {
    fixed: u8,
    /// The last such weekday of the month (0 is Sunday).
    last: u8,
    on_or_after: struct { weekday: u8, day: u8 },
    on_or_before: struct { weekday: u8, day: u8 },
};

const max_year = std.math.maxInt(i64);

const Rule = struct {
    name: []const u8,
    from: i64,
    to: i64,
    month: u8,
    day: Day,
    at: i32,
    at_suffix: Suffix,
    save: i32,
    dst: bool,
    letters: []const u8,
};

const Until = struct {
    year: i64,
    month: u8 = 1,
    day: Day = .{ .fixed = 1 },
    time: i32 = 0,
    suffix: Suffix = .wall,
};

const Rules = union(enum) {
    none,
    fixed: i32,
    named: []const u8,
};

const Line = struct {
    stdoff: i32,
    rules: Rules,
    format: []const u8,
    until: ?Until,
};

const Zone = struct {
    name: []const u8,
    lines: std.ArrayList(Line) = .empty,
};

const Link = struct { target: []const u8, name: []const u8 };

/// The parsed release, its strings in `arena`.
pub const Source = struct {
    arena: std.heap.ArenaAllocator,
    rules: std.ArrayList(Rule) = .empty,
    zones: std.ArrayList(Zone) = .empty,
    links: std.ArrayList(Link) = .empty,

    pub fn init(gpa: Allocator) Source {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(s: *Source) void {
        s.arena.deinit();
    }

    /// Reads one source file.
    pub fn parse(s: *Source, file: []const u8, text: []const u8, diagnostic: *Diagnostic) Error!void {
        const a = s.arena.allocator();
        var lines = std.mem.splitScalar(u8, text, '\n');
        var number: usize = 0;
        var continuing: ?*Zone = null;
        diagnostic.file = file;
        while (lines.next()) |raw| {
            number += 1;
            diagnostic.line = number;
            const content = if (std.mem.findScalar(u8, raw, '#')) |hash| raw[0..hash] else raw;
            var fields: [16][]const u8 = undefined;
            var n: usize = 0;
            var it = std.mem.tokenizeAny(u8, content, " \t\r");
            while (it.next()) |f| {
                if (n == fields.len) return error.Syntax;
                fields[n] = f;
                n += 1;
            }
            if (n == 0) continue;
            const f = fields[0..n];
            if (continuing) |zone| {
                try zone.lines.append(a, try zoneLine(f));
                if (zone.lines.items[zone.lines.items.len - 1].until == null) continuing = null;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(f[0], "Rule")) {
                if (n != 10) return error.Syntax;
                try s.rules.append(a, try rule(f));
            } else if (std.ascii.eqlIgnoreCase(f[0], "Zone")) {
                if (n < 5) return error.Syntax;
                try s.zones.append(a, .{ .name = f[1] });
                const zone = &s.zones.items[s.zones.items.len - 1];
                try zone.lines.append(a, try zoneLine(f[2..]));
                if (zone.lines.items[0].until != null) continuing = zone;
            } else if (std.ascii.eqlIgnoreCase(f[0], "Link")) {
                if (n != 3) return error.Syntax;
                try s.links.append(a, .{ .target = f[1], .name = f[2] });
            } else return error.Syntax;
        }
        if (continuing != null) return error.Syntax;
    }
};

fn rule(f: []const []const u8) Error!Rule {
    const from = try year(f[2], false);
    const to: i64 = if (prefix(f[3], "only", 1)) from else try year(f[3], true);
    if (!std.mem.eql(u8, f[4], "-")) return error.Syntax;
    const at = try time(f[7]);
    var save_text = f[8];
    var dst: ?bool = null;
    if (save_text.len > 0 and (save_text[save_text.len - 1] == 's' or save_text[save_text.len - 1] == 'd')) {
        dst = save_text[save_text.len - 1] == 'd';
        save_text = save_text[0 .. save_text.len - 1];
    }
    const save = try duration(save_text);
    return .{
        .name = f[1],
        .from = from,
        .to = to,
        .month = try month(f[5]),
        .day = try day(f[6]),
        .at = at.seconds,
        .at_suffix = at.suffix,
        .save = save,
        .dst = dst orelse (save != 0),
        .letters = if (std.mem.eql(u8, f[9], "-")) "" else f[9],
    };
}

fn zoneLine(f: []const []const u8) Error!Line {
    if (f.len < 3) return error.Syntax;
    const rules: Rules = if (std.mem.eql(u8, f[1], "-"))
        .none
    else if (std.ascii.isDigit(f[1][0]) or f[1][0] == '-')
        .{ .fixed = try duration(f[1]) }
    else
        .{ .named = f[1] };
    var until: ?Until = null;
    if (f.len > 3) {
        var u: Until = .{ .year = try year(f[3], false) };
        if (f.len > 4) u.month = try month(f[4]);
        if (f.len > 5) u.day = try day(f[5]);
        if (f.len > 6) {
            const t = try time(f[6]);
            u.time = t.seconds;
            u.suffix = t.suffix;
        }
        if (f.len > 7) return error.Syntax;
        until = u;
    }
    return .{ .stdoff = try duration(f[0]), .rules = rules, .format = f[2], .until = until };
}

/// Whether `text` is a prefix of `word` of at least `least` bytes, ignoring case (zic's
/// abbreviations: `Apr`, `April`, `o` for `only`).
fn prefix(text: []const u8, word: []const u8, least: usize) bool {
    return text.len >= least and text.len <= word.len and std.ascii.eqlIgnoreCase(text, word[0..text.len]);
}

fn year(text: []const u8, allow_max: bool) Error!i64 {
    if (allow_max and prefix(text, "maximum", 2)) return max_year;
    return std.fmt.parseInt(i64, text, 10) catch error.Syntax;
}

const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const weekday_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };

fn month(text: []const u8) Error!u8 {
    for (month_names, 1..) |name, i| if (prefix(text, name, 3)) return @intCast(i);
    return error.Syntax;
}

fn weekday(text: []const u8) Error!u8 {
    for (weekday_names, 0..) |name, i| if (prefix(text, name, 2)) return @intCast(i);
    return error.Syntax;
}

fn day(text: []const u8) Error!Day {
    if (text.len > 4 and std.ascii.eqlIgnoreCase(text[0..4], "last")) return .{ .last = try weekday(text[4..]) };
    if (std.mem.find(u8, text, ">=")) |at| return .{ .on_or_after = .{ .weekday = try weekday(text[0..at]), .day = std.fmt.parseInt(u8, text[at + 2 ..], 10) catch return error.Syntax } };
    if (std.mem.find(u8, text, "<=")) |at| return .{ .on_or_before = .{ .weekday = try weekday(text[0..at]), .day = std.fmt.parseInt(u8, text[at + 2 ..], 10) catch return error.Syntax } };
    const d = std.fmt.parseInt(u8, text, 10) catch return error.Syntax;
    if (d < 1 or d > 31) return error.Syntax;
    return .{ .fixed = d };
}

/// `[-]h[:mm[:ss]]` as seconds; `-` alone is zero.
fn duration(text: []const u8) Error!i32 {
    if (std.mem.eql(u8, text, "-")) return 0;
    var rest = text;
    var negative = false;
    if (rest.len > 0 and rest[0] == '-') {
        negative = true;
        rest = rest[1..];
    }
    const scales = [_]i32{ 3600, 60, 1 };
    var total: i32 = 0;
    var parts = std.mem.splitScalar(u8, rest, ':');
    var count: usize = 0;
    while (parts.next()) |part| : (count += 1) {
        if (count == scales.len or part.len == 0) return error.Syntax;
        const v = std.fmt.parseInt(i32, part, 10) catch return error.Syntax;
        if (count > 0 and (v > 59 or part.len != 2)) return error.Syntax;
        total += v * scales[count];
    }
    return if (negative) -total else total;
}

const Timed = struct { seconds: i32, suffix: Suffix };

/// A time of day with zic's suffix: `w` wall clock (the default), `s` standard time, `u`, `g` or `z`
/// universal time.
fn time(text: []const u8) Error!Timed {
    if (text.len == 0) return error.Syntax;
    const last = std.ascii.toLower(text[text.len - 1]);
    const suffix: ?Suffix = switch (last) {
        'w' => .wall,
        's' => .standard,
        'u', 'g', 'z' => .ut,
        else => null,
    };
    const digits = if (suffix != null) text[0 .. text.len - 1] else text;
    return .{ .seconds = try duration(digits), .suffix = suffix orelse .wall };
}

// The calendar, as zic reads it: proleptic Gregorian, days from 1970.

fn daysFromCivil(y: i64, m: i64, d: i64) i64 {
    const yy = y - @intFromBool(m <= 2);
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

fn isLeap(y: i64) bool {
    return @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
}

fn monthLength(y: i64, m: u8) u8 {
    const lengths = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return if (m == 2 and isLeap(y)) 29 else lengths[m - 1];
}

/// 0 is Sunday; 1970-01-01 was a Thursday.
fn weekdayOf(days: i64) u8 {
    return @intCast(@mod(days + 4, 7));
}

/// The day count a rule or an until names in `y` (zic's rpytime, without the time).
fn dayOf(y: i64, m: u8, d: Day) i64 {
    const first = daysFromCivil(y, m, 1);
    switch (d) {
        .fixed => |n| return first + n - 1,
        .last => |w| {
            var at = first + monthLength(y, m) - 1;
            while (weekdayOf(at) != w) at -= 1;
            return at;
        },
        .on_or_after => |x| {
            var at = first + x.day - 1;
            while (weekdayOf(at) != x.weekday) at += 1;
            return at;
        },
        .on_or_before => |x| {
            var at = first + x.day - 1;
            while (weekdayOf(at) != x.weekday) at -= 1;
            return at;
        },
    }
}

// Compiling a zone.

pub const Type = struct {
    offset: i32,
    dst: bool,
    abbreviation: []const u8,

    fn eql(a: Type, b: Type) bool {
        return a.offset == b.offset and a.dst == b.dst and std.mem.eql(u8, a.abbreviation, b.abbreviation);
    }
};

pub const Transition = struct { at: i64, type: usize };

pub const Compiled = struct {
    types: std.ArrayList(Type) = .empty,
    transitions: std.ArrayList(Transition) = .empty,
    /// The POSIX TZ string past the table; empty where there is none.
    footer: []const u8 = "",
};

/// The last year transitions are written out for; past it the footer rules (as zic's fat output).
const table_end_year = 2037;
const first_rule_year = 1800;

/// The abbreviation a FORMAT gives (zic's doabbr): `A/B` by daylight saving, `%z` the offset,
/// `%s` the rule's letters.
fn abbreviate(a: Allocator, format: []const u8, letters: ?[]const u8, dst: bool, offset: i32) Error![]const u8 {
    if (std.mem.findScalar(u8, format, '/')) |slash| return if (dst) format[slash + 1 ..] else format[0..slash];
    if (std.mem.find(u8, format, "%z")) |at| {
        const s: u32 = @abs(offset);
        const sign: u8 = if (offset < 0) '-' else '+';
        const numeric = if (s % 60 != 0)
            try std.fmt.allocPrint(a, "{c}{d:0>2}{d:0>2}{d:0>2}", .{ sign, s / 3600, s / 60 % 60, s % 60 })
        else if (s / 60 % 60 != 0)
            try std.fmt.allocPrint(a, "{c}{d:0>2}{d:0>2}", .{ sign, s / 3600, s / 60 % 60 })
        else
            try std.fmt.allocPrint(a, "{c}{d:0>2}", .{ sign, s / 3600 });
        return std.fmt.allocPrint(a, "{s}{s}{s}", .{ format[0..at], numeric, format[at + 2 ..] });
    }
    if (std.mem.find(u8, format, "%s")) |at| {
        const l = letters orelse return error.NoAbbreviation;
        return std.fmt.allocPrint(a, "{s}{s}{s}", .{ format[0..at], l, format[at + 2 ..] });
    }
    return format;
}

const Builder = struct {
    a: Allocator,
    out: *Compiled,
    default_type: ?usize = null,

    fn addType(b: *Builder, t: Type) Error!usize {
        for (b.out.types.items, 0..) |existing, i| if (existing.eql(t)) return i;
        try b.out.types.append(b.a, t);
        return b.out.types.items.len - 1;
    }

    fn addTransition(b: *Builder, at: i64, t: usize) Error!void {
        try b.out.transitions.append(b.a, .{ .at = at, .type = t });
    }
};

/// The rules a line names, in source order.
fn rulesOf(a: Allocator, source: *const Source, name: []const u8) Error![]const Rule {
    var list: std.ArrayList(Rule) = .empty;
    for (source.rules.items) |r| if (std.mem.eql(u8, r.name, name)) try list.append(a, r);
    if (list.items.len == 0) return error.UnknownRule;
    return list.items;
}

/// Compiles a zone as zic's outzone does, all in `a`.
pub fn compile(a: Allocator, source: *const Source, zone: *const Zone) Error!Compiled {
    var out: Compiled = .{};
    var b: Builder = .{ .a = a, .out = &out };
    var save: i32 = 0;
    var start_time: i64 = std.math.minInt(i64);
    const lines = zone.lines.items;
    for (lines, 0..) |line, i| {
        const use_start = i > 0;
        const use_until = i + 1 < lines.len;
        const stdoff = line.stdoff;
        var start_abbreviation: ?[]const u8 = null;
        var start_offset: i32 = stdoff;
        switch (line.rules) {
            .none, .fixed => {
                save = if (line.rules == .fixed) line.rules.fixed else 0;
                const dst = save != 0;
                const t = try b.addType(.{ .offset = stdoff + save, .dst = dst, .abbreviation = try abbreviate(a, line.format, "", dst, stdoff + save) });
                if (use_start) try b.addTransition(start_time, t) else b.default_type = t;
            },
            .named => |name| {
                const rules = try rulesOf(a, source, name);
                // The line's own rules decide the save at its start: those before it are run
                // through below, and with none, it is standard time (Shanghai's PRC line of 1949,
                // after a line that ended in daylight saving, starts at 0).
                save = 0;
                var use_start_left = use_start;
                var low: i64 = std.math.maxInt(i64);
                var high: i64 = table_end_year;
                for (rules) |r| {
                    low = @min(low, r.from);
                    if (r.to != max_year) high = @max(high, r.to);
                }
                low = @max(low, first_rule_year);
                if (use_until) high = line.until.?.year;
                const todo = try a.alloc(bool, rules.len);
                const times = try a.alloc(i64, rules.len);
                var y = low;
                year_loop: while (y <= high) : (y += 1) {
                    for (rules, 0..) |r, j| {
                        todo[j] = y >= r.from and y <= r.to;
                        if (todo[j]) times[j] = dayOf(y, r.month, r.day) * 86_400 + r.at;
                    }
                    while (true) {
                        var until_time: i64 = undefined;
                        if (use_until) {
                            const u = line.until.?;
                            until_time = dayOf(u.year, u.month, u.day) * 86_400 + u.time;
                            if (u.suffix != .ut) until_time -= stdoff;
                            if (u.suffix == .wall) until_time -= save;
                        }
                        var k: ?usize = null;
                        var k_time: i64 = 0;
                        for (rules, 0..) |r, j| {
                            if (!todo[j]) continue;
                            var offset: i64 = if (r.at_suffix == .ut) 0 else stdoff;
                            if (r.at_suffix == .wall) offset += save;
                            const j_time = times[j] - offset;
                            if (k == null or j_time < k_time) {
                                k = j;
                                k_time = j_time;
                            }
                        }
                        const index = k orelse continue :year_loop;
                        const r = rules[index];
                        todo[index] = false;
                        if (use_until and k_time >= until_time) {
                            if (start_abbreviation == null and stdoff + r.save == start_offset)
                                start_abbreviation = try abbreviate(a, line.format, r.letters, r.dst, stdoff + r.save);
                            break :year_loop;
                        }
                        save = r.save;
                        if (use_start_left and k_time == start_time) use_start_left = false;
                        if (use_start_left) {
                            if (k_time < start_time) {
                                start_offset = stdoff + save;
                                start_abbreviation = try abbreviate(a, line.format, r.letters, r.dst, stdoff + save);
                                continue;
                            }
                            if (start_abbreviation == null and start_offset == stdoff + save)
                                start_abbreviation = try abbreviate(a, line.format, r.letters, r.dst, stdoff + save);
                        }
                        const t = try b.addType(.{ .offset = stdoff + r.save, .dst = r.dst, .abbreviation = try abbreviate(a, line.format, r.letters, r.dst, stdoff + r.save) });
                        if (b.default_type == null and !r.dst) b.default_type = t;
                        try b.addTransition(k_time, t);
                    }
                }
                if (use_start_left) {
                    const dst = start_offset != stdoff;
                    const abbreviation = start_abbreviation orelse abbreviate(a, line.format, null, dst, start_offset) catch return error.NoAbbreviation;
                    const t = try b.addType(.{ .offset = start_offset, .dst = dst, .abbreviation = abbreviation });
                    if (b.default_type == null and !dst) b.default_type = t;
                    try b.addTransition(start_time, t);
                }
            },
        }
        if (use_until) {
            const u = line.until.?;
            start_time = dayOf(u.year, u.month, u.day) * 86_400 + u.time;
            if (u.suffix == .wall) start_time -= save;
            if (u.suffix != .ut) start_time -= stdoff;
        }
    }
    try optimize(a, &out, b.default_type orelse 0);
    out.footer = try footer(a, source, &out, &lines[lines.len - 1]);
    return out;
}

/// Puts the type before the first transition first, sorts the transitions, merges each that falls
/// at or before the one before it in local time into that one (zic's writezone), and drops those
/// that change nothing.
fn optimize(a: Allocator, out: *Compiled, default_type: usize) Error!void {
    // Type 0 is the type before the first transition.
    if (default_type != 0) {
        std.mem.swap(Type, &out.types.items[0], &out.types.items[default_type]);
        for (out.transitions.items) |*t| {
            if (t.type == 0) t.type = default_type else if (t.type == default_type) t.type = 0;
        }
    }
    std.mem.sort(Transition, out.transitions.items, {}, struct {
        fn less(_: void, x: Transition, y: Transition) bool {
            return x.at < y.at;
        }
    }.less);
    const types = out.types.items;
    var kept: std.ArrayList(Transition) = .empty;
    for (out.transitions.items) |t| {
        const n = kept.items.len;
        if (n != 0) {
            const before = if (n == 1) 0 else kept.items[n - 2].type;
            if (t.at + types[kept.items[n - 1].type].offset <= kept.items[n - 1].at + types[before].offset) {
                kept.items[n - 1].type = t.type;
                continue;
            }
        }
        const previous = if (n == 0) 0 else kept.items[n - 1].type;
        if (types[previous].eql(types[t.type])) continue;
        try kept.append(a, t);
    }
    // A merge can leave a transition that changes nothing.
    var final: std.ArrayList(Transition) = .empty;
    for (kept.items) |t| {
        const previous = if (final.items.len == 0) 0 else final.items[final.items.len - 1].type;
        if (!types[previous].eql(types[t.type])) try final.append(a, t);
    }
    out.transitions = final;
}

/// A POSIX abbreviation: bare where it is all letters, else in angle brackets.
fn posixName(a: Allocator, name: []const u8) Error![]const u8 {
    for (name) |c| if (!std.ascii.isAlphabetic(c)) return std.fmt.allocPrint(a, "<{s}>", .{name});
    return name;
}

/// A POSIX offset or time: `[-]h[:mm[:ss]]`.
fn posixClock(a: Allocator, seconds: i64) Error![]const u8 {
    const s: u64 = @abs(seconds);
    const sign = if (seconds < 0) "-" else "";
    if (s % 60 != 0) return std.fmt.allocPrint(a, "{s}{d}:{d:0>2}:{d:0>2}", .{ sign, s / 3600, s / 60 % 60, s % 60 });
    if (s / 60 % 60 != 0) return std.fmt.allocPrint(a, "{s}{d}:{d:0>2}", .{ sign, s / 3600, s / 60 % 60 });
    return std.fmt.allocPrint(a, "{s}{d}", .{ sign, s / 3600 });
}

/// A rule's date and time as a POSIX string writes it (zic's stringrule).
fn posixRule(a: Allocator, r: Rule, save: i32, stdoff: i32) Error![]const u8 {
    var tod: i64 = r.at;
    var date: []const u8 = undefined;
    switch (r.day) {
        .fixed => |d| {
            var total: u32 = 0;
            for (1..r.month) |m| total += monthLength(2001, @intCast(m));
            date = if (r.month <= 2) try std.fmt.allocPrint(a, "{d}", .{total + d - 1}) else try std.fmt.allocPrint(a, "J{d}", .{total + d});
        },
        else => {
            var week: i64 = 5;
            var wd: i64 = undefined;
            switch (r.day) {
                .last => |w| wd = w,
                .on_or_after => |x| {
                    const off: i64 = (x.day - 1) % 7;
                    wd = @as(i64, x.weekday) - off;
                    tod += off * 86_400;
                    week = 1 + @divTrunc(@as(i64, x.day) - 1, 7);
                },
                .on_or_before => |x| {
                    wd = x.weekday;
                    if (x.day != monthLength(2000, r.month)) {
                        const off: i64 = x.day % 7;
                        wd -= off;
                        tod += off * 86_400;
                        week = @divTrunc(@as(i64, x.day), 7);
                    }
                },
                .fixed => unreachable,
            }
            if (wd < 0) wd += 7;
            date = try std.fmt.allocPrint(a, "M{d}.{d}.{d}", .{ r.month, week, wd });
        },
    }
    if (r.at_suffix == .ut) tod += stdoff;
    if (r.at_suffix != .wall and !r.dst) tod += save;
    if (tod == 2 * 3600) return date;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ date, try posixClock(a, tod) });
}

/// The POSIX TZ string for the years past the table (zic's stringzone): the last line's two rules
/// that run to `max`, or its one type where none do.
fn footer(a: Allocator, source: *const Source, out: *const Compiled, last: *const Line) Error![]const u8 {
    const stdoff = last.stdoff;
    const fixed = struct {
        fn f(al: Allocator, t: Type) Error![]const u8 {
            return std.fmt.allocPrint(al, "{s}{s}", .{ try posixName(al, t.abbreviation), try posixClock(al, -@as(i64, t.offset)) });
        }
    }.f;
    switch (last.rules) {
        .none, .fixed => {
            const save: i32 = if (last.rules == .fixed) last.rules.fixed else 0;
            return fixed(a, .{ .offset = stdoff + save, .dst = save != 0, .abbreviation = try abbreviate(a, last.format, "", save != 0, stdoff + save) });
        },
        .named => |name| {
            var std_rule: ?Rule = null;
            var dst_rule: ?Rule = null;
            var count: usize = 0;
            for (try rulesOf(a, source, name)) |r| {
                if (r.to != max_year) continue;
                count += 1;
                if (r.save == 0) std_rule = r else dst_rule = r;
            }
            if (count == 2 and std_rule != null and dst_rule != null) {
                const s = std_rule.?;
                const d = dst_rule.?;
                const std_name = try posixName(a, try abbreviate(a, last.format, s.letters, false, stdoff));
                const dst_name = try posixName(a, try abbreviate(a, last.format, d.letters, true, stdoff + d.save));
                const dst_offset = if (d.save == 3600) "" else try posixClock(a, -@as(i64, stdoff + d.save));
                return std.fmt.allocPrint(a, "{s}{s}{s}{s},{s},{s}", .{
                    std_name,                            try posixClock(a, -@as(i64, stdoff)), dst_name, dst_offset,
                    try posixRule(a, d, d.save, stdoff), try posixRule(a, s, d.save, stdoff),
                });
            }
            // No rules to `max`: the type in force after the table.
            const t = if (out.transitions.items.len == 0) out.types.items[0] else out.types.items[out.transitions.items[out.transitions.items.len - 1].type];
            return fixed(a, t);
        },
    }
}

// Writing TZif and the blob.

/// Where `abbreviation` already ends an entry of `chars` (NUL-terminated strings), as zic shares
/// them: a suffix of an entry reads as itself, a prefix would read on to the entry's end.
fn shared(chars: []const u8, abbreviation: []const u8) ?usize {
    var from: usize = 0;
    while (std.mem.findPos(u8, chars, from, abbreviation)) |at| : (from = at + 1) {
        const end = at + abbreviation.len;
        if (end < chars.len and chars[end] == 0) return at;
    }
    return null;
}

/// A version 2 TZif file of the compiled zone (version 3 where its footer needs RFC 8536's
/// extensions); the version 1 block holds the first type alone.
pub fn writeTzif(a: Allocator, c: *const Compiled) Error![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    var chars: std.ArrayList(u8) = .empty;
    var indices: std.ArrayList(u8) = .empty;
    for (c.types.items) |t| {
        const at = shared(chars.items, t.abbreviation) orelse blk: {
            const at = chars.items.len;
            try chars.appendSlice(a, t.abbreviation);
            try chars.append(a, 0);
            break :blk at;
        };
        try indices.append(a, @intCast(at));
    }
    const version: u8 = if (needsVersion3(c.footer)) '3' else '2';
    const first = c.types.items[0];
    // Version 1: one type, its abbreviation.
    try header(a, &bytes, version, 0, 1, first.abbreviation.len + 1);
    try ttinfo(a, &bytes, first, 0);
    try bytes.appendSlice(a, first.abbreviation);
    try bytes.append(a, 0);
    try header(a, &bytes, version, c.transitions.items.len, c.types.items.len, chars.items.len);
    for (c.transitions.items) |t| try int(a, &bytes, i64, t.at);
    for (c.transitions.items) |t| try bytes.append(a, @intCast(t.type));
    for (c.types.items, indices.items) |t, index| try ttinfo(a, &bytes, t, index);
    try bytes.appendSlice(a, chars.items);
    try bytes.append(a, '\n');
    try bytes.appendSlice(a, c.footer);
    try bytes.append(a, '\n');
    return bytes.items;
}

fn needsVersion3(tz: []const u8) bool {
    // A rule time past 24 hours or negative, after a `/`.
    var it = std.mem.splitScalar(u8, tz, '/');
    _ = it.next();
    while (it.next()) |part| {
        if (part.len > 0 and part[0] == '-') return true;
        const end = std.mem.findAny(u8, part, ":,") orelse part.len;
        const hours = std.fmt.parseInt(u32, part[0..end], 10) catch continue;
        if (hours > 24) return true;
    }
    return false;
}

fn int(a: Allocator, bytes: *std.ArrayList(u8), comptime T: type, v: T) Error!void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, v, .big);
    try bytes.appendSlice(a, &buffer);
}

fn header(a: Allocator, bytes: *std.ArrayList(u8), version: u8, timecnt: usize, typecnt: usize, charcnt: usize) Error!void {
    try bytes.appendSlice(a, "TZif");
    try bytes.append(a, version);
    try bytes.appendNTimes(a, 0, 15);
    for ([_]usize{ 0, 0, 0, timecnt, typecnt, charcnt }) |n| try int(a, bytes, u32, @intCast(n));
}

fn ttinfo(a: Allocator, bytes: *std.ArrayList(u8), t: Type, index: usize) Error!void {
    try int(a, bytes, i32, t.offset);
    try bytes.append(a, @intFromBool(t.dst));
    try bytes.append(a, @intCast(index));
}

/// The blob almanac embeds: `ATZB`, a format byte, the release's version, then the names sorted
/// (each a length byte, the name and the index of its TZif data, a link naming its target's), then
/// the TZif files (each a big-endian u32 length and the bytes).
pub fn pack(gpa: Allocator, source: *const Source, version: []const u8) Error![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const Name = struct { name: []const u8, data: u32 };
    var names: std.ArrayList(Name) = .empty;
    var data: std.ArrayList([]const u8) = .empty;
    for (source.zones.items) |*zone| {
        const compiled = try compile(a, source, zone);
        try data.append(a, try writeTzif(a, &compiled));
        try names.append(a, .{ .name = zone.name, .data = @intCast(data.items.len - 1) });
    }
    for (source.links.items) |link| {
        const target = for (names.items) |n| {
            if (std.mem.eql(u8, n.name, link.target)) break n.data;
        } else return error.UnknownLinkTarget;
        try names.append(a, .{ .name = link.name, .data = target });
    }
    std.mem.sort(Name, names.items, {}, struct {
        fn less(_: void, x: Name, y: Name) bool {
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    }.less);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "ATZB");
    try out.append(gpa, 1);
    try out.append(gpa, @intCast(version.len));
    try out.appendSlice(gpa, version);
    var count: [4]u8 = undefined;
    std.mem.writeInt(u32, &count, @intCast(names.items.len), .big);
    try out.appendSlice(gpa, &count);
    for (names.items) |n| {
        try out.append(gpa, @intCast(n.name.len));
        try out.appendSlice(gpa, n.name);
        std.mem.writeInt(u32, &count, n.data, .big);
        try out.appendSlice(gpa, &count);
    }
    std.mem.writeInt(u32, &count, @intCast(data.items.len), .big);
    try out.appendSlice(gpa, &count);
    for (data.items) |d| {
        std.mem.writeInt(u32, &count, @intCast(d.len), .big);
        try out.appendSlice(gpa, &count);
        try out.appendSlice(gpa, d);
    }
    return out.toOwnedSlice(gpa);
}

/// The release's source files almanac compiles (`backward` for its links; `backzone`, the
/// pre-1970 data zic leaves out by default, is not read).
pub const files = [_][]const u8{ "africa", "antarctica", "asia", "australasia", "europe", "northamerica", "southamerica", "etcetera", "backward", "factory" };
