//! itch.io, from the `.itch\receipt.json.gz` butler leaves.

const std = @import("std");

const game = @import("root.zig");
const fs = @import("fs.zig");

pub const store: game.Store = .itch;

pub fn identify(arena: std.mem.Allocator, io: std.Io, exe: []const u8, _: game.Options) !?game.Game {
    var dirs = fs.ancestors(exe, fs.max_depth);
    while (dirs.next()) |dir| {
        const path = try std.fs.path.join(arena, &.{ dir, ".itch", "receipt.json.gz" });
        const compressed = try fs.read(arena, io, path) orelse continue;
        const text = gunzip(arena, compressed) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        const receipt = std.json.parseFromSliceLeaky(Receipt, arena, text, .{ .ignore_unknown_fields = true }) catch continue;
        const g = receipt.game orelse continue;
        const key = try std.fmt.allocPrint(arena, "{d}", .{g.id});
        return .{ .id = try game.id(arena, .itch, key), .store = .itch, .name = g.title, .dir = dir };
    }
    return null;
}

const Receipt = struct {
    game: ?struct {
        id: u64,
        title: ?[]const u8 = null,
    } = null,
};

fn gunzip(arena: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(compressed);
    const window = try arena.alloc(u8, std.compress.flate.max_window_len);
    var gzip: std.compress.flate.Decompress = .init(&in, .gzip, window);
    return gzip.reader.allocRemaining(arena, .limited(fs.max_file)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidReceipt,
    };
}
