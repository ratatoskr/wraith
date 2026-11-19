//! The wraith command.

const std = @import("std");

const core = @import("wraith_core");
const proxy_info = @import("wraith_proxy_info");

const ops = @import("ops.zig");
const processes = @import("processes.zig");
const anticheat = @import("wraith_game").anticheat;
const serve = @import("serve.zig");
const mods = @import("mods.zig");
const sdk = @import("sdk.zig");
const dev = @import("dev.zig");
const import_cmd = @import("import.zig");

const log = core.log.scoped(.wraith_cli);

const Command = enum { help, ps, games, exes, identify, inject, launch, play, watch, install, uninstall, mods, dev, sdk, import, serve };

const help_text =
    \\Usage: wraith [--console] <command>
    \\  --console                            the game gets a console with wraith's log from the
    \\                                       start (inject, launch, watch, play without --proxy)
    \\Commands:
    \\  help
    \\  ps [--all]                           running programs with windows, likeliest games
    \\                                       first (--all: windowless ones too)
    \\  games                                the games installed from Steam, GOG, Epic and Xbox,
    \\                                       plus the ones you added
    \\  games add <path to game.exe>         add a game no store knows about
    \\  games remove <game id>               take a game you added off the list
    \\  identify <path to game.exe>          which game it is: its ID (what's kept for it, its
    \\                                       settings, is under that), store and name
    \\  inject <process name or pid>         into a running game
    \\  launch <path to game.exe> [args...]  start the game, injected as it starts
    \\  watch <game.exe | folder>            wait for the game to be started (by Steam, a
    \\                                       launcher, ...), injected as it starts; a folder:
    \\                                       whatever starts from it (the game's, from `games`)
    \\  play <game id> [game.exe] [--proxy]  start an installed game (see `games`) with wraith in
    \\                                       it: through its store (Steam, Epic), or its exe.
    \\                                       game.exe (see `exes`): the one to go into, rather
    \\                                       than whatever starts from its folder. --proxy: by
    \\                                       wraith's proxy DLL beside it, not injecting
    \\  exes <game id>                       the exes it could be started from
    \\  install <path to game.exe> [--as <dll>]
    \\                                       put a proxy DLL in the game's folder: the game loads
    \\                                       wraith itself, however it's started. It's version.dll
    \\                                       unless --as picks another (winmm, dinput8, dsound,
    \\                                       winhttp), for a game that doesn't load version.dll or
    \\                                       a folder where another mod already has one
    \\  uninstall <path to game.exe>         take it out again
    \\
++ mods.usage ++
    \\
++ dev.usage ++
    \\
++ sdk.usage ++
    \\
++ import_cmd.usage ++
    \\
    \\  serve                                take requests as JSON lines on stdin (for the
    \\                                       Wraith app)
;

pub fn main(init: std.process.Init) !void {
    var gpa: core.allocator.Default = .init();
    defer if (gpa.deinit() != 0) log.warn("Leaked memory (listed above)", .{});
    const allocator = gpa.allocator();
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    var first = args.next();
    const console = if (first) |f| std.mem.eql(u8, f, "--console") else false;
    if (console) first = args.next();
    const command = std.meta.stringToEnum(Command, first orelse "help") orelse .help;
    // No banner for `sdk`, which runs in plugin builds, or `serve`, which talks to the app
    if (command != .serve and command != .sdk) core.logo.print();

    const dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(dir);
    const ctx: ops.Context = .{ .allocator = allocator, .io = io, .dir = dir, .console = console };

    switch (command) {
        .help => log.printLn(help_text, .{}),
        .ps => {
            const all = if (args.next()) |flag| std.mem.eql(u8, flag, "--all") else false;
            var arena: std.heap.ArenaAllocator = .init(allocator);
            defer arena.deinit();
            const found = processes.list(arena.allocator(), io, .{ .all = all }) catch |err| {
                log.err("Couldn't list processes: {t}", .{err});
                std.process.exit(2);
            };
            const running = anticheat.system(arena.allocator()) catch &.{};
            for (running) |ac| log.printLn("Anti-cheat running: {s} ({s})", .{ ac.product.label(), ac.file });
            log.printLn("{s: >5} {s: >7}  {s: <4} {s: <32} {s}", .{ "score", "pid", "arch", "name", "hints" });
            for (found) |p| {
                var score_buf: [12]u8 = undefined;
                const score = std.fmt.bufPrint(&score_buf, "{d}", .{p.score}) catch unreachable;
                log.print("{s: >5} {d: >7}  {s: <4} {s: <32}", .{ score, p.pid, if (p.arch) |a| @tagName(a) else "?", p.name });
                for (p.hints, 0..) |hint, i| log.print("{s}{t}", .{ if (i == 0) " " else ", ", hint });
                if (p.wraith) log.print("  [wraith]", .{});
                for (p.anticheat) |ac| log.print("  [anti-cheat: {s}]", .{ac.product.label()});
                if (p.windowed and !p.inspected) log.print("  (can't look inside: elevated?)", .{});
                log.print("\n", .{});
            }
        },
        .games => {
            var arena: std.heap.ArenaAllocator = .init(allocator);
            defer arena.deinit();
            if (args.next()) |sub| {
                const what = args.next() orelse {
                    log.err("Usage: wraith games add <path to game.exe> | wraith games remove <game id>", .{});
                    std.process.exit(1);
                };
                if (std.mem.eql(u8, sub, "add")) {
                    _ = ops.addGame(ctx, arena.allocator(), what) catch |err| {
                        log.err("Couldn't add {s}: {t}", .{ what, err });
                        std.process.exit(2);
                    };
                } else if (std.mem.eql(u8, sub, "remove")) {
                    const removed = ops.removeGame(ctx, arena.allocator(), what) catch |err| {
                        log.err("Couldn't remove {s}: {t}", .{ what, err });
                        std.process.exit(2);
                    };
                    if (!removed) {
                        log.err("{s} isn't one you added", .{what});
                        std.process.exit(1);
                    }
                    log.info("Removed {s}", .{what});
                } else {
                    log.err("Usage: wraith games add <path to game.exe> | wraith games remove <game id>", .{});
                    std.process.exit(1);
                }
                return;
            }
            const found = ops.discover(ctx, arena.allocator()) catch |err| {
                log.err("Couldn't list the games: {t}", .{err});
                std.process.exit(2);
            };
            log.printLn("{s: <5} {s: <40} {s: <32} {s}", .{ "store", "name", "id", "starts with" });
            for (found) |g| {
                const starts: []const u8 = switch (g.launch.start) {
                    .store => |link| link,
                    .exe => |exe| exe,
                    .none => "(you start it)",
                };
                log.printLn("{t: <5} {s: <40} {s: <32} {s}{s}", .{ g.store, g.name orelse "?", g.id, starts, if (g.added) "  (added)" else "" });
            }
            log.printLn("{d} games", .{found.len});
        },
        .identify => {
            const path = args.next() orelse {
                log.err("No game given. Usage: wraith identify <path to game.exe>", .{});
                std.process.exit(1);
            };
            var arena: std.heap.ArenaAllocator = .init(allocator);
            defer arena.deinit();
            const found = ops.identify(ctx, arena.allocator(), path) catch std.process.exit(2);
            log.printLn("{s}  ({t}{s}{s})", .{ found.id, found.store, if (found.name != null) ": " else "", found.name orelse "" });
            log.printLn("Installed in {s}", .{found.dir});
        },
        .inject => {
            const target = args.next() orelse {
                log.err("No process given. Usage: wraith inject <process name or pid>", .{});
                std.process.exit(1);
            };
            _ = ops.injectRunning(ctx, target) catch |err| {
                log.err("Injection failed: {t}", .{err});
                std.process.exit(2);
            };
        },
        .launch => {
            const path = args.next() orelse {
                log.err("No game given. Usage: wraith launch <path to game.exe> [args...]", .{});
                std.process.exit(1);
            };
            var game_args: std.ArrayList([]const u8) = .empty;
            defer game_args.deinit(allocator);
            while (args.next()) |arg| try game_args.append(allocator, arg);
            _ = ops.launch(ctx, path, game_args.items) catch |err| {
                log.err("Launch failed: {t}", .{err});
                std.process.exit(2);
            };
        },
        .install, .uninstall => |c| {
            const path = args.next() orelse {
                log.err("No game given. Usage: wraith {t} <path to game.exe>", .{c});
                std.process.exit(1);
            };
            var as: proxy_info.Proxy = proxy_info.proxies[0];
            if (c == .install) if (args.next()) |flag| {
                const name = if (std.mem.eql(u8, flag, "--as")) args.next() else null;
                as = proxy_info.Proxy.find(name orelse "") orelse {
                    log.err("Usage: wraith install <path to game.exe> [--as <dll>], where <dll> is one of:", .{});
                    for (proxy_info.proxies) |p| log.err("  {s}", .{p.name});
                    std.process.exit(1);
                };
            };
            if (c == .install) {
                _ = ops.install(ctx, path, as) catch |err| {
                    log.err("Install failed: {t}", .{err});
                    std.process.exit(2);
                };
            } else {
                _ = ops.uninstall(ctx, path) catch |err| {
                    log.err("Uninstall failed: {t}", .{err});
                    std.process.exit(2);
                };
            }
        },
        .watch => {
            const what = args.next() orelse {
                log.err("No game given. Usage: wraith watch <game.exe | folder>", .{});
                std.process.exit(1);
            };
            const target: ops.WatchTarget = if (std.ascii.endsWithIgnoreCase(what, ".exe"))
                .{ .name = std.fs.path.basename(what) }
            else
                .{ .folder = std.Io.Dir.cwd().realPathFileAlloc(io, what, allocator) catch |err| {
                    log.err("Couldn't find the folder {s}: {t}", .{ what, err });
                    std.process.exit(1);
                } };
            defer if (target == .folder) allocator.free(target.folder);
            _ = ops.watch(ctx, target, .{}) catch |err| {
                log.err("Watching failed: {t}", .{err});
                std.process.exit(2);
            };
        },
        .play => {
            const id = args.next() orelse {
                log.err("No game given. Usage: wraith play <game id> [game.exe] [--proxy] (see wraith games)", .{});
                std.process.exit(1);
            };
            var exe: ?[]const u8 = null;
            var how: ops.How = .inject;
            while (args.next()) |arg| {
                if (std.mem.eql(u8, arg, "--proxy")) how = .proxy else exe = arg;
            }
            var arena: std.heap.ArenaAllocator = .init(allocator);
            defer arena.deinit();
            const exe_path = if (exe) |e| std.Io.Dir.cwd().realPathFileAlloc(io, e, arena.allocator()) catch |err| {
                log.err("Couldn't find {s}: {t}", .{ e, err });
                std.process.exit(1);
            } else null;
            _ = ops.play(ctx, arena.allocator(), id, exe_path, how, .{}) catch |err| {
                log.err("Playing failed: {t}", .{err});
                std.process.exit(2);
            };
        },
        .exes => {
            const id = args.next() orelse {
                log.err("No game given. Usage: wraith exes <game id> (see wraith games)", .{});
                std.process.exit(1);
            };
            var arena: std.heap.ArenaAllocator = .init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const found = for (ops.discover(ctx, a) catch std.process.exit(2)) |g| {
                if (std.mem.eql(u8, g.id, id)) break g;
            } else {
                log.err("No game {s} is installed (see wraith games)", .{id});
                std.process.exit(1);
            };
            for (ops.executables(ctx, a, found.dir, found.store_exe) catch std.process.exit(2)) |e| {
                log.printLn("{Bi: >9.1}  {s}{s}", .{ e.size, e.path, if (e.store) "  (the store's)" else "" });
            }
        },
        .mods => {
            const code = mods.run(ctx, &args) catch |err| {
                log.err("Failed: {t}", .{err});
                std.process.exit(2);
            };
            if (code != 0) std.process.exit(code);
        },
        .dev => {
            const code = dev.run(ctx, &args) catch |err| {
                log.err("Failed: {t}", .{err});
                std.process.exit(2);
            };
            if (code != 0) std.process.exit(code);
        },
        .sdk => {
            const code = sdk.run(ctx, &args) catch |err| {
                log.err("Failed: {t}", .{err});
                std.process.exit(2);
            };
            if (code != 0) std.process.exit(code);
        },
        .import => {
            const code = import_cmd.run(ctx, &args) catch |err| {
                log.err("Failed: {t}", .{err});
                std.process.exit(2);
            };
            if (code != 0) std.process.exit(code);
        },
        .serve => {
            serve.run(ctx) catch std.process.exit(2);
            // Requests like `watch` may still be running. They end with the process
            std.process.exit(0);
        },
    }
}

test {
    _ = ops;
    _ = processes;
    _ = serve;
    _ = mods;
    _ = sdk;
    _ = dev;
    _ = import_cmd;
    _ = @import("deps.zig");
}
