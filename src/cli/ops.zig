//! What `wraith` does, shared by the commands and `serve`.

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const core = @import("wraith_core");
const games = @import("wraith_game");
const platform = @import("wraith_platform");
const inject = @import("tuft_inject");
const proxy_info = @import("wraith_proxy_info");

const log = core.log.scoped(.wraith_cli);

pub fn bootstrapDll(arch: inject.Arch) []const u8 {
    return switch (arch) {
        .x86 => "wraith_bootstrap_x86.dll",
        .x64 => "wraith_bootstrap_x64.dll",
    };
}

pub fn isBootstrap(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, bootstrapDll(.x86)) or std.ascii.eqlIgnoreCase(name, bootstrapDll(.x64));
}
const init_export = "wraith_bootstrap_init";

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    /// Asks the game for a console from the start, which players never get otherwise.
    console: bool = false,
};

pub const Injected = struct {
    pid: u32,
    arch: inject.Arch,
    reloaded: bool,
};

pub fn injectRunning(ctx: Context, target: []const u8) !Injected {
    const pid = try resolvePid(target);
    log.info("Target '{s}' is pid {d}", .{ target, pid });

    var process = try inject.Process.open(pid);
    defer process.close();
    const arch = process.arch();
    log.info("Architecture: {s}", .{@tagName(arch)});

    // An x86 launcher can't reach an x64 game
    if (arch != inject.self_arch and inject.self_arch == .x86) return error.ArchMismatch;

    const dll_path = try bootstrapPath(ctx, arch);
    defer ctx.allocator.free(dll_path);
    log.info("Injecting {s}...", .{std.fs.path.basename(dll_path)});

    const already_loaded = process.findModule(bootstrapDll(arch)) catch null;
    try process.loadLibrary(ctx.allocator, dll_path, .{});

    try initBootstrap(ctx, &process, 0);

    if (already_loaded != null) {
        log.info("Asked the running wraith runtime to reload", .{});
    } else {
        log.info("Injected wraith", .{});
    }
    return .{ .pid = pid, .arch = arch, .reloaded = already_loaded != null };
}

pub fn launch(ctx: Context, exe: []const u8, args: []const []const u8) !u32 {
    log.info("Starting {s}...", .{exe});
    var spawned = try inject.spawn(ctx.allocator, exe, .{ .args = args, .cwd = std.fs.path.dirname(exe) });
    defer spawned.close();
    injectStarting(ctx, spawned.pid, started_with_game) catch |err| {
        // We started it but couldn't inject, so don't leave it running without wraith
        spawned.terminate();
        return err;
    };
    return spawned.pid;
}

pub const WatchOptions = struct {
    /// Set from another thread to stop waiting.
    cancel: ?*const Atomic(bool) = null,
    on_attached: ?Listener = null,
    open: ?[]const u8 = null,
    start: ?[]const u8 = null,

    pub const Listener = struct {
        context: ?*anyopaque,
        call: *const fn (context: ?*anyopaque, pid: u32) void,
    };
};

pub const WatchTarget = inject.Target;

/// E.g. a game started outside Steam gets Steam to start it again.
const max_restarts = 5;
const restart_window_ms = 10_000;
const restart_start_ms = 30_000;
const cancel_check_ms = 250;

/// If that copy exits soon after, like a launcher stub, we get the next one. Null if cancelled.
pub fn watch(ctx: Context, target: WatchTarget, options: WatchOptions) !?u32 {
    const what = switch (target) {
        .name, .path, .folder => |s| s,
    };
    log.info("Waiting for {s}{s} to start...", .{ if (target == .folder) "a game from " else "", what });
    var w = try inject.Watch.init(target, .{});
    if (options.open) |uri| try openUri(ctx, uri);
    if (options.start) |exe| try startPlain(ctx, exe);
    // Wait as long as it takes for the first start
    var timeout_ms: ?u32 = null;
    var restarts: u32 = 0;
    var attached: ?u32 = null;
    while (true) {
        const pid = (waitStart(&w, timeout_ms, options.cancel) catch |err| switch (err) {
            error.Timeout => {
                log.info("No new copy started (closed, rather than restarted?)", .{});
                return attached;
            },
            else => return err,
        }) orelse {
            log.info("Stopped waiting for {s}", .{what});
            return attached;
        };
        injectRetrying(ctx, pid, options.cancel) catch |err| {
            if (!exitsWithin(pid, 0) or restarts == max_restarts) return err;
            restarts += 1;
            log.info("pid {d} exited before wraith was in (restarting itself, through Steam say); waiting for the next...", .{pid});
            w.ignore(pid);
            timeout_ms = restart_start_ms;
            continue;
        };
        attached = pid;
        if (options.on_attached) |l| l.call(l.context, pid);
        if (restarts == max_restarts) return pid;
        log.info("Checking that it doesn't restart itself...", .{});
        if (!exitsWithin(pid, restart_window_ms)) return pid;
        restarts += 1;
        log.info("pid {d} exited (restarting itself, through Steam say); waiting for the next...", .{pid});
        w.ignore(pid);
        timeout_ms = restart_start_ms;
    }
}

fn waitStart(w: *inject.Watch, timeout_ms: ?u32, cancel: ?*const Atomic(bool)) !?u32 {
    w.options.timeout_ms = cancel_check_ms;
    var waited: u32 = 0;
    while (true) {
        if (cancel) |c| if (c.load(.acquire)) return null;
        if (w.wait()) |pid| return pid else |err| switch (err) {
            error.Timeout => {},
            else => return err,
        }
        waited += cancel_check_ms;
        if (timeout_ms) |t| if (waited >= t) return error.Timeout;
    }
}

fn exitsWithin(pid: u32, timeout_ms: u32) bool {
    var process = inject.Process.open(pid) catch |err| {
        if (err == error.ProcessNotFound) return true;
        inject.sleepMs(timeout_ms);
        return false;
    };
    defer process.close();
    return process.exitsWithin(timeout_ms);
}

const retry_ms = 30_000;
const retry_step_ms = 500;

/// Retries while it starts.
fn injectRetrying(ctx: Context, pid: u32, cancel: ?*const Atomic(bool)) !void {
    var waited: u32 = 0;
    var flags = started_with_game;
    while (true) {
        injectStarting(ctx, pid, flags) catch |err| {
            log.warn("Couldn't get into pid {d}: {t}", .{ pid, err });
            if (waited >= retry_ms) return err;
            if (cancel) |c| if (c.load(.acquire)) return err;
            if (exitsWithin(pid, retry_step_ms)) return err;
            waited += retry_step_ms;
            // By now it may be rendering
            flags = 0;
            log.info("pid {d} is still running, trying again...", .{pid});
            continue;
        };
        return;
    }
}

fn injectStarting(ctx: Context, pid: u32, flags: u32) !void {
    var process = try inject.Process.open(pid);
    defer process.close();
    const arch = process.arch();
    log.info("Game is pid {d} ({s})", .{ pid, @tagName(arch) });
    if (arch != inject.self_arch and inject.self_arch == .x86) return error.ArchMismatch;

    const dll_path = try bootstrapPath(ctx, arch);
    defer ctx.allocator.free(dll_path);
    log.info("Injecting {s}...", .{std.fs.path.basename(dll_path)});
    try inject.injectStarting(ctx.allocator, pid, dll_path, .{});
    try initBootstrap(ctx, &process, flags);
    log.info("Injected wraith", .{});
}

const started_with_game = core.runtime_abi.BootstrapFlags.started_with_game;

fn initBootstrap(ctx: Context, process: *const inject.Process, given: u32) !void {
    const allocator = ctx.allocator;
    const flags = given | if (ctx.console) core.runtime_abi.BootstrapFlags.console else 0;
    const bootstrap_dll = bootstrapDll(process.arch());
    const module = process.findModule(bootstrap_dll) catch |err| {
        log.err("{s} was loaded, but can't be found in the game: {t}", .{ bootstrap_dll, err });
        return err;
    };
    const init = process.findExport(allocator, module, init_export) catch |err| {
        log.err("Can't find {s}'s {s}: {t}", .{ bootstrap_dll, init_export, err });
        return err;
    };
    const status = process.call(init, flags, .{}) catch |err| {
        log.err("Couldn't call {s}'s {s}: {t}", .{ bootstrap_dll, init_export, err });
        return err;
    };
    if (status != 0) {
        log.err("{s} failed ({d}): see the game's wraith log", .{ init_export, status });
        return error.BootstrapInitFailed;
    }
}

pub const Presence = enum { missing, ours, theirs };

pub const Inspection = struct {
    arch: inject.Arch,
    proxies: [proxy_info.proxies.len]Presence,

    pub fn installed(self: *const Inspection) ?proxy_info.Proxy {
        for (proxy_info.proxies, self.proxies) |p, presence| {
            if (presence == .ours) return p;
        }
        return null;
    }
};

pub fn inspect(ctx: Context, game_exe: []const u8) !Inspection {
    const game_dir = std.fs.path.dirname(game_exe) orelse return error.NoGameFolder;
    var result: Inspection = .{ .arch = try exeArch(ctx.io, game_exe), .proxies = undefined };
    for (proxy_info.proxies, &result.proxies) |p, *presence| {
        const path = try std.fs.path.join(ctx.allocator, &.{ game_dir, p.name });
        defer ctx.allocator.free(path);
        presence.* = try presenceOf(ctx, path);
    }
    return result;
}

pub fn identify(ctx: Context, arena: std.mem.Allocator, exe: []const u8) !games.Game {
    const path = if (std.fs.path.isAbsolute(exe)) exe else std.Io.Dir.cwd().realPathFileAlloc(ctx.io, exe, arena) catch |err| {
        log.err("Couldn't find {s}: {t}", .{ exe, err });
        return err;
    };
    return games.identify(arena, ctx.io, path, .{});
}

pub fn discover(ctx: Context, arena: std.mem.Allocator) ![]const games.Game {
    return games.discover(arena, ctx.io, try gameOptions(ctx, arena));
}

pub fn addGame(ctx: Context, arena: std.mem.Allocator, exe: []const u8) !games.Game {
    const path = if (std.fs.path.isAbsolute(exe)) exe else try std.Io.Dir.cwd().realPathFileAlloc(ctx.io, exe, arena);
    const result = try games.add(arena, ctx.io, path, try gameOptions(ctx, arena));
    const g = result.game;
    if (result.new) log.info("Added {s} ({s})", .{ g.name orelse g.id, g.id }) else log.info("{s} is already listed ({s})", .{ g.name orelse g.id, g.id });
    return g;
}

pub fn removeGame(ctx: Context, arena: std.mem.Allocator, id: []const u8) !bool {
    return games.remove(arena, ctx.io, id, try gameOptions(ctx, arena));
}

pub fn locations(arena: std.mem.Allocator) !core.Locations {
    return core.Locations.init(arena, .{
        .root_override = try platform.process.envAlloc(arena, "WRAITH_ROOT"),
        .local_app_data = try platform.process.envAlloc(arena, "LOCALAPPDATA"),
    });
}

fn gameOptions(ctx: Context, arena: std.mem.Allocator) !games.Options {
    _ = ctx;
    const l = try locations(arena);
    return .{ .added = try std.fs.path.join(arena, &.{ l.root, "settings", "games.zon" }) };
}

pub const How = enum {
    inject,
    proxy,
};

pub fn play(ctx: Context, arena: std.mem.Allocator, id: []const u8, picked: ?[]const u8, how: How, options: WatchOptions) !?u32 {
    const game = for (try discover(ctx, arena)) |g| {
        if (std.mem.eql(u8, g.id, id)) break g;
    } else {
        log.err("No game {s} is installed", .{id});
        return error.GameNotFound;
    };
    const name = game.name orelse game.id;
    const plan = game.launch.withPick(picked);

    // Already has a proxy, so the game loads wraith itself however it starts
    const installed = if (plan.game_exe) |e| (try inspect(ctx, e)).installed() else null;
    if (how == .proxy or installed != null) {
        const target = plan.game_exe orelse {
            log.err("Which exe of {s} is the game? The proxy goes beside it", .{name});
            return error.NoExe;
        };
        if (installed) |proxy| {
            // From an older wraith or pointing at one. Swap in ours
            if (!try isCurrent(ctx, target, proxy)) {
                log.info("Updating wraith's {s} beside {s}", .{ proxy.name, name });
                _ = install(ctx, target, proxy) catch |err| log.warn("Couldn't update it ({t}): is the game running? The older wraith loads this time", .{err});
            }
        } else _ = try install(ctx, target, proxy_info.proxies[0]);
        switch (plan.start) {
            .store => |uri| try openUri(ctx, uri),
            .exe => |exe| try startPlain(ctx, exe),
            .none => log.info("Start {s} from {t}: it loads wraith itself", .{ name, game.store }),
        }
        return null;
    }

    if (plan.startsGame()) {
        const pid = try launch(ctx, plan.start.exe, &.{});
        if (options.on_attached) |l| l.call(l.context, pid);
        return pid;
    }
    const target: WatchTarget = if (plan.game_exe) |e| .{ .path = e } else .{ .folder = game.dir };
    var then = options;
    switch (plan.start) {
        .store => |uri| {
            log.info("Starting {s} through {t}", .{ name, game.store });
            then.open = uri;
        },
        .exe => |exe| {
            log.info("Starting {s} from {s}: wraith goes in when the game starts", .{ name, std.fs.path.basename(exe) });
            then.start = exe;
        },
        .none => log.info("Start {s} from {t}: wraith goes in as it starts", .{ name, game.store }),
    }
    return watch(ctx, target, then);
}

fn openUri(ctx: Context, uri: []const u8) !void {
    log.info("Opening {s}", .{uri});
    platform.process.openUri(ctx.allocator, uri) catch |err| {
        log.err("Couldn't open {s}: {t}", .{ uri, err });
        return err;
    };
}

fn startPlain(ctx: Context, exe: []const u8) !void {
    log.info("Starting {s}...", .{exe});
    var spawned = try inject.spawn(ctx.allocator, exe, .{ .cwd = std.fs.path.dirname(exe) });
    spawned.close();
}

pub fn executables(ctx: Context, arena: std.mem.Allocator, dir: []const u8, store_exe: ?[]const u8) ![]const games.Exe {
    return games.exes.list(arena, ctx.io, dir, store_exe);
}

/// Removes any other proxy of ours there so wraith only loads once.
pub fn install(ctx: Context, game_exe: []const u8, as: proxy_info.Proxy) !inject.Arch {
    const allocator = ctx.allocator;
    const io = ctx.io;
    const game_dir = std.fs.path.dirname(game_exe) orelse return error.NoGameFolder;
    const arch = try exeArch(io, game_exe);
    const cwd = std.Io.Dir.cwd();

    var file_buf: [64]u8 = undefined;
    const source = try std.fs.path.join(allocator, &.{ ctx.dir, proxy_info.dir, try as.file(&file_buf, @tagName(arch)) });
    defer allocator.free(source);
    const dest = try std.fs.path.join(allocator, &.{ game_dir, as.name });
    defer allocator.free(dest);
    switch (try presenceOf(ctx, dest)) {
        .missing, .ours => {},
        .theirs => {
            log.err("{s} already has a {s} that isn't wraith's (another mod's?), so not replacing it. Try `--as` with another DLL", .{ game_dir, as.name });
            return error.NotOurs;
        },
    }
    for (proxy_info.proxies) |p| {
        if (std.mem.eql(u8, p.name, as.name)) continue;
        const other = try std.fs.path.join(allocator, &.{ game_dir, p.name });
        defer allocator.free(other);
        if (try presenceOf(ctx, other) == .ours) {
            try cwd.deleteFile(io, other);
            log.info("Removed wraith's {s} from {s} (replaced by {s})", .{ p.name, game_dir, as.name });
        }
    }
    try std.Io.Dir.copyFile(cwd, source, cwd, dest, io, .{});
    log.info("Installed {s} ({s}) in {s}", .{ as.name, @tagName(arch), game_dir });

    const init_path = try std.fs.path.join(allocator, &.{ game_dir, proxy_info.init_file });
    defer allocator.free(init_path);
    var init: std.Io.Writer.Allocating = .init(allocator);
    defer init.deinit();
    try std.zon.stringify.serialize(proxy_info.Init{ .wraith_dir = ctx.dir }, .{}, &init.writer);
    try init.writer.writeByte('\n');
    try cwd.writeFile(io, .{ .sub_path = init_path, .data = init.written() });
    log.info("The game loads wraith from {s} whenever it starts; `wraith uninstall` to stop it", .{ctx.dir});
    return arch;
}

pub fn isCurrent(ctx: Context, game_exe: []const u8, proxy: proxy_info.Proxy) !bool {
    const allocator = ctx.allocator;
    const io = ctx.io;
    const cwd = std.Io.Dir.cwd();
    const game_dir = std.fs.path.dirname(game_exe) orelse return error.NoGameFolder;
    const arch = try exeArch(io, game_exe);

    var file_buf: [64]u8 = undefined;
    const source = try std.fs.path.join(allocator, &.{ ctx.dir, proxy_info.dir, try proxy.file(&file_buf, @tagName(arch)) });
    defer allocator.free(source);
    const dest = try std.fs.path.join(allocator, &.{ game_dir, proxy.name });
    defer allocator.free(dest);
    const ours = try cwd.readFileAlloc(io, source, allocator, .limited(64 << 20));
    defer allocator.free(ours);
    const theirs = cwd.readFileAlloc(io, dest, allocator, .limited(64 << 20)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(theirs);
    if (!std.mem.eql(u8, ours, theirs)) return false;

    const init_path = try std.fs.path.join(allocator, &.{ game_dir, proxy_info.init_file });
    defer allocator.free(init_path);
    const text = cwd.readFileAllocOptions(io, init_path, allocator, .limited(64 << 10), .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(text);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const init = std.zon.parse.fromSlice(proxy_info.Init, .{
        .gpa = allocator,
        .arena = arena.allocator(),
        .source = text,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch return false;
    return std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, init.wraith_dir, "\\/"), std.mem.trimEnd(u8, ctx.dir, "\\/"));
}

pub fn uninstall(ctx: Context, game_exe: []const u8) !bool {
    const allocator = ctx.allocator;
    const game_dir = std.fs.path.dirname(game_exe) orelse return error.NoGameFolder;
    const cwd = std.Io.Dir.cwd();
    var removed = false;
    for (proxy_info.proxies) |p| {
        const dest = try std.fs.path.join(allocator, &.{ game_dir, p.name });
        defer allocator.free(dest);
        if (try presenceOf(ctx, dest) == .ours) {
            try cwd.deleteFile(ctx.io, dest);
            log.info("Removed {s} from {s}", .{ p.name, game_dir });
            removed = true;
        }
    }
    if (!removed) log.info("wraith isn't installed in {s}", .{game_dir});
    const init_path = try std.fs.path.join(allocator, &.{ game_dir, proxy_info.init_file });
    defer allocator.free(init_path);
    cwd.deleteFile(ctx.io, init_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    return removed;
}

fn presenceOf(ctx: Context, path: []const u8) !Presence {
    const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.allocator, .limited(64 << 20)) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };
    defer ctx.allocator.free(data);
    return if (std.mem.indexOf(u8, data, proxy_info.marker) != null) .ours else .theirs;
}

/// What the exe at `path` was built for, from its PE header.
pub fn exeArch(io: std.Io, path: []const u8) !inject.Arch {
    var buf: [4096]u8 = undefined;
    const head = std.Io.Dir.cwd().readFile(io, path, &buf) catch |err| {
        log.err("Can't read {s}: {t}", .{ path, err });
        return err;
    };
    if (head.len < 0x40 or !std.mem.eql(u8, head[0..2], "MZ")) return error.NotAnExe;
    const pe = std.mem.readInt(u32, head[0x3C..][0..4], .little);
    if (pe + 6 > head.len or !std.mem.eql(u8, head[pe..][0..4], "PE\x00\x00")) return error.NotAnExe;
    return switch (std.mem.readInt(u16, head[pe + 4 ..][0..2], .little)) {
        0x014C => .x86, // IMAGE_FILE_MACHINE_I386
        0x8664 => .x64, // IMAGE_FILE_MACHINE_AMD64
        else => error.UnsupportedArch,
    };
}

fn resolvePid(target: []const u8) !u32 {
    if (std.fmt.parseInt(u32, target, 10)) |pid| return pid else |_| {}
    return inject.findPid(target);
}

fn bootstrapPath(ctx: Context, arch: inject.Arch) ![]u8 {
    return std.fs.path.join(ctx.allocator, &.{ ctx.dir, bootstrapDll(arch) });
}

const tests = struct {
    const testing = std.testing;

    test "inspecting a game" {
        const allocator = testing.allocator;
        const io = testing.io;
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(dir);
        const ctx: Context = .{ .allocator = allocator, .io = io, .dir = dir };

        // Smallest PE header that says x86, ours as winmm.dll, and someone else's version.dll
        var exe: [0x48]u8 = @splat(0);
        exe[0..2].* = "MZ".*;
        std.mem.writeInt(u32, exe[0x3C..][0..4], 0x40, .little);
        exe[0x40..0x44].* = "PE\x00\x00".*;
        std.mem.writeInt(u16, exe[0x44..][0..2], 0x014C, .little);
        try tmp.dir.writeFile(io, .{ .sub_path = "game.exe", .data = &exe });
        try tmp.dir.writeFile(io, .{ .sub_path = "winmm.dll", .data = "...." ++ proxy_info.marker ++ "...." });
        try tmp.dir.writeFile(io, .{ .sub_path = "version.dll", .data = "someone else's" });

        const game = try std.fs.path.join(allocator, &.{ dir, "game.exe" });
        defer allocator.free(game);
        const found = try inspect(ctx, game);
        try testing.expectEqual(.x86, found.arch);
        try testing.expectEqualStrings("winmm.dll", found.installed().?.name);
        try testing.expectEqual(.theirs, found.proxies[0]);

        try testing.expect(try uninstall(ctx, game));
        try testing.expectEqual(null, (try inspect(ctx, game)).installed());
        // Someone else's gets left alone
        try testing.expectEqual(.theirs, (try inspect(ctx, game)).proxies[0]);
    }

    test "proxy currency" {
        const allocator = testing.allocator;
        const io = testing.io;
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(root);

        // Two wraith versions, and an x86 game
        for ([_][]const u8{ "v1", "v2" }) |v| {
            const path = try std.fmt.allocPrint(allocator, "{s}/proxies/wraith_version_x86.dll", .{v});
            defer allocator.free(path);
            try tmp.dir.createDirPath(io, std.fs.path.dirname(path).?);
            try tmp.dir.writeFile(io, .{ .sub_path = path, .data = proxy_info.marker ++ " built as " ++ "v1" });
        }
        var exe: [0x48]u8 = @splat(0);
        exe[0..2].* = "MZ".*;
        std.mem.writeInt(u32, exe[0x3C..][0..4], 0x40, .little);
        exe[0x40..0x44].* = "PE\x00\x00".*;
        std.mem.writeInt(u16, exe[0x44..][0..2], 0x014C, .little);
        try tmp.dir.createDirPath(io, "game");
        try tmp.dir.writeFile(io, .{ .sub_path = "game/game.exe", .data = &exe });

        const v1 = try std.fs.path.join(allocator, &.{ root, "v1" });
        defer allocator.free(v1);
        const v2 = try std.fs.path.join(allocator, &.{ root, "v2" });
        defer allocator.free(v2);
        const game = try std.fs.path.join(allocator, &.{ root, "game", "game.exe" });
        defer allocator.free(game);
        const proxy = proxy_info.proxies[0];
        const saved = core.log.mute(&.{.cli});
        defer core.log.setFilter(saved);

        const ctx_v1: Context = .{ .allocator = allocator, .io = io, .dir = v1 };
        _ = try install(ctx_v1, game, proxy);
        try testing.expect(try isCurrent(ctx_v1, game, proxy));

        // Another wraith. Same DLL, but the game points at the other one
        const ctx_v2: Context = .{ .allocator = allocator, .io = io, .dir = v2 };
        try testing.expect(!try isCurrent(ctx_v2, game, proxy));
        _ = try install(ctx_v2, game, proxy);
        try testing.expect(try isCurrent(ctx_v2, game, proxy));

        // A newer DLL from the same wraith
        try tmp.dir.writeFile(io, .{ .sub_path = "v2/proxies/wraith_version_x86.dll", .data = proxy_info.marker ++ " built as v2" });
        try testing.expect(!try isCurrent(ctx_v2, game, proxy));
    }
};

test {
    _ = tests;
}
