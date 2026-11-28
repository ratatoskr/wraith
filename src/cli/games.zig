//! `wraith ps` and `wraith games`: what's running, and what's installed.

const std = @import("std");

const core = @import("wraith_core");
const anticheat = @import("wraith_game").anticheat;
const game_engine = @import("wraith_game").game_engine;

const ops = @import("ops.zig");
const processes = @import("processes.zig");
const cli = @import("args.zig");

const log = core.log.scoped(.wraith_cli);

pub const ps_usage =
    \\  ps [--all]                           running programs with windows, likeliest games
    \\                                       first (--all: windowless ones too)
;

pub const usage =
    \\  games                                the games installed from Steam, GOG, Epic and Xbox,
    \\                                       plus the ones you added
    \\  games add <path to game.exe>         add a game no store knows about
    \\  games remove <game id>               take a game you added off the list
    \\  games identify <path to game.exe>    which game it is: its ID (what's kept for it, its
    \\                                       settings, is under that), store and name
    \\  games exes <game id>                 the exes it could be started from
;

pub fn ps(ctx: ops.Context, args: *cli.Args) !u8 {
    var all = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--all")) all = true else return cli.unexpected(arg, ps_usage);
    }
    var arena: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena.deinit();
    const found = processes.list(arena.allocator(), ctx.io, .{ .all = all }) catch |err| {
        log.err("Couldn't list processes: {t}", .{err});
        return 2;
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
        if (p.game_engine) |e| log.print("  [{s}{s}{s}]", .{ e.game_engine.label(), if (e.variant != null) " " else "", e.variant orelse "" });
        for (p.anticheat) |ac| log.print("  [anti-cheat: {s}]", .{ac.product.label()});
        if (p.windowed and !p.inspected) log.print("  (can't look inside: elevated?)", .{});
        log.print("\n", .{});
    }
    return 0;
}

const Sub = enum { list, add, remove, identify, exes };

pub fn run(ctx: ops.Context, args: *cli.Args) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const first = args.next() orelse "list";
    const sub = std.meta.stringToEnum(Sub, first) orelse return cli.unexpected(first, usage);
    if (sub == .list) {
        if (args.next()) |extra| return cli.unexpected(extra, usage);
        return list(ctx, arena);
    }
    const what = args.next() orelse return cli.usageError(usage);
    if (args.next()) |extra| return cli.unexpected(extra, usage);
    switch (sub) {
        .list => unreachable,
        .add => _ = ops.addGame(ctx, arena, what) catch |err| {
            log.err("Couldn't add {s}: {t}", .{ what, err });
            return 2;
        },
        .remove => {
            const removed = ops.removeGame(ctx, arena, what) catch |err| {
                log.err("Couldn't remove {s}: {t}", .{ what, err });
                return 2;
            };
            if (!removed) {
                log.err("{s} isn't one you added", .{what});
                return 1;
            }
            log.info("Removed {s}", .{what});
        },
        .identify => {
            const found = ops.identify(ctx, arena, what) catch return 2;
            log.printLn("{s}  ({t}{s}{s})", .{ found.id, found.store, if (found.name != null) ": " else "", found.name orelse "" });
            log.printLn("Installed in {s}", .{found.dir});
        },
        .exes => {
            const found = for (ops.discover(ctx, arena) catch return 2) |g| {
                if (std.mem.eql(u8, g.id, what)) break g;
            } else {
                log.err("No game {s} is installed (see wraith games)", .{what});
                return 1;
            };
            for (ops.executables(ctx, arena, found.dir, found.store_exe) catch return 2) |e| {
                log.printLn("{Bi: >9.1}  {s}{s}", .{ e.size, e.path, if (e.store) "  (the store's)" else "" });
            }
        },
    }
    return 0;
}

fn list(ctx: ops.Context, arena: std.mem.Allocator) !u8 {
    const found = ops.discover(ctx, arena) catch |err| {
        log.err("Couldn't list the games: {t}", .{err});
        return 2;
    };
    log.printLn("{s: <5} {s: <40} {s: <24} {s: <32} {s}", .{ "store", "name", "game engine", "id", "starts with" });
    for (found) |g| {
        var engine_buf: [64]u8 = undefined;
        const made_with: []const u8 = if (game_engine.ofInstall(arena, ctx.io, g.dir) catch null) |e|
            std.fmt.bufPrint(&engine_buf, "{s}{s}{s}", .{ e.game_engine.label(), if (e.variant != null) " " else "", e.variant orelse "" }) catch e.game_engine.label()
        else
            "?";
        const starts: []const u8 = switch (g.launch.start) {
            .store => |link| link,
            .exe => |exe| exe,
            .none => "(you start it)",
        };
        log.printLn("{t: <5} {s: <40} {s: <24} {s: <32} {s}{s}", .{ g.store, g.name orelse "?", made_with, g.id, starts, if (g.added) "  (added)" else "" });
    }
    log.printLn("{d} games", .{found.len});
    return 0;
}
