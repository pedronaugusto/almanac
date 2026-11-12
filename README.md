# almanac

almanac is civil time for Zig: instants, calendar dates and times, zoned times from the IANA time zone database (the
system's files or an embedded copy), RFC 3339 and RFC 9557 text, ISO 8601 durations, and calendar arithmetic with
Temporal's semantics: an explicit policy at every ambiguous point, and no hidden global state.

## Status

Unreleased and being built: the calendar (dates, times, the proleptic Gregorian kernels), civil arithmetic (spans,
adding, differences, rounding), instants, time zones (TZif files, POSIX TZ strings), the zone database over the system's
files and an embedded copy of the IANA database, zoned times and text are in. [The design](docs/design.md) says what is built.

## Conformance

almanac follows Temporal (TC39). test262's Temporal tests for the types almanac shares, read as text,
give 10660 cases from 1259 of the 1402 files that apply to a Zig API (the rest test JavaScript's object
protocol): 10317 pass, and the 341 others are refused by design and listed by file, almost all values
outside almanac's years -9999 to 9999. Every zone of the embedded IANA database agrees with zic's
compilation of the same release.

## License

MIT. The IANA time zone database, vendored in tzdata/ (release 2026f) and compiled into src/zone/tzdb.bin, and the
test data in testdata/zoneinfo drawn from it, are in the public domain. CLDR's windowsZones.xml, vendored in cldr/
(release 49) and compiled into src/zone/windows.zig, is under the Unicode License v3 (LICENSES/cldr-unicode-v3.txt). The format cases in testdata/json-schema are from
JSON-Schema-Test-Suite (release 23.2.0), under the MIT licence (LICENSES/JSON-Schema-Test-Suite-MIT.txt). The cases
in testdata/test262 are transcribed from test262 (2e58f87), under its BSD licence (LICENSES/test262-BSD.txt).
