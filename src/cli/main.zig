//! The wraith command. Each command is a module's `run`, listed in `commands`.

const std = @import("std");

const core = @import("wraith_core");
const build_info = @import("build_info");

const ops = @import("ops.zig");
const cli = @import("args.zig");
const games = @import("games.zig");
const play = @import("play.zig");
const serve = @import("serve.zig");
const mods = @import("mods.zig");
const sdk = @import("sdk.zig");
const dev = @import("dev.zig");
const import_cmd = @import("import.zig");
const new = @import("new.zig");
const pack = @import("pack.zig");
const publish = @import("publish.zig");

const log = core.log.scoped(.wraith_cli);

const Run = *const fn (ops.Context, *cli.Args) anyerror!u8;

const Command = struct {
    name: []const u8,
    usage: []const u8,
    run: Run,
    /// The logo first. Only where a person's watching, not for output others read.
    banner: bool = false,
};

fn wrap(comptime f: anytype) Run {
    return struct {
        fn call(ctx: ops.Context, args: *cli.Args) anyerror!u8 {
            return f(ctx, args);
        }
    }.call;
}

const version_usage =
    \\  version                              this wraith's version
;
const serve_usage =
    \\  serve                                take requests as JSON lines on stdin (for the
    \\                                       Wraith app)
;

/// In the order help lists them.
const commands = [_]Command{
    .{ .name = "new", .usage = new.usage, .run = wrap(new.run), .banner = true },
    .{ .name = "dev", .usage = dev.usage, .run = wrap(dev.run) },
    .{ .name = "sdk", .usage = sdk.usage, .run = wrap(sdk.run) },
    .{ .name = "pack", .usage = pack.usage, .run = wrap(pack.run) },
    .{ .name = "publish", .usage = publish.usage, .run = wrap(publish.run) },
    .{ .name = "import", .usage = import_cmd.usage, .run = wrap(import_cmd.run) },
    .{ .name = "mods", .usage = mods.usage, .run = wrap(mods.run) },
    .{ .name = "games", .usage = games.usage, .run = wrap(games.run) },
    .{ .name = "ps", .usage = games.ps_usage, .run = wrap(games.ps) },
    .{ .name = "play", .usage = play.play_usage, .run = wrap(play.play), .banner = true },
    .{ .name = "launch", .usage = play.launch_usage, .run = wrap(play.launch), .banner = true },
    .{ .name = "watch", .usage = play.watch_usage, .run = wrap(play.watch), .banner = true },
    .{ .name = "inject", .usage = play.inject_usage, .run = wrap(play.inject), .banner = true },
    .{ .name = "proxy", .usage = play.proxy_usage, .run = wrap(play.proxy) },
    .{ .name = "version", .usage = version_usage, .run = wrap(version) },
    .{ .name = "serve", .usage = serve_usage, .run = wrap(serveCommand) },
};

const help_text = blk: {
    var text: []const u8 =
        \\Usage: wraith [--console] <command> [--help]
        \\  --console                            the game gets a console with wraith's log from the
        \\                                       start (inject, launch, watch, play without --proxy)
        \\  help [<command>]                     this, or just that command's
        \\
    ;
    for (commands) |c| text = text ++ "\n" ++ c.usage;
    break :blk text;
};

fn find(name: []const u8) ?*const Command {
    for (&commands) |*c| if (std.mem.eql(u8, c.name, name)) return c;
    return null;
}

pub fn main(init: std.process.Init) !void {
    var gpa: core.allocator.Default = .init();
    const allocator = gpa.allocator();
    const code = run(init, allocator) catch |err| blk: {
        log.err("Failed: {t}", .{err});
        break :blk 2;
    };
    if (gpa.deinit() != 0) log.warn("Leaked memory (listed above)", .{});
    // Requests `serve` started, like a watch, end with the process
    std.process.exit(code);
}

fn run(init: std.process.Init, allocator: std.mem.Allocator) !u8 {
    const io = init.io;
    const all = try init.minimal.args.toSlice(init.arena.allocator());
    var args: cli.Args = .{ .items = all, .at = 1 };

    var first = args.next();
    const console = if (first) |f| std.mem.eql(u8, f, "--console") else false;
    if (console) first = args.next();
    const name = first orelse "help";

    if (std.mem.eql(u8, name, "help") or cli.isHelp(name)) {
        const which = args.next() orelse {
            core.logo.print();
            log.printLn("{s}", .{help_text});
            return 0;
        };
        const c = find(which) orelse return unknown(which);
        log.printLn("Usage:\n{s}", .{c.usage});
        return 0;
    }
    if (std.mem.eql(u8, name, "--version")) return version(undefined, &args);
    const command = find(name) orelse return unknown(name);
    // `--help` anywhere asks how it's used, but for a game's own arguments
    if (!std.mem.eql(u8, command.name, "launch")) for (args.items[args.at..]) |arg| if (cli.isHelp(arg)) {
        log.printLn("Usage:\n{s}", .{command.usage});
        return 0;
    };
    if (command.banner) core.logo.print();

    const dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(dir);
    const ctx: ops.Context = .{ .allocator = allocator, .io = io, .dir = dir, .console = console };
    return command.run(ctx, &args);
}

fn unknown(name: []const u8) u8 {
    log.err("There's no {s} command. wraith help lists them", .{name});
    return 1;
}

fn version(_: ops.Context, args: *cli.Args) !u8 {
    if (args.next()) |extra| return cli.unexpected(extra, version_usage);
    log.printLn("{s}", .{build_info.version});
    return 0;
}

fn serveCommand(ctx: ops.Context, args: *cli.Args) !u8 {
    if (args.next()) |extra| return cli.unexpected(extra, serve_usage);
    serve.run(ctx) catch return 2;
    return 0;
}

test {
    _ = ops;
    _ = cli;
    _ = games;
    _ = play;
    _ = @import("processes.zig");
    _ = serve;
    _ = mods;
    _ = sdk;
    _ = dev;
    _ = import_cmd;
    _ = new;
    _ = pack;
    _ = publish;
    _ = @import("zip.zig");
    _ = @import("deps.zig");
}

test "every command has a different name, and help says each" {
    for (commands, 0..) |a, i| {
        for (commands[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
        try std.testing.expect(std.mem.indexOf(u8, help_text, a.usage) != null);
    }
    try std.testing.expect(find("games") != null);
    try std.testing.expect(find("install") == null);
}
