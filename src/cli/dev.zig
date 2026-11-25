//! `wraith dev`: plugins you're building.

const std = @import("std");

const core = @import("wraith_core");

const ops = @import("ops.zig");

const log = core.log.scoped(.wraith_cli);

pub const usage =
    \\  dev list                             plugins you're building: the folders Wraith loads them
    \\                                       from, besides the installed ones, and the builds of what
    \\                                       their devDepends name, which load from there too
    \\  dev add <folder>                     load the plugin in <folder>, a build's output with its
    \\                                       wraith.json (zig-out\plugins\kai, dist)
    \\  dev off <folder>                     stop loading it for now, but keep it listed
    \\  dev on <folder>                      load it again
    \\  dev rm <folder>                      stop loading it from there
;

const Sub = enum { list, add, off, on, rm };

pub fn run(ctx: ops.Context, args: anytype) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = ctx.io;
    const path = try core.dev_plugins.pathAlloc(arena, try ops.locations(arena));

    const sub = std.meta.stringToEnum(Sub, args.next() orelse "list") orelse return usageError();
    if (sub == .list) {
        const listed = core.dev_plugins.list(arena, io, path) catch return 1;
        if (listed.len == 0) log.printLn("No dev plugins. Add one with: wraith dev add <folder>", .{});
        for (listed) |l| {
            const off = if (l.on) "" else "  (off)";
            if (l.name) |name| {
                log.printLn("{s}  {s}{s}", .{ name, l.folder, off });
            } else log.printLn("?  {s}  ({s}){s}", .{ l.folder, core.dev_plugins.describe(l.problem.?), off });
        }
        const folders = core.dev_plugins.load(arena, io, path) catch &.{};
        const followed = core.dev_plugins.followed(arena, io, folders) catch &.{};
        for (followed) |f| log.printLn("{s}  {s}  (devDepends of {s})", .{ f.name, f.dir, f.by });
        return 0;
    }

    const given = args.next() orelse return usageError();
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", arena);
    const folder = try std.fs.path.resolve(arena, &.{ cwd, given });

    switch (sub) {
        .list => unreachable,
        .rm => {
            if (!(core.dev_plugins.remove(arena, io, path, folder) catch return 1)) {
                log.err("{s} isn't a dev plugin (see wraith dev list)", .{folder});
                return 1;
            }
            log.printLn("Removed {s}", .{folder});
            return 0;
        },
        .on, .off => {
            if (!(core.dev_plugins.setOn(arena, io, path, folder, sub == .on) catch return 1)) {
                log.err("{s} isn't a dev plugin that's {s} (see wraith dev list)", .{ folder, if (sub == .on) "off" else "on" });
                return 1;
            }
            log.printLn("{s} is {t}. Rescan in a running game's Plugins window to catch up", .{ folder, sub });
            return 0;
        },
        .add => {},
    }

    // Fine before it's built, as long as it's a folder
    const name = core.dev_plugins.nameOf(arena, io, folder) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            log.err("{s} isn't a folder", .{folder});
            return 1;
        },
        else => blk: {
            log.warn("{s}: {s}. It's added, and loads once it has one", .{ folder, core.dev_plugins.describe(err) });
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

fn usageError() u8 {
    log.err("Usage:\n{s}", .{usage});
    return 1;
}
