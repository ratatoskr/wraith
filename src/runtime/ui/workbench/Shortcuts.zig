//! The workbench's own keys, for inside its window. They're saved with Wraith's settings.

const Shortcuts = @This();

const std = @import("std");

const ui = @import("wraith_ui");
const Chord = @import("wraith_platform").input.Chord;

const Workbench = @import("Workbench.zig");
const ShellSettings = @import("../shell/ShellSettings.zig");
const Registry = @import("../../settings/Registry.zig");
const icons = @import("../fonts.zig").icons;

const popup = "Keyboard shortcuts##workbench_keys";

open_popup: bool = false,

pub fn open(self: *Shortcuts) void {
    self.open_popup = true;
}

pub fn draw(self: *Shortcuts, wb: *Workbench) void {
    if (self.open_popup) {
        self.open_popup = false;
        ui.openPopup(popup);
    }
    ui.setNextWindowSize(.{ ui.scaled(460), 0 }, .appearing);
    const modal = ui.modal(popup, .{ .auto_resize = false, .remember = true }) orelse return;
    defer modal.end();

    const shell = wb.shell orelse {
        ui.textDisabled("No game", .{});
        return closeButton();
    };
    const registry = shell.registry;
    for (shell.own.workbench_keys) |s| {
        const scope = ui.id(s);
        defer scope.end();
        const current = registry.get(s).key;
        ui.alignTextToFramePadding();
        ui.text("{s}", .{s.def.name});
        ui.sameLineWith(ui.scaled(170), -1);
        // Shortcuts in the workbench's own window take one key
        var picked: ?Chord = if (current) |k| k.first() else null;
        ui.setNextItemWidth(ui.scaled(200));
        if (ui.chordInput("##key", &picked, .{ .none = "No key" })) set(registry, s, .{ .key = if (picked) |p| .one(p) else null });
        const default = Registry.defaultOf(s.def.kind);
        if (!(Registry.Value{ .key = current }).eql(default)) {
            ui.sameLine();
            if (ui.iconButton(icons.rotate_ccw ++ "##reset", "Back to its default")) set(registry, s, default);
        }
    }
    ui.spacing();
    closeButton();
}

fn set(registry: *Registry, s: *Registry.Setting, v: Registry.Value) void {
    registry.set(s, v) catch |err| std.log.scoped(.wraith_ui).warn("Couldn't save {s}: {t}", .{ s.def.id, err });
}

fn closeButton() void {
    if (ui.button("Close") or ui.isKeyPressed(.escape, false)) ui.closePopup();
}
