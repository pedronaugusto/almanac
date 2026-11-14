//! Temporal's rounding: a mode resolved against a sign to an unsigned mode, and an exact choice
//! between the two candidates a value lies between, on integers and rationals alike.
const std = @import("std");
const units = @import("units.zig");
const aegis = @import("aegis");
const RoundingMode = units.RoundingMode;

/// GetUnsignedRoundingMode's results.
pub const Unsigned = enum { zero, infinity, half_zero, half_infinity, half_even };

/// The unsigned mode `mode` is for a value of sign `negative` (GetUnsignedRoundingMode).
pub fn unsignedMode(mode: RoundingMode, negative: bool) Unsigned {
    return switch (mode) {
        .ceil => if (negative) .zero else .infinity,
        .floor => if (negative) .infinity else .zero,
        .expand => .infinity,
        .trunc => .zero,
        .half_ceil => if (negative) .half_zero else .half_infinity,
        .half_floor => if (negative) .half_infinity else .half_zero,
        .half_expand => .half_infinity,
        .half_trunc => .half_zero,
        .half_even => .half_even,
    };
}

/// Temporal's NegateRoundingMode: what `since` rounds with.
pub fn negate(mode: RoundingMode) RoundingMode {
    return switch (mode) {
        .ceil => .floor,
        .floor => .ceil,
        .half_ceil => .half_floor,
        .half_floor => .half_ceil,
        else => mode,
    };
}

/// ApplyUnsignedRoundingMode for a value `r1 + num/den` of the way to `r2` (0 ≤ num ≤ den, den > 0):
/// whether the result is `r2` rather than `r1`. `r1_even` says whether `r1` is the even candidate,
/// for half-even.
pub fn toSecond(num: i128, den: i128, mode: Unsigned, r1_even: bool) bool {
    aegis.assert.invariant(den > 0 and num >= 0 and num <= den, "den > 0 and num >= 0 and num <= den");
    if (num == 0) return false;
    if (num == den) return true;
    switch (mode) {
        .zero => return false,
        .infinity => return true,
        else => {},
    }
    const twice = 2 * num;
    if (twice < den) return false;
    if (twice > den) return true;
    return switch (mode) {
        .half_zero => false,
        .half_infinity => true,
        .half_even => !r1_even,
        .zero, .infinity => unreachable,
    };
}

/// RoundNumberToIncrement: `x` rounded to a multiple of `increment` (> 0) by `mode`.
pub fn toIncrement(x: i128, increment: i128, mode: RoundingMode) i128 {
    aegis.assert.invariant(increment > 0, "increment > 0");
    const negative = x < 0;
    const ax: i128 = if (negative) -x else x;
    const q = @divFloor(ax, increment);
    const r = ax - q * increment;
    const up = toSecond(r, increment, unsignedMode(mode, negative), @mod(q, 2) == 0);
    const rounded = (if (up) q + 1 else q) * increment;
    return if (negative) -rounded else rounded;
}

/// RoundNumberToIncrementAsIfPositive: rounding on a timeline, where a mode's direction is the
/// timeline's whatever the sign (an instant before 1970 truncates toward the past, as floor).
pub fn toIncrementAsIfPositive(x: i128, increment: i128, mode: RoundingMode) i128 {
    aegis.assert.invariant(increment > 0, "increment > 0");
    const q = @divFloor(x, increment);
    const r = x - q * increment;
    const up = toSecond(r, increment, unsignedMode(mode, false), @mod(q, 2) == 0);
    return (if (up) q + 1 else q) * increment;
}

test "every mode at a tie, below and above it, both signs" {
    const t = std.testing;
    // 15 to tens: ceil 20, floor 10, expand 20, trunc 10, half_ceil 20, half_floor 10,
    // half_expand 20, half_trunc 10, half_even 20; and -15.
    const ups = [_]i128{ 20, 10, 20, 10, 20, 10, 20, 10, 20 };
    const downs = [_]i128{ -10, -20, -20, -10, -10, -20, -20, -10, -20 };
    for (std.enums.values(RoundingMode), ups, downs) |mode, up, down| {
        try t.expectEqual(up, toIncrement(15, 10, mode));
        try t.expectEqual(down, toIncrement(-15, 10, mode));
    }
    try t.expectEqual(20, toIncrement(25, 10, .half_even));
    try t.expectEqual(40, toIncrement(35, 10, .half_even));
    try t.expectEqual(10, toIncrement(14, 10, .half_expand));
    try t.expectEqual(20, toIncrement(16, 10, .half_trunc));
    try t.expectEqual(30, toIncrement(30, 10, .expand));
}

test "on a timeline the direction ignores the sign" {
    const t = std.testing;
    try t.expectEqual(-20, toIncrementAsIfPositive(-15, 10, .trunc));
    try t.expectEqual(-20, toIncrementAsIfPositive(-15, 10, .half_trunc));
    try t.expectEqual(-20, toIncrementAsIfPositive(-15, 10, .half_even));
    try t.expectEqual(-10, toIncrementAsIfPositive(-15, 10, .half_expand));
    try t.expectEqual(-10, toIncrementAsIfPositive(-11, 10, .ceil));
    try t.expectEqual(10, toIncrementAsIfPositive(15, 10, .floor));
}
