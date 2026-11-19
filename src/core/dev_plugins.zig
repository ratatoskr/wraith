//! Plugins you're building, listed in `settings\dev_plugins.zon`.

const std = @import("std");

const Locations = @import("Locations.zig");
const manifest = @import("manifest.zig");

pub const file_name = "dev_plugins.zon";

pub fn pathAlloc(allocator: std.mem.Allocator, locations: Locations) ![]u8 {
    return std.fs.path.join(allocator, &.{ locations.root, "settings", file_name });
}

pub fn load(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]const []const u8 {
    const source = std.Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(1 << 20), .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice([]const []const u8, .{
        .gpa = arena,
        .arena = arena,
        .source = source,
        .diagnostics = &diagnostics,
    }) catch {
        @import("log.zig").scoped(.wraith_core).err("{f}", .{diagnostics.fmt(path)});
        return error.InvalidDevPlugins;
    };
}

pub fn save(gpa: std.mem.Allocator, io: std.Io, path: []const u8, folders: []const []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.zon.stringify.serialize(folders, .{}, &out.writer);
    try out.writer.writeByte('\n');
    if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
}

pub fn add(arena: std.mem.Allocator, io: std.Io, path: []const u8, folder: []const u8) !bool {
    const folders = try load(arena, io, path);
    if (indexOf(folders, folder) != null) return false;
    try save(arena, io, path, try std.mem.concat(arena, []const u8, &.{ folders, &.{folder} }));
    return true;
}

pub fn remove(arena: std.mem.Allocator, io: std.Io, path: []const u8, folder: []const u8) !bool {
    const folders = try load(arena, io, path);
    const i = indexOf(folders, folder) orelse return false;
    try save(arena, io, path, try std.mem.concat(arena, []const u8, &.{ folders[0..i], folders[i + 1 ..] }));
    return true;
}

/// Windows paths, so case and a trailing separator don't matter.
fn indexOf(folders: []const []const u8, folder: []const u8) ?usize {
    for (folders, 0..) |f, i| if (std.ascii.eqlIgnoreCase(trim(f), trim(folder))) return i;
    return null;
}

fn trim(p: []const u8) []const u8 {
    return std.mem.trimEnd(u8, p, "\\/");
}

/// The id in the folder's `wraith.json`.
pub fn nameOf(allocator: std.mem.Allocator, io: std.Io, folder: []const u8) ![]u8 {
    var dir = try std.Io.Dir.openDirAbsolute(io, folder, .{});
    dir.close(io);
    const path = try std.fs.path.join(allocator, &.{ folder, manifest.file_name });
    defer allocator.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 << 10)) catch |err| switch (err) {
        error.FileNotFound => return error.NoManifest,
        else => return err,
    };
    defer allocator.free(text);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const m = try manifest.parse(arena.allocator(), text, null);
    return allocator.dupe(u8, m.id);
}

const tests = struct {
    const testing = std.testing;

    test "add and remove folders" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
        const path = try std.fs.path.join(a, &.{ root, "settings", file_name });

        try testing.expectEqual(0, (try load(a, testing.io, path)).len);
        try testing.expect(try add(a, testing.io, path, "D:\\kai\\dist"));
        try testing.expect(try add(a, testing.io, path, "D:\\other"));
        try testing.expect(!try add(a, testing.io, path, "d:\\KAI\\dist\\"));
        try testing.expect(try remove(a, testing.io, path, "D:\\Kai\\Dist"));
        try testing.expect(!try remove(a, testing.io, path, "D:\\kai\\dist"));
        const left = try load(a, testing.io, path);
        try testing.expectEqual(1, left.len);
        try testing.expectEqualStrings("D:\\other", left[0]);
    }

    test "folder plugin name" {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const a = testing.allocator;
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
        defer a.free(root);
        try testing.expectError(error.NoManifest, nameOf(a, testing.io, root));
        try tmp.dir.writeFile(testing.io, .{ .sub_path = manifest.file_name, .data = "{ \"id\": \"kai\" }" });
        const name = try nameOf(a, testing.io, root);
        defer a.free(name);
        try testing.expectEqualStrings("kai", name);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = manifest.file_name, .data = "{ \"id\": \"Not OK\" }" });
        try testing.expectError(error.BadId, nameOf(a, testing.io, root));
    }
};

test {
    _ = tests;
}
