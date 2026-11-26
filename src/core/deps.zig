//! Finds a plugin's dependencies on this machine: devDepends, dev plugins, siblings, installed, cache.
//! Only `std`, so Zig plugin builds can use it too.

const std = @import("std");

const manifest = @import("manifest.zig");

pub const From = enum { path, dev, beside, installed, hub };

pub const Found = struct {
    name: []const u8,
    /// Its folder, with its wraith.json and schemas.
    dir: []const u8,
    from: From,
    version: []const u8,
};

/// What a plugin's wraith.json says about what it depends on.
pub const Listed = struct {
    depends: []const manifest.Dependency = &.{},
    /// devDepends, from a name to a folder or its wraith.json, relative to the plugin
    paths: std.json.ArrayHashMap([]const u8) = .{},
};

/// From the wraith.json in `dir`. Nothing without one.
pub fn listed(arena: std.mem.Allocator, io: std.Io, dir: []const u8) !Listed {
    const path = try std.fs.path.join(arena, &.{ dir, manifest.file_name });
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    const M = struct {
        depends: []const []const u8 = &.{},
        devDepends: std.json.ArrayHashMap([]const u8) = .{},
    };
    const m = std.json.parseFromSliceLeaky(M, arena, text, .{ .ignore_unknown_fields = true }) catch return error.BadManifest;
    const out = try arena.alloc(manifest.Dependency, m.depends.len);
    for (m.depends, out) |d, *o| o.* = .parse(d);
    return .{ .depends = out, .paths = m.devDepends };
}

/// Where to look.
pub const Places = struct {
    /// The plugin's folder, which `devDepends` and folders beside it go from
    root: []const u8 = ".",
    /// Folders of plugins you're working on
    dev: []const []const u8 = &.{},
    /// Installed mods
    mods: ?[]const u8 = null,
    /// Where the hub's copies are downloaded
    cache: ?[]const u8 = null,
};

/// Without looking on the hub. Null if none will do.
pub fn find(arena: std.mem.Allocator, io: std.Io, places: Places, list: Listed, dep: manifest.Dependency) !?Found {
    if (list.paths.map.get(dep.name)) |path| {
        if (try fitting(arena, io, try devFolder(arena, places.root, path), dep, .path)) |f| return f;
    }
    for (places.dev) |folder| {
        if (try fitting(arena, io, folder, dep, .dev)) |f| return f;
    }
    if (try fitting(arena, io, try std.fs.path.join(arena, &.{ places.root, "..", dep.name }), dep, .beside)) |f| return f;
    if (places.mods) |mods| {
        if (try fitting(arena, io, try std.fs.path.join(arena, &.{ mods, dep.name }), dep, .installed)) |f| return f;
    }
    if (places.cache) |cache| {
        if (try fitting(arena, io, try std.fs.path.join(arena, &.{ cache, dep.name }), dep, .hub)) |f| return f;
    }
    return null;
}

/// The folder a `devDepends` path means, which can name its wraith.json.
pub fn devFolder(arena: std.mem.Allocator, root: []const u8, path: []const u8) ![]const u8 {
    const folder = if (std.ascii.eqlIgnoreCase(std.fs.path.basename(path), manifest.file_name)) std.fs.path.dirname(path) orelse "." else path;
    return std.fs.path.resolve(arena, &.{ root, folder });
}

/// `dir` if it's the plugin and its version will do.
pub fn fitting(arena: std.mem.Allocator, io: std.Io, dir: []const u8, dep: manifest.Dependency, from: From) !?Found {
    const path = try std.fs.path.join(arena, &.{ dir, manifest.file_name });
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch return null;
    const M = struct { id: []const u8 = "", version: []const u8 = "" };
    const m = std.json.parseFromSliceLeaky(M, arena, text, .{ .ignore_unknown_fields = true }) catch return null;
    if (!std.ascii.eqlIgnoreCase(m.id, dep.name)) return null;
    // One you're working on is whatever version it says
    if (from != .path and from != .dev and !dep.fits(m.version)) return null;
    return .{ .name = dep.name, .dir = dir, .from = from, .version = m.version };
}

test "devDepends goes first and takes any version" {
    const testing = std.testing;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);

    try tmp.dir.createDirPath(io, "libs/freecam");
    try tmp.dir.writeFile(io, .{ .sub_path = "libs/freecam/wraith.json", .data = "{ \"id\": \"freecam\", \"version\": \"0.1.0\" }" });
    try tmp.dir.createDirPath(io, "games/kai");
    try tmp.dir.writeFile(io, .{ .sub_path = "games/kai/wraith.json", .data =
        \\{ "id": "kai", "depends": ["freecam@2"], "devDepends": { "freecam": "../../libs/freecam/wraith.json" } }
    });
    // Installed, but too old, so it's the dev one
    try tmp.dir.createDirPath(io, "mods/freecam");
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/freecam/wraith.json", .data = "{ \"id\": \"freecam\", \"version\": \"1.0.0\" }" });

    const plugin = try std.fs.path.join(a, &.{ root, "games", "kai" });
    const list = try listed(a, io, plugin);
    try testing.expectEqual(1, list.depends.len);
    const places: Places = .{ .root = plugin, .mods = try std.fs.path.join(a, &.{ root, "mods" }) };
    const found = (try find(a, io, places, list, list.depends[0])).?;
    try testing.expectEqual(From.path, found.from);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ root, "libs", "freecam" }), found.dir);

    // Without it, the installed one's too old
    try testing.expectEqual(null, try find(a, io, places, .{ .depends = list.depends }, list.depends[0]));
    // A folder works as well as its wraith.json
    var folder: Listed = .{ .depends = list.depends };
    try folder.paths.map.put(a, "freecam", "../../libs/freecam");
    try testing.expectEqual(From.path, (try find(a, io, places, folder, list.depends[0])).?.from);
}
