# almanac

almanac is civil time for Zig: instants, calendar dates and times, zoned times from the IANA time zone database (the
system's files or an embedded copy), RFC 3339 and RFC 9557 text, ISO 8601 durations, and calendar arithmetic with
Temporal's semantics: an explicit policy at every ambiguous point, and no hidden global state.

## Status

Unreleased. Everything the design names is built: the calendar, civil arithmetic and spans, instants, time zones
(TZif files, POSIX TZ strings), the zone database over the system's files and an embedded copy of the IANA database,
Windows' zone mapping, zoned times, and text (RFC 3339, RFC 9557, ISO 8601 durations, the strict RFC 3339 checks). [The design](docs/design.md) says what is built.

## Usage

```zig
// Zones come from a database: here the embedded IANA data (the system's files go through
// `.zoneinfo`, a directory the caller opens).
var db = almanac.Database.init(init.gpa, .{ .source = .embedded });
defer db.deinit();
var lisbon = try db.zone(io, .init("Europe/Lisbon"));
defer lisbon.release();

// An instant read from RFC 3339 text, seen in Lisbon.
const t = try almanac.text.parseTimestamp(.init("2026-03-29T00:30:00Z"), .{});
const before = try almanac.Zoned.init(t, lisbon.get());

// A day later by the calendar is 23 hours later: the clocks went forward.
const after = try before.add(try almanac.Span.fromSigned(.{ .days = 1 }), .constrain);
const hours = try before.until(after, .{ .largest = .hour });

var buffer: [128]u8 = undefined;
var w: std.Io.Writer = .fixed(&buffer);
try w.print("{f} -> {f}: {f}", .{ before, after, hours });
std.debug.assert(std.mem.eql(u8, w.buffered(), "2026-03-29T00:30:00+00:00[Europe/Lisbon] -> 2026-03-30T00:30:00+01:00[Europe/Lisbon]: PT23H"));

// Civil arithmetic: January 31 plus a month is February's last day, or refused.
const jan31 = try almanac.Date.init(2024, 1, 31);
const month = try almanac.Span.fromSigned(.{ .months = 1 });
std.debug.assert((try jan31.add(month, .constrain)).eql(try almanac.Date.init(2024, 2, 29)));
std.debug.assert(jan31.add(month, .reject) == error.OutOfRange);
```

The block is `examples/usage.zig`, built and run with the tests.

## Conformance

almanac follows Temporal (TC39). test262's Temporal tests for the types almanac shares, read as text,
give 10660 cases from 1259 of the 1402 files that apply to a Zig API (the rest test JavaScript's object
protocol): 10317 pass, and the 341 others are refused by design and listed by file, almost all values
outside almanac's years -9999 to 9999. One reading is unconfirmed: rounding a span measured from a zoned
time inside a repeated hour (a fold) starts from that time's own instant, and test262 has no case of it
yet. Every zone of the embedded IANA database agrees with zic's compilation of the same release.

## License

MIT. The IANA time zone database, vendored in tzdata/ (release 2026f) and compiled into src/zone/tzdb.bin, and the
test data in testdata/zoneinfo drawn from it, are in the public domain. CLDR's windowsZones.xml, vendored in cldr/
(release 49) and compiled into src/zone/windows.zig, is under the Unicode License v3 (LICENSES/cldr-unicode-v3.txt). The format cases in testdata/json-schema are from
JSON-Schema-Test-Suite (release 23.2.0), under the MIT licence (LICENSES/JSON-Schema-Test-Suite-MIT.txt). The cases
in testdata/test262 are transcribed from test262 (2e58f87), under its BSD licence (LICENSES/test262-BSD.txt).
