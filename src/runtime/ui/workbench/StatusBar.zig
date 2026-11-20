//! Along the bottom of the Workbench, like an editor's. What's going on goes on the left, little
//! things to glance at on the right. Hover an item for more, click it, or right-click it for its
//! menu. Each frame, `begin` it after everything else in the window, then add `item`s.

const StatusBar = @This();

const std = @import("std");

const ui = @import("wraith_ui");

const c = @import("../imgui.zig").c;

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

list: *c.ImDrawList,
top: f32,
bottom: f32,
/// Where the next item on each side goes.
left: f32,
right: f32,

/// How much of the window to leave free for it.
pub fn height() f32 {
    return c.ImGui_GetFrameHeight();
}

/// Across the bottom of the current window, over the last `height` of it.
pub fn begin() StatusBar {
    const pos = c.ImGui_GetWindowPos();
    const size = c.ImGui_GetWindowSize();
    const min: c.ImVec2 = .{ .x = pos.x, .y = pos.y + size.y - height() };
    const max: c.ImVec2 = .{ .x = pos.x + size.x, .y = pos.y + size.y };
    const list = c.ImGui_GetWindowDrawList();
    c.ImDrawList_AddRectFilled(list, min, max, c.ImGui_GetColorU32(c.ImGuiCol_MenuBarBg));
    c.ImDrawList_AddLine(list, min, .{ .x = max.x, .y = min.y }, c.ImGui_GetColorU32(c.ImGuiCol_Border));
    const edge = ui.scaled(4);
    return .{ .list = list, .top = min.y, .bottom = max.y, .left = min.x + edge, .right = max.x - edge };
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

    const min: c.ImVec2 = .{ .x = x, .y = self.top };
    const max: c.ImVec2 = .{ .x = x + width, .y = self.bottom };
    c.ImGui_SetCursorScreenPos(min);
    _ = c.ImGui_InvisibleButton(it.id, .{ .x = width, .y = self.bottom - self.top }, c.ImGuiButtonFlags_MouseButtonLeft | c.ImGuiButtonFlags_MouseButtonRight);
    if (c.ImGui_IsItemHovered(0)) c.ImDrawList_AddRectFilled(self.list, min, max, c.ImGui_GetColorU32(c.ImGuiCol_HeaderHovered));
    const color = if (it.color) |v| c.ImGui_GetColorU32ImVec4(.{ .x = v[0], .y = v[1], .z = v[2], .w = v[3] }) else c.ImGui_GetColorU32(c.ImGuiCol_Text);
    const text_at: c.ImVec2 = .{ .x = x + pad, .y = self.top + (self.bottom - self.top - text_size[1]) / 2 };
    c.ImDrawList_AddTextEx(self.list, text_at, color, @ptrCast(it.text.ptr), @ptrCast(it.text.ptr + it.text.len));
    if (it.tooltip) |t| ui.tooltip("{s}", .{t});
    return .{
        .clicked = c.ImGui_IsItemClicked(),
        .menu = c.ImGui_BeginPopupContextItemEx(it.id, c.ImGuiPopupFlags_MouseButtonRight),
    };
}

/// After an item's menu, when `menu` said it was open.
pub fn endMenu() void {
    c.ImGui_EndPopup();
}
