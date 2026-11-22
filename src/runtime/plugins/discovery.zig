//! Finds plugin folders, installed and dev ones, and reads their manifests.

const std = @import("std");

const core = @import("wraith_core");
const build_info = @import("build_info");
const registry = @import("wraith_registry");

const PluginLoader = @import("../PluginLoader.zig");
const Known = @import("Known.zig");
const Manifest = @import("../Manifest.zig");

const log = core.log.scoped(.wraith_runtime);

pub const Dev = struct { name: []u8, dir: []u8 };

pub fn sourceDir(loader: *PluginLoader, name: []const u8) ![]u8 {
    if (devDir(loader, name)) |dir| return loader.allocator.dupe(u8, dir);
    return std.fs.path.join(loader.allocator, &.{ loader.plugins_dir, name });
}

pub fn folderExists(loader: *PluginLoader, name: []const u8) bool {
    const path = sourceDir(loader, name) catch return false;
    defer loader.allocator.free(path);
    std.Io.Dir.accessAbsolute(loader.io, path, .{}) catch return false;
    return true;
}

pub fn isListed(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.ascii.eqlIgnoreCase(n, name)) return true;
    }
    return false;
}

pub fn clearDev(loader: *PluginLoader) void {
    for (loader.dev.items) |d| {
        loader.allocator.free(d.name);
        loader.allocator.free(d.dir);
    }
    loader.dev.clearRetainingCapacity();
}

fn findDev(loader: *PluginLoader) !void {
    clearDev(loader);
    defer loader.dev_count.store(@intCast(loader.dev.items.len), .release);
    var arena: std.heap.ArenaAllocator = .init(loader.allocator);
    defer arena.deinit();
    const folders = core.dev_plugins.load(arena.allocator(), loader.io, loader.dev_file) catch |err| {
        log.err("Couldn't read the dev plugins in {s}: {t}", .{ loader.dev_file, err });
        return;
    };
    for (folders) |folder| {
        const name = core.dev_plugins.nameOf(loader.allocator, loader.io, folder) catch |err| {
            log.warn("Dev plugin {s} skipped: {t}", .{ folder, err });
            continue;
        };
        defer loader.allocator.free(name);
        if (devDir(loader, name)) |dir| {
            log.warn("Dev plugin {s} skipped: {s} is already in {s}", .{ folder, name, dir });
            continue;
        }
        try loader.dev.ensureUnusedCapacity(loader.allocator, 1);
        const owned_name = try loader.allocator.dupe(u8, name);
        errdefer loader.allocator.free(owned_name);
        loader.dev.appendAssumeCapacity(.{ .name = owned_name, .dir = try loader.allocator.dupe(u8, folder) });
    }
    // What they're built against with devDepends, so those don't need adding too
    const extra = core.dev_plugins.followed(arena.allocator(), loader.io, folders) catch |err| {
        log.warn("Couldn't follow the dev plugins' devDepends: {t}", .{err});
        return;
    };
    for (extra) |f| {
        if (devDir(loader, f.name) != null) continue;
        log.info("Dev plugin {s} is {s}'s devDepends", .{ f.name, f.by });
        try loader.dev.ensureUnusedCapacity(loader.allocator, 1);
        const owned_name = try loader.allocator.dupe(u8, f.name);
        errdefer loader.allocator.free(owned_name);
        loader.dev.appendAssumeCapacity(.{ .name = owned_name, .dir = try loader.allocator.dupe(u8, f.dir) });
    }
}

fn devDir(loader: *const PluginLoader, name: []const u8) ?[]const u8 {
    for (loader.dev.items) |d| if (std.mem.eql(u8, d.name, name)) return d.dir;
    return null;
}

/// Needs `op_lock` held. Forgets folders that are gone unless loaded, and rereads idle manifests.
pub fn scan(loader: *PluginLoader) !void {
    var found: std.ArrayList([]u8) = .empty;
    defer {
        for (found.items) |n| loader.allocator.free(n);
        found.deinit(loader.allocator);
    }
    const plugins = &found;
    try findDev(loader);
    for (loader.dev.items) |d| {
        log.info("Dev plugin {s} from {s}", .{ d.name, d.dir });
        const name = try loader.allocator.dupe(u8, d.name);
        plugins.append(loader.allocator, name) catch |err| {
            loader.allocator.free(name);
            return err;
        };
    }
    {
        var names: std.ArrayList([]u8) = .empty;
        defer names.deinit(loader.allocator);
        try listFolders(loader, loader.plugins_dir, &names);
        for (names.items) |name| {
            // Projects go in the same folder, but there's nothing in them to load
            if (isProject(loader, name)) {
                loader.allocator.free(name);
                continue;
            }
            if (isListed(plugins.items, name)) {
                log.info("Installed plugin {s} is replaced by its dev one", .{name});
                loader.allocator.free(name);
                continue;
            }
            plugins.append(loader.allocator, name) catch |err| {
                loader.allocator.free(name);
                return err;
            };
        }
    }

    // A manifest may have been added or changed
    var idle: std.ArrayList(*Known) = .empty;
    defer idle.deinit(loader.allocator);
    {
        loader.known.lock.lock();
        defer loader.known.lock.unlock();
        var i: usize = 0;
        while (i < loader.known.items.items.len) {
            const k = loader.known.items.items[i];
            if (k.loaded == null and !isListed(found.items, k.name)) {
                _ = loader.known.items.orderedRemove(i);
                k.destroy(loader.allocator);
            } else {
                i += 1;
            }
        }
        for (found.items) |name| _ = try Known.findOrAdd(&loader.known, loader.allocator, name);
        for (loader.known.items.items) |k| {
            if (k.loaded == null) try idle.append(loader.allocator, k);
        }
    }
    for (idle.items) |k| {
        const support = readManifest(loader, k) catch |err| {
            log.err("Couldn't read the manifest of plugin {s}: {t}", .{ k.name, err });
            k.setState(&loader.known, .failed, err);
            continue;
        };
        loader.known.lock.lock();
        defer loader.known.lock.unlock();
        if (support.reason()) |reason| {
            k.state = .unsupported;
            k.last_error = reason;
        } else if (k.state == .unsupported) {
            k.state = .unloaded;
            k.last_error = null;
        }
    }
}

/// Its wraith.json says it's a project, which the Workbench opens rather than the loader.
fn isProject(loader: *PluginLoader, name: []const u8) bool {
    const dir = std.fs.path.join(loader.allocator, &.{ loader.plugins_dir, name }) catch return false;
    defer loader.allocator.free(dir);
    const manifest = (Manifest.read(loader.allocator, loader.io, dir) catch return false) orelse return false;
    defer manifest.deinit();
    return manifest.value.kind == .project;
}

fn listFolders(loader: *PluginLoader, dir_path: []const u8, out: *std.ArrayList([]u8)) !void {
    var dir = std.Io.Dir.openDirAbsolute(loader.io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            log.info("No folder at {s}", .{dir_path});
            return;
        },
        else => return err,
    };
    defer dir.close(loader.io);
    var it = dir.iterate();
    while (try it.next(loader.io)) |entry| {
        if (entry.kind != .directory) continue;
        const owned = try loader.allocator.dupe(u8, entry.name);
        out.append(loader.allocator, owned) catch |err| {
            loader.allocator.free(owned);
            return err;
        };
    }
}

pub const Support = enum {
    yes,
    other_game,
    other_arch,
    newer_wraith,
    /// The hub pulled the copy that's installed.
    revoked,

    pub fn reason(self: Support) ?anyerror {
        return switch (self) {
            .yes => null,
            .other_game => error.UnsupportedGame,
            .other_arch => error.UnsupportedArch,
            .newer_wraith => error.NeedsNewerWraith,
            .revoked => error.Revoked,
        };
    }
};

/// Needs `op_lock` held so `known` stays put.
pub fn readManifest(loader: *PluginLoader, known: *Known) !Support {
    const source_dir = try sourceDir(loader, known.name);
    var keep_dir = false;
    defer if (!keep_dir) loader.allocator.free(source_dir);
    const manifest = (try Manifest.read(loader.allocator, loader.io, source_dir)) orelse {
        std.Io.Dir.cwd().access(loader.io, source_dir, .{}) catch return error.FileNotFound;
        log.err("Plugin {s} has no {s} in {s}", .{ known.name, core.manifest.file_name, source_dir });
        return error.NoManifest;
    };
    defer manifest.deinit();
    if (!std.mem.eql(u8, manifest.value.id, known.name)) {
        log.warn("Plugin {s}'s {s} says its id is {s}, but it's in a folder called {s}", .{ known.name, core.manifest.file_name, manifest.value.id, known.name });
    }
    const provider = try loader.allocator.dupe(u8, manifest.providerName());
    errdefer loader.allocator.free(provider);

    loader.known.lock.lock();
    defer loader.known.lock.unlock();
    try known.setDepends(loader.allocator, manifest.value.depends);
    known.about = .of(manifest);
    known.auto_load = manifest.value.autoLoad;
    if (known.provider) |old| loader.allocator.free(old);
    known.provider = provider;
    if (known.dir) |old| loader.allocator.free(old);
    known.dir = source_dir;
    keep_dir = true;
    if (!manifest.value.isFor(loader.here())) return .other_game;
    if (!manifest.value.builtFor(Manifest.native_arch)) return .other_arch;
    if (!manifest.value.runsOn(build_info.version)) return .newer_wraith;
    if (isRevoked(loader, source_dir)) return .revoked;
    return .yes;
}

/// What the cached revoked list has to be signed with. Tests swap it.
pub var revoked_key: []const u8 = registry.public_key;

/// The hub's revoked list from the last time it was fetched, so it works offline. Empty without one.
pub fn cachedRevoked(arena: std.mem.Allocator, io: std.Io, cache_dir: []const u8) []const []const u8 {
    const cache = std.fs.path.join(arena, &.{ cache_dir, registry.cache_folder }) catch return &.{};
    return registry.cachedRevoked(arena, io, .{ .cache_dir = cache, .key = revoked_key }) catch &.{};
}

/// Whether the copy in `mods_dir/name` is one the hub pulled. Only ones installed from the hub
/// have a hash to check.
pub fn installedRevoked(arena: std.mem.Allocator, io: std.Io, revoked: []const []const u8, mods_dir: []const u8, name: []const u8) bool {
    if (revoked.len == 0) return false;
    const have = (registry.installed(arena, io, mods_dir, name) catch return false) orelse return false;
    return registry.isRevoked(revoked, have.sha256);
}

fn isRevoked(loader: *PluginLoader, source_dir: []const u8) bool {
    var arena_state: std.heap.ArenaAllocator = .init(loader.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parent = std.fs.path.dirname(source_dir) orelse return false;
    return installedRevoked(arena, loader.io, cachedRevoked(arena, loader.io, loader.cache_dir), parent, std.fs.path.basename(source_dir));
}

const tests = struct {
    const testing = std.testing;

    const Install = @import("../testing/Install.zig");

    test "rescan finds and forgets folders" {
        const io = testing.io;
        const options = @import("test_options");
        var install: Install = undefined;
        try install.init(.{ .plugins = &.{.{ "fixture", options.fixture_plugin }} });
        defer install.deinit();
        const loader = &install.loader;
        try loader.start(&.{"fixture"});
        try testing.expectEqual(.unloaded, install.info("fixture").?.state);

        try install.addDll("plugins", "drawing", options.drawing_plugin);
        try install.tmp.dir.deleteTree(io, "plugins/fixture");
        try (try loader.rescan()).wait();
        try testing.expectEqual(.unloaded, install.info("drawing").?.state);
        try testing.expectEqual(null, install.info("fixture"));
    }

    test "start skips autoLoad off" {
        const options = @import("test_options");
        var install: Install = undefined;
        try install.init(.{ .plugins = &.{.{ "fixture", options.fixture_plugin }} });
        defer install.deinit();
        const loader = &install.loader;
        try install.pluginManifest("fixture", "\"autoLoad\": false");

        try loader.start(&.{});
        try testing.expectEqual(0, loader.count());
        try testing.expectEqual(.unloaded, install.info("fixture").?.state);
        try (try loader.load("fixture")).wait();
        try testing.expectEqual(1, loader.count());
    }

    test "a game engine's plugin loads in its games" {
        const options = @import("test_options");
        var install: Install = undefined;
        try install.init(.{ .plugins = &.{.{ "fixture", options.fixture_plugin }} });
        defer install.deinit();
        const loader = &install.loader;
        loader.executable.set("game.exe");
        loader.game_engine.set("unity");
        loader.game_engine_variant.set("Mono");
        try install.pluginManifest("fixture", "\"gameEngine\": { \"id\": \"unity\", \"variants\": [\"IL2CPP\"] }");

        try loader.start(&.{});
        try testing.expectEqual(.unsupported, install.info("fixture").?.state);
        try testing.expectEqualStrings("Unity (IL2CPP) games", install.info("fixture").?.about.games.get());

        try install.pluginManifest("fixture", "\"gameEngine\": { \"id\": \"unity\" }");
        try (try loader.rescan()).wait();
        try testing.expectEqual(.unloaded, install.info("fixture").?.state);
        try (try loader.load("fixture")).wait();
        try testing.expectEqual(1, loader.count());
    }

    test "other game's plugin is unsupported" {
        const options = @import("test_options");
        var install: Install = undefined;
        try install.init(.{ .plugins = &.{.{ "fixture", options.fixture_plugin }} });
        defer install.deinit();
        const loader = &install.loader;
        loader.executable.set("game.exe");
        loader.game_id.set("steam-10");
        try install.pluginManifest("fixture", "\"game\": { \"ids\": [\"steam-20\"], \"exes\": [\"other.exe\"] }");

        try loader.start(&.{});
        try testing.expectEqual(0, loader.count());
        const listed = install.info("fixture").?;
        try testing.expectEqual(.unsupported, listed.state);
        try testing.expectEqualStrings("steam-20, other.exe", listed.about.games.get());
        try testing.expectError(error.UnsupportedGame, (try loader.load("fixture")).wait());
        try testing.expectEqual(.unsupported, install.info("fixture").?.state);

        try install.pluginManifest("fixture", "\"game\": { \"exes\": [\"other.exe\", \"GAME.exe\"] }");
        try (try loader.rescan()).wait();
        try testing.expectEqual(.unloaded, install.info("fixture").?.state);
        try install.pluginManifest("fixture", "\"game\": { \"ids\": [\"steam-20\", \"steam-10\"] }");
        try (try loader.load("fixture")).wait();
        try testing.expectEqual(1, loader.count());

        // Dev builds load anything, so only releases check this
        try (try loader.unload("fixture")).wait();
        try install.pluginManifest("fixture", "\"wraith\": \"999.0.0\"");
        if (core.manifest.compareVersions(build_info.version, core.manifest.dev_version) != .eq) {
            try testing.expectError(error.NeedsNewerWraith, (try loader.load("fixture")).wait());
            try testing.expectEqual(.unsupported, install.info("fixture").?.state);
        }

        try install.pluginManifest("fixture", "\"game\": 3");
        try testing.expectError(error.BadManifest, (try loader.load("fixture")).wait());
        try testing.expectEqual(.failed, install.info("fixture").?.state);
    }

    test "a version the hub pulled isn't loaded" {
        const io = testing.io;
        const options = @import("test_options");
        var install: Install = undefined;
        try install.init(.{ .plugins = &.{.{ "fixture", options.fixture_plugin }} });
        defer install.deinit();
        const loader = &install.loader;
        try install.tmp.dir.writeFile(io, .{ .sub_path = "plugins/fixture/" ++ registry.installed_name, .data = ".{ .id = \"fixture\", .version = \"1.0.0\", .sha256 = \"abc\" }" });

        const pair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(3));
        const key = std.fmt.bytesToHex(pair.public_key.toBytes(), .lower);
        const saved_key = revoked_key;
        revoked_key = &key;
        defer revoked_key = saved_key;
        const text = "{ \"format\": 1, \"sha256\": [\"ABC\"] }";
        const sig = std.fmt.bytesToHex((try pair.sign(text, null)).toBytes(), .lower);
        try install.tmp.dir.createDirPath(io, "cache/registry/v1");
        try install.tmp.dir.writeFile(io, .{ .sub_path = "cache/registry/v1/revoked.json", .data = text });
        try install.tmp.dir.writeFile(io, .{ .sub_path = "cache/registry/v1/revoked.json.sig", .data = &sig });

        const saved = core.log.mute(&.{.runtime});
        defer core.log.setFilter(saved);
        try loader.start(&.{});
        try testing.expectEqual(0, loader.count());
        try testing.expectEqual(.unsupported, install.info("fixture").?.state);
        try testing.expectError(error.Revoked, (try loader.load("fixture")).wait());

        // A different copy loads
        try install.tmp.dir.writeFile(io, .{ .sub_path = "plugins/fixture/" ++ registry.installed_name, .data = ".{ .id = \"fixture\", .version = \"1.0.1\", .sha256 = \"abd\" }" });
        try (try loader.load("fixture")).wait();
        try testing.expectEqual(1, loader.count());
    }

    test "no manifest, no load" {
        const io = testing.io;
        const options = @import("test_options");
        var install: Install = undefined;
        try install.init(.{ .plugins = &.{.{ "fixture", options.fixture_plugin }} });
        defer install.deinit();
        const loader = &install.loader;
        try install.tmp.dir.deleteFile(io, "plugins/fixture/" ++ core.manifest.file_name);

        const saved = core.log.mute(&.{.runtime});
        defer core.log.setFilter(saved);
        try loader.start(&.{});
        try testing.expectEqual(0, loader.count());
        try testing.expectEqual(.failed, install.info("fixture").?.state);
        try testing.expectError(error.NoManifest, (try loader.load("fixture")).wait());
        try testing.expectEqual(error.NoManifest, install.info("fixture").?.last_error.?);
    }

    test "projects in the mods folder aren't plugins" {
        const options = @import("test_options");
        var install: Install = undefined;
        try install.init(.{ .plugins = &.{.{ "fixture", options.fixture_plugin }} });
        defer install.deinit();
        try install.tmp.dir.createDirPath(testing.io, "plugins/tables");
        try install.writeManifest("plugins/tables", "tables", "\"kind\": \"project\"");

        try install.loader.start(&.{});
        try testing.expect(install.info("fixture") != null);
        try testing.expectEqual(null, install.info("tables"));
    }

    test "dev plugin replaces installed" {
        const options = @import("test_options");
        var install: Install = undefined;
        try install.init(.{ .dev_plugins = &.{ "build" ++ std.fs.path.sep_str ++ "out", "build" ++ std.fs.path.sep_str ++ "empty" } });
        defer install.deinit();
        try install.addDll("plugins", "fixture", options.fixture_plugin);
        try install.addDll("plugins", "drawing", options.drawing_plugin);
        try install.addDll("build", "fixture", options.fixture_plugin);
        try install.tmp.dir.rename("build/fixture", install.tmp.dir, "build/out", testing.io);
        try install.tmp.dir.createDirPath(testing.io, "build/empty");
        const loader = &install.loader;

        try loader.start(&.{});
        const fixture = install.info("fixture").?;
        try testing.expectEqual(.loaded, fixture.state);
        try testing.expect(std.mem.endsWith(u8, fixture.source_dir.get(), "build" ++ std.fs.path.sep_str ++ "out"));
        try testing.expect(std.mem.endsWith(u8, install.info("drawing").?.source_dir.get(), "plugins" ++ std.fs.path.sep_str ++ "drawing"));

        try install.addDll("build", "failing", options.failing_plugin);
        try install.tmp.dir.rename("build/failing", install.tmp.dir, "build/late", testing.io);
        const late = try std.fs.path.join(testing.allocator, &.{ install.root, "build", "late" });
        defer testing.allocator.free(late);
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        try testing.expect(try core.dev_plugins.add(arena.allocator(), testing.io, loader.dev_file, late));
        try testing.expectEqual(null, install.info("failing"));
        try (try loader.rescan()).wait();
        try testing.expect(std.mem.endsWith(u8, install.info("failing").?.source_dir.get(), "build" ++ std.fs.path.sep_str ++ "late"));
        var out: [16]PluginLoader.Info = undefined;
        var fixtures: usize = 0;
        for (out[0..loader.list(&out)]) |i| {
            if (std.mem.eql(u8, i.name.get(), "fixture")) fixtures += 1;
        }
        try testing.expectEqual(1, fixtures);
    }

    test "missing directories fail cleanly" {
        var install: Install = undefined;
        try install.init(.{});
        defer install.deinit();
        const loader = &install.loader;

        try loader.start(&.{});
        try testing.expectEqual(0, loader.count());
        try testing.expectError(error.FileNotFound, (try loader.load("ghost")).wait());
        try testing.expectEqual(0, loader.count());
        try testing.expectEqual(.failed, install.info("ghost").?.state);
    }
};

test {
    _ = tests;
}
