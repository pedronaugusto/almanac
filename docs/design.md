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
`Time.zig`, `DateTime.zig`), instants (`instant.zig`), the zone's sources (`zone/posix.zig`, `zone/tzif.zig`, which sit beneath the
arithmetic beside the kernels), the zone (`TimeZone.zig`), resolution (`resolve.zig`), zoned values (`Zoned.zig`), the zone database (`Database.zig`), text (`text.zig`; beneath it, with the kernels, `text/iso.zig`,
the reader, `text/write.zig`, the writers, and `text/strict.zig`), and the root.
Arithmetic in a zone reaches the zone through `arithmetic.Zone`, two functions (the wall clock at an
instant, and a wall clock's instant under `compatible`), since the zone sits above the arithmetic. The span sits beneath the types it is added to, so what gives its
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
- **In a zone** (AddZonedDateTime, DifferenceZonedDateTime, NudgeToZonedTime): days are calendar units,
  added to the wall clock and resolved `compatible`, so a day across a change of offset is 23 or 25 hours;
  a difference finds whole days by stepping back from the end's date until the time left runs the same way
  as the whole; rounding to the day uses the day's own length. Where NudgeToCalendarUnit's start is the
  origin itself, the origin's instant is used rather than its wall clock resolved again, which in a fold
  could be the other of its two instants.
- **Not yet:** `Duration.total`, and rounding a `DateTime` or a `Time`.

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

## Zones

Every zone has one compiled form, `TimeZone`: an initial local time type, a sorted array of
transitions (seconds since 1970) with the type each starts, and an optional POSIX rule for times past
the table. A TZif file fills all of it; a POSIX string is a zone of a rule alone; a fixed offset and
UTC have neither transitions nor rule. A local time type holds its offset, its daylight saving flag
and its abbreviation inline (up to 16 bytes), so `Info.abbreviation` is borrowed from the zone and a
zone made by value (`utc`, `fixed`, `posix`) holds no pointer into itself.

A lookup is a binary search, then the rule. A zone is immutable and holds no hint of its own; a
caller's `Cursor` remembers the last transition found and is tried, with its neighbour, before the
search. Any cursor gives the same answers.

**POSIX strings** (`std offset [dst [offset] ,start[/time],end[/time]]`, with RFC 8536's rule times
from -167 to 167 hours) parse into a `Rule` of fixed size. Daylight saving time without a rule is
refused rather than given an implementation's default. A rule is evaluated in closed form: the
transitions of the years around an instant are computed and sorted, an end before a start at the same
instant, so daylight saving all year (an end and the next start at once) stays in force. The next and
previous changes are searched over several years and reported only where every event at that instant
is known.

**TZif files** (RFC 8536, versions 1 to 4) are untrusted bytes: each block's length is computed from
its counts and checked against what the file still holds before anything is allocated; transitions
must ascend strictly, every index, flag, offset (within ±25:59:59) and abbreviation is checked, and the
footer must be the file's last line. A file with a leap second table (a `right/` zone) is refused as
`LeapSeconds`: almanac counts POSIX time.

Transitions are Temporal's: `nextTransition` and `previousTransition` report instants where the
offset changes, so a change of abbreviation or daylight saving flag alone (Lisbon's WEST to CET in
1992) is none.

## Resolution and zoned values

A wall clock's candidates in a zone are found by trying each offset in force within two days either side
of it: the wall clock less that offset is a candidate where that offset is the one in force there. A gap
has none, a fold two. `Disambiguation` picks among them as Temporal does (in a gap, `compatible` and
`later` move the wall clock forward by the gap's length, `earlier` back); `OffsetConflict` weighs an
offset written beside the wall clock (`use`, `ignore`, `prefer`, `reject`, with RFC 3339's minute
precision as an option). `Zoned` holds an instant, a borrowed zone and the offset in force, and is
refused where its wall clock would leave the calendar. Its arithmetic, differences (the hour the default
largest unit), rounding and `startOfDay` are Temporal's `ZonedDateTime`'s; differences in date units need
the same zone (the same zone value, or the same IANA name).

## The zone database

`Database` finds and loads zones and caches one counted handle per name. Each zone is its own
`aegis.Shared` block, so handles stay valid after a `refresh` replaced their zone and after the
database itself is gone; the cache sits under an `aegis.RwGuarded` taken through the caller's `Io`, and
a loaded zone's lookup is a shared read. A miss is loaded with no lock held, then inserted, keeping
whichever load another caller finished first.

Names are untrusted. A name is components of letters, digits, `_`, `-` and `+` joined by `/`, none
empty, `.` or `..`; anything else names no zone, so no path outside the zoneinfo directory is formed
from one. The system's files are read beneath the caller's `zoneinfo` directory handle: every prefix
of the path is checked for a link, and a link is followed only while it stays beneath (an absolute
target or one that climbs out names no zone), at most eight links deep. A file over `max_zone_bytes`
is `TooLarge` before it is read; a damaged one is `Corrupt`, never a silent fallback to the embedded
data, which is consulted only where the system has no such zone.

`local` takes the caller's `$TZ` (almanac reads no environment) as POSIX reads it: empty is UTC,
`:name` or a zone name is that zone, anything else a POSIX TZ string. Unset, it is the zone the
`localtime` link names (its target past `zoneinfo/`), or the file it reaches where that names none,
or UTC where there is no `localtime`. `refresh` compares each cached system file's inode, size and
modification time with what was loaded and loads the changed ones again as new zones.

## The embedded database

almanac carries its own compiler of the zic language (`tools/zic.zig`, a development tool, not
shipped): it reads an IANA release's source files (vendored in `tzdata/` with their version, public
domain), computes each zone's transitions as zic's `outzone` does (rules run year by year with each
time's suffix, a zone line's start and until, zic's merge of a transition that falls at or before the
one before it in local time), writes each zone as a TZif file with its POSIX TZ string for the years
past 2037 (zic's `stringzone`, including RFC 8536's rule times past 24 hours and negative daylight
saving), and packs them with every name and link into `src/zone/tzdb.bin` (about 280 KiB). One
choice differs from a literal reading of zic: a rule-driven zone line starts from its own rules' save
(standard time where none has fired yet), not the previous line's, which is what zic's own output for
Shanghai's 1949 line shows.

`bay dev tzdb` regenerates the file; a unit test regenerates it in memory and fails unless it is the
same byte for byte. `-Dtzdb=system` leaves it out of a build; `embedded` and `both` (the default) link
it, and `Database` reads it where the system has no such zone or where only it is asked for.

## Windows

Windows has no zoneinfo; its zones come from the embedded data. Its time zone names are mapped to IANA
names by CLDR's `windowsZones.xml` (vendored in `cldr/` with its release, Unicode License v3 in
`LICENSES/cldr-unicode-v3.txt`), each name's default (territory 001), generated into
`src/zone/windows.zig` by `tools/windows.zig` with the rest of `bay dev tzdb` and checked by
regeneration. `Database.local` with no `$TZ` asks Windows for its dynamic time zone
(`GetDynamicTimeZoneInformation`), maps its key name, and reads that zone; where the user turned
daylight saving adjustment off, it is the standard offset all year.

## Text

`text/iso.zig` reads ISO 8601 and RFC 9557 as Temporal does and returns plain checked fields, so it sits
with the kernels and each type builds itself from them: `Date`, `Time`, `DateTime` and `Span` publish
`parse`, `format` and `max_text_len` (the text-form contract strand reads), and `text.zig` adds what needs
more than one type: `parseTimestamp` (an instant written with its offset), `parseZoned` (the zone
annotation from a `Database`, a written offset weighed by `OffsetConflict`, matched to the minute where it
was written to the minute, `Z` as the exact instant, a date alone as the day's start), and
`writeTimestamp`. The reading: dates extended or basic with six-digit signed years (`-000000` refused),
`T`, `t` or a space, times to nine fractional digits with `.` or `,`, a leap second read as :59, offsets
`Z` or `±HH[:MM[:SS[.f]]]` to the nanosecond (an instant takes it whole; a zoned value matches whole
seconds), annotations with the time zone first and once, the first `u-ca` naming `iso8601` for a value
with a calendar (a time or an instant reads past any), later ones passed over unless one is critical,
other keys passed over or refused by option and refused when critical; a time without `T` refused where
it reads as a year and month or a month and day too. U+2212 is not a minus sign, as Temporal no longer
reads it. Durations: a sign,
`P`, `Y M W D`, `T`, `H M S`, a fraction only on the last unit, carried into the units below. Every refusal
is `Invalid` with a `Diagnostic` (where, and what was expected).

`text/strict.zig` is RFC 3339's grammar alone: `isDateTime`, `isDate`, `isTime`, `isDuration`
(Appendix A), case-insensitive literals, the offset required, a leap second only at 23:59:60 UTC, any
fraction length, no sign or fraction in a duration. Every text it accepts is read by the lenient reader to
the same value, past two limits of the lenient reading: at most nine fractional digits, and Temporal's
bounds on a span.

Writing is Temporal's: four-digit years (six and a sign outside 0000 to 9999), the fraction's trailing
zeros left off, a zoned value's offset rounded to the minute and its zone's name or fixed offset in
brackets, durations with the seconds and smaller units as one fraction and `PT0S` for zero.

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
`.boot` clocks, a duration and an integer. Zones are checked on POSIX strings of both hemispheres,
rule times past 24 hours and negative, Julian and zero-based days, daylight saving all year, and what
is refused; on TZif files of the IANA database (testdata/zoneinfo: New York, Lisbon, Lord Howe and
Apia, compiled by zic from tzdata 2026f) against zdump's account of each transition tested; on a
property that lookups with any cursor agree with a linear scan and that the next and previous
transitions bound the offset in force; and on mutated rules and mutated files, which parse or are
refused and, when parsed, answer consistently. Resolution is checked on New York's gap and fold under
every disambiguation and offset policy, Lisbon's local mean time written to the minute, a day whose
midnight is skipped, zoned arithmetic, differences, rounding and spans across changes of offset, and a
property that the candidates and the `compatible` resolution agree with a brute-force search over every
offset the zone uses. The database is checked on a temporary zoneinfo tree: names that climb out, links
inside and escaping it, a link loop, damaged and oversized files, the cache's handles, `$TZ`'s forms
and the `localtime` link, a refresh that replaces and removes zones while the old ones are held, under
shakedown's quarantine allocator (where a use after free faults), and failures, a short read and a
cancel of the reads under shakedown's FaultIo, after which the cache loads the zone as before. The
embedded database is checked byte for byte against its regeneration, every name in it loads, and its
zones agree with zic's compiled output on the offset at every transition of either (and the second
before it) to 2400 and at every hour from 1800 to 2100: the four zones of testdata/zoneinfo in the unit
tests, and every zone of a zoneinfo directory in a trial (`-Dzic-out=<dir>`, run in a release build).
Against the system's zoneinfo of the same release (2026f) all 598 zones agree; against zic 2022g's
compilation of 2026f, 595 do, the other three (America/Ojinaga in 2022, Asia/Gaza and Asia/Hebron in
2073) being where that older zic differs from 2026f's own compiled files, which almanac matches. The Windows table is checked by regeneration, its order, and every name it gives
being a zone of the embedded data; the Windows code is compiled for Windows targets. Text is checked on
Temporal's forms and refusals, zoned text through the embedded database, writing and reading back (each
type's `parse`, `format` and `max_text_len` at its widest values, and a property over random values), the
strict checks against JSON-Schema-Test-Suite's `date-time`, `date`, `time` and `duration` cases (release
23.2.0, vendored in testdata/json-schema), properties that every date-time and duration the strict checks
accept is read leniently to the same value, and every parser and check on mutated text. test262's
Temporal string cases (the `from` tests of PlainDate, PlainDateTime, PlainTime, Instant, Duration and
ZonedDateTime at test262 2e58f87) are transcribed as text by `testdata/test262/extract.py`, which runs
no JavaScript and recognises only the shapes those files repeat (arrays of strings that must throw,
tables of strings and expected fields, the same inline), into `testdata/test262/temporal.json`: 760
cases from 89 files. 754 pass; the other 6 are years outside -9999 to 9999, listed by name in
`src/test262_test.zig` as refused by design. The arithmetic tests (until, since, round, add) take
objects and options the extractor does not read; the arithmetic is checked by the cases worked from the
specification and the properties above.

## Not built yet

Lint rules and the benchmark rows.
