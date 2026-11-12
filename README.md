# almanac

almanac is civil time for Zig: instants, calendar dates and times, zoned times from the IANA time zone database (the
system's files or an embedded copy), RFC 3339 and RFC 9557 text, ISO 8601 durations, and calendar arithmetic with
Temporal's semantics: an explicit policy at every ambiguous point, and no hidden global state.

## Status

Unreleased and being built: the calendar (dates, times, the proleptic Gregorian kernels), civil arithmetic (spans,
adding, differences, rounding), instants, time zones (TZif files, POSIX TZ strings) and zoned times are in; the zone
database, text and the embedded database follow. [The design](docs/design.md) says what is built.

## License

MIT. The test data in testdata/zoneinfo is from the IANA time zone database, which is in the public domain.
