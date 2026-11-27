//! A few panels inside one of the Workbench's tabs, as tabs of their own or split in two.

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

how: How,
parts: [max_parts]Part,
len: u8,
pick: ?u8 = null,
shown: u8 = 0,

pub fn init(how: How, parts: []const Part) Group {
    std.debug.assert(parts.len <= max_parts and parts.len > 0);
    std.debug.assert(how != .split or parts.len == 2);
    var self: Group = .{ .how = how, .parts = undefined, .len = @intCast(parts.len) };
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

/// Puts `panel` in front from the next draw. Its tab's the Workbench's to show.
pub fn select(self: *Group, panel: *const anyopaque) void {
    if (self.indexOf(panel)) |i| self.pick = i;
}

/// In front at the last draw.
pub fn showing(self: *const Group, panel: *const anyopaque) bool {
    const i = self.indexOf(panel) orelse return false;
    return self.shown == i;
}

fn indexOf(self: *const Group, panel: *const anyopaque) ?u8 {
    for (self.parts[0..self.len], 0..) |p, i| if (p.owner == panel) return @intCast(i);
    return null;
}
