//! How a game gets started, and where wraith goes into it.

const std = @import("std");

const game = @import("root.zig");
const fs = @import("fs.zig");
const launchers = @import("launchers.zig");

pub const Launch = struct {
    start: Start,
    /// Null if we don't know. Then it's the player's pick, or anything from the game's folder.
    game_exe: ?[]const u8 = null,

    pub const Start = union(enum) {
        store: []const u8,
        exe: []const u8,
        none,
    };

    pub fn plan(arena: std.mem.Allocator, g: game.Game, set_up: []const launchers.Found) !Launch {
        const files = if (g.known) |k| k.files() else null;
        // The store's exe is our best guess at the game, unless we know better
        const game_exe = if (files) |f| try std.fs.path.join(arena, &.{ g.dir, f.hook }) else g.store_exe;
        const start: Start = blk: {
            if (launchers.of(set_up, g)) |l| break :blk .{ .exe = l.exe };
            switch (g.store) {
                .steam => break :blk .{ .store = try std.fmt.allocPrint(arena, "steam://rungameid/{s}", .{storeKey(g)}) },
                .epic => break :blk .{ .store = try std.fmt.allocPrint(arena, "com.epicgames.launcher://apps/{s}?action=launch&silent=true", .{storeKey(g)}) },
                // Packaged apps start through the shell with an ID the config doesn't have
                .xbox => break :blk .none,
                .gog, .itch, .local => {},
            }
            if (files) |f| if (f.boot) |boot| break :blk .{ .exe = try std.fs.path.join(arena, &.{ g.dir, boot }) };
            break :blk if (game_exe orelse g.store_exe) |exe| .{ .exe = exe } else .none;
        };
        return .{ .start = start, .game_exe = game_exe };
    }

    /// Otherwise something else starts it and we wait for the game.
    pub fn startsGame(self: Launch) bool {
        const exe = switch (self.start) {
            .exe => |e| e,
            else => return false,
        };
        return if (self.game_exe) |g| fs.isSame(exe, g) else false;
    }

    /// A pick of what starts the game is ignored unless we start the game directly.
    pub fn withPick(self: Launch, pick: ?[]const u8) Launch {
        const p = pick orelse return self;
        if (self.startsGame()) return .{ .start = .{ .exe = p }, .game_exe = p };
        if (self.start == .exe and self.game_exe != null and fs.isSame(self.start.exe, p)) return self;
        return .{ .start = self.start, .game_exe = p };
    }
    pub fn jsonStringify(self: Launch, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("start");
        try jw.write(@tagName(self.start));
        try jw.objectField("link");
        try jw.write(if (self.start == .store) self.start.store else null);
        try jw.objectField("exe");
        try jw.write(if (self.start == .exe) self.start.exe else null);
        try jw.objectField("game_exe");
        try jw.write(self.game_exe);
        try jw.objectField("starts_game");
        try jw.write(self.startsGame());
        try jw.endObject();
    }
};

fn storeKey(g: game.Game) []const u8 {
    return (g.store_id orelse g.id)[@tagName(g.store).len + 1 ..];
}

const testing = std.testing;

test "pick replaces start" {
    const direct: Launch = .{ .start = .{ .exe = "D:\\g\\game.exe" }, .game_exe = "D:\\g\\game.exe" };
    try testing.expect(direct.startsGame());
    const picked = direct.withPick("D:\\g\\bin\\real.exe");
    try testing.expectEqualStrings("D:\\g\\bin\\real.exe", picked.start.exe);
    try testing.expectEqualStrings("D:\\g\\bin\\real.exe", picked.game_exe.?);

    const boots: Launch = .{ .start = .{ .exe = "D:\\g\\boot\\boot.exe" }, .game_exe = "D:\\g\\game\\game.exe" };
    try testing.expect(!boots.startsGame());
    // Picking the launcher is a pick from before we knew
    try testing.expectEqualStrings("D:\\g\\game\\game.exe", boots.withPick("d:\\G\\boot\\BOOT.exe").game_exe.?);
    const other = boots.withPick("D:\\g\\game\\game_dx9.exe");
    try testing.expectEqualStrings("D:\\g\\boot\\boot.exe", other.start.exe);
    try testing.expectEqualStrings("D:\\g\\game\\game_dx9.exe", other.game_exe.?);

    const store: Launch = .{ .start = .{ .store = "steam://rungameid/1" } };
    try testing.expectEqualStrings("D:\\g\\x.exe", store.withPick("D:\\g\\x.exe").game_exe.?);
    try testing.expectEqual(null, store.withPick(null).game_exe);
}
