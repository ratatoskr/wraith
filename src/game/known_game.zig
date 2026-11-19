//! Games we know whatever the store, so settings and plugins are shared.

const std = @import("std");

const Product = @import("anticheat.zig").Product;

pub const KnownGame = enum {
    ffxiv,

    pub const Files = struct {
        /// A launcher, if that isn't the game itself.
        boot: ?[]const u8 = null,
        /// Where wraith goes.
        hook: []const u8,
    };

    pub fn files(self: KnownGame) Files {
        return switch (self) {
            .ffxiv => .{ .boot = "boot\\ffxivboot.exe", .hook = "game\\ffxiv_dx11.exe" },
        };
    }

    pub fn anticheat(self: KnownGame) ?Product {
        return switch (self) {
            else => null,
        };
    }

    pub fn fromSteam(app_id: []const u8) ?KnownGame {
        for (steam_apps) |app| if (std.mem.eql(u8, app[0], app_id)) return app[1];
        return null;
    }

    pub fn label(g: KnownGame) []const u8 {
        return switch (g) {
            .ffxiv => "Final Fantasy XIV",
        };
    }

    pub fn jsonStringify(g: KnownGame, jw: anytype) !void {
        try jw.write(.{ .id = @tagName(g), .label = g.label() });
    }
};

const steam_apps = [_]struct { []const u8, KnownGame }{
    .{ "39210", .ffxiv }, // retail
    .{ "312060", .ffxiv }, // free trial
};
