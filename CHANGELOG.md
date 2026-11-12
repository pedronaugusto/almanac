# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

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
  of every type, 9622 cases; 9279 pass, 341 are refused by design (listed by file), 2 use calendar eras.
- `Time.add`, `subtract`, `until`, `since` and `round`; `DateTime.round`; `Span.total`.

### Changed

- Text reading follows test262: U+2212 is no minus sign; offsets are read to the nanosecond; only the first
  calendar annotation names the calendar, and a time or an instant reads past any; annotation values may be
  of any length; a time without `T` is read unless it is also a date.
- Arithmetic follows test262: NudgeToCalendarUnit's window moves on where a constrained month's end leaves the
  destination past it; two nameless zones of the same rules are the same zone.
