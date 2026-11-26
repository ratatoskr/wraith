//! Dear ImGui through the runtime, as `sdk.ui`. Draw from `sdk.threads.onDraw`.

const std = @import("std");

const api = @import("wraith_api");
const Owner = @import("Owner.zig");
const ui = @import("wraith_ui");

const W = api.wraith;

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

/// A move/rotate/scale gizmo. One shows at a time (the latest). Any thread, so a tick can do it all:
///
///     if (self.gizmo.moved()) |m| moveTo(picked, m);
///     self.gizmo.place(worldOf(picked));
pub const Gizmo = struct {
    object: W.Gizmo,

    pub const Tool = W.Gizmo.Tool;

    /// In front of any other, like when something's picked for it. It needs a `place`.
    pub fn show(self: Gizmo) void {
        self.object.show();
    }

    /// Till the next `show`. Whichever was shown before it shows again.
    pub fn hide(self: Gizmo) void {
        self.object.hide();
    }

    /// Where it is in the world, each tick so it keeps up. It stays put while it's dragged.
    pub fn place(self: Gizmo, world: W.Mat4) void {
        self.object.place(world);
    }

    pub fn setTool(self: Gizmo, tool: Tool) void {
        self.object.setTool(tool);
    }

    /// Along the world's axes rather than its own.
    pub fn setWorldAxes(self: Gizmo, on: bool) void {
        self.object.setWorldAxes(on);
    }

    /// Where it's been dragged to since you last asked, or null. The end of a drag comes through too.
    pub fn moved(self: Gizmo) ?W.Mat4 {
        return self.object.moved();
    }

    pub fn dragging(self: Gizmo) bool {
        return self.object.dragging();
    }

    /// The mouse was on it last frame, so a click there is for it.
    pub fn hovered(self: Gizmo) bool {
        return self.object.hovered();
    }

    /// Never shows again. Fine to call twice.
    pub fn remove(self: Gizmo) void {
        self.object.remove();
    }
};

pub fn addGizmo() error{ OwnerGone, Failed }!Gizmo {
    const owner = Owner.current() orelse return error.OwnerGone;
    const object = owner.root.ui().addGizmo();
    if (object.table == null) return error.Failed;
    return .{ .object = object };
}

fn resolve(name: []const u8) ?*const anyopaque {
    const owner = Owner.own() orelse return null;
    return @ptrFromInt(owner.root.ui().imguiProc(name));
}
