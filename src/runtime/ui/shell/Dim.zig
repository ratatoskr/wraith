//! Darkens the game, fading in and out, and holds the mouse, keyboard and controllers while it's
//! wanted. Render thread.

const Dim = @This();

const ui = @import("wraith_ui");

const Overlay = @import("../Overlay.zig");

/// 0 is gone, 1 all the way in.
fade: f32 = 0,
holding: bool = false,
/// Only while holding, and while the overlay's setting wants it.
holding_gamepad: bool = false,

pub const Mode = enum {
    /// Under every overlay window, so plugin windows still work.
    behind,
    /// Over every overlay window but what's drawn after it, and takes their clicks.
    blocking,
    /// Not drawn. Just the fade and holding the input.
    none,
};

const fade_seconds = 0.25;
/// How dark the game gets.
const darkness = 0.6;

/// Each frame. Fades towards `wanted`, and gives it 0 once it's gone. `name` keeps blocking ones
/// apart.
pub fn update(self: *Dim, overlay: *Overlay, wanted: bool, mode: Mode, name: [:0]const u8) f32 {
    self.hold(overlay, wanted);
    const step = ui.getIO().DeltaTime / fade_seconds;
    self.fade = if (wanted) @min(self.fade + step, 1) else @max(self.fade - step, 0);
    if (self.fade == 0) return 0;
    const viewport = ui.mainViewport();
    const colour = ui.rgba(0, 0, 0, @intFromFloat(darkness * self.fade * 255));
    switch (mode) {
        .behind => fill(ui.getBackgroundDrawList(), viewport, colour),
        .blocking => drawBlocker(viewport, colour, name),
        .none => {},
    }
    return self.fade;
}

/// Gives the game its input back now, without waiting for `update`.
pub fn release(self: *Dim, overlay: *Overlay) void {
    self.hold(overlay, false);
}

/// Carries on from `from` without a gap. It's as dark as it was, and holds before `from` lets go.
pub fn takeOver(self: *Dim, overlay: *Overlay, from: *Dim) void {
    self.fade = @max(self.fade, from.fade);
    self.hold(overlay, true);
    from.release(overlay);
    from.fade = 0;
}

fn hold(self: *Dim, overlay: *Overlay, on: bool) void {
    if (on != self.holding) {
        self.holding = on;
        overlay.requestCursor(on);
        overlay.take(.keyboard, on);
        overlay.take(.mouse, on);
    }
    // Checked every frame, so changing the setting while open takes effect
    const pad = on and overlay.ui_takes_gamepad.load(.acquire);
    if (pad == self.holding_gamepad) return;
    self.holding_gamepad = pad;
    overlay.take(.gamepad, pad);
}

fn drawBlocker(viewport: ui.Viewport, colour: u32, name: [:0]const u8) void {
    ui.setNextWindowOnMainViewport();
    ui.setNextWindowPos(viewport.pos, .always, .{ 0, 0 });
    ui.setNextWindowSize(viewport.size, .always);
    const win = ui.window(name, .{ .flags = .{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_scrollbar = true,
        .no_collapse = true,
        .no_background = true,
        .no_saved_settings = true,
        .no_focus_on_appearing = true,
        .no_nav = true,
        .no_docking = true,
    } }) orelse return;
    defer win.end();
    bringToFront();
    const draw_list = ui.getWindowDrawList();
    draw_list.pushClipRectFullScreen();
    defer draw_list.popClipRect();
    fill(draw_list, viewport, colour);
}

fn fill(draw_list: ui.DrawList, viewport: ui.Viewport, colour: u32) void {
    const min = viewport.pos;
    draw_list.addRectFilled(min, .{ min[0] + viewport.size[0], min[1] + viewport.size[1] }, colour);
}

/// Over the other windows. Call between a window's begin and end.
pub fn bringToFront() void {
    if (ui.rawOptional(fn () callconv(.c) void, "tuft_imgui_bring_window_to_front")) |f| f();
}
