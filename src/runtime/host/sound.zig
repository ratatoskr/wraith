//! Plugins' sounds, through one player for the whole runtime. Nothing plays while the user has
//! sounds off.

const std = @import("std");

const sound = @import("tuft_sys").sound;
const api = @import("wraith_api");

const Loaded = @import("../PluginLoader.zig").Loaded;

/// Set at start, before plugins, and gone after them.
var player: ?*sound.Player = null;
var enabled: std.atomic.Value(bool) = .init(true);

/// The runtime keeps going without sound.
pub fn start(allocator: std.mem.Allocator) void {
    player = sound.Player.create(allocator) catch |err| blk: {
        std.log.scoped(.wraith_runtime).warn("No sounds: {t}", .{err});
        break :blk null;
    };
}

/// After plugins are gone.
pub fn stop() void {
    if (player) |p| p.destroy();
    player = null;
}

/// From the settings. Turning it off stops what's playing. Any thread.
pub fn setEnabled(on: bool) void {
    enabled.store(on, .release);
    if (!on) if (player) |p| p.stop();
}

pub fn play(_: *Loaded, wav: []const u8) api.SoundError!void {
    // Checked even with sounds off, so a bad file shows up either way
    if (!sound.isWav(wav)) return error.InvalidSound;
    const p = player orelse return;
    if (!enabled.load(.acquire)) return;
    try p.play(wav);
}

pub fn playSystem(_: *Loaded, which: api.SystemSound) void {
    const p = player orelse return;
    if (!enabled.load(.acquire)) return;
    p.playSystem(switch (which) {
        inline else => |w| @field(sound.System, @tagName(w)),
    });
}

pub fn stopSound(_: *Loaded) void {
    if (player) |p| p.stop();
}

const tests = struct {
    const testing = std.testing;

    test "plays through the player, and not when off" {
        start(testing.allocator);
        defer stop();
        var a: Loaded = undefined;
        a.initForTest(testing.allocator, "a");
        defer a.deinitForTest();

        const wav = sound.silence();
        try play(&a, &wav);
        try testing.expectError(error.InvalidSound, play(&a, "not a wav"));
        setEnabled(false);
        defer setEnabled(true);
        try play(&a, &wav);
        try testing.expectError(error.InvalidSound, play(&a, "still checked"));
        stopSound(&a);
    }
};

test {
    _ = tests;
}
