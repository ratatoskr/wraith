//! What the runtime keeps about a game in `games/<game id>/game.zon`. Settings live in the registry.

const GameSettings = @This();

const std = @import("std");

/// Store name, else exe name, for people browsing these folders.
name: []const u8 = "",

/// Plugins not loaded in this game.
disabled_plugins: []const []const u8 = &.{},

/// The `.rwp` older versions saved the project to. Moved into `workbench/` and emptied.
project_file: []const u8 = "",
/// Where the export and open dialogs start.
project_folder: []const u8 = "",

tweaks: Tweaks = .{},

/// How the tweak lists are laid out, by `TweakLayout`'s ids.
tweak_layout: Layout = .{},

pub const Layout = struct {
    /// Each in the order it goes among the ones next to it.
    order: []const u64 = &.{},
    folded: []const u64 = &.{},
};

pub const Tweaks = struct {
    /// Which are on, by name.
    on: []const []const u8 = &.{},
    /// Use the keys the project's tweaks suggest. Yours always count.
    project_keys: bool = true,
    /// Data values you set, over the tweak's own.
    values: []const Value = &.{},

    pub const Value = struct {
        tweak: []const u8,
        field: []const u8,
        value: f64,
    };
};

test "older files with settings in them still load" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const game = try std.zon.parse.fromSlice(GameSettings, .{
        .gpa = std.testing.allocator,
        .arena = arena.allocator(),
        .source = ".{ .disabled_plugins = .{\"kai\"}, .wraith = .{ .ui = .{ .overlay_scale = 2.0 } } }",
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    });
    try std.testing.expectEqualStrings("kai", game.disabled_plugins[0]);
}
