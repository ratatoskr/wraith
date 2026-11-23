//! The game's speed, as a slider with a pause button by it. The Workbench, Settings and Photo mode
//! each draw one, and they all show and set the same speed, whoever else set it, like a key or a
//! plugin. It changes as you slide it, without a toast, since you can see where it's at.

const GameSpeed = @This();

const std = @import("std");

const core = @import("wraith_core");
const ui = @import("wraith_ui");

const game_area = @import("../host/game_area.zig");
const icons = @import("icons.zig");

const log = core.log.scoped(.wraith_ui);

pub const max = 10;

pub const Options = struct {
    /// The slider's, unscaled. 0 takes what's left of the line.
    width: f32 = 110,
    /// "Speed" before it.
    label: bool = true,
};

/// Said once, rather than every frame of a drag.
warned: bool = false,
/// Where the slider was drawn last, for tests.
rect: [2]ui.Vec2 = .{ .{ 0, 0 }, .{ 0, 0 } },

pub fn draw(self: *GameSpeed, options: Options) void {
    if (options.label) {
        ui.textDisabled("Speed", .{});
        ui.sameLine();
    }
    const is_paused = game_area.paused();
    if (ui.iconButton(if (is_paused) icons.play ++ "##game_speed_pause" else icons.pause ++ "##game_speed_pause", if (is_paused) "Carry on at the speed from before" else "Pause the game")) {
        self.report(game_area.setPausedForPlayer(!is_paused));
    }
    ui.sameLine();
    var speed: f64 = game_area.currentSpeed();
    ui.setNextItemWidth(if (options.width == 0) -std.math.floatMin(f32) else ui.scaled(options.width));
    var changed = ui.sliderWith("##game_speed", &speed, 0, max, .{ .format = "%.2fx", .clamp = true, .logarithmic = true });
    self.rect = .{ ui.getItemRectMin(), ui.getItemRectMax() };
    if (ui.isItemClicked(.right)) {
        speed = 1;
        changed = true;
    }
    ui.tooltip("How fast the game runs. Right-click for normal. 0 pauses in games whose plugin handles speed, like Unity's and Unreal's, and is as slow as it goes elsewhere", .{});
    if (changed) self.report(game_area.setSpeedForPlayer(speed));
}

fn report(self: *GameSpeed, result: anyerror!void) void {
    result catch |err| {
        if (!self.warned) log.warn("Couldn't change the game's speed: {t}", .{err});
        self.warned = true;
        return;
    };
    self.warned = false;
}