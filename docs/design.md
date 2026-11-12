# Architecture

almanac owns civil time: calendar dates and times, instants, zones and their rules, text forms and
calendar arithmetic. Its runtime closure is almanac → aegis → std.

This describes the implementation in this repository. Change it with the code when an owner, an
invariant or a decision changes.

## Layers

[ci/layers.zig](../ci/layers.zig) checks the production import graph, lowest first: the vocabulary
(`units.zig`: ranged fields, `Offset`, units, rounding modes and policies), the calendar
(`calendar.zig`: the kernels), the civil values (`Date.zig`, `Time.zig`, `DateTime.zig`), and the root.

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

## Validation

The kernels are checked against Hinnant's independent `days_from_civil` on every day of the range, ISO
weeks at the years' edges, and a shakedown property over random day counts.

## Not built yet

Calendar arithmetic and spans, instants, zones (TZif, POSIX strings, the embedded database), the
database, resolution and zoned values, and text.
