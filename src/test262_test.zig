//! test262's Temporal cases (testdata/test262/temporal.json, transcribed as text by
//! tools/test262.zig, each with its source path): the `from` string cases and the arithmetic
//! (`until`, `since`, `round`, `add`, `subtract`, `total`) of the six types almanac shares, run
//! through almanac. Every case passes, or is listed by path with the reason almanac does not
//! follow it; a listed case that passes fails the test, so the list stays exact.
const std = @import("std");
const aegis = @import("aegis");
const almanac = @import("almanac.zig");
const test262 = @import("test262");
const text = almanac.text;
const testing = std.testing;
const Json = std.json.Value;
const Untrusted = aegis.input.Untrusted([]const u8);
const Span = almanac.Span;
const Unit = almanac.Unit;

/// What a JSON value evaluates to.
const Val = union(enum) {
    date: almanac.Date,
    date_time: almanac.DateTime,
    time: almanac.Time,
    span: Span,
    instant: almanac.Timestamp,
    zoned: almanac.Zoned,
    string: []const u8,
    number: f64,
    bigint: i128,
    boolean: bool,
    nothing,
    object: std.json.ObjectMap,
    array: []const Json,
};

/// Why a case cannot be run here: the reason is counted.
const Unsupported = error{Unsupported};

const Runner = struct {
    db: *almanac.Database,
    zones: std.ArrayList(almanac.Zone) = .empty,
    reason: []const u8 = "",
    /// The options a `from` was given, for the property bag it reads.
    bag_options: Options = .{},

    fn deinit(r: *Runner) void {
        for (r.zones.items) |*z| z.release();
        r.zones.deinit(testing.allocator);
    }

    fn unsupported(r: *Runner, reason: []const u8) Unsupported {
        r.reason = reason;
        return error.Unsupported;
    }

    fn zone(r: *Runner, name: []const u8) !*const almanac.TimeZone {
        const z = if (name.len > 0 and (name[0] == '+' or name[0] == '-')) blk: {
            // `±HH`, `±HHMM` or `±HH:MM`: a zone identifier has no seconds.
            const digits = name.len - 1 - @as(usize, if (std.mem.findScalar(u8, name, ':') != null) 1 else 0);
            if (digits != 2 and digits != 4) return error.Invalid;
            const dt = text.parseTimestamp(Untrusted.init(try arena.print("1970-01-01T00:00{s}", .{name})), .{}) catch return error.Invalid;
            // A zone's offset is written to the minute.
            if (@rem(dt.raw(), 60 * std.time.ns_per_s) != 0) return error.Invalid;
            break :blk try r.db.fixedZone(try almanac.Offset.init(@intCast(@divExact(-dt.raw(), std.time.ns_per_s))));
        } else try r.db.zone(testing.io, .init(name));
        try r.zones.append(testing.allocator, z);
        return r.zones.items[r.zones.items.len - 1].get();
    }

    // Values.

    fn eval(r: *Runner, v: Json) anyerror!Val {
        switch (v) {
            .string => |s| return .{ .string = s },
            .bool => |b| return .{ .boolean = b },
            .null => return .nothing,
            .array => |a| return .{ .array = a.items },
            .object => |o| {
                if (o.get("number")) |n| return .{ .number = std.fmt.parseFloat(f64, n.string) catch return r.unsupported("a number literal") };
                if (o.get("bigint")) |n| return .{ .bigint = std.fmt.parseInt(i128, n.string, 0) catch return r.unsupported("a bigint literal") };
                if (o.get("object")) |m| return .{ .object = m.object };
                if (o.get("temporal")) |t| return r.temporal(t.string, o.get("make").?.string, o.get("args").?.array.items);
                if (o.get("method")) |_| return r.call(o);
                return r.unsupported("a value");
            },
            else => return r.unsupported("a value"),
        }
    }

    fn int(r: *Runner, v: ?Json) !i64 {
        const x = v orelse return 0;
        if (x == .object) if (x.object.get("number")) |text_value| {
            if (std.fmt.parseInt(i64, text_value.string, 10)) |n| return n else |_| {}
        };
        const val = try r.eval(x);
        return switch (val) {
            // A whole number as a double: exact up to 2^63.
            .number => |n| if (n == @trunc(n) and @abs(n) < 9.2e18) @intFromFloat(n) else error.Invalid,
            .nothing => 0,
            else => r.unsupported("a non-number field"),
        };
    }

    /// An integer that must fit `T`, or a RangeError as Temporal throws one.
    fn fit(comptime T: type, v: i64) !T {
        return std.math.cast(T, v) orelse error.OutOfRange;
    }

    fn arg(args: []const Json, i: usize) ?Json {
        return if (i < args.len) args[i] else null;
    }

    fn temporal(r: *Runner, ty: []const u8, make: []const u8, args: []const Json) anyerror!Val {
        if (std.mem.eql(u8, make, "from")) return r.from(ty, args);
        if (args.len > 0) if (args[args.len - 1] == .string and !std.mem.eql(u8, ty, "ZonedDateTime")) try r.calendar(args[args.len - 1].string);
        if (std.mem.eql(u8, ty, "PlainDate")) {
            if (args.len > 4) return r.unsupported("a calendar argument");
            return .{ .date = try almanac.Date.init(try fit(i16, try r.int(arg(args, 0))), try fit(u8, try r.int(arg(args, 1))), try fit(u8, try r.int(arg(args, 2)))) };
        }
        if (std.mem.eql(u8, ty, "PlainTime")) return .{ .time = try r.timeOf(args, 0) };
        if (std.mem.eql(u8, ty, "PlainDateTime")) {
            if (args.len > 10) return r.unsupported("a calendar argument");
            return .{ .date_time = .{ .date = try almanac.Date.init(try fit(i16, try r.int(arg(args, 0))), try fit(u8, try r.int(arg(args, 1))), try fit(u8, try r.int(arg(args, 2)))), .time = try r.timeOf(args, 3) } };
        }
        if (std.mem.eql(u8, ty, "Duration")) {
            var f: Span.Signed = .{};
            inline for (.{ "years", "months", "weeks", "days", "hours", "minutes", "seconds", "milliseconds", "microseconds", "nanoseconds" }, 0..) |name, i| {
                @field(f, name) = try r.int(arg(args, i));
            }
            return .{ .span = try Span.fromSigned(f) };
        }
        if (std.mem.eql(u8, ty, "Instant")) {
            const ns = switch (try r.eval(args[0])) {
                .bigint => |b| b,
                else => return r.unsupported("an instant of no bigint"),
            };
            return .{ .instant = try almanac.instant.timestamp(almanac.Timestamp.fromRaw(std.math.cast(i96, ns) orelse return error.OutOfRange)) };
        }
        if (std.mem.eql(u8, ty, "ZonedDateTime")) {
            if (args.len > 2) try r.calendar(switch (args[2]) {
                .string => |c| c,
                else => return r.unsupported("a calendar of no string"),
            });
            const ns = switch (try r.eval(args[0])) {
                .bigint => |b| b,
                else => return r.unsupported("a zoned value of no bigint"),
            };
            const name = switch (try r.eval(args[1])) {
                .string => |s| s,
                else => return r.unsupported("a zone of no string"),
            };
            return .{ .zoned = try almanac.Zoned.init(almanac.Timestamp.fromRaw(std.math.cast(i96, ns) orelse return error.OutOfRange), try r.zone(name)) };
        }
        return r.unsupported("a type");
    }

    fn timeOf(r: *Runner, args: []const Json, at: usize) !almanac.Time {
        const h = try r.int(arg(args, at));
        const mi = try r.int(arg(args, at + 1));
        const s = try r.int(arg(args, at + 2));
        const ms = try r.int(arg(args, at + 3));
        const us = try r.int(arg(args, at + 4));
        const ns = try r.int(arg(args, at + 5));
        if (ms < 0 or ms > 999 or us < 0 or us > 999 or ns < 0 or ns > 999) return error.OutOfRange;
        return almanac.Time.init(try fit(u8, h), try fit(u8, mi), try fit(u8, s), try fit(u32, ms * 1_000_000 + us * 1000 + ns));
    }

    /// `Temporal.<Type>.from(x)`: a string read as almanac reads it, a property bag, or a value of
    /// another type converted as Temporal converts it.
    fn from(r: *Runner, ty: []const u8, args: []const Json) anyerror!Val {
        const value = try r.eval(args[0]);
        const saved = r.bag_options;
        defer r.bag_options = saved;
        if (args.len > 1) r.bag_options = try r.options(args[1]);
        return r.convert(ty, value);
    }

    fn convert(r: *Runner, ty: []const u8, v: Val) anyerror!Val {
        const is = struct {
            fn f(a: []const u8, b: []const u8) bool {
                return std.mem.eql(u8, a, b);
            }
        }.f;
        switch (v) {
            .string => |s| {
                const u = Untrusted.init(s);
                if (is(ty, "PlainDate")) return .{ .date = try text.parseDate(u, .{}) };
                if (is(ty, "PlainDateTime")) return .{ .date_time = try text.parseDateTime(u, .{}) };
                if (is(ty, "PlainTime")) return .{ .time = try text.parseTime(u, .{}) };
                if (is(ty, "Duration")) return .{ .span = try text.parseSpan(u, .{}) };
                if (is(ty, "Instant")) return .{ .instant = try text.parseTimestamp(u, .{}) };
                if (is(ty, "ZonedDateTime")) {
                    const p = try text.parseZoned(r.db, testing.io, u, .{});
                    try r.zones.append(testing.allocator, p.zone);
                    return .{ .zoned = p.zoned };
                }
            },
            .object => |o| return r.bag(ty, o),
            .date => |d| {
                if (is(ty, "PlainDate")) return v;
                if (is(ty, "PlainDateTime")) return .{ .date_time = .{ .date = d } };
            },
            .date_time => |dt| {
                if (is(ty, "PlainDateTime")) return v;
                if (is(ty, "PlainDate")) return .{ .date = dt.date };
                if (is(ty, "PlainTime")) return .{ .time = dt.time };
            },
            .zoned => |z| {
                if (is(ty, "ZonedDateTime")) return v;
                if (is(ty, "Instant")) return .{ .instant = z.timestamp };
                const dt = z.dateTime();
                if (is(ty, "PlainDateTime")) return .{ .date_time = dt };
                if (is(ty, "PlainDate")) return .{ .date = dt.date };
                if (is(ty, "PlainTime")) return .{ .time = dt.time };
            },
            .time, .span, .instant => if (std.meta.activeTag(v) == tagOf(ty)) return v,
            else => {},
        }
        return r.unsupported("a conversion");
    }

    fn tagOf(ty: []const u8) std.meta.Tag(Val) {
        if (std.mem.eql(u8, ty, "PlainTime")) return .time;
        if (std.mem.eql(u8, ty, "Duration")) return .span;
        if (std.mem.eql(u8, ty, "Instant")) return .instant;
        return .nothing;
    }

    /// A property bag of the type's fields.
    fn bag(r: *Runner, ty: []const u8, o: std.json.ObjectMap) anyerror!Val {
        var it = o.iterator();
        while (it.next()) |e| {
            const known = [_][]const u8{ "year", "month", "monthCode", "day", "hour", "minute", "second", "millisecond", "microsecond", "nanosecond", "years", "months", "weeks", "days", "hours", "minutes", "seconds", "milliseconds", "microseconds", "nanoseconds", "calendar", "timeZone", "offset" };
            var found = false;
            for (known) |k| found = found or std.mem.eql(u8, k, e.key_ptr.*);
            if (!found) return r.unsupported("a property bag with other keys");
        }
        if (std.mem.eql(u8, ty, "Duration")) {
            var f: Span.Signed = .{};
            var any = false;
            inline for (.{ "years", "months", "weeks", "days", "hours", "minutes", "seconds", "milliseconds", "microseconds", "nanoseconds" }) |name| {
                if (o.get(name)) |x| {
                    @field(f, name) = @intCast(try r.int(x));
                    any = true;
                }
            }
            if (!any) return error.Invalid;
            return .{ .span = try Span.fromSigned(f) };
        }
        if (o.get("calendar")) |c| {
            if (c != .string) return r.unsupported("a calendar of no string");
            try r.calendar(c.string);
        }
        if ((o.get("timeZone") != null or o.get("offset") != null) and !std.mem.eql(u8, ty, "ZonedDateTime")) {
            if (o.get("timeZone") == null) return r.unsupported("an offset without a zone");
        }
        var month: i64 = if (o.get("month")) |m| try r.int(m) else 0;
        if (o.get("monthCode")) |mc| {
            const code = switch (try r.eval(mc)) {
                .string => |s| s,
                else => return r.unsupported("a month code of no string"),
            };
            if (code.len != 3 or code[0] != 'M') return error.Invalid;
            const from_code = std.fmt.parseInt(i64, code[1..], 10) catch return error.Invalid;
            // A month code names a month of the calendar or none: no constraining.
            if (from_code < 1 or from_code > 12) return error.Invalid;
            if (month != 0 and month != from_code) return error.Invalid;
            month = from_code;
        }
        const reject = r.bag_options.overflow == .reject;
        // A date reads no time fields.
        const time: almanac.Time = if (std.mem.eql(u8, ty, "PlainDate")) .midnight else blk: {
            const h = try r.int(o.get("hour"));
            const mi = try r.int(o.get("minute"));
            const s = try r.int(o.get("second"));
            const ms = try r.int(o.get("millisecond"));
            const us = try r.int(o.get("microsecond"));
            const ns = try r.int(o.get("nanosecond"));
            if (h < 0 or mi < 0 or s < 0 or ms < 0 or us < 0 or ns < 0) return error.Invalid;
            if (reject and (h > 23 or mi > 59 or s > 59 or ms > 999 or us > 999 or ns > 999)) return error.OutOfRange;
            break :blk try almanac.Time.init(@intCast(@min(h, 23)), @intCast(@min(mi, 59)), @intCast(@min(s, 59)), @intCast(@min(ms, 999) * 1_000_000 + @min(us, 999) * 1000 + @min(ns, 999)));
        };
        if (std.mem.eql(u8, ty, "PlainTime")) return .{ .time = time };
        const year = if (o.get("year")) |y| try r.int(y) else return error.Invalid;
        const day = if (o.get("day")) |d| try r.int(d) else return error.Invalid;
        if (month < 1 or day < 1) return error.Invalid;
        const m: u8 = @intCast(@min(month, 12));
        if (year < -9999 or year > 9999) return error.OutOfRange;
        const dim = almanac.calendar.daysInMonth(year, m);
        if (reject and (month > 12 or day > dim)) return error.OutOfRange;
        const date = try almanac.Date.init(@intCast(year), m, @intCast(@min(day, dim)));
        if (std.mem.eql(u8, ty, "PlainDate")) return .{ .date = date };
        if (std.mem.eql(u8, ty, "PlainDateTime")) return .{ .date_time = .{ .date = date, .time = time } };
        if (std.mem.eql(u8, ty, "ZonedDateTime")) {
            const name = switch (try r.eval(o.get("timeZone") orelse return error.Invalid)) {
                .string => |n| n,
                else => return r.unsupported("a zone of no string"),
            };
            const tz = try r.zone(name);
            const civil: almanac.DateTime = .{ .date = date, .time = time };
            const ns = if (o.get("offset")) |written| blk: {
                const offset_text = switch (try r.eval(written)) {
                    .string => |t| t,
                    else => return r.unsupported("an offset of no string"),
                };
                const probe = try text.parseTimestamp(Untrusted.init(try arena.print("1970-01-01T00:00{s}", .{offset_text})), .{});
                const seconds = std.math.cast(i32, @divTrunc(-probe.raw(), std.time.ns_per_s)) orelse return error.Invalid;
                break :blk try almanac.resolve.resolveWithOffset(tz, civil, try almanac.Offset.init(seconds), r.bag_options.offset, r.bag_options.disambiguation, false);
            } else try almanac.resolve.resolve(tz, civil, r.bag_options.disambiguation);
            return .{ .zoned = try almanac.Zoned.init(almanac.Timestamp.fromRaw(@intCast(ns)), tz) };
        }
        return r.unsupported("a property bag of this type");
    }

    /// A calendar named, or given by an ISO string (its `u-ca`, ISO 8601 where none): almanac's
    /// one, another CLDR calendar (unsupported), or none at all.
    fn calendar(r: *Runner, s: []const u8) !void {
        if (std.ascii.eqlIgnoreCase(s, "iso8601")) return;
        const others = [_][]const u8{ "buddhist", "chinese", "coptic", "dangi", "ethioaa", "ethiopic", "gregory", "hebrew", "indian", "islamic", "islamic-civil", "islamic-tbla", "islamic-umalqura", "japanese", "persian", "roc" };
        for (others) |name| if (std.ascii.eqlIgnoreCase(s, name)) return r.unsupported("a calendar other than ISO 8601");
        const u = Untrusted.init(s);
        const readable = if (text.parseDateTime(u, .{})) |_| true else |_| if (text.parseTimestamp(u, .{})) |_| true else |_| if (text.parseTime(u, .{})) |_| true else |_| monthDayOrYearMonth(s);
        if (!readable) return error.Invalid;
        if (std.mem.find(u8, s, "u-ca=")) |at| {
            const rest = s[at + 5 ..];
            const end = std.mem.findScalar(u8, rest, ']') orelse rest.len;
            return r.calendar(rest[0..end]);
        }
    }

    /// A month and day (`01-01`, `--01-01`, `0101`) or a year and month (`2020-01`, `202001`), its
    /// annotations left off: ISO strings a calendar can be given by too.
    fn monthDayOrYearMonth(s: []const u8) bool {
        const end = std.mem.findScalar(u8, s, '[') orelse s.len;
        var t = s[0..end];
        if (std.mem.startsWith(u8, t, "--")) t = t[2..];
        var digits: usize = 0;
        var dashes: usize = 0;
        for (t, 0..) |c, i| {
            if (std.ascii.isDigit(c)) digits += 1 else if (c == '-' and i > 0) dashes += 1 else if (!(i == 0 and (c == '+' or c == '-'))) return false;
        }
        return dashes <= 1 and (digits == 4 or digits == 6 or digits == 8);
    }

    // Options.

    fn unit(r: *Runner, s: []const u8) !?Unit {
        if (std.mem.eql(u8, s, "auto")) return null;
        const names = [_][]const u8{ "year", "month", "week", "day", "hour", "minute", "second", "millisecond", "microsecond", "nanosecond" };
        for (names, 0..) |n, i| {
            if (std.mem.eql(u8, s, n) or (s.len == n.len + 1 and std.mem.startsWith(u8, s, n) and s[n.len] == 's')) return @fromBackingInt(@intCast(i));
        }
        _ = r;
        return error.Invalid;
    }

    fn mode(s: []const u8) !almanac.RoundingMode {
        const names = [_][]const u8{ "ceil", "floor", "expand", "trunc", "halfCeil", "halfFloor", "halfExpand", "halfTrunc", "halfEven" };
        for (names, 0..) |n, i| if (std.mem.eql(u8, s, n)) return @fromBackingInt(@intCast(i));
        return error.Invalid;
    }

    const Options = struct {
        largest: ?Unit = null,
        largest_given: bool = false,
        smallest: ?Unit = null,
        increment: u32 = 1,
        mode: ?almanac.RoundingMode = null,
        overflow: almanac.Overflow = .constrain,
        relative_to: ?Span.RelativeTo = null,
        unit_option: ?Unit = null,
        disambiguation: almanac.Disambiguation = .compatible,
        offset: almanac.OffsetConflict = .reject,
    };

    fn options(r: *Runner, v: ?Json) anyerror!Options {
        var o: Options = .{};
        const x = v orelse return o;
        const val = try r.eval(x);
        const map = switch (val) {
            .object => |m| m,
            .nothing => return o,
            // Temporal refuses options that are no object.
            else => return error.Invalid,
        };
        var it = map.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            const value = try r.eval(e.value_ptr.*);
            if (value == .nothing) continue;
            if (std.mem.eql(u8, key, "relativeTo")) {
                o.relative_to = switch (try r.relativeTo(value)) {
                    .date => |d| d.relativeTo(),
                    .zoned => |z| z.relativeTo(),
                    else => return r.unsupported("a relativeTo"),
                };
                continue;
            }
            if (std.mem.eql(u8, key, "roundingIncrement")) {
                const n = switch (value) {
                    .number => |n| n,
                    else => return r.unsupported("an increment of no number"),
                };
                if (!(n >= 1 and n <= 1e9)) return error.Invalid;
                o.increment = @intFromFloat(@trunc(n));
                continue;
            }
            const s = switch (value) {
                .string => |s| s,
                // An option of the wrong type is refused.
                else => return error.Invalid,
            };
            if (std.mem.eql(u8, key, "largestUnit")) {
                o.largest = try r.unit(s);
                o.largest_given = true;
            } else if (std.mem.eql(u8, key, "smallestUnit")) {
                o.smallest = (try r.unit(s)) orelse return error.Invalid;
            } else if (std.mem.eql(u8, key, "roundingMode")) {
                o.mode = try mode(s);
            } else if (std.mem.eql(u8, key, "overflow")) {
                o.overflow = if (std.mem.eql(u8, s, "constrain")) .constrain else if (std.mem.eql(u8, s, "reject")) .reject else return error.Invalid;
            } else if (std.mem.eql(u8, key, "unit")) {
                o.unit_option = (try r.unit(s)) orelse return error.Invalid;
            } else if (std.mem.eql(u8, key, "disambiguation")) {
                o.disambiguation = std.meta.stringToEnum(almanac.Disambiguation, s) orelse return error.Invalid;
            } else if (std.mem.eql(u8, key, "offset")) {
                o.offset = std.meta.stringToEnum(almanac.OffsetConflict, s) orelse return error.Invalid;
            } else return r.unsupported("an option almanac does not take");
        }
        return o;
    }

    fn relativeTo(r: *Runner, v: Val) anyerror!Val {
        return switch (v) {
            .string => |s| blk: {
                // A zone annotation makes it zoned; otherwise a date.
                if (std.mem.findScalar(u8, s, '[')) |_| break :blk try r.convert("ZonedDateTime", v);
                break :blk try r.convert("PlainDate", v);
            },
            .date => v,
            .date_time => |dt| .{ .date = dt.date },
            .zoned => v,
            .object => |o| if (o.get("timeZone") != null) try r.convert("ZonedDateTime", v) else try r.convert("PlainDate", v),
            else => r.unsupported("a relativeTo"),
        };
    }

    fn difference(o: Options, default_mode: almanac.RoundingMode) almanac.Difference {
        return .{ .largest = o.largest, .smallest = o.smallest, .increment = o.increment, .mode = o.mode orelse default_mode };
    }

    // Calls.

    fn call(r: *Runner, o: std.json.ObjectMap) anyerror!Val {
        const method = o.get("method").?.string;
        const args = o.get("args").?.array.items;
        const receiver_json = o.get("receiver").?;
        // `Temporal.<Type>.from(...)`.
        if (receiver_json.object.get("make")) |m| if (std.mem.eql(u8, m.string, "type")) return r.from(receiver_json.object.get("temporal").?.string, args);
        const receiver = try r.eval(receiver_json);
        const is = struct {
            fn f(a: []const u8, b: []const u8) bool {
                return std.mem.eql(u8, a, b);
            }
        }.f;
        if (is(method, "until") or is(method, "since")) {
            const ty = typeName(receiver);
            const other = try r.convert(ty, try r.eval(args[0]));
            const opts = try r.options(arg(args, 1));
            const d = difference(opts, .trunc);
            const until = is(method, "until");
            return .{ .span = switch (receiver) {
                .date => |a| if (until) try a.until(other.date, d) else try a.since(other.date, d),
                .date_time => |a| if (until) try a.until(other.date_time, d) else try a.since(other.date_time, d),
                .time => |a| if (until) try a.until(other.time, d) else try a.since(other.time, d),
                .instant => |a| if (until) try almanac.instant.until(a, other.instant, d) else try almanac.instant.since(a, other.instant, d),
                .zoned => |a| if (until) try a.until(other.zoned, d) else try a.since(other.zoned, d),
                else => return r.unsupported("until on this type"),
            } };
        }
        if (is(method, "add") or is(method, "subtract")) {
            const span = (try r.convert("Duration", try r.eval(args[0]))).span;
            // A time of day takes no options and reads none.
            const opts: Options = if (receiver == .time) .{} else try r.options(arg(args, 1));
            const s = if (is(method, "subtract")) span.negate() else span;
            return switch (receiver) {
                .date => |a| .{ .date = try a.add(s, opts.overflow) },
                .date_time => |a| .{ .date_time = try a.add(s, opts.overflow) },
                .time => |a| .{ .time = try a.add(s) },
                .instant => |a| .{ .instant = try almanac.instant.add(a, s) },
                .zoned => |a| .{ .zoned = try a.add(s, opts.overflow) },
                .span => |a| .{ .span = try a.add(s) },
                else => r.unsupported("add on this type"),
            };
        }
        if (is(method, "round")) {
            const given = try r.eval(args[0]);
            var opts: Options = .{};
            switch (given) {
                .string => |s| opts.smallest = (try r.unit(s)) orelse return error.Invalid,
                else => opts = try r.options(args[0]),
            }
            const m = opts.mode orelse .half_expand;
            // Temporal's options name a largest or a smallest unit; almanac's `Round` takes null for
            // `auto`, so the rule is the options' and read here.
            if (receiver == .span and !opts.largest_given and opts.smallest == null) return error.Invalid;
            return switch (receiver) {
                .span => |a| .{ .span = try a.round(.{ .largest = if (opts.largest_given) (opts.largest orelse a.largestUnit()) else null, .smallest = opts.smallest, .increment = opts.increment, .mode = m, .relative_to = opts.relative_to }) },
                .instant => |a| .{ .instant = try almanac.instant.round(a, .{ .smallest = opts.smallest orelse return error.Invalid, .increment = opts.increment, .mode = m }) },
                .time => |a| .{ .time = try a.round(.{ .smallest = opts.smallest orelse return error.Invalid, .increment = opts.increment, .mode = m }) },
                .date_time => |a| .{ .date_time = try a.round(.{ .smallest = opts.smallest orelse return error.Invalid, .increment = opts.increment, .mode = m }) },
                .zoned => |a| .{ .zoned = try a.round(.{ .smallest = opts.smallest orelse return error.Invalid, .increment = opts.increment, .mode = m }) },
                else => r.unsupported("round on this type"),
            };
        }
        if (is(method, "total")) {
            const given = try r.eval(args[0]);
            var opts: Options = .{};
            switch (given) {
                .string => |s| opts.unit_option = (try r.unit(s)) orelse return error.Invalid,
                else => opts = try r.options(args[0]),
            }
            const span = switch (receiver) {
                .span => |s| s,
                else => return r.unsupported("total on this type"),
            };
            return .{ .number = try span.total(opts.unit_option orelse return error.Invalid, opts.relative_to) };
        }
        return r.unsupported("a method");
    }

    fn typeName(v: Val) []const u8 {
        return switch (v) {
            .date => "PlainDate",
            .date_time => "PlainDateTime",
            .time => "PlainTime",
            .span => "Duration",
            .instant => "Instant",
            .zoned => "ZonedDateTime",
            else => "",
        };
    }
};

var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
const arena = arena_state.allocator();

/// The result's fields in test262's order for `kind`, or null where they do not match its type.
fn fields(kind: []const u8, v: Val, out: *[10]i128) ?[]const i128 {
    const k = struct {
        fn f(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }.f;
    if (k(kind, "assertDuration")) {
        if (v != .span) return null;
        for (std.enums.values(Unit), 0..) |u, i| out[i] = v.span.get(u);
        return out[0..10];
    }
    const time = switch (v) {
        .time => |t| t,
        .date_time => |dt| dt.time,
        else => null,
    };
    if (k(kind, "assertPlainDate")) {
        const d = switch (v) {
            .date => |d| d,
            else => return null,
        };
        out[0..3].* = .{ d.year.raw(), d.month.raw(), d.day.raw() };
        return out[0..3];
    }
    const t = time orelse return null;
    const ns = t.nanosecond.raw();
    const tf = [_]i128{ t.hour.raw(), t.minute.raw(), t.second.raw(), ns / 1_000_000, (ns / 1000) % 1000, ns % 1000 };
    if (k(kind, "assertPlainTime")) {
        if (v != .time) return null;
        out[0..6].* = tf;
        return out[0..6];
    }
    if (k(kind, "assertPlainDateTime")) {
        if (v != .date_time) return null;
        const d = v.date_time.date;
        out[0..3].* = .{ d.year.raw(), d.month.raw(), d.day.raw() };
        @memcpy(out[3..9], &tf);
        return out[0..9];
    }
    return null;
}

const Outcome = enum { pass, fail, unsupported };

/// The files whose failing cases almanac refuses by design, with why. Each must still hold a case
/// that fails here, so the list stays exact.
const range = "a value outside almanac's range, -9999 to 9999: Temporal reaches -271821 to +275760 (jiff's range, four-digit RFC 3339 years in an i16)";
const refused = [_]struct { []const u8, []const u8 }{
    .{ "test/built-ins/Temporal/Instant/prototype/add/argument-duration-max.js", range },
    .{ "test/built-ins/Temporal/PlainDate/prototype/add/argument-duration-max.js", range },
    .{ "test/built-ins/Temporal/PlainDate/prototype/subtract/argument-duration-max.js", range },
    .{ "test/built-ins/Temporal/PlainDate/prototype/add/argument-duration-max-plus-min-date.js", range },
    .{ "test/built-ins/Temporal/PlainDate/prototype/subtract/argument-duration-max-plus-min-date.js", range },
    .{ "test/built-ins/Temporal/PlainDateTime/prototype/add/argument-duration-max.js", range },
    .{ "test/built-ins/Temporal/PlainDateTime/prototype/subtract/argument-duration-max.js", range },
    .{ "test/built-ins/Temporal/PlainDateTime/prototype/add/argument-duration-max-plus-min-date.js", range },
    .{ "test/built-ins/Temporal/PlainDateTime/prototype/subtract/argument-duration-max-plus-min-date.js", range },
    .{ "test/built-ins/Temporal/PlainDate/from/argument-string.js", range },
    .{ "test/built-ins/Temporal/Duration/prototype/round/roundingincrement-days-large.js", range },
    .{ "test/built-ins/Temporal/Instant/prototype/subtract/argument-duration-max.js", range },
    .{ "test/built-ins/Temporal/ZonedDateTime/prototype/add/argument-duration-max.js", range },
    .{ "test/built-ins/Temporal/ZonedDateTime/prototype/subtract/argument-duration-max.js", range },
    .{ "test/built-ins/Temporal/PlainDate/from/limits.js", range },
    .{ "test/built-ins/Temporal/PlainDateTime/from/limits.js", range },
    .{ "test/built-ins/Temporal/Duration/prototype/round/relativeto-date-limits.js", range },
    .{ "test/built-ins/Temporal/Duration/prototype/total/relativeto-date-limits.js", range },
    .{ "test/built-ins/Temporal/Duration/prototype/round/relativeto-rounding-near-minimum-date.js", range },
    .{ "test/built-ins/Temporal/PlainDate/prototype/until/rounding-near-minimum-date.js", range },
    .{ "test/built-ins/Temporal/PlainDate/prototype/since/rounding-near-minimum-date.js", range },
    .{ "test/built-ins/Temporal/PlainDateTime/prototype/until/rounding-near-minimum-date.js", range },
    .{ "test/built-ins/Temporal/PlainDateTime/prototype/since/rounding-near-minimum-date.js", range },
    .{ "test/built-ins/Temporal/ZonedDateTime/prototype/until/roundingincrement-addition-out-of-range.js", range },
    .{ "test/built-ins/Temporal/ZonedDateTime/prototype/since/roundingincrement-addition-out-of-range.js", range },
    .{ "test/built-ins/Temporal/Duration/prototype/round/float64-representable-integer.js", "Temporal's duration fields are doubles, so a field past 2^53 is rounded before it is used again; almanac's are exact integers" },
};

fn refusedWhy(path: []const u8) ?[]const u8 {
    for (refused) |entry| if (std.mem.eql(u8, entry[0], path)) return entry[1];
    return null;
}

var last_got: [1200]u8 = undefined;
var last_got_len: usize = 0;

fn describe(v: anytype) void {
    var w: std.Io.Writer = .fixed(&last_got);
    w.print("{any}", .{v}) catch {};
    last_got_len = w.end;
}

/// Whether two results are the same value of the same type.
fn same(a: Val, b: Val) bool {
    return switch (a) {
        .date => |x| b == .date and x.eql(b.date),
        .date_time => |x| b == .date_time and x.eql(b.date_time),
        .time => |x| b == .time and x.eql(b.time),
        .span => |x| b == .span and x.eql(b.span),
        .instant => |x| b == .instant and x.raw() == b.instant.raw(),
        .zoned => |x| b == .zoned and x.timestamp.raw() == b.zoned.timestamp.raw(),
        else => false,
    };
}

fn run(r: *Runner, case: std.json.ObjectMap) Outcome {
    const expect = case.get("expect").?;
    if (expect == .object) if (expect.object.get("equal")) |other| {
        const a = r.eval(case.get("call").?) catch |err| return if (err == error.Unsupported) .unsupported else .fail;
        const b = r.eval(other) catch |err| return if (err == error.Unsupported) .unsupported else .fail;
        describe(a);
        return if (same(a, b)) .pass else .fail;
    };
    const got = r.eval(case.get("call").?);
    last_got_len = 0;
    if (got) |v| describe(v) else |err| describe(err);
    if (got) |v| {
        if (expect == .string) return .fail;
        const e = expect.object;
        if (e.get("fields")) |want| {
            var buffer: [10]i128 = undefined;
            const g = fields(e.get("kind").?.string, v, &buffer) orelse return .fail;
            const w = want.array.items;
            for (g, 0..) |x, i| {
                const wi: i128 = if (i < w.len) w[i].integer else 0;
                // test262 compares JS numbers: past 2^53, as doubles.
                if (x != wi and @as(f64, @floatFromInt(x)) != @as(f64, @floatFromInt(wi))) return .fail;
            }
            return .pass;
        }
        if (e.get("epoch_ns")) |want| {
            const ns: i128 = switch (v) {
                .instant => |t| t.raw(),
                .zoned => |z| z.timestamp.raw(),
                else => return .fail,
            };
            return if ((std.fmt.parseInt(i128, want.string, 0) catch return .fail) == ns) .pass else .fail;
        }
        if (e.get("number")) |want| {
            const n = switch (v) {
                .number => |n| n,
                else => return .fail,
            };
            return if ((std.fmt.parseFloat(f64, want.string) catch return .fail) == n) .pass else .fail;
        }
        return .fail;
    } else |err| {
        if (err == error.Unsupported) return .unsupported;
        return if (expect == .string) .pass else .fail;
    }
}

test "test262's Temporal cases: each passes or is listed" {
    defer _ = arena_state.reset(.free_all);
    const parsed = try std.json.parseFromSlice(Json, testing.allocator, test262.temporal, .{});
    defer parsed.deinit();
    var db = almanac.Database.init(testing.allocator, .{ .source = .embedded });
    defer db.deinit();
    var reasons: std.array_hash_map.String(usize) = .empty;
    defer reasons.deinit(testing.allocator);
    var counts: [3]usize = @splat(0);
    var listed: usize = 0;
    var used: [refused.len]bool = @splat(false);
    for (parsed.value.object.get("cases").?.array.items) |c| {
        var r: Runner = .{ .db = &db };
        defer r.deinit();
        const outcome = run(&r, c.object);
        const path = c.object.get("path").?.string;
        if (outcome == .fail) if (refusedWhy(path)) |_| {
            for (refused, 0..) |entry, i| if (std.mem.eql(u8, entry[0], path)) {
                used[i] = true;
            };
            listed += 1;
            continue;
        };
        counts[@backingInt(outcome)] += 1;
        switch (outcome) {
            .fail => {
                var w: std.Io.Writer.Allocating = .init(testing.allocator);
                defer w.deinit();
                std.json.Stringify.value(c, .{}, &w.writer) catch {};
                std.debug.print("FAIL {s} GOT {s}\n", .{ w.written(), last_got[0..last_got_len] });
            },
            .unsupported => (try reasons.getOrPutValue(testing.allocator, r.reason, 0)).value_ptr.* += 1,
            .pass => {},
        }
    }
    var it = reasons.iterator();
    while (it.next()) |e| std.debug.print("unsupported: {s}: {d}\n", .{ e.key_ptr.*, e.value_ptr.* });
    for (refused, used) |entry, u| if (!u) {
        std.debug.print("listed as refused but nothing there fails: {s}\n", .{entry[0]});
        counts[1] += 1;
    };
    const cases = parsed.value.object.get("cases").?.array.items.len;
    const unread = parsed.value.object.get("files_without_cases").?.array.items;
    const without = unread.len;
    var applicable: usize = 0;
    for (unread) |u| {
        if (std.mem.startsWith(u8, u.object.get("why").?.string, "applicable")) applicable += 1;
    }
    std.debug.print("test262 Temporal ({s}): {d} cases read from {d} files: {d} pass, {d} refused by design, {d} fail, {d} not runnable here; {d} files read no case: {d} applicable and unread, {d} not applicable to a Zig API\n", .{
        parsed.value.object.get("commit").?.string, cases, parsed.value.object.get("files_read").?.integer - @as(i64, @intCast(without)), counts[0], listed, counts[1], counts[2], without, applicable, without - applicable,
    });
    try testing.expectEqual(0, counts[1]);
}

// Cases transcribed by hand from files whose expectations the reader cannot evaluate (they compute
// them in JavaScript's doubles): the same double arithmetic, in the same order, written here.

fn duration(f: Span.Signed) Span {
    return Span.fromSigned(f) catch unreachable;
}

// Transcribed: test/built-ins/Temporal/Duration/prototype/total/relativeto-total-of-each-unit.js
test "transcribed: each unit's total of P5Y5M5W5DT5H5M5.005005005S from a date and from a zoned value" {
    var db = almanac.Database.init(testing.allocator, .{ .source = .embedded });
    defer db.deinit();
    var utc = try db.zone(testing.io, .init("UTC"));
    defer utc.release();
    const d = duration(.{ .years = 5, .months = 5, .weeks = 5, .days = 5, .hours = 5, .minutes = 5, .seconds = 5, .milliseconds = 5, .microseconds = 5, .nanoseconds = 5 });
    const plain = (try almanac.Date.init(2000, 1, 1)).relativeTo();
    const zoned = (try almanac.Zoned.init(almanac.Timestamp.fromRaw(63072000_000_000_000), utc.get())).relativeTo();
    const day_ms: f64 = 24 * 3600 * 1000;
    const full_years: f64 = 5;
    const full_months: f64 = full_years * 12 + 5 + 1;
    const full_days: f64 = 366 + 365 + 365 + 365 + 366 + 31 + 28 + 31 + 30 + 31 + 5 * 7 + 5;
    const full_ms: f64 = full_days * day_ms + 5 * 3600_000 + 5 * 60_000 + 5000 + 5;
    const partial_day_ms: f64 = full_ms - full_days * day_ms + 0.005005;
    const fractional_day = partial_day_ms / day_ms;
    const partial_year_days = full_days - (full_years * 365 + 2);
    const fractional_year = partial_year_days / 365 + fractional_day / 365;
    const fractional_months = (10 * day_ms + partial_day_ms) / (31 * day_ms);
    const want = [_]f64{
        full_years + fractional_year,
        full_months + fractional_months,
        @floor(full_days / 7) + (2 + fractional_day) / 7,
        full_days + fractional_day,
        full_days * 24 + partial_day_ms / 3600000,
        full_days * 24 * 60 + partial_day_ms / 60000,
        full_days * 24 * 60 * 60 + partial_day_ms / 1000,
        full_ms + 0.005005,
        full_ms * 1000 + 5.005,
        full_ms * 1000000 + 5005,
    };
    for (std.enums.values(Unit), want) |unit, w| for ([_]Span.RelativeTo{ plain, zoned }) |rel| {
        const got = try d.total(unit, rel);
        errdefer std.debug.print("{t}: {d} {d}\n", .{ unit, got, w });
        try testing.expectEqual(w, got);
    };
}

// Transcribed: test/built-ins/Temporal/Duration/prototype/total/relativeto-unit-weeks-balances-hours-into-days.js
test "transcribed: weeks total of 6 days 20 hours, both signs" {
    const rel = (try almanac.Date.init(2020, 1, 1)).relativeTo();
    // As JavaScript computes it: a double after each operation.
    const six: f64 = 6;
    const twenty: f64 = 20;
    const want: f64 = (six + twenty / 24) / 7;
    try testing.expect(@abs(try duration(.{ .days = 6, .hours = 20 }).total(.week, rel) - want) < std.math.floatEps(f64));
    try testing.expect(@abs(try duration(.{ .days = -6, .hours = -20 }).total(.week, rel) - -want) < std.math.floatEps(f64));
}

// Transcribed: test/built-ins/Temporal/Duration/prototype/total/relativeto-calendar-units-depend-on-relative-date.js
test "transcribed: forty days in months depends on the months it spans" {
    // `toPrecision(16)` exactly: the value's 16 significant digits, rounded half to even from its
    // exact binary value (for 1 <= |x| < 10, which these are). Zig's `{e:.15}` rounds from the
    // shortest representation instead, which rounds twice.
    const precision = struct {
        fn digits(x: f64) i128 {
            const bits: u64 = @bitCast(x);
            const exponent: i32 = @as(i32, @intCast((bits >> 52) & 0x7ff)) - 1075;
            const mantissa: u128 = (bits & ((1 << 52) - 1)) | (1 << 52);
            const scaled = mantissa * 1_000_000_000_000_000;
            const shift: u7 = @intCast(-exponent);
            var q = scaled >> shift;
            const rest = scaled & ((@as(u128, 1) << shift) - 1);
            const half = @as(u128, 1) << (shift - 1);
            if (rest > half or (rest == half and q & 1 == 1)) q += 1;
            const v: i128 = @intCast(q);
            return if (x < 0) -v else v;
        }
        fn same(a: f64, b: f64) !void {
            try testing.expect(@abs(a) >= 1 and @abs(a) < 10);
            try testing.expectEqual(digits(b), digits(a));
        }
    }.same;
    const forty = duration(.{ .days = 40 });
    const one: f64 = 1;
    const eleven: f64 = 11;
    const nine: f64 = 9;
    try precision(try forty.total(.month, (try almanac.Date.init(2020, 2, 1)).relativeTo()), one + eleven / 31);
    try precision(try forty.total(.month, (try almanac.Date.init(2020, 1, 1)).relativeTo()), one + nine / 29);
    try precision(try forty.negate().total(.month, (try almanac.Date.init(2020, 3, 1)).relativeTo()), -(one + eleven / 31));
    try precision(try forty.negate().total(.month, (try almanac.Date.init(2020, 4, 1)).relativeTo()), -(one + nine / 29));
}

// Transcribed: test/built-ins/Temporal/Duration/prototype/total/relativeto-zoneddatetime-with-fractional-days.js
test "transcribed: a week and an hour in days from a zoned value" {
    var db = almanac.Database.init(testing.allocator, .{ .source = .embedded });
    defer db.deinit();
    var utc = try db.zone(testing.io, .init("UTC"));
    defer utc.release();
    const rel = (try almanac.Zoned.init(almanac.Timestamp.fromRaw(0), utc.get())).relativeTo();
    const seven: f64 = 7;
    const one: f64 = 1;
    try testing.expectEqual(seven + one / 24, try duration(.{ .weeks = 1, .hours = 1 }).total(.day, rel));
}

/// The cases written by hand above, counted for the report.
pub const transcribed = 20 + 2 + 4 + 1;
