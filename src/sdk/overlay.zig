//! Dear ImGui through the runtime's, for `sdk.ui`. Draw from `sdk.frame.onFrame`. Toasts, the cursor,
//! the game's input and menu items are `wraith.sal`'s `ui` area.

const std = @import("std");

const api = @import("wraith_api");
const Owner = @import("Owner.zig");
const ui = @import("wraith_ui");

const log = @import("log.zig").scoped(.wraith_sdk);

var bound = false;

pub fn attach() void {
    const owner = Owner.own() orelse return;
    const area = owner.root.ui();
    if (!area.available()) return;
    const hosted = area.imguiVersion();
    if (hosted != ui.version) {
        log.warn("UI unavailable: built against ImGui {d}, the runtime hosts {d}", .{ ui.version, hosted });
        return;
    }
    bound = true;
    ui.bind(resolve);
}

pub fn detach() void {
    if (!bound) return;
    ui.bind(null);
    bound = false;
}

pub fn available() bool {
    return bound;
}

fn resolve(name: []const u8) ?*const anyopaque {
    const owner = Owner.own() orelse return null;
    return @ptrFromInt(owner.root.ui().imguiProc(name));
}
