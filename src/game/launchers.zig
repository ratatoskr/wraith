//! Third-party launchers like XIVLauncher that start a known game.

const std = @import("std");

const platform = @import("wraith_platform");

const game = @import("root.zig");
const fs = @import("fs.zig");
const KnownGame = @import("known_game.zig").KnownGame;

pub const store: game.Store = .local;

const Launcher = struct {
    known: KnownGame,
    name: []const u8,
    /// It being there means the launcher's set up.
    config: []const u8,
    exe: []const u8,
};

const launchers = [_]Launcher{
    // `GamePath` in its config is the game folder it starts
    .{ .known = .ffxiv, .name = "XIVLauncher", .config = "XIVLauncher\\launcherConfigV3.json", .exe = "XIVLauncher\\current\\XIVLauncher.exe" },
};

pub const Found = struct {
    known: KnownGame,
    name: []const u8,
    exe: []const u8,
    game_dir: []const u8,
};

pub const AppData = struct {
    roaming: []const u8,
    local: []const u8,
};

pub fn find(arena: std.mem.Allocator, io: std.Io, options: game.Options) ![]const Found {
    const dirs = options.app_data orelse AppData{
        .roaming = try platform.process.envAlloc(arena, "APPDATA") orelse return &.{},
        .local = try platform.process.envAlloc(arena, "LOCALAPPDATA") orelse return &.{},
    };
    var out: std.ArrayList(Found) = .empty;
    for (launchers) |l| {
        const exe = try std.fs.path.join(arena, &.{ dirs.local, l.exe });
        if (!fs.exists(io, exe)) continue;
        const text = try fs.read(arena, io, try std.fs.path.join(arena, &.{ dirs.roaming, l.config })) orelse continue;
        const config = std.json.parseFromSliceLeaky(struct { GamePath: ?[]const u8 = null }, arena, text, .{ .ignore_unknown_fields = true }) catch continue;
        const game_dir = std.mem.trimEnd(u8, config.GamePath orelse continue, "\\/");
        if (!std.fs.path.isAbsolute(game_dir)) continue;
        try out.append(arena, .{ .known = l.known, .name = l.name, .exe = exe, .game_dir = game_dir });
    }
    return out.items;
}

pub fn of(launchers_found: []const Found, g: game.Game) ?Found {
    const known = g.known orelse return null;
    for (launchers_found) |l| {
        if (l.known == known and fs.isSame(l.game_dir, std.mem.trimEnd(u8, g.dir, "\\/"))) return l;
    }
    return null;
}

/// A store's find of the same game wins, it just starts through the launcher.
pub fn discover(arena: std.mem.Allocator, io: std.Io, options: game.Options, into: *std.ArrayList(game.Game)) !void {
    for (try find(arena, io, options)) |l| {
        if (!fs.exists(io, l.game_dir)) continue;
        try into.append(arena, .{ .id = @tagName(l.known), .store = .local, .known = l.known, .dir = l.game_dir });
    }
}

pub fn identify(arena: std.mem.Allocator, io: std.Io, exe: []const u8, options: game.Options) !?game.Game {
    for (try find(arena, io, options)) |l| {
        if (fs.isWithin(l.game_dir, exe)) return .{ .id = @tagName(l.known), .store = .local, .known = l.known, .dir = l.game_dir };
    }
    return null;
}
