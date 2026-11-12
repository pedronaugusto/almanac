const std = @import("std");

/// What a project that depends on almanac builds: the `almanac` module, which imports aegis
/// alone. The tests, checks and gate are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = almanacModule(b, b, target, optimize);
}

fn almanacModule(b: *std.Build, p: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const module = b.addModule("almanac", .{ .root_source_file = p.path("src/almanac.zig"), .target = target, .optimize = optimize });
    module.addImport("aegis", p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis"));
    return module;
}

/// almanac's development: its tests and checks under preflight's gate. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const package = b.dependency("almanac", .{ .target = target, .optimize = optimize });
    const p = package.builder;
    const filters = if (test_filter) |filter| &.{filter} else &.{};
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize });
    const tests = b.addTest(.{
        .name = "almanac-tests",
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aegis", .module = p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis") },
                .{ .name = "shakedown", .module = shakedown.module("shakedown") },
            },
        }),
    });
    const check = b.step("check", "Compile the tests without running them");
    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    check.dependOn(&tests.step);

    // An instant of another clock, or no instant, does not compile where almanac takes one.
    if (test_filter == null or std.mem.find(u8, "instant", test_filter.?) != null) {
        const aegis_module = p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
        const almanac_module = package.module("almanac");
        for (instant_rejections, 0..) |message, case| {
            const rejection_options = b.addOptions();
            rejection_options.addOption(usize, "case", case);
            const rejected = b.addObject(.{
                .name = b.fmt("instant-rejected-{d}", .{case}),
                .root_module = b.createModule(.{
                    .root_source_file = p.path("src/testing/instant_rejected.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "aegis", .module = aegis_module },
                        .{ .name = "almanac", .module = almanac_module },
                    },
                }),
            });
            rejected.root_module.addOptions("rejection_options", rejection_options);
            rejected.expect_errors = .{ .contains = message };
            test_step.dependOn(&rejected.step);
            check.dependOn(&rejected.step);
        }
    }
    b.getInstallStep().dependOn(&tests.step);
    // The release tier runs every property under Zig's fuzzer, and the suite with safety on.
    tools.preflight.addCi(b, p, .{ .tests = test_step, .portable_tests = true, .hardened = .{ .fuzz_step = "test", .tsan_step = "test" } });
}

/// What each case of src/testing/instant_rejected.zig is refused with.
const instant_rejections = [_][]const u8{
    "is of the awake clock, which names no civil time",
    "is of the boot clock, which names no civil time",
    "is an aegis duration, no instant",
    "u64 is no aegis scalar",
};
