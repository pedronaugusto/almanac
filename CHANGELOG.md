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
