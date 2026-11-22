//! The game's speed on the Workbench's menu bar, the same one the speed key and plugins set. It
//! changes as you slide it, without a toast, since you can see where it's at.

const GameSpeed = @This();

const std = @import("std");

const core = @import("wraith_core");
const ui = @import("wraith_ui");

const game_area = @import("../../host/game_area.zig");

const log = core.log.scoped(.wraith_ui);

/// Up to what the overlay's speed setting goes to.
pub const max = 10;

/// Said once, rather than every frame of a drag.
warned: bool = false,
/// Where it was drawn last, for tests.
rect: [2]ui.Vec2 = .{ .{ 0, 0 }, .{ 0, 0 } },

pub fn draw(self: *GameSpeed) void {
    ui.textDisabled("Speed", .{});
    ui.sameLine();
    var speed: f64 = game_area.currentSpeed();
    ui.setNextItemWidth(110);
    var changed = ui.sliderWith("##game_speed", &speed, 0, max, .{ .format = "%.2fx", .clamp = true, .logarithmic = true });
    self.rect = .{ ui.getItemRectMin(), ui.getItemRectMax() };
    if (ui.isItemClicked(.right)) {
        speed = 1;
        changed = true;
    }
    ui.tooltip("How fast the game runs. Right-click for normal. 0 pauses in games whose plugin handles speed, like Unity's, and is as slow as it goes elsewhere", .{});
    if (changed) self.set(speed);
}

pub fn set(self: *GameSpeed, speed: f64) void {
    game_area.setSpeedForPlayer(speed) catch |err| {
        if (!self.warned) log.warn("Couldn't change the game's speed: {t}", .{err});
        self.warned = true;
        return;
    };
    self.warned = false;
}
