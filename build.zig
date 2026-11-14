const std = @import("std");

/// What a project that depends on almanac builds: the `almanac` module, which imports aegis
/// alone. The tests, checks and gate are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tzdb = b.option(Tzdb, "tzdb", "Zone data linked in: system files only, the embedded database, or both (default)") orelse .both;
    _ = almanacModule(b, b, target, optimize, tzdb);
}

/// Which zone data a program carries: `system` reads only the system's files, `embedded` and
/// `both` link almanac's copy of the IANA database (about 400 KiB).
pub const Tzdb = enum { system, embedded, both };

fn almanacModule(b: *std.Build, p: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, tzdb: Tzdb) *std.Build.Module {
    const module = b.addModule("almanac", .{ .root_source_file = p.path("src/almanac.zig"), .target = target, .optimize = optimize });
    module.addImport("aegis", p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis"));
    const options = b.addOptions();
    options.addOption(bool, "embedded", tzdb != .system);
    module.addOptions("almanac_options", options);
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
    const zic = b.createModule(.{ .root_source_file = p.path("tools/zic.zig"), .target = target, .optimize = optimize });
    const windows_tool = b.createModule(.{ .root_source_file = p.path("tools/windows.zig"), .target = target, .optimize = optimize });
    const test_options = b.addOptions();
    test_options.addOption(bool, "embedded", true);
    test_options.addOption(?[]const u8, "zic_out", b.option([]const u8, "zic-out", "A directory of zic's output for the tests to compare every zone against"));
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
                .{ .name = "zoneinfo", .module = zoneinfo(b, p) },
                .{ .name = "zic", .module = zic },
                .{ .name = "windows_tool", .module = windows_tool },
                .{ .name = "tzdata", .module = tzdata(b, p) },
                .{ .name = "json_schema", .module = jsonSchema(b, p) },
                .{ .name = "test262", .module = test262Cases(b, p) },
                .{ .name = "readme", .module = readme(b, p) },
            },
        }),
    });
    tests.root_module.addOptions("almanac_options", test_options);

    // The embedded database, regenerated from tzdata/ by almanac's own zic compiler.
    const generator = b.addExecutable(.{
        .name = "generate",
        .root_module = b.createModule(.{
            .root_source_file = p.path("tools/generate.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "zic", .module = zic }, .{ .name = "windows", .module = windows_tool } },
        }),
    });
    const generate = b.addRunArtifact(generator);
    generate.addDirectoryArg2(p.path("tzdata"), .{});
    generate.addDirectoryArg2(p.path("cldr"), .{});
    generate.addDirectoryArg2(p.path("src/zone"), .{});
    generate.has_side_effects = true;
    b.step("tzdb", "Regenerate src/zone/tzdb.bin from tzdata/ and src/zone/windows.zig from cldr/").dependOn(&generate.step);

    // test262's Temporal cases, transcribed from a checkout into testdata/test262/temporal.json.
    const transcriber = b.addExecutable(.{
        .name = "test262",
        .root_module = b.createModule(.{ .root_source_file = p.path("tools/test262.zig"), .target = target, .optimize = optimize }),
    });
    const transcribe = b.addRunArtifact(transcriber);
    transcribe.addArg(b.option([]const u8, "test262", "A test262 checkout to transcribe the Temporal cases from") orelse "test262");
    transcribe.addArg(b.option([]const u8, "test262-commit", "The checkout's commit, recorded in the cases") orelse "2e58f87");
    transcribe.addDirectoryArg2(p.path("testdata/test262"), .{});
    transcribe.has_side_effects = true;
    b.step("test262", "Transcribe test262's Temporal cases into testdata/test262/temporal.json").dependOn(&transcribe.step);

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
    // The README's example, run with the tests.
    const example = b.addExecutable(.{
        .name = "usage",
        .root_module = b.createModule(.{ .root_source_file = p.path("examples/usage.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "almanac", .module = package.module("almanac") }} }),
    });
    const examples = b.step("examples", "Build and run the usage example");
    examples.dependOn(&b.addRunArtifact(example).step);
    test_step.dependOn(examples);
    check.dependOn(&example.step);
    tools.preflight.addCi(b, p, .{
        .tests = test_step,
        .portable_tests = true,
        .hardened = .{ .fuzz_step = "test", .tsan_step = "test" },
        // The benchmark rows (design §8): CI compiles them; timings are the running machine's.
        .bench = .{
            .programs = &.{.{ .name = "bench", .source = "bench/main.zig" }},
            .imports = tools.preflight.Bench.importsFrom(benchImports),
            .target = target,
            .optimize = optimize,
        },
    });
}

/// almanac again, in the mode a benchmark builds in: an imported module keeps its own mode.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const p = b.dependency("almanac", .{ .target = target, .optimize = optimize }).builder;
    const module = b.createModule(.{ .root_source_file = p.path("src/almanac.zig"), .target = target, .optimize = optimize });
    module.addImport("aegis", p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis"));
    const options = b.addOptions();
    options.addOption(bool, "embedded", true);
    module.addOptions("almanac_options", options);
    return b.allocator.dupe(std.Build.Module.Import, &.{.{ .name = "almanac", .module = module }}) catch @panic("OOM");
}

/// The zones the tests read (testdata/zoneinfo: compiled by zic from tzdata 2026f, public domain), as a
/// module of their bytes.
fn zoneinfo(b: *std.Build, p: *std.Build) *std.Build.Module {
    const files = b.addWriteFiles();
    var source: std.ArrayList(u8) = .empty;
    for (zoneinfo_files) |name| {
        _ = files.addCopyFile(p.path(b.fmt("testdata/zoneinfo/{s}", .{name})), name);
        source.print(b.allocator, "pub const {s} = @embedFile(\"{s}\");\n", .{ name, name }) catch @panic("OOM");
    }
    return b.createModule(.{ .root_source_file = files.add("zoneinfo.zig", source.items) });
}

/// The vendored IANA release's source files, as a module of their bytes, for the test that
/// regenerating the embedded database reproduces it.
fn tzdata(b: *std.Build, p: *std.Build) *std.Build.Module {
    const files = b.addWriteFiles();
    var source: std.ArrayList(u8) = .empty;
    for (tzdata_files) |name| {
        _ = files.addCopyFile(p.path(b.fmt("tzdata/{s}", .{name})), name);
        source.print(b.allocator, "pub const @\"{s}\" = @embedFile(\"{s}\");\n", .{ name, name }) catch @panic("OOM");
    }
    _ = files.addCopyFile(p.path("cldr/windowsZones.xml"), "windowsZones.xml");
    _ = files.addCopyFile(p.path("cldr/version"), "cldr_version");
    source.appendSlice(b.allocator, "pub const windows_zones = @embedFile(\"windowsZones.xml\");\npub const cldr_version = @embedFile(\"cldr_version\");\n") catch @panic("OOM");
    return b.createModule(.{ .root_source_file = files.add("tzdata.zig", source.items) });
}

const tzdata_files = [_][]const u8{ "africa", "antarctica", "asia", "australasia", "europe", "northamerica", "southamerica", "etcetera", "backward", "factory", "version" };

/// JSON-Schema-Test-Suite's format cases (testdata/json-schema, release 23.2.0, MIT), as a module.
fn jsonSchema(b: *std.Build, p: *std.Build) *std.Build.Module {
    const files = b.addWriteFiles();
    var source: std.ArrayList(u8) = .empty;
    for ([_][]const u8{ "date-time", "date", "time", "duration" }) |name| {
        _ = files.addCopyFile(p.path(b.fmt("testdata/json-schema/{s}.json", .{name})), b.fmt("{s}.json", .{name}));
        source.print(b.allocator, "pub const @\"{s}\" = @embedFile(\"{s}.json\");\n", .{ name, name }) catch @panic("OOM");
    }
    _ = files.addCopyFile(p.path("testdata/json-schema/version"), "version");
    source.appendSlice(b.allocator, "pub const version = @embedFile(\"version\");\n") catch @panic("OOM");
    return b.createModule(.{ .root_source_file = files.add("json_schema.zig", source.items) });
}

/// The README and the example it shows, for the test that keeps them the same.
fn readme(b: *std.Build, p: *std.Build) *std.Build.Module {
    const files = b.addWriteFiles();
    _ = files.addCopyFile(p.path("README.md"), "README.md");
    _ = files.addCopyFile(p.path("examples/usage.zig"), "usage.zig");
    return b.createModule(.{ .root_source_file = files.add("readme.zig", "pub const text = @embedFile(\"README.md\");\npub const usage = @embedFile(\"usage.zig\");\n") });
}

/// test262's Temporal cases (testdata/test262/temporal.json), as a module.
fn test262Cases(b: *std.Build, p: *std.Build) *std.Build.Module {
    const files = b.addWriteFiles();
    _ = files.addCopyFile(p.path("testdata/test262/temporal.json"), "temporal.json");
    return b.createModule(.{ .root_source_file = files.add("test262.zig", "pub const temporal = @embedFile(\"temporal.json\");\n") });
}

const zoneinfo_files = [_][]const u8{ "America_New_York", "Europe_Lisbon", "Australia_Lord_Howe", "Pacific_Apia" };

/// What each case of src/testing/instant_rejected.zig is refused with.
const instant_rejections = [_][]const u8{
    "is of the awake clock, which names no civil time",
    "is of the boot clock, which names no civil time",
    "is an aegis duration, no instant",
    "u64 is no aegis scalar",
};
