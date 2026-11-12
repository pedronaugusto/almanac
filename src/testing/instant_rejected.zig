//! Compile-error fixtures: almanac's instant operations take an aegis instant of the real clock and
//! nothing else, whichever operation is reached.
const aegis = @import("aegis");
const almanac = @import("almanac");
const options = @import("rejection_options");

const T = switch (options.case) {
    0 => aegis.units.Instant(.awake, .nanosecond, i96),
    1 => aegis.units.Instant(.boot, .millisecond, u64),
    2 => aegis.units.Duration(.nanosecond, i96),
    3 => u64,
    else => unreachable,
};

export fn rejected() bool {
    const value: T = switch (options.case) {
        3 => 0,
        else => .fromRaw(0),
    };
    return almanac.instant.inRange(value);
}
