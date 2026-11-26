//! Plugins you're building, in `settings\dev_plugins.zon`. Disabled ones go in `dev_plugins_off.zon`.

const std = @import("std");

const Locations = @import("Locations.zig");
const manifest = @import("manifest.zig");
const deps = @import("deps.zig");

pub const file_name = "dev_plugins.zon";
pub const off_file_name = "dev_plugins_off.zon";

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

/// The switched off list beside `path`.
pub fn offPathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(path) orelse return allocator.dupe(u8, off_file_name);
    return std.fs.path.join(allocator, &.{ dir, off_file_name });
}

/// The ones that are switched off.
pub fn loadOff(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]const []const u8 {
    return load(arena, io, try offPathAlloc(arena, path));
}

/// On, even if it was switched off. False if it already was.
pub fn add(arena: std.mem.Allocator, io: std.Io, path: []const u8, folder: []const u8) !bool {
    _ = try dropFrom(arena, io, try offPathAlloc(arena, path), folder);
    return addTo(arena, io, path, folder);
}

/// Off both lists. False if it wasn't on either.
pub fn remove(arena: std.mem.Allocator, io: std.Io, path: []const u8, folder: []const u8) !bool {
    const was_off = try dropFrom(arena, io, try offPathAlloc(arena, path), folder);
    return try dropFrom(arena, io, path, folder) or was_off;
}

/// Moves it between the lists. False if it's on neither, or already that way.
pub fn setOn(arena: std.mem.Allocator, io: std.Io, path: []const u8, folder: []const u8, on: bool) !bool {
    const off_path = try offPathAlloc(arena, path);
    const from, const to = if (on) .{ off_path, path } else .{ path, off_path };
    if (!try dropFrom(arena, io, from, folder)) return false;
    _ = try addTo(arena, io, to, folder);
    return true;
}

/// Takes folders that aren't there any more off both lists. True if any went.
pub fn prune(arena: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
    var any = false;
    for ([_][]const u8{ path, try offPathAlloc(arena, path) }) |p| {
        const folders = try load(arena, io, p);
        var kept: std.ArrayList([]const u8) = .empty;
        for (folders) |f| if (isDir(io, f)) try kept.append(arena, f);
        if (kept.items.len == folders.len) continue;
        try save(arena, io, p, kept.items);
        any = true;
    }
    return any;
}

fn isDir(io: std.Io, folder: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(io, folder, .{}) catch return false;
    dir.close(io);
    return true;
}

fn addTo(arena: std.mem.Allocator, io: std.Io, path: []const u8, folder: []const u8) !bool {
    const folders = try load(arena, io, path);
    if (indexOf(folders, folder) != null) return false;
    try save(arena, io, path, try std.mem.concat(arena, []const u8, &.{ folders, &.{folder} }));
    return true;
}

fn dropFrom(arena: std.mem.Allocator, io: std.Io, path: []const u8, folder: []const u8) !bool {
    const folders = try load(arena, io, path);
    const i = indexOf(folders, folder) orelse return false;
    try save(arena, io, path, try std.mem.concat(arena, []const u8, &.{ folders[0..i], folders[i + 1 ..] }));
    return true;
}

/// One on either list, as the CLI, the launcher and Settings show it.
pub const Listed = struct {
    folder: []const u8,
    /// Its plugin's id. Null if its wraith.json can't be read.
    name: ?[]const u8,
    /// Why there's no name.
    problem: ?anyerror,
    on: bool,
};

/// The on ones first, in order, then the off ones.
pub fn list(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]const Listed {
    const on = try load(arena, io, path);
    const off = try loadOff(arena, io, path);
    var out: std.ArrayList(Listed) = .empty;
    for ([_][]const []const u8{ on, off }, [_]bool{ true, false }) |folders, is_on| {
        for (folders) |folder| {
            // Back on with an older Wraith's `dev add`, so it's on
            if (!is_on and indexOf(on, folder) != null) continue;
            var l: Listed = .{ .folder = folder, .name = null, .problem = null, .on = is_on };
            l.name = nameOf(arena, io, folder) catch |err| blk: {
                l.problem = err;
                break :blk null;
            };
            try out.append(arena, l);
        }
    }
    return out.items;
}

/// Why `nameOf` failed, for people.
pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.NoManifest => "no wraith.json in it",
        error.BadManifest => "its wraith.json isn't right",
        error.BadId => "its wraith.json's id should be lowercase letters, digits, _ or -",
        error.FileNotFound => "it's not there",
        else => @errorName(err),
    };
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

/// Plugins reachable through `folders`' devDepends that aren't in `folders`, at their build folder if any.
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
        const named = deps.listed(arena, io, source) catch continue;
        for (named.paths.map.keys(), named.paths.map.values()) |name, path| {
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

/// `dir` if its wraith.json has devDepends, else the source folder it was built from.
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
            .{
                "games/kai/wraith.json",
                \\{ "id": "kai", "depends": ["posing"], "devDepends": { "posing": "../../libs/posing/wraith.json" } }
            },
            .{
                "games/kai/zig-out/wraith.json",
                \\{ "id": "kai", "depends": ["posing"] }
            },
            // Posing's build, and its own devDepends on camera, built to dist
            .{
                "libs/posing/wraith.json",
                \\{ "id": "posing", "depends": ["camera"], "devDepends": { "camera": "../camera" } }
            },
            .{
                "libs/posing/zig-out/wraith.json",
                \\{ "id": "posing" }
            },
            .{
                "libs/camera/wraith.json",
                \\{ "id": "camera" }
            },
            .{
                "libs/camera/dist/wraith.json",
                \\{ "id": "camera" }
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

    test "switched off, back on and gone" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const io = testing.io;
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io, "kai");
        try tmp.dir.createDirPath(io, "other");
        try tmp.dir.writeFile(io, .{ .sub_path = "kai/" ++ manifest.file_name, .data = "{ \"id\": \"kai\" }" });
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        const path = try std.fs.path.join(a, &.{ root, "settings", file_name });
        const kai = try std.fs.path.join(a, &.{ root, "kai" });
        const other = try std.fs.path.join(a, &.{ root, "other" });
        const gone = try std.fs.path.join(a, &.{ root, "gone" });
        for ([_][]const u8{ kai, other, gone }) |f| _ = try add(a, io, path, f);

        // Off leaves the loaded list but stays listed
        try testing.expect(try setOn(a, io, path, kai, false));
        try testing.expect(!try setOn(a, io, path, kai, false));
        try testing.expectEqual(2, (try load(a, io, path)).len);
        const listed = try list(a, io, path);
        try testing.expectEqual(3, listed.len);
        try testing.expectEqualStrings(kai, listed[2].folder);
        try testing.expectEqualStrings("kai", listed[2].name.?);
        try testing.expect(!listed[2].on);
        try testing.expectEqual(error.NoManifest, listed[0].problem.?);

        // Adding it again turns it back on
        try testing.expect(try add(a, io, path, kai));
        try testing.expectEqual(0, (try loadOff(a, io, path)).len);

        try testing.expect(try setOn(a, io, path, other, false));
        try testing.expect(try prune(a, io, path));
        try testing.expect(!try prune(a, io, path));
        try testing.expectEqual(2, (try list(a, io, path)).len);

        try testing.expect(try remove(a, io, path, other));
        try testing.expect(!try remove(a, io, path, other));
        try testing.expectEqual(1, (try list(a, io, path)).len);
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
