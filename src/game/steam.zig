//! Steam.

const std = @import("std");

const sys = @import("tuft_sys");

const game = @import("root.zig");
const fs = @import("fs.zig");
const vdf = @import("vdf.zig");
const KnownGame = @import("known_game.zig").KnownGame;
const Product = @import("anticheat.zig").Product;

pub const store: game.Store = .steam;

const not_games = [_][]const u8{
    "228980", // Steamworks Common Redistributables
    "250820", // SteamVR
};

const anticheat = std.StaticStringMap(Product).initComptime(.{
    .{ "10", .vac }, // Counter-Strike
    .{ "20", .vac }, // Team Fortress Classic
    .{ "30", .vac }, // Day of Defeat
    .{ "40", .vac }, // Deathmatch Classic
    .{ "50", .vac }, // Half-Life: Opposing Force
    .{ "60", .vac }, // Ricochet
    .{ "70", .vac }, // Half-Life
    .{ "80", .vac }, // Counter-Strike: Condition Zero
    .{ "240", .vac }, // Counter-Strike: Source
    .{ "300", .vac }, // Day of Defeat: Source
    .{ "320", .vac }, // Half-Life 2: Deathmatch
    .{ "360", .vac }, // Half-Life Deathmatch: Source
    .{ "440", .vac }, // Team Fortress 2
    .{ "500", .vac }, // Left 4 Dead
    .{ "550", .vac }, // Left 4 Dead 2
    .{ "570", .vac }, // Dota 2
    .{ "730", .vac }, // Counter-Strike 2
    .{ "1422450", .vac }, // Deadlock
    .{ "4465480", .vac }, // Counter-Strike: Global Offensive (legacy)

    .{ "1808500", .denuvo }, // ARC Raiders
    .{ "2767030", .netease_security }, // Marvel Rivals
});

pub fn anticheatOf(app_id: []const u8) ?Product {
    return anticheat.get(app_id);
}

pub fn discover(arena: std.mem.Allocator, io: std.Io, _: game.Options, into: *std.ArrayList(game.Game)) !void {
    const key = try sys.registry.Key.open(.current_user, "Software\\Valve\\Steam", .native) orelse return;
    defer key.close();
    const steam_dir = try key.stringAlloc(arena, "SteamPath") orelse return;
    // Steam writes it with forward slashes
    std.mem.replaceScalar(u8, steam_dir, '/', '\\');
    try discoverIn(arena, io, steam_dir, into);
}

pub fn discoverIn(arena: std.mem.Allocator, io: std.Io, steam_dir: []const u8, into: *std.ArrayList(game.Game)) !void {
    var libraries: std.ArrayList([]const u8) = .empty;
    try libraries.append(arena, steam_dir);
    const folders_path = try std.fs.path.join(arena, &.{ steam_dir, "steamapps", "libraryfolders.vdf" });
    if (try fs.read(arena, io, folders_path)) |text| {
        const folders = vdf.parse(arena, text) catch vdf.Object{};
        for ((folders.object("libraryfolders") orelse vdf.Object{}).fields) |field| {
            const library = switch (field.value) {
                .object => |o| o.string("path") orelse continue,
                .string => continue,
            };
            // Only absolute paths can be found again, and std insists anyway
            if (!std.fs.path.isAbsolute(library)) continue;
            for (libraries.items) |known| {
                if (std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, known, "\\/"), std.mem.trimEnd(u8, library, "\\/"))) break;
            } else try libraries.append(arena, library);
        }
    }

    for (libraries.items) |library| {
        const steamapps = try std.fs.path.join(arena, &.{ library, "steamapps" });
        for (try fs.list(arena, io, steamapps, "appmanifest_", ".acf")) |path| {
            const text = try fs.read(arena, io, path) orelse continue;
            const manifest = vdf.parse(arena, text) catch continue;
            const app = manifest.object("AppState") orelse continue;
            const app_id = app.string("appid") orelse continue;
            for (not_games) |tool| {
                if (std.mem.eql(u8, app_id, tool)) break;
            } else {
                const installdir = app.string("installdir") orelse continue;
                const dir = try std.fs.path.join(arena, &.{ steamapps, "common", installdir });
                // Leftover manifest for an uninstalled game
                if (!fs.exists(io, dir)) continue;
                try into.append(arena, .{
                    .id = try game.id(arena, .steam, app_id),
                    .store = .steam,
                    .known = KnownGame.fromSteam(app_id),
                    .anticheat = anticheatOf(app_id),
                    .name = app.string("name"),
                    .dir = dir,
                    .last_played = lastPlayed(app),
                    .build = try buildOf(arena, app),
                });
            }
        }
    }
}

/// Like `steam:18234455`, the way manifests list builds.
fn buildOf(arena: std.mem.Allocator, app: vdf.Object) !?[]const u8 {
    const id = app.string("buildid") orelse return null;
    if (id.len == 0 or std.mem.eql(u8, id, "0")) return null;
    return try std.fmt.allocPrint(arena, "steam:{s}", .{id});
}

/// "0" means never, so null.
fn lastPlayed(app: vdf.Object) ?i64 {
    const at = std.fmt.parseInt(i64, app.string("LastPlayed") orelse return null, 10) catch return null;
    return if (at > 0) at else null;
}

pub fn identify(arena: std.mem.Allocator, io: std.Io, exe: []const u8, _: game.Options) !?game.Game {
    var dirs = fs.ancestors(exe, std.math.maxInt(usize));
    while (dirs.next()) |dir| {
        const common = std.fs.path.dirname(dir) orelse return null;
        const steamapps = std.fs.path.dirname(common) orelse return null;
        if (std.ascii.eqlIgnoreCase(std.fs.path.basename(common), "common") and
            std.ascii.eqlIgnoreCase(std.fs.path.basename(steamapps), "steamapps"))
        {
            return fromManifests(arena, io, steamapps, dir);
        }
    }
    return null;
}

fn fromManifests(arena: std.mem.Allocator, io: std.Io, steamapps: []const u8, dir: []const u8) !?game.Game {
    const installdir = std.fs.path.basename(dir);
    for (try fs.list(arena, io, steamapps, "appmanifest_", ".acf")) |path| {
        const text = try fs.read(arena, io, path) orelse continue;
        const manifest = vdf.parse(arena, text) catch continue;
        const app = manifest.object("AppState") orelse continue;
        if (!std.ascii.eqlIgnoreCase(app.string("installdir") orelse continue, installdir)) continue;
        const app_id = app.string("appid") orelse continue;
        return .{ .id = try game.id(arena, .steam, app_id), .store = .steam, .known = KnownGame.fromSteam(app_id), .anticheat = anticheatOf(app_id), .name = app.string("name"), .dir = dir, .build = try buildOf(arena, app) };
    }
    return null;
}
