//! Text: RFC 3339 and RFC 9557 read as Temporal reads them, ISO 8601 durations, and writing. Every
//! parser takes untrusted text and refuses anything else with `ParseError.Invalid`, a `Diagnostic`
//! saying where and what was expected. `strict` answers whether a text is exactly RFC 3339.
const std = @import("std");
const aegis = @import("aegis");
const units = @import("units.zig");
const iso = @import("text/iso.zig");
const write = @import("text/write.zig");
const instant = @import("instant.zig");
const resolve = @import("resolve.zig");
const Date = @import("Date.zig");
const Time = @import("Time.zig");
const DateTime = @import("DateTime.zig");
const Span = @import("Span.zig");
const Zoned = @import("Zoned.zig");
const Database = @import("Database.zig");
const Untrusted = aegis.input.Untrusted([]const u8);
const Timestamp = instant.Timestamp;
const Offset = units.Offset;

pub const strict = @import("text/strict.zig");
pub const ParseError = iso.ParseError;
pub const Diagnostic = iso.Diagnostic;
pub const Options = iso.Options;

const invalid = iso.refuse;

/// An instant written with its offset (`2026-10-31T09:00:00Z`, `2026-10-31T10:00:00+01:00`, an
/// RFC 9557 annotation after it allowed and passed over): Temporal's `Instant.from`.
pub fn parseTimestamp(s: Untrusted, options: Options) ParseError!Timestamp {
    const text = s.readForParse();
    const dt = try iso.dateTime(text, options);
    const time = dt.time orelse return invalid(options, text.len, "a time");
    const written = dt.offset orelse return invalid(options, text.len, "an offset or 'Z'");
    const seconds: i32 = switch (written) {
        .z => 0,
        .numeric => |n| n.offset.seconds.raw(),
    };
    const local = resolve.wallClock(.{ .date = Date.fromCivil(dt.date), .time = Time.fromCivil(time) });
    const ns = resolve.checked(local - @as(i128, seconds) * std.time.ns_per_s) catch return invalid(options, 0, "an instant from -9999 to 9999");
    return .fromRaw(@intCast(ns));
}

/// A calendar date (`2026-10-31`, `20261031`, or a date-time whose date is taken): Temporal's
/// `PlainDate.from`. `Z` is refused: a date with no zone names no instant.
pub fn parseDate(s: Untrusted, options: Options) ParseError!Date {
    return Date.fromText(s.readForParse(), options);
}

/// A civil date and time (the time optional: midnight): Temporal's `PlainDateTime.from`.
pub fn parseDateTime(s: Untrusted, options: Options) ParseError!DateTime {
    return DateTime.fromText(s.readForParse(), options);
}

/// A time of day (`09:00`, `T0900`, `09:00:00.5`, or a date-time whose time is taken):
/// Temporal's `PlainTime.from`.
pub fn parseTime(s: Untrusted, options: Options) ParseError!Time {
    return Time.fromText(s.readForParse(), options);
}

/// An ISO 8601 duration (`P1Y2M3DT4H5M6.5S`, `-PT1.5H`): Temporal's `Duration.from`.
pub fn parseSpan(s: Untrusted, options: Options) ParseError!Span {
    return Span.fromText(s.readForParse(), options);
}

pub const ParseZoned = struct {
    /// How a wall clock the zone skips or repeats is resolved where no offset is written.
    disambiguation: units.Disambiguation = .compatible,
    /// How a written offset is weighed against the zone's (Temporal's default: refused where it
    /// disagrees).
    offset: units.OffsetConflict = .reject,
    options: Options = .{},
};

/// A zoned value and the handle to the zone it borrows; release the handle when done with both.
pub const ParsedZoned = struct {
    zoned: Zoned,
    zone: Database.Zone,

    pub fn release(p: *ParsedZoned) void {
        p.zone.release();
    }
};

pub const ParseZonedError = ParseError || Database.ZoneError || resolve.ResolveError || error{OffsetConflict};

/// An RFC 9557 zoned date-time (`2026-10-31T09:00:00+00:00[Europe/Lisbon]`): Temporal's
/// `ZonedDateTime.from`. The zone annotation is required: a name from `db`, or an offset. A
/// written offset is weighed by `options.offset` (matched to the minute where it was written to
/// the minute); `Z` takes the instant as written; with no time, the day's start.
pub fn parseZoned(db: *Database, io: std.Io, s: Untrusted, options: ParseZoned) ParseZonedError!ParsedZoned {
    const text = s.readForParse();
    const dt = try iso.dateTime(text, options.options);
    const annotation = dt.zone orelse return invalid(options.options, text.len, "a time zone annotation");
    var zone = switch (annotation) {
        .name => |n| try db.zone(io, .init(n)),
        .offset => |o| try db.fixedZone(o),
    };
    errdefer zone.release();
    const tz = zone.get();
    const ns: i128 = if (dt.time) |time| blk: {
        const civil: DateTime = .{ .date = Date.fromCivil(dt.date), .time = Time.fromCivil(time) };
        const written = dt.offset orelse break :blk try resolve.resolve(tz, civil, options.disambiguation);
        break :blk switch (written) {
            .z => try resolve.checked(resolve.wallClock(civil)),
            .numeric => |n| try resolve.resolveWithOffset(tz, civil, n.offset, options.offset, options.disambiguation, !n.seconds),
        };
    } else try resolve.startOfDay(tz, Date.fromCivil(dt.date));
    return .{ .zoned = try Zoned.init(Timestamp.fromRaw(@intCast(ns)), tz), .zone = zone };
}

/// The most bytes `writeTimestamp` writes.
pub const timestamp_len = DateTime.max_text_len + write.offset_len;

/// An instant as RFC 3339 writes it: in UTC with `Z` (`offset` null), or at `offset`. The
/// fraction of the second where there is one.
pub fn writeTimestamp(w: *std.Io.Writer, at: anytype, offset: ?Offset) (std.Io.Writer.Error || units.RangeError)!void {
    const dt = try instant.toDateTime(at, offset orelse .utc);
    try dt.format(w);
    if (offset) |o| try write.offset(w, o.seconds.raw()) else try w.writeByte('Z');
}
