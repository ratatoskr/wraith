//! A plugin's or provider's manifest, plus the memory it was parsed into.

const Manifest = @This();

const std = @import("std");

const api = @import("wraith_api");
const core = @import("wraith_core");
const game_engine = @import("wraith_game").game_engine;

const log = core.log.scoped(.wraith_runtime);

pub const Arch = core.arch.Arch;

pub const native_arch = core.arch.native;

value: core.Manifest = .{},
arena: ?*std.heap.ArenaAllocator = null,

/// `dir`'s `wraith.json`. Null if there isn't one.
pub fn read(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) !?Manifest {
    const path = try std.fs.path.join(allocator, &.{ dir, core.manifest.file_name });
    defer allocator.free(path);
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 << 10)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(source);
    return try parse(allocator, source, path);
}

pub fn parse(allocator: std.mem.Allocator, source: []const u8, path: []const u8) !Manifest {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    var problem: []const u8 = "";
    const value = core.manifest.parse(arena.allocator(), source, &problem) catch |err| {
        if (err != error.OutOfMemory) log.warn("{s} isn't right: {s}", .{ path, problem });
        return err;
    };
    return .{ .value = value, .arena = arena };
}

pub fn deinit(self: Manifest) void {
    const arena = self.arena orelse return;
    const allocator = arena.child_allocator;
    arena.deinit();
    allocator.destroy(arena);
}

pub fn providerName(self: Manifest) []const u8 {
    return self.value.provider orelse api.default_provider;
}

pub fn gamesText(self: Manifest, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    const game = self.value.game orelse {
        // Like `Unity (IL2CPP) games`
        const engine = self.value.gameEngine orelse return "";
        const label = if (std.meta.stringToEnum(game_engine.GameEngine, engine.id)) |e| e.label() else engine.id;
        w.writeAll(label) catch return w.buffered();
        for (engine.variants, 0..) |v, i| w.print("{s}{s}", .{ if (i == 0) " (" else ", ", v }) catch return w.buffered();
        if (engine.variants.len > 0) w.writeAll(")") catch return w.buffered();
        w.writeAll(" games") catch return w.buffered();
        return w.buffered();
    };
    for (game.ids, 0..) |id, i| {
        if (i != 0) w.writeAll(", ") catch return w.buffered();
        w.writeAll(id) catch return w.buffered();
    }
    for (game.exes, 0..) |exe, i| {
        if (i != 0 or game.ids.len != 0) w.writeAll(", ") catch return w.buffered();
        w.writeAll(exe) catch return w.buffered();
    }
    return w.buffered();
}

test "provider names what runs it" {
    const a = std.testing.allocator;
    const native = try parse(a, "{ \"id\": \"ab\", \"provider\": \"native\", \"arches\": [\"x64\"] }", "test");
    defer native.deinit();
    try std.testing.expectEqualStrings("native", native.providerName());

    const script = try parse(a, "{ \"id\": \"ab\", \"provider\": \"js\" }", "test");
    defer script.deinit();
    try std.testing.expectEqualStrings("js", script.providerName());
}

test "lists games" {
    const m = try parse(std.testing.allocator, "{ \"id\": \"ab\", \"provider\": \"native\", \"game\": { \"exes\": [\"kai.exe\"], \"ids\": [\"steam-1\", \"gog-1\"] } }", "test");
    defer m.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("steam-1, gog-1, kai.exe", m.gamesText(&buf));
}

test "a broken one is an error" {
    const saved = core.log.mute(&.{.runtime});
    defer core.log.setFilter(saved);
    try std.testing.expectError(error.BadManifest, parse(std.testing.allocator, "{ \"id\": \"ab\", \"provider\": \"native\", \"game\": 3 }", "test"));
}
