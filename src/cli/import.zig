//! `wraith import ct`: a Cheat Engine table to a project.

const std = @import("std");

const core = @import("wraith_core");
const ce = @import("wraith_importer").ce;

const ops = @import("ops.zig");

const log = core.log.scoped(.wraith_cli);

pub const usage =
    \\  import ct <table.CT> [--out <folder | project.rwp>]
    \\                                       a Cheat Engine table to a project: its scripts as
    \\                                       tweaks, its records in the Addresses list, and
    \\                                       import-report.md on what needs a look. Next to the
    \\                                       table as <table>.rwp unless --out says where
;

pub fn run(ctx: ops.Context, args: anytype) !u8 {
    const what = args.next() orelse "";
    if (!std.mem.eql(u8, what, "ct")) return usageError();
    var input: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--out")) {
            out = args.next() orelse return usageError();
        } else if (input == null) {
            input = arg;
        } else return usageError();
    }
    const path = input orelse return usageError();

    var arena_state: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd = std.Io.Dir.cwd();
    const source = cwd.readFileAlloc(ctx.io, path, arena, .limited(64 << 20)) catch |err| {
        log.err("Couldn't read {s}: {t}", .{ path, err });
        return 2;
    };
    const project = ce.import(arena, ctx.allocator, source, .{ .name = std.fs.path.basename(path) }) catch |err| {
        log.err("Couldn't import {s}: {t}", .{ path, err });
        return 2;
    };

    const target = out orelse try std.fmt.allocPrint(arena, "{s}.rwp", .{path[0 .. path.len - std.fs.path.extension(path).len]});
    ce.zip.save(ctx.io, ctx.allocator, target, project.files) catch |err| {
        log.err("Couldn't write {s}: {t}", .{ target, err });
        return 2;
    };
    // A project's report is inside it, so it goes beside it too
    var report_path: []const u8 = try std.fs.path.join(arena, &.{ target, ce.report_file });
    if (std.ascii.endsWithIgnoreCase(target, ".rwp")) {
        report_path = try std.fmt.allocPrint(arena, "{s}.{s}", .{ target[0 .. target.len - 4], ce.report_file });
        cwd.writeFile(ctx.io, .{ .sub_path = report_path, .data = project.report }) catch |err| {
            log.err("Couldn't write {s}: {t}", .{ report_path, err });
            return 2;
        };
    }

    const s = project.stats;
    log.printLn("{s}", .{target});
    log.printLn("{d} scripts: {d} converted, {d} off for review, {d} Lua with the CE layer", .{ s.scripts(), s.clean, s.review, s.lua });
    log.printLn("{d} address list entries in {d} groups", .{ s.records, s.groups });
    log.printLn("What needs a look is in {s}", .{report_path});
    return 0;
}

fn usageError() u8 {
    log.err("Usage:\n{s}", .{usage});
    return 1;
}
