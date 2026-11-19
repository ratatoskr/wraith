//! A docked window with a few panels in it, as tabs or split in two.

const Group = @This();

const std = @import("std");

const ui = @import("wraith_ui");

pub const max_parts = 8;

pub const Part = struct {
    label: [:0]const u8,
    owner: *anyopaque,
    draw: *const fn (owner: *anyopaque) void,

    pub fn of(label: [:0]const u8, panel: anytype) Part {
        const T = @typeInfo(@TypeOf(panel)).pointer.child;
        const Thunk = struct {
            fn draw(raw: *anyopaque) void {
                T.draw(@ptrCast(@alignCast(raw)));
            }
        };
        return .{ .label = label, .owner = panel, .draw = Thunk.draw };
    }
};

pub const How = union(enum) {
    tabs,
    split: ui.Split,
};

window: ui.Window,
how: How,
parts: [max_parts]Part,
len: u8,
pick: ?u8 = null,
shown: u8 = 0,

pub fn init(title: [:0]const u8, how: How, parts: []const Part) Group {
    std.debug.assert(parts.len <= max_parts and parts.len > 0);
    std.debug.assert(how != .split or parts.len == 2);
    var self: Group = .{ .window = .{ .title = title }, .how = how, .parts = undefined, .len = @intCast(parts.len) };
    @memcpy(self.parts[0..parts.len], parts);
    return self;
}

pub fn draw(self: *Group) void {
    switch (self.how) {
        .tabs => self.drawTabs(),
        .split => |*split| {
            if (split.first(self.parts[0].label)) |part| {
                defer part.end();
                self.parts[0].draw(self.parts[0].owner);
            }
            if (split.second(self.parts[1].label)) |part| {
                defer part.end();
                self.parts[1].draw(self.parts[1].owner);
            }
        },
    }
}

fn drawTabs(self: *Group) void {
    const bar = ui.tabBar("parts") orelse return;
    defer bar.end();
    defer self.pick = null;
    for (self.parts[0..self.len], 0..) |p, i| {
        const tab = ui.tabItem(p.label, .{ .select = self.pick != null and self.pick.? == i }) orelse continue;
        defer tab.end();
        self.shown = @intCast(i);
        const part = ui.child(p.label, .{ 0, 0 }, .{}) orelse continue;
        defer part.end();
        p.draw(p.owner);
    }
}

/// Brings it to the front.
pub fn focus(self: *Group, panel: *const anyopaque) void {
    if (self.indexOf(panel)) |i| self.pick = i;
    self.window.focus();
}

/// Without taking focus.
pub fn show(self: *Group, panel: *const anyopaque) void {
    if (!self.window.open) if (self.indexOf(panel)) |i| {
        self.pick = i;
    };
    self.window.show();
}

/// Opens it on `panel`'s tab, even if it was on another, without taking focus.
pub fn select(self: *Group, panel: *const anyopaque) void {
    if (self.indexOf(panel)) |i| self.pick = i;
    self.window.show();
}

/// Open with `panel`'s tab in front, as of the last frame.
pub fn showing(self: *const Group, panel: *const anyopaque) bool {
    const i = self.indexOf(panel) orelse return false;
    return self.window.open and self.shown == i;
}

fn indexOf(self: *const Group, panel: *const anyopaque) ?u8 {
    for (self.parts[0..self.len], 0..) |p, i| if (p.owner == panel) return @intCast(i);
    return null;
}
