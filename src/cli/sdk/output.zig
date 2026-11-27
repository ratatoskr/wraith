//! Writing what a language's types are: only files that changed, so builds that run `sdk types` each time
//! don't rebuild for nothing, then `inputs.txt`, what they're made from, for builds to know when to run it.

const std = @import("std");

const core = @import("wraith_core");

const ops = @import("../ops.zig");

const log = core.log.scoped(.wraith_cli);

/// A file to write, by its path in the folder.
pub const Made = struct { name: []const u8, text: []const u8 };

/// What `inputs.txt` is called: one absolute path a line, each a file or a folder.
pub const inputs_file = "inputs.txt";

/// Writes each of `made` into `out` that isn't there with that text already, saying which, then `inputs.txt`.
pub fn write(ctx: ops.Context, arena: std.mem.Allocator, out: []const u8, made: []const Made, inputs: []const []const u8) !void {
    var list: std.Io.Writer.Allocating = .init(arena);
    for (inputs) |i| try list.writer.print("{s}\n", .{i});
    var wrote: usize = 0;
    for (made) |m| {
        if (try writeIfChanged(ctx, arena, out, m.name, m.text)) {
            log.printLn("{s}/{s}", .{ out, m.name });
            wrote += 1;
        }
    }
    _ = try writeIfChanged(ctx, arena, out, inputs_file, list.written());
    if (wrote == 0) log.printLn("{s} is up to date", .{out});
}

/// False if it already had `text`.
pub fn writeIfChanged(ctx: ops.Context, arena: std.mem.Allocator, out: []const u8, name: []const u8, text: []const u8) !bool {
    const io = ctx.io;
    const cwd = std.Io.Dir.cwd();
    const path = try std.fs.path.join(arena, &.{ out, name });
    if (cwd.readFileAlloc(io, path, arena, .limited(64 << 20))) |have| {
        if (std.mem.eql(u8, have, text)) return false;
    } else |_| {}
    if (std.fs.path.dirname(path)) |d| try cwd.createDirPath(io, d);
    try cwd.writeFile(io, .{ .sub_path = path, .data = text });
    return true;
}
