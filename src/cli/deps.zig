//! Finds the plugins a plugin depends on, for its typings and its editor. Each is the first of: one of
//! your dev plugins, a folder by its name next to this one, the installed one, or else the hub's,
//! downloaded into the cache. Only versions its `depends` allows count.

const std = @import("std");

const core = @import("wraith_core");
const registry = @import("wraith_registry");
const build_info = @import("build_info");

const ops = @import("ops.zig");
const mods = @import("mods.zig");

const log = core.log.scoped(.wraith_cli);
const manifest = core.manifest;

pub const From = enum { dev, beside, installed, hub };

pub const Found = struct {
    name: []const u8,
    /// Its folder, with its wraith.json and schemas.
    dir: []const u8,
    from: From,
    version: []const u8,
};

/// What `wraith.json` here depends on, by name. None without one.
pub fn listed(arena: std.mem.Allocator, io: std.Io) ![]const manifest.Dependency {
    const text = std.Io.Dir.cwd().readFileAlloc(io, manifest.file_name, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    const M = struct { depends: []const []const u8 = &.{} };
    const m = std.json.parseFromSliceLeaky(M, arena, text, .{ .ignore_unknown_fields = true }) catch return &.{};
    const out = try arena.alloc(manifest.Dependency, m.depends.len);
    for (m.depends, out) |d, *o| o.* = .parse(d);
    return out;
}

/// Where to look, and the hub to download from. Null doesn't download.
pub const Where = struct {
    mods: []const u8,
    cache: []const u8,
    dev: []const []const u8 = &.{},
    hub: ?registry.Source = null,
};

/// Each of `depends`, or a warning for one that can't be had. `hub` says whether to download.
pub fn resolve(ctx: ops.Context, arena: std.mem.Allocator, depends: []const manifest.Dependency, hub: bool) ![]const Found {
    const locations = try ops.locations(arena);
    const dev_file = try core.dev_plugins.pathAlloc(arena, locations);
    return resolveIn(arena, ctx.io, .{
        .mods = locations.mods,
        .cache = try std.fs.path.join(arena, &.{ locations.root, "cache", "deps" }),
        .dev = core.dev_plugins.load(arena, ctx.io, dev_file) catch &.{},
        .hub = if (hub) (try mods.setup(ctx, arena)).source else null,
    }, depends);
}

pub fn resolveIn(arena: std.mem.Allocator, io: std.Io, where: Where, depends: []const manifest.Dependency) ![]const Found {
    var out: std.ArrayList(Found) = .empty;
    for (depends) |dep| {
        if (try find(arena, io, where, dep)) |f| {
            try out.append(arena, f);
        } else {
            log.warn("Couldn't find {s}{s}{s} as a dev plugin, next to this one, installed{s}", .{
                dep.name,
                if (dep.min != null) " " else "",
                dep.min orelse "",
                if (where.hub != null) " or on the hub" else "",
            });
        }
    }
    return out.items;
}

fn find(arena: std.mem.Allocator, io: std.Io, where: Where, dep: manifest.Dependency) !?Found {
    for (where.dev) |folder| {
        const id = core.dev_plugins.nameOf(arena, io, folder) catch continue;
        if (!std.ascii.eqlIgnoreCase(id, dep.name)) continue;
        if (try fitting(arena, io, folder, dep, .dev)) |f| return f;
    }
    const beside = try std.fs.path.join(arena, &.{ "..", dep.name });
    if (try fitting(arena, io, beside, dep, .beside)) |f| return f;
    const installed = try std.fs.path.join(arena, &.{ where.mods, dep.name });
    if (try fitting(arena, io, installed, dep, .installed)) |f| return f;

    const cached = try std.fs.path.join(arena, &.{ where.cache, dep.name });
    if (try fitting(arena, io, cached, dep, .hub)) |f| return f;
    const source = where.hub orelse return null;

    const pkg = (registry.package(arena, io, source, dep.name) catch |err| {
        log.warn("Couldn't ask the hub for {s}: {t}", .{ dep.name, err });
        return null;
    }) orelse return null;
    const version = registry.latest(pkg, build_info.version, null) orelse return null;
    if (!dep.fits(version.version)) return null;
    log.info("Getting {s} {s} from the hub", .{ dep.name, version.version });
    registry.install(arena, io, source, where.cache, pkg, version) catch |err| {
        log.warn("Couldn't download {s}: {t}", .{ dep.name, err });
        return null;
    };
    return fitting(arena, io, cached, dep, .hub);
}

/// `dir` if it's the plugin and its version will do.
fn fitting(arena: std.mem.Allocator, io: std.Io, dir: []const u8, dep: manifest.Dependency, from: From) !?Found {
    const path = try std.fs.path.join(arena, &.{ dir, manifest.file_name });
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch return null;
    const M = struct { id: []const u8 = "", version: []const u8 = "" };
    const m = std.json.parseFromSliceLeaky(M, arena, text, .{ .ignore_unknown_fields = true }) catch return null;
    if (!std.ascii.eqlIgnoreCase(m.id, dep.name)) return null;
    // A dev build's version is whatever it says, so only released ones get checked
    if (from != .dev and !dep.fits(m.version)) return null;
    return .{ .name = dep.name, .dir = dir, .from = from, .version = m.version };
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
        \\{{ "format": 1, "generated": "now", "id": "hello", "kind": "plugin", "author": "me", "title": "Hello", "versions": [{{ "version": "1.0.0", "url": "p/hello/1.0.0.zip", "sha256": "{s}", "size": 1 }}] }}
    , .{&std.fmt.bytesToHex(digest, .lower)});
    try tmp.dir.createDirPath(io, "site/p/hello");
    try tmp.dir.createDirPath(io, "site/v1/packages");
    try tmp.dir.writeFile(io, .{ .sub_path = "site/p/hello/1.0.0.zip", .data = zip });
    try tmp.dir.writeFile(io, .{ .sub_path = "site/v1/packages/hello.json", .data = index });
    const sig = std.fmt.bytesToHex((try pair.sign(index, null)).toBytes(), .lower);
    try tmp.dir.writeFile(io, .{ .sub_path = "site/v1/packages/hello.json.sig", .data = &sig });

    const where: Where = .{
        .mods = try std.fs.path.join(a, &.{ root, "mods" }),
        .cache = try std.fs.path.join(a, &.{ root, "deps" }),
        .hub = .{ .location = try std.fs.path.join(a, &.{ root, "site" }), .key = &key, .cache_dir = try std.fs.path.join(a, &.{ root, "cache" }) },
    };
    const got = try resolveIn(a, io, where, &.{.parse("hello@1")});
    try testing.expectEqual(1, got.len);
    try testing.expectEqual(From.hub, got[0].from);
    try testing.expectEqualStrings("1.0.0", got[0].version);
    try tmp.dir.access(io, "deps/hello/wraith.json", .{});

    // The hub's gone, so this one's from the cache
    var offline = where;
    offline.hub = null;
    const again = try resolveIn(a, io, offline, &.{.parse("hello")});
    try testing.expectEqual(From.hub, again[0].from);
    // Too old, and nothing newer to get. It says so, which isn't news here
    const saved = core.log.mute(&.{.cli});
    defer core.log.setFilter(saved);
    try testing.expectEqual(0, (try resolveIn(a, io, offline, &.{.parse("hello@2")})).len);
}
