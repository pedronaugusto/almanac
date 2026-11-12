//! Source layers, lowest first. Every production source has one place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "vocabulary", .patterns = &.{"src/units.zig"} },
    .{ .name = "kernels", .patterns = &.{ "src/calendar.zig", "src/round.zig" } },
    .{ .name = "rules", .patterns = &.{ "src/zone/posix.zig", "src/zone/tzif.zig" } },
    .{ .name = "arithmetic", .patterns = &.{"src/arithmetic.zig"} },
    .{ .name = "span", .patterns = &.{"src/Span.zig"} },
    .{ .name = "civil", .patterns = &.{ "src/Date.zig", "src/Time.zig", "src/DateTime.zig" } },
    .{ .name = "instant", .patterns = &.{"src/instant.zig"} },
    .{ .name = "zone", .patterns = &.{"src/TimeZone.zig"} },
    .{ .name = "resolve", .patterns = &.{"src/resolve.zig"} },
    .{ .name = "zoned", .patterns = &.{"src/Zoned.zig"} },
    .{ .name = "root", .patterns = &.{"src/almanac.zig"} },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{
    .{ .name = "almanac", .path = "src/almanac.zig" },
};

const package_references = [_]gantry.rules.ReferenceRule{
    .{
        .name = "named dependencies",
        .unresolved_only = true,
        .except_targets = &.{ "std", "aegis", "shakedown", "builtin", "rejection_options", "zoneinfo" },
    },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

/// A family package is reached through its module name, never by a path into it.
pub const references: []const gantry.rules.ReferenceRule = &package_references;

/// Every production source, so a file added without a layer is refused.
pub const required = [_][]const u8{
    "src/units.zig",
    "src/calendar.zig",
    "src/round.zig",
    "src/arithmetic.zig",
    "src/Span.zig",
    "src/instant.zig",
    "src/zone/posix.zig",
    "src/zone/tzif.zig",
    "src/TimeZone.zig",
    "src/resolve.zig",
    "src/Zoned.zig",
    "src/Date.zig",
    "src/Time.zig",
    "src/DateTime.zig",
    "src/almanac.zig",
};
