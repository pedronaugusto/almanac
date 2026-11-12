# almanac

almanac is civil time for Zig: instants, calendar dates and times, zoned times from the IANA time zone database (the
system's files or an embedded copy), RFC 3339 and RFC 9557 text, ISO 8601 durations, and calendar arithmetic with
Temporal's semantics: an explicit policy at every ambiguous point, and no hidden global state.

## Status

Unreleased and being built: the calendar (dates, times, the proleptic Gregorian kernels), civil arithmetic (spans,
adding, differences, rounding), instants, time zones (TZif files, POSIX TZ strings), the zone database over the system's
files and an embedded copy of the IANA database, and zoned times are in; text follows. [The design](docs/design.md) says what is built.

## License

MIT. The IANA time zone database, vendored in tzdata/ (release 2026f) and compiled into src/zone/tzdb.bin, and the
test data in testdata/zoneinfo drawn from it, are in the public domain.
