//! A civil date and time to an instant in a zone, with Temporal's policies at every ambiguous
//! point: a wall clock the zone skips (a gap) or repeats (a fold) is resolved as `Disambiguation`
//! says, and a written offset that disagrees with the zone's as `OffsetConflict` says.
const units = @import("units.zig");
const arithmetic = @import("arithmetic.zig");
const instant = @import("instant.zig");
const rounding = @import("round.zig");
const TimeZone = @import("TimeZone.zig");
const DateTime = @import("DateTime.zig");
const Date = @import("Date.zig");
const Offset = units.Offset;

pub const RangeError = units.RangeError;
/// `Skipped`: the wall clock falls in a gap, under `.reject`. `Ambiguous`: it falls in a fold, under
/// `.reject`.
pub const ResolveError = RangeError || error{ Skipped, Ambiguous };
/// `OffsetConflict`: a written offset is none of the zone's for that wall clock, under `.reject`.
pub const OffsetError = ResolveError || error{OffsetConflict};

pub const Epoch = arithmetic.Epoch;
const one_day = arithmetic.one_day;

/// A civil date and time read as if UTC.
pub fn wallClock(dt: DateTime) Epoch {
    return (arithmetic.IsoDateTime{ .date = dt.date.iso(), .time = dt.time.sinceMidnight() }).epochNs();
}

/// A place on the timeline inside almanac's range.
pub fn checked(at: Epoch) RangeError!Epoch {
    return instant.checked(at);
}

/// GetEpochNanosecondsFor: the instant of a wall clock (nanoseconds read as if UTC) in `zone`.
/// One candidate is the answer. In a fold, `.earlier` and `.compatible` take the first, `.later`
/// the second. In a gap, `.earlier` moves the wall clock back by the gap's length and takes the
/// first instant there, `.later` and `.compatible` move it forward and take the last: the instant
/// is then the wall clock read at the offset before the gap, or after it for `.earlier`.
pub fn resolveWallClock(zone: *const TimeZone, local: Epoch, disambiguation: units.Disambiguation) ResolveError!Epoch {
    const c = zone.candidatesAt(local);
    if (c.count == 1) return checked(c.instants[0]);
    if (c.count >= 2) return switch (disambiguation) {
        .earlier, .compatible => checked(c.earliest().?),
        .later => checked(c.latest().?),
        .reject => error.Ambiguous,
    };
    if (disambiguation == .reject) return error.Skipped;
    const before = zone.offsetAtNanoseconds(local.sub(one_day) catch return error.OutOfRange);
    const after = zone.offsetAtNanoseconds(local.add(one_day) catch return error.OutOfRange);
    const gap = after.nanoseconds().sub(before.nanoseconds()) catch return error.OutOfRange;
    if (disambiguation == .earlier) {
        const shifted = zone.candidatesAt(local.sub(gap) catch return error.OutOfRange);
        return checked(shifted.earliest() orelse return error.OutOfRange);
    }
    const shifted = zone.candidatesAt(local.add(gap) catch return error.OutOfRange);
    return checked(shifted.latest() orelse return error.OutOfRange);
}

/// The instant of a civil date and time in `zone`.
pub fn resolve(zone: *const TimeZone, dt: DateTime, disambiguation: units.Disambiguation) ResolveError!Epoch {
    return resolveWallClock(zone, wallClock(dt), disambiguation);
}

/// InterpretISODateTimeOffset with an offset written beside the wall clock: `.use` takes the
/// written offset whatever the zone says, `.ignore` the zone's resolution alone, `.prefer` the
/// candidate whose offset is the written one or else the zone's resolution, `.reject` that
/// candidate or `OffsetConflict`. With `match_minutes`, an offset written to the minute matches a
/// candidate's offset rounded to the minute (RFC 3339 text cannot write seconds in an offset).
pub fn resolveWithOffset(
    zone: *const TimeZone,
    dt: DateTime,
    offset: Offset,
    conflict: units.OffsetConflict,
    disambiguation: units.Disambiguation,
    match_minutes: bool,
) OffsetError!Epoch {
    const local = wallClock(dt);
    const written = offset.nanoseconds();
    switch (conflict) {
        .ignore => return resolveWallClock(zone, local, disambiguation),
        .use => return checked(local.sub(written) catch return error.OutOfRange),
        .prefer, .reject => {},
    }
    const c = zone.candidatesAt(local);
    for (c.slice()) |candidate| {
        const candidate_offset = candidate.durationTo(local) catch return error.OutOfRange;
        if (candidate_offset.eql(written)) return checked(candidate);
        if (match_minutes) {
            const to_minute = rounding.toIncrementNs(candidate_offset, arithmetic.length(.minute), .half_expand) catch return error.OutOfRange;
            if (to_minute.eql(written)) return checked(candidate);
        }
    }
    if (conflict == .reject) return error.OffsetConflict;
    return resolveWallClock(zone, local, disambiguation);
}

/// GetStartOfDay: the first instant of a date in `zone`: midnight's first candidate, or where
/// midnight is skipped, the transition that skips it.
pub fn startOfDay(zone: *const TimeZone, date: Date) RangeError!Epoch {
    const local = (arithmetic.IsoDateTime{ .date = date.iso() }).epochNs();
    const c = zone.candidatesAt(local);
    if (c.earliest()) |first| return checked(first);
    const change = zone.nextChange(local.sub(one_day) catch return error.OutOfRange) orelse return error.OutOfRange;
    return checked(change);
}
