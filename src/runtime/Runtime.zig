//! The running runtime. Stops in reverse order of starting.

const Runtime = @This();

const std = @import("std");

const core = @import("wraith_core");
const wraith_platform = @import("wraith_platform");
const hook = @import("tuft_hook");
const RuntimeInfo = core.runtime_abi.RuntimeInfo;

const PluginLoader = @import("PluginLoader.zig");
const Settings = @import("Settings.zig");
const GameSettings = @import("GameSettings.zig");
const GameSettingsFile = core.config.Lifecycle(GameSettings);
const Game = @import("Game.zig");
const GameInfo = @import("GameInfo.zig");
const speed = @import("speed/root.zig");
const Registry = @import("settings/Registry.zig");
const host = @import("host/root.zig");
const LogFile = @import("LogFile.zig");
const Console = @import("Console.zig");
const LogHistory = @import("LogHistory.zig");
const Names = @import("Names.zig");
const SharedSchemas = @import("SharedSchemas.zig");
const Libraries = @import("Libraries.zig");
const Images = @import("Images.zig");
const OriginalCode = @import("OriginalCode.zig");
const Files = @import("Files.zig");
const Managed = @import("Managed.zig");
const crash = @import("crash/root.zig");
const memory = @import("tuft_mem");

const log = core.log.scoped(.wraith_runtime);

allocator: std.mem.Allocator,
threaded: std.Io.Threaded,
game_settings: *core.Config(GameSettings),
/// What Wraith, plugins and tweaks register, keys included.
registry: *Registry,
/// The runtime's own settings in it.
own: Settings.Own,
game: ?*Game,
loader: PluginLoader,
previous_recorder: ?memory.scans.Recorder = null,

pub fn create(allocator: std.mem.Allocator, info: *const RuntimeInfo) !*Runtime {
    if (info.size < RuntimeInfo.min_size) return error.IncompatibleBootstrap;

    // Heap-allocated because `threaded` hands out pointers to itself
    const self = try allocator.create(Runtime);
    errdefer allocator.destroy(self);
    self.allocator = allocator;

    self.threaded = .init(allocator, .{});
    errdefer self.threaded.deinit();
    const io = self.threaded.io();

    // Before any hook, so every one claims its bytes
    memory.Claims.enable(allocator);
    errdefer memory.Claims.disable();
    try hook.init(allocator);
    errdefer hook.deinit();

    const locations = try findLocations(allocator);
    defer locations.deinit(allocator);
    const config_root = try Settings.rootAlloc(allocator, locations);
    defer allocator.free(config_root);
    openLog(allocator, io, locations, info.wraith_dir.slice());
    errdefer crash.uninstall();

    // First, since which game this is decides where its settings are
    GameInfo.global.start(allocator, io);
    errdefer GameInfo.global.stop();

    const game_dir = try Settings.gameDirAlloc(allocator, config_root, GameInfo.global.id());
    defer allocator.free(game_dir);
    {
        const path = try std.fs.path.join(allocator, &.{ game_dir, "game.zon" });
        defer allocator.free(path);
        self.game_settings = try GameSettingsFile.open(allocator, io, path);
    }
    errdefer GameSettingsFile.close(self.game_settings);
    if (self.game_settings.value.name.len == 0) {
        const title = GameInfo.global.title();
        const name = if (title.len > 0) title else GameInfo.global.name();
        self.game_settings.value.name = try self.game_settings.arena.allocator().dupe(u8, name);
    }
    {
        const global_path = try Settings.valuesPathAlloc(allocator, config_root);
        defer allocator.free(global_path);
        const game_path = try Settings.gameValuesPathAlloc(allocator, game_dir);
        defer allocator.free(game_path);
        self.registry = try Registry.create(allocator, .{ .io = io, .global_path = global_path, .game_path = game_path });
    }
    errdefer self.registry.destroy();
    self.own = try Settings.Own.add(self.registry);
    errdefer self.own.remove();
    Settings.applyLogLevel(self.own.logLevel());
    if (self.own.wantsConsole()) Console.show();
    if (self.own.watchesFiles()) Files.global.start(allocator);
    errdefer Files.global.stop();
    host.sound.start(allocator);
    errdefer host.sound.stop();
    host.sound.setEnabled(self.own.playsSounds());
    log.info("Settings in {s}; this game's in {s}", .{ config_root, game_dir });
    host.keybinds.setRegistry(self.registry);
    errdefer host.keybinds.setRegistry(null);
    host.settings.setRegistry(self.registry);
    errdefer host.settings.setRegistry(null);
    host.wraith.setIo(io);
    errdefer host.wraith.setIo(null);

    // Before anything hooks the game's code
    OriginalCode.global.take(std.heap.page_allocator, io);
    errdefer OriginalCode.global.release();
    Names.global = .init(allocator);
    errdefer Names.global.deinit();
    SharedSchemas.global = .init(allocator);
    errdefer SharedSchemas.global.deinit();
    Libraries.global = try .initBuiltin(allocator);
    errdefer Libraries.global.deinit();
    Images.global = .init(allocator);
    errdefer Images.global.deinit();
    self.previous_recorder = memory.scans.setRecorder(Names.recordOwn);
    errdefer _ = memory.scans.setRecorder(self.previous_recorder);
    // Before plugins, so they find the game's C# as soon as it's running
    {
        const clr_dir = try locations.path(allocator, "cache" ++ std.fs.path.sep_str ++ "coreclr");
        defer allocator.free(clr_dir);
        Managed.global.start(io, clr_dir);
    }
    errdefer Managed.global.stop();

    const before_rendering = info.flagsOf() & RuntimeInfo.flag_before_rendering != 0;
    self.game = Game.create(allocator, io, self.game_settings, config_root, .{ .before_rendering = before_rendering, .handover = info.handoverOf(), .registry = self.registry, .ime = self.own.usesIme() }) catch |err| blk: {
        log.err("No overlay (graphics, window or input unavailable): {t}", .{err});
        break :blk null;
    };
    errdefer if (self.game) |g| g.destroy();

    self.loader = try openLoader(allocator, io, info, locations, config_root, game_dir);
    errdefer self.loader.deinit();
    self.loader.game_id.set(GameInfo.global.id());
    if (GameInfo.global.game_engine) |e| self.loader.game_engine.set(@tagName(e));
    self.loader.game_engine_variant.set(GameInfo.global.engineVariant());
    if (self.game) |g| g.shell.setLoader(&self.loader);
    errdefer if (self.game) |g| g.shell.setLoader(null);
    try self.loader.start(self.game_settings.value.disabled_plugins);
    // The game engine's own plugin, kept up to date off the hub, on a worker
    if (self.game) |g| g.shell.windows.mods.keepEssentials(g.shell);

    log.info("Runtime started with {d} plugin(s)", .{self.loader.count()});

    return self;
}

pub fn destroy(self: *Runtime) void {
    GameInfo.global.stop();
    if (self.game) |g| g.shell.setLoader(null);
    self.loader.deinit();
    if (self.game) |g| g.destroy();
    // After plugins and the game, which register settings in it
    host.keybinds.setRegistry(null);
    host.settings.setRegistry(null);
    host.wraith.setIo(null);
    self.own.remove();
    self.registry.destroy();
    _ = memory.scans.setRecorder(self.previous_recorder);
    // After plugins and the game, which may still hold its listeners
    Files.global.stop();
    host.sound.stop();
    // After plugins, which may be waiting on it
    Managed.global.stop();
    Names.global.deinit();
    SharedSchemas.global.deinit();
    Libraries.global.deinit();
    Images.global.deinit();
    OriginalCode.global.release();
    // Its hook goes with the rest
    crash.uninstall();
    speed.stop();
    hook.deinit();
    memory.Claims.disable();
    GameSettingsFile.close(self.game_settings);
    self.threaded.deinit();
    self.allocator.destroy(self);
}

/// And crash handling, whose reports go next to it. The runtime keeps going without either.
fn openLog(allocator: std.mem.Allocator, io: std.Io, locations: core.Locations, wraith_dir: []const u8) void {
    const dir = locations.path(allocator, "logs") catch return;
    defer allocator.free(dir);
    var exe_buf: [1024]u8 = undefined;
    const exe = memory.Module.main().name(&exe_buf) orelse "game.exe";
    const pid = wraith_platform.process.currentId();
    if (LogFile.global.open(allocator, io, dir, exe, pid, &LogHistory.global)) {
        log.info("Logging to {s}", .{LogFile.global.path()});
    } else |err| log.warn("No log file in {s}: {t}", .{ dir, err });
    // Ours, since it must match the game's arch
    var handler_buf: [1100]u8 = undefined;
    const handler = std.fmt.bufPrint(&handler_buf, "{s}{c}crash{c}wraith_crashhandler_{t}.exe", .{ wraith_dir, std.fs.path.sep, std.fs.path.sep, core.arch.native }) catch null;
    crash.install(dir, exe, pid, handler);
}

fn findLocations(allocator: std.mem.Allocator) !core.Locations {
    const root_override = try wraith_platform.process.envAlloc(allocator, "WRAITH_ROOT");
    defer if (root_override) |r| allocator.free(r);
    const local = try wraith_platform.process.envAlloc(allocator, "LOCALAPPDATA");
    defer if (local) |l| allocator.free(l);
    const locations = try core.Locations.init(allocator, .{ .root_override = root_override, .local_app_data = local });
    log.info("Wraith root: {s}", .{locations.root});
    return locations;
}

fn openLoader(allocator: std.mem.Allocator, io: std.Io, info: *const RuntimeInfo, locations: core.Locations, config_root: []const u8, game_dir: []const u8) !PluginLoader {
    const dev_file = try core.dev_plugins.pathAlloc(allocator, locations);
    errdefer allocator.free(dev_file);
    log.info("Mods from {s}", .{locations.mods});
    const plugins_dir = try allocator.dupe(u8, locations.mods);
    errdefer allocator.free(plugins_dir);
    const copies_dir = try std.fs.path.join(allocator, &.{ info.temp_dir.slice(), "plugins" });
    errdefer allocator.free(copies_dir);
    const cache_dir = try locations.path(allocator, "cache");
    errdefer allocator.free(cache_dir);
    const config_dir = try allocator.dupe(u8, config_root);
    errdefer allocator.free(config_dir);
    const game_config_dir = try allocator.dupe(u8, game_dir);
    return PluginLoader.init(allocator, io, .{ .plugins = plugins_dir, .dev_plugins = dev_file, .copies = copies_dir, .cache = cache_dir, .config = config_dir, .game_config = game_config_dir });
}
