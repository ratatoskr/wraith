//! Getting Wraith into a game: `inject`, `launch`, `watch`, `play` and `proxy`.

const std = @import("std");

const core = @import("wraith_core");
const proxy_info = @import("wraith_proxy_info");

const ops = @import("ops.zig");
const cli = @import("args.zig");

const log = core.log.scoped(.wraith_cli);

pub const inject_usage =
    \\  inject <process name or pid>         into a running game
;
pub const launch_usage =
    \\  launch <path to game.exe> [args...]  start the game, injected as it starts
;
pub const watch_usage =
    \\  watch <game.exe | folder>            wait for the game to be started (by Steam, a
    \\                                       launcher, ...), injected as it starts; a folder:
    \\                                       whatever starts from it (the game's, from `games`)
;
pub const play_usage =
    \\  play <game id> [game.exe] [--proxy]  start an installed game (see `games`) with wraith in
    \\                                       it: through its store (Steam, Epic), or its exe.
    \\                                       game.exe (see `games exes`): the one to go into, rather
    \\                                       than whatever starts from its folder. --proxy: by
    \\                                       wraith's proxy DLL beside it, not injecting
;
pub const proxy_usage =
    \\  proxy add <path to game.exe> [--as <dll>]
    \\                                       put a proxy DLL in the game's folder: the game loads
    \\                                       wraith itself, however it's started. It's version.dll
    \\                                       unless --as picks another (winmm, dinput8, dsound,
    \\                                       winhttp), for a game that doesn't load version.dll or
    \\                                       a folder where another mod already has one
    \\  proxy remove <path to game.exe>      take it out again
;

/// The one thing it's given, and nothing more.
fn only(args: *cli.Args, usage: []const u8) ?[]const u8 {
    const what = args.next() orelse {
        _ = cli.usageError(usage);
        return null;
    };
    if (args.next()) |extra| {
        _ = cli.unexpected(extra, usage);
        return null;
    }
    return what;
}

pub fn inject(ctx: ops.Context, args: *cli.Args) !u8 {
    const target = only(args, inject_usage) orelse return 1;
    _ = ops.injectRunning(ctx, target) catch |err| {
        log.err("Injection failed: {t}", .{err});
        return 2;
    };
    return 0;
}

pub fn launch(ctx: ops.Context, args: *cli.Args) !u8 {
    const path = args.next() orelse return cli.usageError(launch_usage);
    // The rest are the game's own
    _ = ops.launch(ctx, path, args.rest()) catch |err| {
        log.err("Launch failed: {t}", .{err});
        return 2;
    };
    return 0;
}

pub fn watch(ctx: ops.Context, args: *cli.Args) !u8 {
    const what = only(args, watch_usage) orelse return 1;
    const target: ops.WatchTarget = if (std.ascii.endsWithIgnoreCase(what, ".exe"))
        .{ .name = std.fs.path.basename(what) }
    else
        .{ .folder = std.Io.Dir.cwd().realPathFileAlloc(ctx.io, what, ctx.allocator) catch |err| {
            log.err("Couldn't find the folder {s}: {t}", .{ what, err });
            return 1;
        } };
    defer if (target == .folder) ctx.allocator.free(target.folder);
    _ = ops.watch(ctx, target, .{}) catch |err| {
        log.err("Watching failed: {t}", .{err});
        return 2;
    };
    return 0;
}

pub fn play(ctx: ops.Context, args: *cli.Args) !u8 {
    var id: ?[]const u8 = null;
    var exe: ?[]const u8 = null;
    var how: ops.How = .inject;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--proxy")) {
            how = .proxy;
        } else if (cli.isFlag(arg)) {
            return cli.unexpected(arg, play_usage);
        } else if (id == null) {
            id = arg;
        } else if (exe == null) {
            exe = arg;
        } else return cli.unexpected(arg, play_usage);
    }
    const game = id orelse return cli.usageError(play_usage);
    var arena: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena.deinit();
    const exe_path = if (exe) |e| std.Io.Dir.cwd().realPathFileAlloc(ctx.io, e, arena.allocator()) catch |err| {
        log.err("Couldn't find {s}: {t}", .{ e, err });
        return 1;
    } else null;
    _ = ops.play(ctx, arena.allocator(), game, exe_path, how, .{}) catch |err| {
        log.err("Playing failed: {t}", .{err});
        return 2;
    };
    return 0;
}

pub fn proxy(ctx: ops.Context, args: *cli.Args) !u8 {
    const sub = args.next() orelse return cli.usageError(proxy_usage);
    if (std.mem.eql(u8, sub, "remove")) {
        const path = only(args, proxy_usage) orelse return 1;
        _ = ops.uninstall(ctx, path) catch |err| {
            log.err("Couldn't take it out: {t}", .{err});
            return 2;
        };
        return 0;
    }
    if (!std.mem.eql(u8, sub, "add")) return cli.unexpected(sub, proxy_usage);
    var path: ?[]const u8 = null;
    var as: proxy_info.Proxy = proxy_info.proxies[0];
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--as")) {
            const name = args.value("--as") orelse return 1;
            as = proxy_info.Proxy.find(name) orelse {
                log.err("{s} isn't one it can be. It can be:", .{name});
                for (proxy_info.proxies) |p| log.err("  {s}", .{p.name});
                return 1;
            };
        } else if (path == null and !cli.isFlag(arg)) {
            path = arg;
        } else return cli.unexpected(arg, proxy_usage);
    }
    _ = ops.install(ctx, path orelse return cli.usageError(proxy_usage), as) catch |err| {
        log.err("Couldn't put it in: {t}", .{err});
        return 2;
    };
    return 0;
}
