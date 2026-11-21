//! Loads and unloads plugins, each run by a `PluginKind`. What a plugin needs, and the plugin that
//! made its kind, load first and unload last. Everything here runs with `op_lock` held.

const std = @import("std");

const core = @import("wraith_core");
const wraith_platform = @import("wraith_platform");
const tuft_sys = @import("tuft_sys");
const api = @import("wraith_api");
const build_info = @import("build_info");

const PluginLoader = @import("../PluginLoader.zig");
const Loaded = @import("Loaded.zig");
const Known = @import("Known.zig");
const Op = @import("Jobs.zig").Op;
const discovery = @import("discovery.zig");
const host = @import("../host/root.zig");
const Manifest = @import("../Manifest.zig");
const sal = api.salamander;

const log = core.log.scoped(.wraith_runtime);

/// Takes `op_lock` itself.
pub fn run(loader: *PluginLoader, op: Op, name: []const u8) !void {
    loader.op_lock.lock();
    defer loader.op_lock.unlock();
    return switch (op) {
        .load => {
            _ = try loadNow(loader, name);
        },
        .unload => unloadNow(loader, name),
        .reload => reloadNow(loader, name),
        .rescan => discovery.scan(loader),
    };
}

pub fn loadNow(loader: *PluginLoader, name: []const u8) !*Loaded {
    const known = blk: {
        loader.known.lock.lock();
        defer loader.known.lock.unlock();
        const k = try Known.findOrAdd(&loader.known, loader.allocator, name);
        if (k.loaded != null) return error.AlreadyLoaded;
        k.state = .loading;
        break :blk k;
    };
    const support = discovery.readManifest(loader, known) catch |err| {
        known.setState(&loader.known, .failed, err);
        return err;
    };
    if (support.reason()) |reason| {
        known.setState(&loader.known, .unsupported, reason);
        switch (support) {
            .yes => unreachable,
            .other_game => log.info("Not loading plugin {s}: it's for {s}, not this game ({s})", .{ known.name, known.about.games.get(), loader.executable.get() }),
            .other_arch => log.info("Not loading plugin {s}: it isn't built for {t} games", .{ known.name, Manifest.native_arch }),
            .newer_wraith => log.info("Not loading plugin {s}: it needs Wraith {s} (this is {s})", .{ known.name, known.about.wraith.get(), build_info.version }),
            .revoked => log.warn("Not loading plugin {s}: the hub pulled this version. Update or remove it", .{known.name}),
        }
        return reason;
    }
    // First, since a kind can come from a plugin it depends on
    try loadDepends(loader, known);
    const runner = findRunner(loader, known.name, known.provider.?) catch |err| {
        known.setState(&loader.known, .failed, err);
        return err;
    };
    const loaded = instantiate(loader, known, runner) catch |err| {
        known.setState(&loader.known, .failed, err);
        return err;
    };
    {
        loader.known.lock.lock();
        defer loader.known.lock.unlock();
        known.loaded = loaded;
        known.state = .loaded;
        known.last_error = null;
        known.needs = .{};
    }
    log.info("Loaded plugin {s}", .{known.name});
    return loaded;
}

/// The `PluginKind` provided as `wraith.kind.<name>`, by the runtime or a plugin.
fn findRunner(loader: *PluginLoader, plugin: []const u8, name: []const u8) error{KindNotFound}!Loaded.Runner {
    var buf: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "wraith.kind.{s}", .{name}) catch return error.KindNotFound;
    // Kinds are lowercase, and manifests may not be
    _ = std.ascii.lowerString(key, key);
    const k = sal.host().get(host.wraith.PluginKind, key, 1) orelse {
        log.err("Plugin {s} needs the {s} kind, which nothing provides", .{ plugin, name });
        return error.KindNotFound;
    };
    return .{ .kind = k, .maker = makerOf(loader, k.table) };
}

/// The loaded plugin whose owner guards `table`. Null for ones the runtime made.
fn makerOf(loader: *PluginLoader, table: ?*const anyopaque) ?*Loaded {
    const o = sal.headerOf(table orelse return null).owner orelse return null;
    loader.known.lock.lockShared();
    defer loader.known.lock.unlockShared();
    for (loader.known.items.items) |k| {
        const loaded = k.loaded orelse continue;
        if (loaded.owner.salamanderMade() == o) return loaded;
    }
    return null;
}

pub const DependError = error{ MissingDependency, DependencyOff, DependencyFailed, DependencyTooOld, DependencyCycle };

/// Loads what `known` depends on that isn't already. Marks it failed if one can't be.
fn loadDepends(loader: *PluginLoader, known: *Known) DependError!void {
    // Only scans change `depends`, and those need `op_lock`, which we hold
    for (known.depends) |text| {
        const dep: core.manifest.Dependency = .parse(text);
        loadDependency(loader, known, dep) catch |err| {
            {
                loader.known.lock.lock();
                defer loader.known.lock.unlock();
                known.state = .failed;
                known.last_error = err;
                known.needs.set(text);
            }
            switch (err) {
                error.MissingDependency => log.err("Plugin {s} needs {s}, which isn't installed", .{ known.name, dep.name }),
                error.DependencyOff => log.warn("Plugin {s} needs {s}, which is turned off", .{ known.name, dep.name }),
                error.DependencyFailed => log.err("Plugin {s} needs {s}, which couldn't be loaded", .{ known.name, dep.name }),
                error.DependencyTooOld => log.err("Plugin {s} needs {s} {s} or newer", .{ known.name, dep.name, dep.min.? }),
                error.DependencyCycle => log.err("Plugin {s} and {s} need each other, so neither can load first", .{ known.name, dep.name }),
            }
            return err;
        };
    }
}

fn loadDependency(loader: *PluginLoader, known: *Known, dep: core.manifest.Dependency) DependError!void {
    if (std.ascii.eqlIgnoreCase(dep.name, known.name)) return error.DependencyCycle;
    const found: ?Known.State = blk: {
        loader.known.lock.lockShared();
        defer loader.known.lock.unlockShared();
        const k = Known.find(&loader.known, dep.name) orelse break :blk null;
        break :blk k.state;
    };
    // Not scanned yet, or added since
    const state = found orelse if (discovery.folderExists(loader, dep.name)) Known.State.unloaded else return error.MissingDependency;
    switch (state) {
        .loaded => {},
        .loading => return error.DependencyCycle,
        else => {
            if (discovery.isListed(loader.skipping, dep.name)) return error.DependencyOff;
            _ = loadNow(loader, dep.name) catch |err| switch (err) {
                error.AlreadyLoaded => {},
                error.DependencyCycle => return error.DependencyCycle,
                else => return error.DependencyFailed,
            };
        },
    }
    const version = blk: {
        loader.known.lock.lockShared();
        defer loader.known.lock.unlockShared();
        const k = Known.find(&loader.known, dep.name) orelse return error.DependencyFailed;
        break :blk k.about.version;
    };
    if (!dep.fits(version.get())) return error.DependencyTooOld;
}

/// The plugins loaded now, which the caller frees.
fn loadedPlugins(loader: *PluginLoader) ![][]u8 {
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| loader.allocator.free(n);
        names.deinit(loader.allocator);
    }
    loader.known.lock.lockShared();
    defer loader.known.lock.unlockShared();
    for (loader.known.items.items) |k| {
        if (k.loaded == null) continue;
        const name = try loader.allocator.dupe(u8, k.name);
        names.append(loader.allocator, name) catch |err| {
            loader.allocator.free(name);
            return err;
        };
    }
    return names.toOwnedSlice(loader.allocator);
}

fn freeNames(loader: *PluginLoader, names: [][]u8) void {
    for (names) |n| loader.allocator.free(n);
    loader.allocator.free(names);
}

fn reloadNow(loader: *PluginLoader, name: []const u8) !void {
    // What its kinds run and what depends on it go with it, so they come back after
    const was_loaded = try loadedPlugins(loader);
    defer freeNames(loader, was_loaded);
    unloadNow(loader, name) catch |err| if (err != error.NotLoaded) return err;
    _ = try loadNow(loader, name);
    for (was_loaded) |plugin| {
        if (loader.find(plugin) != null) continue;
        _ = loadNow(loader, plugin) catch |err| log.err("Couldn't load plugin {s}: {t}", .{ plugin, err });
    }
}

fn unloadNow(loader: *PluginLoader, name: []const u8) !void {
    const known = blk: {
        loader.known.lock.lockShared();
        defer loader.known.lock.unlockShared();
        const k = Known.find(&loader.known, name) orelse return error.NotLoaded;
        if (k.loaded == null) return error.NotLoaded;
        break :blk k;
    };
    unloadKnown(loader, known);
}

pub fn unloadKnown(loader: *PluginLoader, known: *Known) void {
    known.setState(&loader.known, .unloading, null);
    // What its kinds run goes first, and plugins go before what they need
    while (loadedGuestOf(loader, known.loaded.?)) |guest| unloadKnown(loader, guest);
    while (loadedDependentOf(loader, known)) |dependent| unloadKnown(loader, dependent);
    const loaded = blk: {
        loader.known.lock.lock();
        defer loader.known.lock.unlock();
        defer known.loaded = null;
        break :blk known.loaded.?;
    };
    destroy(loader, loaded);
    known.setState(&loader.known, .unloaded, null);
}

fn loadedGuestOf(loader: *PluginLoader, maker: *Loaded) ?*Known {
    loader.known.lock.lockShared();
    defer loader.known.lock.unlockShared();
    for (loader.known.items.items) |k| {
        const loaded = k.loaded orelse continue;
        if (loaded.maker() == maker) return k;
    }
    return null;
}

fn loadedDependentOf(loader: *PluginLoader, known: *const Known) ?*Known {
    loader.known.lock.lockShared();
    defer loader.known.lock.unlockShared();
    for (loader.known.items.items) |k| {
        if (k != known and k.loaded != null and k.state != .unloading and k.dependsOn(known.name)) return k;
    }
    return null;
}

fn instantiate(loader: *PluginLoader, known: *Known, runner: Loaded.Runner) !*Loaded {
    const allocator = loader.allocator;
    const name = known.name;

    const source_dir = try discovery.sourceDir(loader, name);
    defer allocator.free(source_dir);

    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);

    const config_dir = try std.fs.path.join(allocator, &.{ loader.config_dir, "plugins", name });
    errdefer allocator.free(config_dir);
    const game_config_dir = try std.fs.path.join(allocator, &.{ loader.game_config_dir, "plugins", name });
    errdefer allocator.free(game_config_dir);

    const copy_dir = try makeCopyDir(loader, name);
    errdefer allocator.free(copy_dir);
    try wraith_platform.fs.copyDirectory(allocator, loader.io, source_dir, copy_dir);
    errdefer deleteCopy(loader, copy_dir);

    // Discovery read the source's, but the copy's is what runs
    const manifest = try Manifest.read(allocator, loader.io, copy_dir) orelse return error.NoManifest;
    errdefer manifest.deinit();

    const schemas = try loadSchemas(loader, known, copy_dir);
    errdefer if (schemas) |s| s.destroy();

    const loaded = try allocator.create(Loaded);
    loaded.* = .{
        .name = owned_name,
        .manifest = manifest,
        .owner = .init(owned_name),
        .copy_dir = copy_dir,
        .config_dir = config_dir,
        .game_config_dir = game_config_dir,
        .runner = runner,
        .allocator = allocator,
        .schemas = schemas,
    };
    host.shared_schemas.publish(loaded);

    const started = core.timing.now();
    const result = startKind(loader, known, loaded);
    loaded.start_ns = core.timing.now() -| started;
    result catch |err| {
        // The errdefers above free the rest
        teardown(loaded);
        allocator.destroy(loaded);
        return err;
    };
    collectServices(loaded) catch |err| {
        teardown(loaded);
        allocator.destroy(loaded);
        return err;
    };
    return loaded;
}

/// The plugins it depends on, all loaded already.
fn dependencies(loader: *PluginLoader, known: *Known, out: *std.ArrayList(*Loaded)) !void {
    loader.known.lock.lockShared();
    defer loader.known.lock.unlockShared();
    for (known.depends) |text| {
        const dep: core.manifest.Dependency = .parse(text);
        const k = Known.find(&loader.known, dep.name) orelse continue;
        if (k.loaded) |l| try out.append(loader.allocator, l);
    }
}

/// Wraith's, its own `schemas` folder's and those of the plugins it depends on, which are loaded already.
fn loadSchemas(loader: *PluginLoader, known: *Known, dir: []const u8) !?*host.schemas.Schemas {
    var depends: std.ArrayList(*Loaded) = .empty;
    defer depends.deinit(loader.allocator);
    try dependencies(loader, known, &depends);
    return host.schemas.load(loader.io, known.name, dir, depends.items) catch |err| {
        log.err("Plugin {s}'s schemas can't be used: {t}", .{ known.name, err });
        return err;
    };
}

fn startKind(loader: *PluginLoader, known: *Known, loaded: *Loaded) anyerror!void {
    const k = &loaded.runner;
    const root = host.wraith.root(loaded);
    if (root.table == null) return error.PluginStartFailed;
    const schema = if (loaded.schemas) |s| s.text else api.wraith_sal;

    // What the plugins it depends on offer, all of them in one list
    var depends: std.ArrayList(*Loaded) = .empty;
    defer depends.deinit(loader.allocator);
    try dependencies(loader, known, &depends);
    var services: std.ArrayList(host.wraith.Service) = .empty;
    defer services.deinit(loader.allocator);
    for (depends.items) |d| try services.appendSlice(loader.allocator, d.services.items);

    const guest: host.wraith.Guest = .{
        .name = loaded.name,
        .dir = loaded.copy_dir,
        .wraith = root.as(@FieldType(host.wraith.Guest, "wraith")),
        .schema = schema,
        .services = services.items,
    };
    k.plugin = k.kind.start(guest) catch return error.PluginStartFailed;
    if (k.plugin.table == null) return error.PluginStartFailed;
}

pub const ServiceError = error{ OutOfMemory, MissingService };

/// What its main exports for each [Service] trait in its own schemas. Fails if one's missing.
fn collectServices(loaded: *Loaded) ServiceError!void {
    const s = loaded.schemas orelse return;
    const gpa = std.heap.page_allocator;
    const names = try s.services(gpa, loaded.name);
    defer gpa.free(names);
    for (names) |trait| {
        const obj = loaded.runner.plugin.service(trait);
        if (obj.table == null) {
            log.err("Plugin {s} says it offers {s}, but its main doesn't export one", .{ loaded.name, trait });
            return error.MissingService;
        }
        loaded.services.append(gpa, .{ .plugin = loaded.name, .trait = trait, .obj = obj }) catch {
            sal.host().release(obj);
            return error.OutOfMemory;
        };
    }
}

fn releaseServices(loaded: *Loaded) void {
    for (loaded.services.items) |svc| sal.host().release(svc.obj);
    loaded.services.deinit(std.heap.page_allocator);
    loaded.services = .empty;
}

/// Close, stop, release, unload. What its kinds run must already be unloaded.
fn teardown(loaded: *Loaded) void {
    const r = &loaded.runner;
    loaded.owner.close();
    releaseServices(loaded);
    if (r.plugin.table != null) r.plugin.stop();
    loaded.owner.release();
    if (r.plugin.table != null) {
        r.plugin.unload();
        // Its kind kept it for us, so it can let go
        r.plugin.release();
    }
}

fn destroy(loader: *PluginLoader, loaded: *Loaded) void {
    teardown(loaded);
    loaded.free();
    deleteCopy(loader, loaded.copy_dir);
    log.info("Unloaded plugin {s}", .{loaded.name});

    loader.allocator.free(loaded.copy_dir);
    loader.allocator.free(loaded.config_dir);
    loader.allocator.free(loaded.game_config_dir);
    loader.allocator.free(loaded.name);
    loaded.manifest.deinit();
    loader.allocator.destroy(loaded);
}

/// Unique per load so a reload never hits a copy still being deleted.
fn makeCopyDir(loader: *PluginLoader, name: []const u8) ![]const u8 {
    try wraith_platform.fs.ensureDirectory(loader.io, loader.copies_dir);

    var random: [6]u8 = undefined;
    loader.io.random(&random);
    const hex = std.fmt.bytesToHex(random, .lower);

    const folder = try std.fmt.allocPrint(loader.allocator, "{s}_{s}", .{ name, &hex });
    defer loader.allocator.free(folder);
    return std.fs.path.join(loader.allocator, &.{ loader.copies_dir, folder });
}

fn deleteCopy(loader: *PluginLoader, copy_dir: []const u8) void {
    wraith_platform.fs.deleteDirectory(loader.io, copy_dir) catch |err| {
        // Bootstrap clears the temp dir on next start anyway
        log.warn("Couldn't delete copy {s}: {t}", .{ copy_dir, err });
    };
}

const tests = struct {
    const testing = std.testing;
    const Owner = @import("tuft_event").Owner;

    fn exists(io: std.Io, path: []const u8) bool {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
        return true;
    }

    const Lifecycle = struct {
        owner: ?*const Owner = null,
        closes: u32 = 0,
        releases: u32 = 0,
        in_order: bool = true,

        fn closing(self: *Lifecycle, owner: *Owner) void {
            if (owner == self.owner) self.closes += 1;
        }

        fn released(self: *Lifecycle, owner: *Owner) void {
            if (owner != self.owner) return;
            self.releases += 1;
            if (self.closes != self.releases) self.in_order = false;
        }
    };

    const Install = @import("../testing/Install.zig");

    fn zoneListed(name: []const u8, owner: []const u8) bool {
        var out: [256]core.timing.Stats = undefined;
        for (out[0..core.timing.registry.snapshot(&out)]) |s| {
            if (std.mem.eql(u8, s.name(), name) and std.mem.eql(u8, s.ownerName(), owner)) return true;
        }
        return false;
    }

    /// A JS plugin that does nothing, with `fields` in its manifest.
    fn addNeeding(install: *Install, name: []const u8, fields: []const u8) !void {
        try install.addScript(name, "js");
        const all = try std.fmt.allocPrint(testing.allocator, "\"provider\": \"js\", {s}", .{fields});
        defer testing.allocator.free(all);
        try install.pluginManifest(name, all);
    }

    test "plugins load after what they need" {
        // The JS kind reads its plugins' files
        host.wraith.setIo(testing.io);
        defer host.wraith.setIo(null);
        var install: Install = undefined;
        try install.init(.{});
        defer install.deinit();
        const loader = &install.loader;
        try addNeeding(&install, "top", "\"depends\": [\"mid@1.1\"]");
        try addNeeding(&install, "mid", "\"version\": \"1.2.0\", \"depends\": [\"base\"]");
        try addNeeding(&install, "base", "\"version\": \"1.0.0\", \"autoLoad\": false");
        try addNeeding(&install, "lost", "\"depends\": [\"ghost\"]");
        try addNeeding(&install, "old", "\"depends\": [\"base@2\"]");
        try addNeeding(&install, "loop_a", "\"depends\": [\"loop_b\"]");
        try addNeeding(&install, "loop_b", "\"depends\": [\"loop_a\"]");
        try addNeeding(&install, "user", "\"depends\": [\"off\"]");
        try install.addScript("off", "js");

        try loader.start(&.{"off"});
        // base doesn't load on its own, but mid needs it
        for ([_][]const u8{ "top", "mid", "base" }) |name| try testing.expectEqual(.loaded, install.info(name).?.state);
        const expectFailed = struct {
            fn check(i: *Install, name: []const u8, err: anyerror, needs: []const u8) !void {
                const info = i.info(name).?;
                try testing.expectEqual(.failed, info.state);
                try testing.expectEqual(err, info.last_error.?);
                try testing.expectEqualStrings(needs, info.needs.get());
            }
        }.check;
        try expectFailed(&install, "lost", error.MissingDependency, "ghost");
        try expectFailed(&install, "old", error.DependencyTooOld, "base@2");
        try expectFailed(&install, "user", error.DependencyOff, "off");
        try testing.expectEqual(error.DependencyCycle, install.info("loop_a").?.last_error.?);
        try testing.expectEqual(error.DependencyCycle, install.info("loop_b").?.last_error.?);
        try testing.expectEqual(.unloaded, install.info("off").?.state);

        // What needs it goes first
        try (try loader.unload("base")).wait();
        for ([_][]const u8{ "top", "mid", "base" }) |name| try testing.expectEqual(.unloaded, install.info(name).?.state);
        try (try loader.load("top")).wait();
        for ([_][]const u8{ "top", "mid", "base" }) |name| try testing.expectEqual(.loaded, install.info(name).?.state);

        // And comes back after a reload
        try (try loader.reload("base")).wait();
        for ([_][]const u8{ "top", "mid", "base" }) |name| try testing.expectEqual(.loaded, install.info(name).?.state);

        // Loading it by hand loads what it needs, even if that's off
        try (try loader.load("user")).wait();
        try testing.expectEqual(.loaded, install.info("off").?.state);
        try testing.expectEqualStrings("", install.info("user").?.needs.get());
    }

    test "loads from a temp copy" {
        const io = testing.io;
        const a = testing.allocator;
        const options = @import("test_options");
        var install: Install = undefined;
        try install.init(.{ .plugins = &.{.{ "fixture", options.fixture_plugin }} });
        defer install.deinit();
        const loader = &install.loader;

        try loader.start(&.{});
        try testing.expectEqual(1, loader.count());
        const first_copy = try a.dupe(u8, loader.find("fixture").?.copy_dir);
        defer a.free(first_copy);
        try testing.expect(std.mem.startsWith(u8, first_copy, loader.copies_dir));
        try testing.expect(exists(io, first_copy));
        try testing.expectError(error.AlreadyLoaded, (try loader.load("fixture")).wait());

        // The loaded copy doesn't lock the original
        const dll = try core.arch.native.dllNameAlloc(a, "fixture");
        defer a.free(dll);
        const original = try std.fs.path.join(a, &.{ install.root, "plugins", "fixture", dll });
        defer a.free(original);
        const file = try std.Io.Dir.openFileAbsolute(io, original, .{ .mode = .read_write });
        file.close(io);

        var lifecycle: Lifecycle = .{ .owner = &loader.find("fixture").?.owner };
        const on_closing = try Owner.closing.subscribeUnscoped(&lifecycle, Lifecycle.closing);
        defer on_closing.unsubscribe();
        const on_released = try Owner.released.subscribeUnscoped(&lifecycle, Lifecycle.released);
        defer on_released.unsubscribe();
        try (try loader.reload("fixture")).wait();
        try testing.expectEqual(1, lifecycle.closes);
        try testing.expectEqual(1, lifecycle.releases);
        try testing.expect(lifecycle.in_order);
        try testing.expectEqual(1, loader.count());
        const second_copy = try a.dupe(u8, loader.find("fixture").?.copy_dir);
        defer a.free(second_copy);
        try testing.expect(!std.mem.eql(u8, first_copy, second_copy));
        try testing.expect(!exists(io, first_copy));
        try testing.expect(exists(io, second_copy));

        lifecycle = .{ .owner = &loader.find("fixture").?.owner };
        try (try loader.unload("fixture")).wait();
        try testing.expectEqual(1, lifecycle.releases);
        try testing.expectEqual(0, loader.count());
        try testing.expect(!exists(io, second_copy));
        try testing.expectError(error.NotLoaded, (try loader.unload("fixture")).wait());
    }

    test "debug logging reaches the Log" {
        const options = @import("test_options");
        const Settings = @import("../Settings.zig");
        const LogHistory = @import("../LogHistory.zig");
        var install: Install = undefined;
        try install.init(.{ .plugins = &.{.{ "fixture", options.fixture_plugin }} });
        defer install.deinit();
        const loader = &install.loader;
        try loader.start(&.{"fixture"});

        const previous = core.log.setSink(&LogHistory.sink);
        defer _ = core.log.setSink(previous);
        core.log.setFilter(.{ .subsystems = .initMany(&.{ .runtime, .plugin }) });
        for ([_]std.log.Level{ .debug, .info, .debug }) |level| {
            Settings.applyLogLevel(level);
            var entries: [16]LogHistory.Entry = undefined;
            var seq: u64 = 0;
            while (true) {
                const batch = LogHistory.global.readSince(seq, &entries);
                if (batch.len == 0) break;
                seq = batch[batch.len - 1].seq + 1;
            }

            core.log.scoped(.wraith_runtime).debug("Runtime debug check", .{});
            try (try loader.load("fixture")).wait();
            var runtime_debug = false;
            var plugin_debug = false;
            for (LogHistory.global.readSince(seq, &entries)) |entry| {
                if (entry.level != .debug) continue;
                if (std.mem.eql(u8, entry.message(), "Runtime debug check")) runtime_debug = true;
                if (std.mem.eql(u8, entry.message(), "[fixture] Fixture debug start")) plugin_debug = true;
            }
            try testing.expectEqual(level == .debug, runtime_debug);
            try testing.expectEqual(level == .debug, plugin_debug);
            try (try loader.unload("fixture")).wait();
        }
    }

    test "settings persist across reloads" {
        const io = testing.io;
        const a = testing.allocator;
        const options = @import("test_options");
        var install: Install = undefined;
        try install.init(.{ .plugins = &.{.{ "fixture", options.fixture_plugin }} });
        defer install.deinit();
        const loader = &install.loader;

        // The fixture counts its starts in its settings, and its tasks that got cancelled
        try (try loader.load("fixture")).wait();
        try (try loader.reload("fixture")).wait();
        try (try loader.unload("fixture")).wait();

        const Settings = struct { starts: u32 = 0, cancelled_tasks: u32 = 0 };
        const path = try std.fs.path.join(a, &.{ install.root, "settings", "plugins", "fixture", "config.zon" });
        defer a.free(path);
        const File = core.config.Lifecycle(Settings);
        const saved = try File.open(a, io, path);
        defer File.discard(saved);
        try testing.expectEqual(2, saved.value.starts);
        try testing.expectEqual(2, saved.value.cancelled_tasks);
    }

    test "native plugins have to be Wraith plugins" {
        const options = @import("test_options");
        var install: Install = undefined;
        try install.init(.{ .plugins = &.{.{ "bogus", options.foreign_dll }} });
        defer install.deinit();
        const loader = &install.loader;

        try loader.start(&.{});
        const bogus = install.info("bogus").?;
        try testing.expectEqual(.failed, bogus.state);
        try testing.expectEqual(error.PluginStartFailed, bogus.last_error.?);
    }

    test "failed start is marked failed" {
        const io = testing.io;
        const options = @import("test_options");
        var install: Install = undefined;
        try install.init(.{ .plugins = &.{.{ "failing", options.failing_plugin }} });
        defer install.deinit();
        const loader = &install.loader;

        try testing.expectError(error.PluginStartFailed, (try loader.load("failing")).wait());
        try testing.expectEqual(0, loader.count());
        const failed = install.info("failing").?;
        try testing.expectEqual(.failed, failed.state);
        try testing.expectEqual(error.PluginStartFailed, failed.last_error.?);

        var copies = try std.Io.Dir.openDirAbsolute(io, loader.copies_dir, .{ .iterate = true });
        defer copies.close(io);
        var it = copies.iterate();
        while (try it.next(io)) |entry| try testing.expect(!std.mem.startsWith(u8, entry.name, "failing_"));
    }
};

test {
    _ = tests;
}
