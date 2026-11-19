//! The workbench's command keys, from settings to the views.

const std = @import("std");

const devtools = @import("tuft_devtools");
const tuft_imgui = @import("tuft_imgui");
const ui = @import("wraith_ui");

const Settings = @import("Settings.zig");

pub fn apply(keys: Settings.Keys) void {
    inline for (@typeInfo(Settings.Keys).@"struct".field_names) |name| {
        @field(devtools.keys, name) = chord(@field(keys, name));
    }
}

/// Unbound ones never are.
pub fn pressed(bound: ?ui.Chord) bool {
    const ch = bound orelse return false;
    return ch.pressed();
}

fn chord(from: @import("wraith_platform").input.Chord) ui.Chord {
    return .{
        .key = @fromBackingInt(@intCast(tuft_imgui.input.key(from.key))),
        .ctrl = from.mods.ctrl,
        .shift = from.mods.shift,
        .alt = from.mods.alt,
    };
}

test "default keys" {
    const defaults: devtools.Keys = .{};
    const saved = devtools.keys;
    defer devtools.keys = saved;
    devtools.keys = .{ .copy = null };
    apply(.{});
    inline for (@typeInfo(devtools.Keys).@"struct".field_names) |name| {
        try std.testing.expectEqual(@field(defaults, name), @field(devtools.keys, name));
    }
}
