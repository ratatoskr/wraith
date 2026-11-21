//! Along the bottom of the Workbench, like an editor's. What's going on goes on the left, little
//! things to glance at on the right. Hover an item for more, click it, or right-click it for its
//! menu. Each frame, `begin` it after everything else in the window, then add `item`s.

const StatusBar = @This();

const std = @import("std");

const ui = @import("wraith_ui");

pub const Side = enum { left, right };

pub const Item = struct {
    /// Unique in the bar.
    id: [:0]const u8,
    text: []const u8,
    side: Side = .left,
    /// The usual text colour if null.
    color: ?[4]f32 = null,
    tooltip: ?[]const u8 = null,
};

pub const Response = struct {
    clicked: bool,
    /// Its right-click menu's open. Add `ui.menuItem`s, then `endMenu`.
    menu: bool,
};

list: ui.DrawList,
top: f32,
bottom: f32,
/// Where the next item on each side goes.
left: f32,
right: f32,

/// How much of the window to leave free for it.
pub fn height() f32 {
    return ui.frameHeight();
}

/// Across the bottom of the current window, over the last `height` of it.
pub fn begin() StatusBar {
    const pos = ui.getWindowPos();
    const size = ui.getWindowSize();
    const min: ui.Vec2 = .{ pos[0], pos[1] + size[1] - height() };
    const max: ui.Vec2 = .{ pos[0] + size[0], pos[1] + size[1] };
    const list = ui.getWindowDrawList();
    list.addRectFilled(min, max, ui.getColorU32(.menu_bar_bg));
    list.addLine(min, .{ max[0], min[1] }, ui.getColorU32(.border), 1);
    const edge = ui.scaled(4);
    return .{ .list = list, .top = min[1], .bottom = max[1], .left = min[0] + edge, .right = max[0] - edge };
}

pub fn item(self: *StatusBar, it: Item) Response {
    const pad = ui.scaled(8);
    const text_size = ui.calcTextSize(it.text);
    const width = text_size[0] + pad * 2;
    const x = switch (it.side) {
        .left => self.left,
        .right => self.right - width,
    };
    switch (it.side) {
        .left => self.left += width,
        .right => self.right -= width,
    }

    const min: ui.Vec2 = .{ x, self.top };
    const max: ui.Vec2 = .{ x + width, self.bottom };
    ui.setCursorScreenPos(min);
    _ = ui.invisibleButtonWith(it.id, .{ width, self.bottom - self.top }, .{ .right = true });
    if (ui.isItemHovered()) self.list.addRectFilled(min, max, ui.getColorU32(.header_hovered));
    const color = if (it.color) |v| ui.colorU32(v) else ui.getColorU32(.text);
    const text_at: ui.Vec2 = .{ x + pad, self.top + (self.bottom - self.top - text_size[1]) / 2 };
    self.list.addText(text_at, color, it.text);
    if (it.tooltip) |t| ui.tooltip("{s}", .{t});
    return .{
        .clicked = ui.isItemClicked(.left),
        .menu = ui.contextMenu(it.id) != null,
    };
}

/// After an item's menu, when `menu` said it was open.
pub fn endMenu() void {
    const menu: ui.Popup = .{};
    menu.end();
}
