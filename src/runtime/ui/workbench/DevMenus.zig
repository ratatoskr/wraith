//! The workbench's ImGui and Danger menus, and the demo windows they open. Its thread.

const DevMenus = @This();

const std = @import("std");

const ui = @import("wraith_ui");

show_demo: bool = false,
show_metrics: bool = false,
show_id_stack: bool = false,
show_debug_log: bool = false,
guizmo: ui.GuizmoDemo = .{},
plot: ui.PlotDemo = .{},

pub fn drawMenus(self: *DevMenus) void {
    if (ui.menu("ImGui")) |menu| {
        defer menu.end();
        _ = ui.menuItem("Demo", .{ .checked = &self.show_demo });
        _ = ui.menuItem("Metrics", .{ .checked = &self.show_metrics });
        _ = ui.menuItem("ID stack tool", .{ .checked = &self.show_id_stack });
        _ = ui.menuItem("Debug log", .{ .checked = &self.show_debug_log });
        ui.separator();
        self.guizmo.menuItems();
        self.plot.menuItems();
    }

    if (ui.menu("Danger")) |menu| {
        defer menu.end();
        if (ui.menuItem("Abort", .{})) std.process.abort();
        if (ui.menuItem("Trigger Panic", .{})) @panic("Triggered panic from the workbench");
        if (ui.menuItem("Trigger Breakpoint", .{})) @breakpoint();
    }
}

pub fn drawWindows(self: *DevMenus) void {
    if (self.show_demo) ui.showDemoWindow(&self.show_demo);
    if (self.show_metrics) ui.showMetricsWindow(&self.show_metrics);
    if (self.show_id_stack) ui.showIdStackToolWindow(&self.show_id_stack);
    if (self.show_debug_log) ui.showDebugLogWindow(&self.show_debug_log);
    self.guizmo.draw();
    self.plot.draw();
}

pub fn deinit(self: *DevMenus) void {
    self.guizmo.deinit();
}
