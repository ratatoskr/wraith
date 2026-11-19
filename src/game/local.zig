//! Known games installed by their own installer, found by uninstall entry.

const std = @import("std");

const sys = @import("tuft_sys");

const game = @import("root.zig");
const fs = @import("fs.zig");
const KnownGame = @import("known_game.zig").KnownGame;

pub const store: game.Store = .local;

pub const Install = struct {
    known: KnownGame,
    dir: []const u8,
    name: ?[]const u8 = null,
};

const Installer = struct {
    known: KnownGame,
    /// Under `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall`, 32-bit view.
    uninstall: []const u8,
    /// The game's folder is this many levels up from the entry's `DisplayIcon`.
    icon_depth: usize,
};

const installers = [_]Installer{
    // `DisplayIcon` is `<game>\boot\ffxivboot.exe`, `InstallLocation` is the SquareEnix folder above
    .{ .known = .ffxiv, .uninstall = "{2B41E132-07DF-4925-A3D3-F2D1765CCDFE}", .icon_depth = 2 },
};

pub fn discover(arena: std.mem.Allocator, io: std.Io, options: game.Options, into: *std.ArrayList(game.Game)) !void {
    for (try installed(arena, options)) |install| {
        if (!fs.exists(io, install.dir)) continue;
        try into.append(arena, .{ .id = @tagName(install.known), .store = .local, .known = install.known, .name = install.name, .dir = install.dir });
    }
}

pub fn identify(arena: std.mem.Allocator, _: std.Io, exe: []const u8, options: game.Options) !?game.Game {
    for (try installed(arena, options)) |install| {
        if (!fs.isWithin(install.dir, exe)) continue;
        return .{ .id = @tagName(install.known), .store = .local, .known = install.known, .name = install.name, .dir = install.dir };
    }
    return null;
}

fn installed(arena: std.mem.Allocator, options: game.Options) ![]const Install {
    if (options.known_installs) |given| return given;
    var out: std.ArrayList(Install) = .empty;
    for (installers) |installer| {
        if (try fromRegistry(arena, installer)) |install| try out.append(arena, install);
    }
    return out.items;
}

fn fromRegistry(arena: std.mem.Allocator, installer: Installer) !?Install {
    const path = try std.fmt.allocPrint(arena, "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{s}", .{installer.uninstall});
    const key = try sys.registry.Key.open(.local_machine, path, .x86) orelse return null;
    defer key.close();
    const icon = try key.stringAlloc(arena, "DisplayIcon") orelse return null;
    // Sometimes quoted, sometimes with `,<icon index>` on the end
    var dir: []const u8 = std.mem.trim(u8, icon, "\" ");
    if (std.mem.lastIndexOfScalar(u8, dir, ',')) |comma| {
        if (std.fmt.parseInt(i32, std.mem.trim(u8, dir[comma + 1 ..], " "), 10)) |_| {
            dir = std.mem.trim(u8, dir[0..comma], "\" ");
        } else |_| {}
    }
    for (0..installer.icon_depth) |_| dir = std.fs.path.dirname(dir) orelse return null;
    if (!std.fs.path.isAbsolute(dir)) return null;
    return .{ .known = installer.known, .dir = dir, .name = try key.stringAlloc(arena, "DisplayName") };
}
