//! Plugins you're building, listed in `settings\dev_plugins.zon`.

const std = @import("std");

const Locations = @import("Locations.zig");
const manifest = @import("manifest.zig");
const deps = @import("deps.zig");

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

/// A plugin a dev plugin's `devDepends` names, loaded from its build like a dev plugin.
pub const Followed = struct {
    name: []const u8,
    dir: []const u8,
    /// The plugin whose devDepends named it
    by: []const u8,
};

/// Where a build of a plugin's source folder is, by these names inside it, or the folder itself.
const build_folders = [_][]const u8{ "zig-out", "dist" };

/// The plugins `folders`' devDepends name, and theirs in turn, that aren't in `folders`. Each is in its
/// build folder, like zig-out, if it has one. A dev plugin's own wraith.json can leave devDepends
/// out, as builds do, so the source one beside it counts too.
pub fn followed(arena: std.mem.Allocator, io: std.Io, folders: []const []const u8) ![]const Followed {
    var names: std.ArrayList([]const u8) = .empty;
    var dirs: std.ArrayList([]const u8) = .empty;
    for (folders) |f| {
        const name = nameOf(arena, io, f) catch continue;
        try names.append(arena, name);
        try dirs.append(arena, f);
    }
    var out: std.ArrayList(Followed) = .empty;
    var i: usize = 0;
    while (i < dirs.items.len) : (i += 1) {
        const by = names.items[i];
        const source = sourceOf(arena, io, dirs.items[i], by) orelse continue;
        const list = deps.listed(arena, io, source) catch continue;
        for (list.paths.map.keys(), list.paths.map.values()) |name, path| {
            if (isNamed(names.items, name)) continue;
            const folder = try deps.devFolder(arena, source, path);
            const dir = try builtIn(arena, io, folder, name) orelse continue;
            try names.append(arena, name);
            try dirs.append(arena, dir);
            try out.append(arena, .{ .name = name, .dir = dir, .by = by });
        }
    }
    return out.items;
}

/// The folder with `name`'s wraith.json whose devDepends count: `dir` if it has some, or the one
/// it was built from just above it.
fn sourceOf(arena: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8) ?[]const u8 {
    const own = deps.listed(arena, io, dir) catch return null;
    if (own.paths.map.count() > 0) return dir;
    const parent = std.fs.path.dirname(dir) orelse return null;
    const id = nameOf(arena, io, parent) catch return null;
    return if (std.mem.eql(u8, id, name)) parent else null;
}

/// `folder`'s build of `name`, or `folder` itself if it's not built elsewhere.
fn builtIn(arena: std.mem.Allocator, io: std.Io, folder: []const u8, name: []const u8) !?[]const u8 {
    for (build_folders) |sub| {
        const dir = try std.fs.path.join(arena, &.{ folder, sub });
        const id = nameOf(arena, io, dir) catch continue;
        if (std.mem.eql(u8, id, name)) return dir;
    }
    const id = nameOf(arena, io, folder) catch return null;
    return if (std.mem.eql(u8, id, name)) folder else null;
}

fn isNamed(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
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

    test "devDepends of dev plugins are followed to their builds" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const io = testing.io;
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        const files = [_][2][]const u8{
            // The game plugin's source, and its build without devDepends, which is what's added
            .{ "games/kai/wraith.json", \\{ "id": "kai", "depends": ["posing"], "devDepends": { "posing": "../../libs/posing/wraith.json" } }
            },
            .{ "games/kai/zig-out/wraith.json", \\{ "id": "kai", "depends": ["posing"] }
            },
            // Posing's build, and its own devDepends on camera, built to dist
            .{ "libs/posing/wraith.json", \\{ "id": "posing", "depends": ["camera"], "devDepends": { "camera": "../camera" } }
            },
            .{ "libs/posing/zig-out/wraith.json", \\{ "id": "posing" }
            },
            .{ "libs/camera/wraith.json", \\{ "id": "camera" }
            },
            .{ "libs/camera/dist/wraith.json", \\{ "id": "camera" }
            },
        };
        for (files) |f| {
            try tmp.dir.createDirPath(io, std.fs.path.dirname(f[0]).?);
            try tmp.dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
        }
        const kai = try std.fs.path.join(a, &.{ root, "games", "kai", "zig-out" });
        const found = try followed(a, io, &.{kai});
        try testing.expectEqual(2, found.len);
        try testing.expectEqualStrings("posing", found[0].name);
        try testing.expectEqualStrings(try std.fs.path.join(a, &.{ root, "libs", "posing", "zig-out" }), found[0].dir);
        try testing.expectEqualStrings("kai", found[0].by);
        try testing.expectEqualStrings("camera", found[1].name);
        try testing.expectEqualStrings(try std.fs.path.join(a, &.{ root, "libs", "camera", "dist" }), found[1].dir);
        try testing.expectEqualStrings("posing", found[1].by);

        // One that's already a dev plugin isn't found again
        const posing = try std.fs.path.join(a, &.{ root, "libs", "posing", "zig-out" });
        const again = try followed(a, io, &.{ kai, posing });
        try testing.expectEqual(1, again.len);
        try testing.expectEqualStrings("camera", again[0].name);
    }

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
