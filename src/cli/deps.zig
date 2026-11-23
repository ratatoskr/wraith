//! Finds the plugins a plugin depends on, for its typings and its editor, as `core.deps` does, or
//! else downloads the hub's into the cache.

const std = @import("std");

const core = @import("wraith_core");
const registry = @import("wraith_registry");
const build_info = @import("build_info");

const ops = @import("ops.zig");
const mods = @import("mods.zig");

const log = core.log.scoped(.wraith_cli);
const manifest = core.manifest;

pub const From = core.deps.From;
pub const Found = core.deps.Found;
pub const Listed = core.deps.Listed;

/// What `wraith.json` here depends on. Nothing without one.
pub fn listed(arena: std.mem.Allocator, io: std.Io) !Listed {
    return core.deps.listed(arena, io, ".") catch |err| switch (err) {
        error.BadManifest => .{},
        else => err,
    };
}

/// Where to look, and the hub to download from. Null doesn't download.
pub const Where = struct {
    mods: []const u8,
    cache: []const u8,
    dev: []const []const u8 = &.{},
    hub: ?registry.Source = null,
    /// The plugin's folder
    root: []const u8 = ".",
};

/// Each of `list`, or a warning for one that can't be had. `hub` says whether to download.
pub fn resolve(ctx: ops.Context, arena: std.mem.Allocator, list: Listed, hub: bool) ![]const Found {
    const locations = try ops.locations(arena);
    const dev_file = try core.dev_plugins.pathAlloc(arena, locations);
    return resolveIn(arena, ctx.io, .{
        .mods = locations.mods,
        .cache = try std.fs.path.join(arena, &.{ locations.root, "cache", "deps" }),
        .dev = core.dev_plugins.load(arena, ctx.io, dev_file) catch &.{},
        .hub = if (hub) (try mods.setup(ctx, arena)).source else null,
    }, list);
}

pub fn resolveIn(arena: std.mem.Allocator, io: std.Io, where: Where, list: Listed) ![]const Found {
    var out: std.ArrayList(Found) = .empty;
    for (list.depends) |dep| {
        if (try find(arena, io, where, list, dep)) |f| {
            try out.append(arena, f);
        } else {
            log.warn("Couldn't find {s}{s}{s} in devDepends, as a dev plugin, next to this one, installed{s}", .{
                dep.name,
                if (dep.min != null) " " else "",
                dep.min orelse "",
                if (where.hub != null) " or on the hub" else "",
            });
        }
    }
    return out.items;
}

fn find(arena: std.mem.Allocator, io: std.Io, where: Where, list: Listed, dep: manifest.Dependency) !?Found {
    const cache = try std.fs.path.join(arena, &.{ where.cache, dep.name });
    const places: core.deps.Places = .{ .root = where.root, .dev = where.dev, .mods = where.mods, .cache = where.cache };
    if (try core.deps.find(arena, io, places, list, dep)) |f| return f;
    const source = where.hub orelse return null;

    const index = registry.fetch(arena, io, source) catch |err| {
        log.warn("Couldn't ask the hub for {s}: {t}", .{ dep.name, err });
        return null;
    };
    const pkg = index.find(dep.name) orelse return null;
    const version = registry.latest(pkg.*, build_info.version, null) orelse return null;
    if (!dep.fits(version.version)) return null;
    log.info("Getting {s} {s} from the hub", .{ dep.name, version.version });
    registry.install(arena, io, source, where.cache, pkg.*, version) catch |err| {
        log.warn("Couldn't download {s}: {t}", .{ dep.name, err });
        return null;
    };
    return core.deps.fitting(arena, io, cache, dep, .hub);
}

test "downloads from the hub once, then uses the cache" {
    const testing = std.testing;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);

    // A signed hub with `hello` 1.0.0
    const Ed25519 = std.crypto.sign.Ed25519;
    const pair = try Ed25519.KeyPair.generateDeterministic(@splat(7));
    const key = std.fmt.bytesToHex(pair.public_key.toBytes(), .lower);
    const zip = registry.testing.hello_zip;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(zip, &digest, .{});
    const index = try std.fmt.allocPrint(a,
        \\{{ "format": 2, "generated": "now", "packages": [{{ "id": "hello", "kind": "plugin", "author": "me", "title": "Hello", "versions": [{{ "version": "1.0.0", "apiVersion": 1, "url": "p/hello/1.0.0.zip", "sha256": "{s}", "size": 1 }}] }}] }}
    , .{&std.fmt.bytesToHex(digest, .lower)});
    try tmp.dir.createDirPath(io, "site/p/hello");
    try tmp.dir.createDirPath(io, "site/v2");
    try tmp.dir.writeFile(io, .{ .sub_path = "site/p/hello/1.0.0.zip", .data = zip });
    try tmp.dir.writeFile(io, .{ .sub_path = "site/" ++ registry.index_path, .data = try registry.sign(a, index, pair) });

    const where: Where = .{
        .mods = try std.fs.path.join(a, &.{ root, "mods" }),
        .cache = try std.fs.path.join(a, &.{ root, "deps" }),
        .hub = .{ .location = try std.fs.path.join(a, &.{ root, "site" }), .key = &key, .cache_dir = try std.fs.path.join(a, &.{ root, "cache" }) },
    };
    const got = try resolveIn(a, io, where, .{ .depends = &.{.parse("hello@1")} });
    try testing.expectEqual(1, got.len);
    try testing.expectEqual(From.hub, got[0].from);
    try testing.expectEqualStrings("1.0.0", got[0].version);
    try tmp.dir.access(io, "deps/hello/wraith.json", .{});

    // The hub's gone, so this one's from the cache
    var offline = where;
    offline.hub = null;
    const again = try resolveIn(a, io, offline, .{ .depends = &.{.parse("hello")} });
    try testing.expectEqual(From.hub, again[0].from);
    // Too old, and nothing newer to get. It says so, which isn't news here
    const saved = core.log.mute(&.{.cli});
    defer core.log.setFilter(saved);
    try testing.expectEqual(0, (try resolveIn(a, io, offline, .{ .depends = &.{.parse("hello@2")} })).len);
}
