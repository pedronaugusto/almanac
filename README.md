# almanac

almanac is civil time for Zig: instants, calendar dates and times, zoned times from the IANA time zone database (the
system's files or an embedded copy), RFC 3339 and RFC 9557 text, ISO 8601 durations, and calendar arithmetic with
Temporal's semantics: an explicit policy at every ambiguous point, and no hidden global state.

## Status

Unreleased and being built: the calendar (dates, times, the proleptic Gregorian kernels), civil arithmetic (spans,
adding, differences, rounding) and instants are in; zones, text and the embedded database follow. [The design](docs/design.md) says what is built.

## License

MIT.
