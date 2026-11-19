//! Graphics drives tuft_input, delivering keybinds at the start of each frame.

const core = @import("wraith_core");
const tuft_input = @import("tuft_input");

const Graphics = @import("graphics/Graphics.zig");

const deliver_priority = 100;

/// Dispose `scope` before `window` and `keybinds` go.
pub fn wire(scope: *core.Scope, graphics: *Graphics, window: *tuft_input.Window, keybinds: *tuft_input.Keybinds) !void {
    try graphics.attach.subscribe(scope, window, attachWindow);
    try graphics.frame.subscribeOpts(scope, keybinds, deliver, .{ .priority = deliver_priority });
}

fn attachWindow(window: *tuft_input.Window, frame: *const Graphics.Frame) void {
    window.attach(@ptrCast(frame.window));
}

fn deliver(keybinds: *tuft_input.Keybinds, _: *const Graphics.Frame) void {
    keybinds.deliver();
}
