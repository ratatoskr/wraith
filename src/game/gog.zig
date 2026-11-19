//! GOG.

const std = @import("std");

const sys = @import("tuft_sys");

const game = @import("root.zig");
const fs = @import("fs.zig");

pub const store: game.Store = .gog;

pub fn discover(arena: std.mem.Allocator, io: std.Io, _: game.Options, into: *std.ArrayList(game.Game)) !void {
    const games_key = try sys.registry.Key.open(.local_machine, "SOFTWARE\\GOG.com\\Games", .x86) orelse return;
    defer games_key.close();
    for (try games_key.subkeysAlloc(arena)) |key_name| {
        const path = try std.fmt.allocPrint(arena, "SOFTWARE\\GOG.com\\Games\\{s}", .{key_name});
        const key = try sys.registry.Key.open(.local_machine, path, .x86) orelse continue;
        defer key.close();
        if (try key.stringAlloc(arena, "dependsOn")) |depends| if (depends.len > 0) continue;
        const dir = try key.stringAlloc(arena, "path") orelse continue;
        if (!fs.exists(io, dir)) continue;
        const game_id = try key.stringAlloc(arena, "gameID") orelse key_name;
        try into.append(arena, .{
            .id = try game.id(arena, .gog, game_id),
            .store = .gog,
            .name = try key.stringAlloc(arena, "gameName"),
            .dir = std.mem.trimEnd(u8, dir, "\\/"),
            .store_exe = try key.stringAlloc(arena, "exe"),
        });
    }
}

pub fn identify(arena: std.mem.Allocator, io: std.Io, exe: []const u8, _: game.Options) !?game.Game {
    var dirs = fs.ancestors(exe, fs.max_depth);
    while (dirs.next()) |dir| {
        // Fallback if only DLC info is there. It has the game's ID but not its name
        var dlc: ?game.Game = null;
        for (try fs.list(arena, io, dir, "goggame-", ".info")) |path| {
            const text = try fs.read(arena, io, path) orelse continue;
            const info = std.json.parseFromSliceLeaky(Info, arena, text, .{ .ignore_unknown_fields = true }) catch continue;
            const game_id = try idText(arena, info.gameId) orelse continue;
            const root_id = try idText(arena, info.rootGameId) orelse game_id;
            const found: game.Game = .{ .id = try game.id(arena, .gog, root_id), .store = .gog, .dir = dir };
            if (std.mem.eql(u8, game_id, root_id)) return .{ .id = found.id, .store = .gog, .name = info.name, .dir = dir };
            if (dlc == null) dlc = found;
        }
        if (dlc) |found| return found;
    }
    return null;
}

const Info = struct {
    gameId: std.json.Value = .null,
    rootGameId: std.json.Value = .null,
    name: ?[]const u8 = null,
};

fn idText(arena: std.mem.Allocator, v: std.json.Value) !?[]const u8 {
    return switch (v) {
        .string => |s| if (s.len > 0) s else null,
        .integer => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
        .number_string => |s| s,
        else => null,
    };
}
