# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `Date`, `Time`, `DateTime` and `Span` declare `text_form`, `.{ .max_len = max_text_len }` (the date's with `.schema_format = "date"`, RFC 3339's full-date, for years 0000 to 9999): the declaration a format reads and writes a value as text by (strand's text form), through their existing `parse` and `format`. A plain literal: almanac imports nothing for it. The others name no JSON Schema format, as Schema's `time` and `date-time` carry an offset and its `duration` takes no sign or fraction. Tests: the declarations and signatures, and each one's documented examples.

### Changed

- Pins aegis f52eabe, still 0.2.4 (its addition: `id.raws`), the one aegis the family builds on; development on preflight's ci-standard f991816 and shakedown 327bc61. Nothing this package calls changed.
- Development on preflight's ci-standard 9c18016 and shakedown b99b768.
- The zone sources are chosen where a program makes its `Database`, and the build has no `-Dtzdb` option (nor
  `Tzdb`): `Database.Options.source` is gone, and `Database.Options.embedded` takes almanac's copy of the IANA
  database, `&almanac.tzdb`. The sources are what the options give: `zoneinfo` alone reads the system's files,
  `embedded` alone the embedded data, and both read the system's files first and the embedded data where the
  system has no such zone. The data (about 280 KiB) is compiled only into a program that names `almanac.tzdb`.
  Before: `.{ .source = .embedded }`, `.{ .zoneinfo = .of(dir), .source = .system }`, `.{ .zoneinfo = .of(dir) }`.
  After: `.{ .embedded = &almanac.tzdb }`, `.{ .zoneinfo = .of(dir) }`, `.{ .zoneinfo = .of(dir), .embedded =
  &almanac.tzdb }`. `Database.embeddedBytes(name)` and `Database.embeddedVersion()` are `almanac.tzdb.find(name)`
  and `almanac.tzdb.version()` (with `count()`, on `almanac.Embedded`).
- Time is carried as aegis units through the arithmetic: a length as `Duration(.nanosecond, i128)`, a place on the
  timeline as `Instant(.real, .nanosecond, i128)`, an offset converted from its ranged seconds, so seconds and
  nanoseconds cannot be mixed. `resolve.wallClock`, `resolve.checked`, `resolve.resolveWallClock`, `resolve.resolve`,
  `resolve.resolveWithOffset` and `resolve.startOfDay` take and return `resolve.Epoch`;
  `TimeZone.candidatesAt`, `TimeZone.offsetAtNanoseconds` (now returning an `Offset`) and `TimeZone.nextChange` take
  one, and `TimeZone.Candidates.instants` holds them.
- `Database.Options.zoneinfo` and `Database.Options.localtime` are `aegis.own.Unowned(Io.Dir)`: directories the
  caller opens and closes, given as `.of(dir)`.
- `text`'s written offset holds its length as a nanosecond `Duration`.

### Fixed

- On Windows, a link in the zoneinfo directory whose target climbs out of it is refused, as on POSIX: Windows gives a link's target with `\` for its separator (and an absolute one with a drive), which the check read as one name and followed.

### Added

- `Time.sinceMidnight`, `Time.fromSinceMidnight` and `Time.wrapped`; `Offset.nanoseconds` and `Offset.eql`;
  `instant.inside` and `instant.checked`.

- The calendar: the proleptic Gregorian calendar's date to day count conversions by Neri and Schneider's Euclidean
  affine functions, ISO weekdays and week dates, days of the year, leap years and month lengths, over the years -9999
  to 9999; `Date`, `Time` and `DateTime`, each field a ranged integer and a date's day checked against its month;
  `Offset`, the units, the rounding modes and the policies (`Overflow`, `Disambiguation`, `OffsetConflict`).
- Civil arithmetic with Temporal's semantics: `Span` (Temporal's `Duration`: one sign, years, months and weeks below
  2^32, days and time together below 2^53 seconds), its `add`, `subtract`, `compare` and `round` (every rounding
  mode, increments, balancing, calendar units measured from a date); `Date` and `DateTime` `add` and `subtract`
  (month ends constrained or refused) and `until` and `since` with a largest and smallest unit, an increment and a
  rounding mode.
- Instants: `Timestamp` (aegis's `Instant(.real, .nanosecond, i96)`) and operations on any aegis instant of the
  real clock at its own unit and representation: `now`, `inRange`, `timestamp`, `convert`, civil time at an offset
  and back (`toDateTime`, `fromDateTime`), `round`, `until`, `since`, `add` and `subtract` with Temporal's
  `Instant` semantics; an instant of another clock is a compile error.
- Time zones: `TimeZone`, one compiled form for TZif files (RFC 8536, versions 1 to 4, read as untrusted bytes),
  POSIX TZ strings (with RFC 8536's extensions), fixed offsets and UTC; `offsetAt`, `infoAt` (offset, daylight
  saving, abbreviation), a caller's `Cursor`, and `nextTransition` and `previousTransition`.
- Resolution and zoned values: `TimeZone.candidates`, `resolve` (every `Disambiguation`, a written offset under
  every `OffsetConflict`, the start of a day), and `Zoned` (Temporal's `ZonedDateTime`: `add`, `subtract`, `until`,
  `since`, `round`, `startOfDay`, `hoursInDay`); a zoned value as a span's `relativeTo`.
- The zone database: `Database` with counted `Zone` handles (`aegis.Shared`), a cache under `aegis.RwGuarded`,
  zones read beneath the caller's zoneinfo directory (links followed only while they stay beneath it), the local
  zone from the caller's `$TZ` or the `localtime` link, and `refresh`, which frees nothing in use.
- The embedded database: the IANA time zone database (release 2026f, vendored in `tzdata/`) compiled by almanac's
  own zic compiler (`tools/zic.zig`) into `src/zone/tzdb.bin`, linked by `-Dtzdb=embedded` or `both` (the
  default) and read by `Database` where the system has no such zone; regeneration is checked byte for byte.
- Windows: its time zone names mapped to IANA names by CLDR's windowsZones (release 49, vendored), and
  `Database.local` reading Windows' dynamic time zone where no `$TZ` is given.
- Text: RFC 3339 and RFC 9557 read as Temporal reads them (`text.parseTimestamp`, `parseDate`, `parseTime`,
  `parseDateTime`, `parseSpan`, `parseZoned`), each type's `parse`, `format` and `max_text_len`,
  `text.writeTimestamp`, and `text.strict`'s exact RFC 3339 checks (`isDateTime`, `isDate`, `isTime`,
  `isDuration`).
- test262's Temporal cases, transcribed as text by `tools/test262.zig`: the `from` strings and the arithmetic
  of every type, 10660 cases from 1259 of the 1402 applicable files; 10317 pass, 341 are refused by design
  (listed by file), 2 use calendar eras.
- `Time.add`, `subtract`, `until`, `since` and `round`; `DateTime.round`; `Span.total`.

- `lint_rules` for glint; the benchmark rows (`bench/main.zig`, compiled in CI); a usage example run with the
  tests and shown in the README.

### Changed

- Text reading follows test262: U+2212 is no minus sign; offsets are read to the nanosecond; only the first
  calendar annotation names the calendar, and a time or an instant reads past any; annotation values may be
  of any length; a time without `T` is read unless it is also a date.
- Arithmetic follows test262: NudgeToCalendarUnit's window moves on where a constrained month's end leaves the
  destination past it; two nameless zones of the same rules are the same zone.
