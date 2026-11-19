//! Search this process's memory for a value, Cheat Engine style.

const Search = @This();

const devtools = @import("tuft_devtools");
const ui = @import("wraith_ui");

const Workbench = @import("../Workbench.zig");

window: ui.Window = .{ .title = "Search", .size = .{ 640, 480 }, .min_size = .{ 440, 240 } },
wb: *Workbench,
view: devtools.SearchView,

/// Call before the workbench goes.
pub fn deinit(self: *Search) void {
    self.view.deinit();
}

pub fn draw(self: *Search) void {
    self.view.draw();
    const keys = &devtools.keys;
    var menu = ui.commands("search", .{ .activated = self.view.activated() });
    defer menu.end();
    const one = self.view.selection();
    if (menu.item(.{ .label = "Show in memory", .chord = keys.show_memory, .enabled = one != null, .default = true })) {
        self.wb.openMemory(one.?.address, one.?.len, .{ .start = one.?.address, .len = one.?.len });
    }
    if (menu.item(.{ .label = "Show as code", .chord = keys.show_code, .enabled = one != null })) self.wb.openCode(one.?.address);
    if (menu.item(.{ .label = "Add to address list", .chord = keys.add_to_list, .enabled = one != null, .tooltip = "Every picked result" })) {
        var hits: [256]devtools.SearchView.Hit = undefined;
        for (self.view.selectedHits(&hits)) |hit| self.wb.panels.addresses.add(hit.address, hit.kind, hit.len);
    }
    menu.separator();
    self.view.commands(&menu);
}
