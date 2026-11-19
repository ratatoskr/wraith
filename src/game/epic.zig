//! Epic Games Store.

const std = @import("std");

const platform = @import("wraith_platform");

const game = @import("root.zig");
const fs = @import("fs.zig");

pub const store: game.Store = .epic;

pub fn identify(arena: std.mem.Allocator, io: std.Io, exe: []const u8, options: game.Options) !?game.Game {
    const items = try readItems(arena, io, options);

    // Deepest wins if they're nested
    var installed: ?Item = null;
    for (items) |item| {
        if (!item.isGame() or !fs.isWithin(item.InstallLocation, exe)) continue;
        if (installed == null or item.InstallLocation.len > installed.?.InstallLocation.len) installed = item;
    }
    if (installed) |item| return .{
        .id = try game.id(arena, .epic, item.AppName),
        .store = .epic,
        .name = item.DisplayName,
        .dir = std.mem.trimEnd(u8, item.InstallLocation, "\\/"),
    };

    var dirs = fs.ancestors(exe, fs.max_depth);
    while (dirs.next()) |dir| {
        const egstore = try std.fs.path.join(arena, &.{ dir, ".egstore" });
        for (try fs.list(arena, io, egstore, "", ".mancpn")) |path| {
            const text = try fs.read(arena, io, path) orelse continue;
            const mancpn = std.json.parseFromSliceLeaky(struct { AppName: []const u8 }, arena, text, .{ .ignore_unknown_fields = true }) catch continue;
            if (mancpn.AppName.len == 0) continue;
            const name = for (items) |item| {
                if (std.mem.eql(u8, item.AppName, mancpn.AppName)) break item.DisplayName;
            } else null;
            return .{ .id = try game.id(arena, .epic, mancpn.AppName), .store = .epic, .name = name, .dir = dir };
        }
    }
    return null;
}

pub fn discover(arena: std.mem.Allocator, io: std.Io, options: game.Options, into: *std.ArrayList(game.Game)) !void {
    for (try readItems(arena, io, options)) |item| {
        if (!item.isGame() or item.bIsIncompleteInstall) continue;
        const dir = std.mem.trimEnd(u8, item.InstallLocation, "\\/");
        if (!fs.exists(io, dir)) continue;
        const exe = if (item.LaunchExecutable.len > 0) try std.fs.path.join(arena, &.{ dir, item.LaunchExecutable }) else null;
        try into.append(arena, .{ .id = try game.id(arena, .epic, item.AppName), .store = .epic, .name = item.DisplayName, .dir = dir, .store_exe = exe });
    }
}

const Item = struct {
    AppName: []const u8 = "",
    DisplayName: ?[]const u8 = null,
    InstallLocation: []const u8 = "",
    /// Relative to `InstallLocation`.
    LaunchExecutable: []const u8 = "",
    bIsIncompleteInstall: bool = false,
    MainGameAppName: ?[]const u8 = null,
    bIsApplication: bool = true,
    /// Set for engine plugins. Their `InstallLocation` is the engine's.
    HostInstallationGuid: ?[]const u8 = null,

    fn isGame(self: Item) bool {
        if (self.AppName.len == 0 or self.InstallLocation.len == 0) return false;
        if (!self.bIsApplication) return false;
        if (self.HostInstallationGuid) |host| if (host.len > 0) return false;
        const main = self.MainGameAppName orelse return true;
        return main.len == 0 or std.mem.eql(u8, main, self.AppName);
    }
};

fn readItems(arena: std.mem.Allocator, io: std.Io, options: game.Options) ![]const Item {
    const dir = options.epic_manifests orelse blk: {
        const program_data = try platform.process.envAlloc(arena, "ProgramData") orelse return &.{};
        break :blk try std.fs.path.join(arena, &.{ program_data, "Epic", "EpicGamesLauncher", "Data", "Manifests" });
    };
    var items: std.ArrayList(Item) = .empty;
    for (try fs.list(arena, io, dir, "", ".item")) |path| {
        const text = try fs.read(arena, io, path) orelse continue;
        const item = std.json.parseFromSliceLeaky(Item, arena, text, .{ .ignore_unknown_fields = true }) catch continue;
        try items.append(arena, item);
    }
    return items.items;
}
