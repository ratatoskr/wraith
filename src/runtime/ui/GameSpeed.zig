//! The game's speed as a slider with a pause button, shared by the Workbench, Settings and Photo
//! mode. Slowing and pausing need a plugin that handles the game's speed.

const GameSpeed = @This();

const std = @import("std");

const core = @import("wraith_core");
const ui = @import("wraith_ui");

const game_area = @import("../host/game_area.zig");
const icons = @import("icons.zig");

const log = core.log.scoped(.wraith_ui);

pub const max = 10;

/// Why it only speeds up, for wherever it's explained.
pub const only_faster = "This game has no plugin that handles its speed, so Wraith can only speed it up.";
/// Why it can't be changed now, for wherever it's explained.
pub const off_now = "This game's plugin keeps its speed as it is for now, and turns speed on where it works, like in a photo mode.";

pub const Options = struct {
    /// The slider's, unscaled. 0 takes what's left of the line.
    width: f32 = 110,
    /// "Speed" before it.
    label: bool = true,
    /// Says under it why it only speeds up, when it does.
    explain: bool = false,
};

/// Said once, rather than every frame of a drag.
warned: bool = false,
/// Where the slider was drawn last, for tests.
rect: [2]ui.Vec2 = .{ .{ 0, 0 }, .{ 0, 0 } },

pub fn draw(self: *GameSpeed, options: Options) void {
    const on = game_area.controllable();
    const can_slow = game_area.canSlow();
    if (options.label) {
        ui.textDisabled("Speed", .{});
        ui.sameLine();
    }
    const all_off = ui.disabled(!on);
    defer all_off.end();
    const is_paused = game_area.paused();
    {
        const off = ui.disabled(!can_slow);
        defer off.end();
        const tip = if (!can_slow) "Pausing needs a plugin that handles this game's speed" else if (is_paused) "Carry on at the speed from before" else "Pause the game";
        if (ui.iconButton(if (is_paused) icons.play ++ "##game_speed_pause" else icons.pause ++ "##game_speed_pause", tip)) {
            self.report(game_area.setPausedForPlayer(!is_paused));
        }
    }
    ui.sameLine();
    var speed: f64 = game_area.currentSpeed();
    ui.setNextItemWidth(if (options.width == 0) -std.math.floatMin(f32) else ui.scaled(options.width));
    var changed = ui.sliderWith("##game_speed", &speed, if (can_slow) 0 else 1, max, .{ .format = "%.2fx", .clamp = true, .logarithmic = true });
    self.rect = .{ ui.getItemRectMin(), ui.getItemRectMax() };
    if (ui.isItemClicked(.right)) {
        speed = 1;
        changed = true;
    }
    if (!on) {
        ui.tooltip("{s}", .{off_now});
    } else if (can_slow) {
        ui.tooltip("How fast the game runs. Right-click for normal, and 0 pauses", .{});
    } else ui.tooltip("How fast the game runs. Right-click for normal. Only faster in this game, since it has no plugin that handles its speed", .{});
    if (changed and on) self.report(game_area.setSpeedForPlayer(speed));
    if (options.explain) {
        if (!on) ui.textWrapped("{s}", .{off_now}) else if (!can_slow) ui.textWrapped("{s}", .{only_faster});
    }
}

fn report(self: *GameSpeed, result: anyerror!void) void {
    result catch |err| {
        if (!self.warned) log.warn("Couldn't change the game's speed: {t}", .{err});
        self.warned = true;
        return;
    };
    self.warned = false;
}
