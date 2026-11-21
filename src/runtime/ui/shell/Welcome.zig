//! The first time Wraith runs, a window over the dimmed game. It holds the mouse and keyboard till
//! Continue's clicked, then the shell hands over to the overlay. Render thread.

const Welcome = @This();

const ui = @import("wraith_ui");
const Chord = @import("wraith_platform").input.Chord;

const Overlay = @import("../Overlay.zig");
const Dim = @import("Dim.zig");

/// Showing, or fading out.
open: bool = false,
/// Continue was clicked, so it's on its way out.
leaving: bool = false,
dim: Dim = .{},
choices: Choices = .{},

/// What's picked in it, from the settings to start.
pub const Choices = struct {
    overlay_key: Chord = .{ .key = .insert },
};

const width = 480;

/// What was picked, the frame Continue's clicked. The caller takes over its dim and input then,
/// with `Dim.takeOver`, or calls `dismiss`.
pub fn draw(self: *Welcome, overlay: *Overlay) ?Choices {
    if (!self.open) return null;
    // Covers any plugin windows too, so only this takes clicks
    const fade = self.dim.update(overlay, !self.leaving, .blocking, "##wraith.welcome_dim");
    if (fade == 0) {
        self.open = false;
        return null;
    }

    const viewport = ui.mainViewport();
    const faded = ui.styleVars(.{ .alpha = fade });
    defer faded.end();
    // The whole viewport's middle, not just its work area's
    const centre: ui.Vec2 = .{ viewport.pos[0] + viewport.size[0] / 2, viewport.pos[1] + viewport.size[1] / 2 };
    ui.setNextWindowOnMainViewport();
    ui.setNextWindowPos(centre, .always, .{ 0.5, 0.5 });
    if (!self.leaving) ui.setNextWindowFocus();
    // 0 height fits it to what's in it
    const win = ui.window("Welcome to Wraith###wraith.welcome", .{
        .size = .{ width, 0 },
        .size_cond = .always,
        .flags = .{ .no_resize = true, .no_move = true, .no_collapse = true, .no_saved_settings = true, .no_docking = true },
    }) orelse return null;
    defer win.end();
    Dim.bringToFront();
    if (self.leaving) return null;
    self.drawChoices();
    ui.spacing();
    if (ui.button("Continue")) {
        self.leaving = true;
        return self.choices;
    }
    return null;
}

fn drawChoices(self: *Welcome) void {
    ui.separatorText("Overlay key");
    ui.textWrapped("The key that brings up Wraith over the game. Click it to pick another.", .{});
    var key: ?Chord = self.choices.overlay_key;
    ui.setNextItemWidth(160);
    // Escape leaves it as it was, and there's always one
    if (ui.chordInput("##overlay_key", &key, .{})) self.choices.overlay_key = key.?;
}

/// Fades it out and gives the game its input back.
pub fn dismiss(self: *Welcome, overlay: *Overlay) void {
    self.leaving = true;
    self.dim.release(overlay);
}

/// Gives back anything it's holding.
pub fn deinit(self: *Welcome, overlay: *Overlay) void {
    self.dim.release(overlay);
}
