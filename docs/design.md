# Architecture

almanac owns civil time: calendar dates and times, instants, zones and their rules, text forms and
calendar arithmetic. Its runtime closure is almanac → aegis → std.

This describes the implementation in this repository. Change it with the code when an owner, an
invariant or a decision changes.

## Layers

[ci/layers.zig](../ci/layers.zig) checks the production import graph, lowest first: the vocabulary
(`units.zig`: ranged fields, `Offset`, units, rounding modes, policies and errors), the kernels
(`calendar.zig`, the calendar's conversions; `round.zig`, rounding), the arithmetic (`arithmetic.zig`,
Temporal's abstract operations over plain records), the span (`Span.zig`), the civil values (`Date.zig`,
`Time.zig`, `DateTime.zig`), instants (`instant.zig`), and the root. The span sits beneath the types it is added to, so what gives its
calendar units a length (`Span.RelativeTo`) holds their records and is made by them (`Date.relativeTo`).

## The calendar

The proleptic Gregorian (ISO 8601) calendar over the years -9999 to 9999. A date converts to its day
count (days since 1970-01-01) and back by Neri and Schneider's Euclidean affine functions ("Euclidean
affine functions and their application to calendar algorithms", 2021): the calendar is shifted by 82
400-year cycles so every year read is positive and starts in March, so the leap day comes last, and each
step is a multiply and a shift. The weekday is ISO's (Monday 1); the ISO week date takes the year of the
week's Thursday. Every kernel is total over the range and evaluable at `comptime`.

## Civil values

`Date`, `Time` and `DateTime` hold aegis `Ranged` fields, so no value outside its calendar exists, and a
date's day is checked against its month when it is made. There is no leap second: almanac counts POSIX
time, as Temporal, jiff, Go and java.time do.

## Arithmetic

almanac's arithmetic is Temporal's, transcribed from its abstract operations in `arithmetic.zig`:

- **Spans.** `Span` is Temporal's `Duration`, its fields Temporal's (years to nanoseconds, milliseconds and
  microseconds among them), one sign and unsigned magnitudes, each field bounded as IsValidDuration bounds it and the
  days and time together below 2^53 seconds. Internally a span is Temporal's internal duration record: a signed date
  part and a time part in nanoseconds (`i128`).
- **Adding.** Years and months first, the day regulated (`Overflow`: constrained to the month's end, or refused),
  then weeks and days (CalendarDateAdd); a date takes the span's time as whole days toward zero, a date and time adds
  the time to its time of day first and carries the whole days into the date part. Intermediate years are read wide
  (`calendar.daysFromCivilWide`) and only the result is checked against the range.
- **Differences.** CalendarDateUntil counts each unit while the date reached, its day unregulated, does not pass the
  end; that test is monotone in the count, so the count is the distance in the unit, less one where the day
  overshoots. A unit test runs the specification's loops as written against the closed form. A date and time borrows
  a day where the time runs against the dates (DifferenceISODateTime). `since` is the same difference, rounded with
  the mode negated, then negated, so it is not the reverse `until`.
- **Rounding.** RoundRelativeDuration: a calendar unit by the destination's exact progress between the truncated
  count and one increment more, as dates (NudgeToCalendarUnit); days and time as one count of nanoseconds
  (NudgeToDayOrTime); then a carry bubbles up through the units to the largest. Every comparison is exact integer
  arithmetic: progress is a fraction of two `i128`s, never a float. A span rounded without a date may hold no calendar
  units, and a day is 24 hours.
- **Not yet:** a zoned value as `relativeTo` (with zones), `Duration.total`, and rounding a `DateTime` or a `Time`.

## Instants

`Timestamp` is aegis's `Instant(.real, .nanosecond, i96)`, not a wrapper. Every operation in `instant.zig`
takes any aegis instant of the real clock, at its own unit and representation, read through its
`aegis_scalar` declaration (`.kind = .instant`, `.clock`, `.unit`, `.representation`): chronicle's `Time`
(milliseconds in an `i64`), a `u64` count of seconds and a `Timestamp` meet without a conversion layer.
Anything else is a compile error saying why: an instant of another clock (`.awake`, `.boot`) names no
civil time, and a duration or a plain integer is no instant. Instants are read as nanoseconds in an
`i128`, which holds every instant a 64-bit count of any aegis unit up to days can name; past that an
instant is simply out of range.

The range is the calendar's in UTC, -9999-01-01T00:00:00Z to 9999-12-31T23:59:59.999999999Z; civil time
at an offset that carries an instant past the calendar's edge is refused. The operations are Temporal's
`Instant`'s: rounding on the timeline (RoundNumberToIncrementAsIfPositive, so `.trunc` before 1970 goes
back), increments that divide a day; differences in time units only, the second the default largest;
adding a span of time units (days and calendar units have no fixed length on a timeline). `round` keeps
the instant's type, refusing a length that is neither a multiple nor a divisor of its unit; `add` returns
an exact `Timestamp`, and `convert` takes it to a coarser type under an explicit rounding mode.

## Validation

The kernels are checked against Hinnant's independent `days_from_civil` on every day of the range, ISO
weeks at the years' edges, and a shakedown property over random day counts. The arithmetic is checked on cases
worked from Temporal's specification (month ends, leap days, `since` against `until`, every rounding mode at and
around ties, increments, carries into larger units, the bounds), CalendarDateUntil's loops against the closed form,
and properties over random dates and date-times that adding a difference reaches its end in every largest unit, its
`since` negated likewise, and that truncation never passes the end. Instants are checked at the range's
edges, at offsets, in conversion and rounding before and after 1970, chronicle's `Time` and a `u64` of
milliseconds against a `Timestamp` of the same instant, a property that civil time at any offset and back
is the instant, and compile-error fixtures (`src/testing/instant_rejected.zig`) for the `.awake` and
`.boot` clocks, a duration and an integer.

## Not built yet

Zones (TZif, POSIX strings, the embedded database), the database, resolution and zoned values, and
text.
