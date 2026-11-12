//! Writes almanac's embedded zone data: `generate <tzdata directory> <cldr directory> <output
//! directory>`, which writes `tzdb.bin` and `windows.zig` there. The tzdata directory holds an IANA
//! release's source files, the cldr directory CLDR's windowsZones.xml, each with a `version` file.
const std = @import("std");
const zic = @import("zic");
const windows = @import("windows");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    if (args.len != 4) {
        std.debug.print("usage: generate <tzdata directory> <cldr directory> <output directory>\n", .{});
        std.process.exit(2);
    }
    const blob = try build(gpa, io, std.Io.Dir.cwd(), args[1]);
    defer gpa.free(blob);
    var cldr = try std.Io.Dir.cwd().openDir(io, args[2], .{});
    defer cldr.close(io);
    const xml = try cldr.readFileAlloc(io, "windowsZones.xml", gpa, .limited(1 << 20));
    defer gpa.free(xml);
    const version = try cldr.readFileAlloc(io, "version", gpa, .limited(64));
    defer gpa.free(version);
    const table = try windows.generate(gpa, xml, std.mem.trim(u8, version, " \n"));
    defer gpa.free(table);
    var out = try std.Io.Dir.cwd().openDir(io, args[3], .{});
    defer out.close(io);
    try out.writeFile(io, .{ .sub_path = "tzdb.bin", .data = blob });
    try out.writeFile(io, .{ .sub_path = "windows.zig", .data = table });
}

/// The blob for the release in `path` beneath `dir`.
pub fn build(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) ![]u8 {
    var tzdata = try dir.openDir(io, path, .{});
    defer tzdata.close(io);
    var source: zic.Source = .init(gpa);
    defer source.deinit();
    var diagnostic: zic.Diagnostic = .{};
    for (zic.files) |name| {
        const text = try tzdata.readFileAlloc(io, name, source.arena.allocator(), .limited(4 << 20));
        source.parse(name, text, &diagnostic) catch |err| {
            std.debug.print("{s}:{d}: {s}\n", .{ diagnostic.file, diagnostic.line, @errorName(err) });
            return err;
        };
    }
    const version = std.mem.trim(u8, try tzdata.readFileAlloc(io, "version", source.arena.allocator(), .limited(64)), " \n");
    return zic.pack(gpa, &source, version);
}
