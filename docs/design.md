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
`Time.zig`, `DateTime.zig`), and the root. The span sits beneath the types it is added to, so what gives its
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

## Validation

The kernels are checked against Hinnant's independent `days_from_civil` on every day of the range, ISO
weeks at the years' edges, and a shakedown property over random day counts. The arithmetic is checked on cases
worked from Temporal's specification (month ends, leap days, `since` against `until`, every rounding mode at and
around ties, increments, carries into larger units, the bounds), CalendarDateUntil's loops against the closed form,
and properties over random dates and date-times that adding a difference reaches its end in every largest unit, its
`since` negated likewise, and that truncation never passes the end.

## Not built yet

Instants, zones (TZif, POSIX strings, the embedded database), the
database, resolution and zoned values, and text.
