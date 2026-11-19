//! Games the player added by exe.

const std = @import("std");

const fs = @import("fs.zig");

const Saved = struct {
    exes: []const []const u8 = &.{},
};

/// Empty if there's no file yet or it's broken.
pub fn read(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]const []const u8 {
    const text = try fs.read(arena, io, path) orelse return &.{};
    const source = try arena.dupeSentinel(u8, text, 0);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const saved = std.zon.parse.fromSlice(Saved, .{ .gpa = arena, .arena = arena, .source = source, .diagnostics = &diagnostics, .ignore_unknown_fields = true }) catch return &.{};
    return saved.exes;
}

pub fn add(arena: std.mem.Allocator, io: std.Io, path: []const u8, exe: []const u8) !bool {
    const exes = try read(arena, io, path);
    for (exes) |e| if (fs.isSame(e, exe)) return false;
    try write(arena, io, path, try std.mem.concat(arena, []const u8, &.{ exes, &.{exe} }));
    return true;
}

pub fn removeIf(arena: std.mem.Allocator, io: std.Io, path: []const u8, context: anytype, comptime keep: fn (@TypeOf(context), []const u8) bool) !usize {
    var kept: std.ArrayList([]const u8) = .empty;
    const exes = try read(arena, io, path);
    for (exes) |e| if (keep(context, e)) try kept.append(arena, e);
    if (kept.items.len != exes.len) try write(arena, io, path, kept.items);
    return exes.len - kept.items.len;
}

fn write(arena: std.mem.Allocator, io: std.Io, path: []const u8, exes: []const []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.zon.stringify.serialize(Saved{ .exes = exes }, .{}, &out.writer);
    if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
}

test "add and remove" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const path = try std.fs.path.join(a, &.{ root, "settings", "games.zon" });

    try std.testing.expectEqual(0, (try read(a, std.testing.io, path)).len);
    try std.testing.expect(try add(a, std.testing.io, path, "C:\\Games\\Kai\\kai.exe"));
    try std.testing.expect(!try add(a, std.testing.io, path, "c:/games/kai/KAI.exe"));
    try std.testing.expect(try add(a, std.testing.io, path, "D:\\Other\\other.exe"));
    try std.testing.expectEqual(2, (try read(a, std.testing.io, path)).len);

    const gone = try removeIf(a, std.testing.io, path, @as([]const u8, "D:\\Other\\other.exe"), struct {
        fn keep(drop: []const u8, exe: []const u8) bool {
            return !fs.isSame(drop, exe);
        }
    }.keep);
    try std.testing.expectEqual(1, gone);
    const left = try read(a, std.testing.io, path);
    try std.testing.expectEqual(1, left.len);
    try std.testing.expectEqualStrings("C:\\Games\\Kai\\kai.exe", left[0]);
}
