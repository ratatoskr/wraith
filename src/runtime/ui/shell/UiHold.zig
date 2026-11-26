//! Holds the game's input while a Wraith screen's up: cursor, mouse, keyboard, and controllers if
//! the overlay's setting wants them. Leaves mouse and keyboard in mouse-free games unless `always`. Render thread.

const UiHold = @This();

const Overlay = @import("../Overlay.zig");

/// Takes the mouse and keyboard even where the game leaves the mouse free, for screens that must be answered.
always: bool = false,
holding: bool = false,
/// The mouse, keyboard and cursor, while holding.
holding_input: bool = false,
/// Only while holding, and while the overlay's setting wants it.
holding_gamepad: bool = false,

/// Each frame, so changing the settings while it's up counts straight away.
pub fn set(self: *UiHold, overlay: *Overlay, on: bool) void {
    self.holding = on;
    const input = on and (self.always or !overlay.mouseFree());
    if (input != self.holding_input) {
        self.holding_input = input;
        overlay.requestCursor(input);
        overlay.take(.keyboard, input);
        overlay.take(.mouse, input);
    }
    const pad = on and overlay.ui_takes_gamepad.load(.acquire);
    if (pad == self.holding_gamepad) return;
    self.holding_gamepad = pad;
    overlay.take(.gamepad, pad);
}

/// Gives the game its input back now.
pub fn release(self: *UiHold, overlay: *Overlay) void {
    self.set(overlay, false);
}

/// Carries on from `from` without a gap, holding before it lets go.
pub fn takeOver(self: *UiHold, overlay: *Overlay, from: *UiHold) void {
    self.set(overlay, true);
    from.release(overlay);
}
