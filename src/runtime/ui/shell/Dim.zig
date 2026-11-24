//! Fades in and out, and darkens the game while it's in, either under the overlay's windows or over
//! them. Holding the game's input is `UiHold`'s. Render thread.

const Dim = @This();

const ui = @import("wraith_ui");

/// 0 is gone, 1 all the way in.
fade: f32 = 0,

pub const Mode = enum {
    /// Under every overlay window, so plugin windows still work.
    behind,
    /// Over every overlay window but what's drawn after it, and takes their clicks.
    blocking,
    /// Not drawn. Just the fade, for something that fades in on its own.
    none,
};

const fade_seconds = 0.25;
/// How dark the game gets.
const darkness = 0.6;

/// Each frame. Fades towards `wanted`, and gives it 0 once it's gone. `name` keeps blocking ones
/// apart.
pub fn update(self: *Dim, wanted: bool, mode: Mode, name: [:0]const u8) f32 {
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

/// Carries on from `from` as far in as it was, and `from` is gone.
pub fn takeOver(self: *Dim, from: *Dim) void {
    self.fade = @max(self.fade, from.fade);
    from.fade = 0;
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
