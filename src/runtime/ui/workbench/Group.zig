//! Two panels inside one of the Workbench's tabs, split, like Scripts' Console and Sessions. Tabs
//! inside a tab are the `workbench` slot's, by `parent`.

const Group = @This();

const std = @import("std");

const ui = @import("wraith_ui");

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

split: ui.Split,
parts: [2]Part,

pub fn init(split: ui.Split, parts: [2]Part) Group {
    return .{ .split = split, .parts = parts };
}

pub fn draw(self: *Group) void {
    if (self.split.first(self.parts[0].label)) |part| {
        defer part.end();
        self.parts[0].draw(self.parts[0].owner);
    }
    if (self.split.second(self.parts[1].label)) |part| {
        defer part.end();
        self.parts[1].draw(self.parts[1].owner);
    }
}
