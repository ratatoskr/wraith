//! `wraith dev`: plugins you're building.

const std = @import("std");

const core = @import("wraith_core");

const ops = @import("ops.zig");

const log = core.log.scoped(.wraith_cli);

pub const usage =
    \\  dev list                             plugins you're building: the folders Wraith loads them
    \\                                       from, besides the installed ones
    \\  dev add <folder>                     load the plugin in <folder>, a build's output with its
    \\                                       wraith.json (zig-out\plugins\kai, dist)
    \\  dev rm <folder>                      stop loading it from there
;

pub fn run(ctx: ops.Context, args: anytype) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = ctx.io;
    const path = try core.dev_plugins.pathAlloc(arena, try ops.locations(arena));

    const sub = args.next() orelse "list";
    if (std.mem.eql(u8, sub, "list")) {
        const folders = core.dev_plugins.load(arena, io, path) catch return 1;
        if (folders.len == 0) log.printLn("No dev plugins. Add one with: wraith dev add <folder>", .{});
        for (folders) |f| {
            if (core.dev_plugins.nameOf(arena, io, f)) |name| {
                log.printLn("{s}  {s}", .{ name, f });
            } else |err| log.printLn("?  {s}  ({s})", .{ f, problem(err) });
        }
        return 0;
    }

    const is_add = std.mem.eql(u8, sub, "add");
    if (!is_add and !std.mem.eql(u8, sub, "rm")) return usageError();
    const given = args.next() orelse return usageError();
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", arena);
    const folder = try std.fs.path.resolve(arena, &.{ cwd, given });

    if (!is_add) {
        if (!(core.dev_plugins.remove(arena, io, path, folder) catch return 1)) {
            log.err("{s} isn't a dev plugin (see wraith dev list)", .{folder});
            return 1;
        }
        log.printLn("Removed {s}", .{folder});
        return 0;
    }

    // Fine before it's built, as long as it's a folder
    const name = core.dev_plugins.nameOf(arena, io, folder) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            log.err("{s} isn't a folder", .{folder});
            return 1;
        },
        else => blk: {
            log.warn("{s}: {s}. It's added, and loads once it has one", .{ folder, problem(err) });
            break :blk null;
        },
    };
    if (!(core.dev_plugins.add(arena, io, path, folder) catch return 1)) {
        log.printLn("{s} is already a dev plugin", .{folder});
        return 0;
    }
    log.printLn("Added {s}{s}{s}. Rescan in a running game's Plugins window to load it", .{ folder, if (name != null) " as " else "", name orelse "" });
    return 0;
}

fn problem(err: anyerror) []const u8 {
    return switch (err) {
        error.NoManifest => "no wraith.json in it",
        error.BadManifest => "its wraith.json isn't right",
        error.BadId => "its wraith.json's id should be lowercase letters, digits, _ or -",
        error.FileNotFound => "it's not there",
        else => @errorName(err),
    };
}

fn usageError() u8 {
    log.err("Usage:\n{s}", .{usage});
    return 1;
}
