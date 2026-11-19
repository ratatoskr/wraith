//! Exes a game might start from, minus obvious junk.

const std = @import("std");

const fs = @import("fs.zig");

pub const Exe = struct {
    path: []const u8,
    size: u64,
    store: bool = false,
};

/// Unreal puts them in `<Project>\Binaries\Win64`.
const max_depth = 6;
/// More than this and it's not a game folder.
const max_exes = 200;

pub fn list(arena: std.mem.Allocator, io: std.Io, dir: []const u8, store_exe: ?[]const u8) ![]const Exe {
    var found: std.ArrayList(Exe) = .empty;
    try walk(arena, io, dir, 0, &found);
    for (found.items) |*e| {
        if (store_exe) |s| e.store = fs.isSame(s, e.path);
    }
    std.mem.sort(Exe, found.items, {}, storeThenBiggest);
    return found.items;
}

fn walk(arena: std.mem.Allocator, io: std.Io, path: []const u8, depth: usize, found: *std.ArrayList(Exe)) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch return) |entry| {
        if (found.items.len == max_exes) return;
        switch (entry.kind) {
            .directory => if (depth < max_depth and !isJunkFolder(entry.name)) {
                try walk(arena, io, try std.fs.path.join(arena, &.{ path, entry.name }), depth + 1, found);
            },
            .file => if (std.ascii.endsWithIgnoreCase(entry.name, ".exe") and !isJunkExe(entry.name)) {
                const stat = dir.statFile(io, entry.name, .{}) catch continue;
                try found.append(arena, .{ .path = try std.fs.path.join(arena, &.{ path, entry.name }), .size = stat.size });
            },
            else => {},
        }
    }
}

fn storeThenBiggest(_: void, a: Exe, b: Exe) bool {
    if (a.store != b.store) return a.store;
    return a.size > b.size;
}

fn isJunkFolder(name: []const u8) bool {
    const junk = [_][]const u8{
        "_CommonRedist", "CommonRedist", "Redist",     "_Redist",    "Redistributables", "__Installer",
        "Installer",     "Installers",   "DirectX",    "vcredist",   "Prerequisites",    "EasyAntiCheat",
        "BattlEye",      "__overlay",    "ThirdParty", "DotNetCore", "dotnet",
    };
    for (junk) |j| if (std.ascii.eqlIgnoreCase(name, j)) return true;
    return false;
}

fn isJunkExe(name: []const u8) bool {
    if (std.ascii.startsWithIgnoreCase(name, "unins")) return true;
    const within = [_][]const u8{
        "crashhandler",         "crashreport", "crashpad", "crash_reporter", "redist",     "setup",     "prereq",
        "dotnetfx",             "oalinst",     "physx",    "vc_redist",      "helper",     "uninstall", "webengineprocess",
        "start_protected_game", "eaanticheat", "battleye", "easyanticheat",  "subprocess", "checker",   "-runtime-",
    };
    for (within) |w| if (std.ascii.findIgnoreCase(name, w) != null) return true;
    return false;
}

test list {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const files = [_]struct { []const u8, usize }{
        .{ "Launcher\\GameLauncher.exe", 10 },
        .{ "bin\\game.exe", 300 },
        .{ "bin\\game_dx11.exe", 200 },
        .{ "bin\\UnityCrashHandler64.exe", 400 },
        .{ "unins000.exe", 400 },
        .{ "_CommonRedist\\vcredist\\setup.exe", 400 },
        .{ "EasyAntiCheat\\EasyAntiCheat_EOS_Setup.exe", 400 },
        .{ "readme.txt", 400 },
    };
    for (files) |f| {
        if (std.fs.path.dirname(f[0])) |d| try tmp.dir.createDirPath(io, d);
        const data = try testing.allocator.alloc(u8, f[1]);
        defer testing.allocator.free(data);
        @memset(data, 0);
        try tmp.dir.writeFile(io, .{ .sub_path = f[0], .data = data });
    }
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const launcher = try std.fs.path.join(a, &.{ root, "Launcher", "GameLauncher.exe" });
    const exes = try list(a, io, root, launcher);
    try testing.expectEqual(3, exes.len);
    // Store's first, then biggest
    try testing.expectEqualStrings(launcher, exes[0].path);
    try testing.expect(exes[0].store);
    try testing.expect(std.mem.endsWith(u8, exes[1].path, "game.exe"));
    try testing.expect(std.mem.endsWith(u8, exes[2].path, "game_dx11.exe"));
}
