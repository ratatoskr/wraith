//! A docked window of tabs: some of the Workbench's own panels, then plugins' panels from
//! `host.workbench_panels`. The engine's group has Classes and engine plugins' panels, named after
//! the game's engine. The plugins' group has the rest.

const PanelGroup = @This();

const std = @import("std");

const ui = @import("wraith_ui");

const panels = @import("../../host/workbench_panels.zig");
const Group = @import("Group.zig");

const Panel = panels.Panel;

/// Most plugin panels a group shows.
pub const max_panels = 32;

window: ui.Window,
/// Engine plugins' panels, or the rest.
engine: bool,
own: [2]Group.Part = undefined,
own_len: u8 = 0,
/// What it says when there's nothing in it.
empty: [:0]const u8,
title_buf: [96:0]u8 = @splat(0),
/// Its own part to bring to the front next frame.
pick_own: ?u8 = null,
/// A plugin panel to bring to the front next frame, by its label.
pick_label: ?u64 = null,
/// Opened itself once already, so closing it sticks.
opened_once: bool = false,

pub fn init(engine: bool, own: []const Group.Part, empty: [:0]const u8) PanelGroup {
    var self: PanelGroup = .{
        .window = .{ .title = if (engine) "Engine###wraith.engine" else "Plugins###wraith.plugins" },
        .engine = engine,
        .empty = empty,
        .own_len = @intCast(own.len),
    };
    @memcpy(self.own[0..own.len], own);
    return self;
}

/// `name` like `Unity`, keeping it the same window.
pub fn setName(self: *PanelGroup, name: []const u8) void {
    const id = if (self.engine) "###wraith.engine" else "###wraith.plugins";
    const title = std.fmt.bufPrintSentinel(&self.title_buf, "{s}{s}", .{ name, id }, 0) catch return;
    if (!std.mem.eql(u8, title, self.window.title)) self.window.title = title;
}

/// Each frame before drawing, whether it's open or not: picks up `focus` from plugins, and opens
/// itself the first time there's something to show. Workbench thread.
pub fn poll(self: *PanelGroup, something_to_show: bool) void {
    var buf: [max_panels]*Panel = undefined;
    const taken = panels.take(self.engine, &buf);
    defer panels.release(taken);
    for (taken) |p| {
        // Drawing it sets it again
        p.shown.store(false, .release);
        if (p.focus_wanted.swap(false, .acq_rel)) {
            self.pick_label = std.hash.Wyhash.hash(0, p.label);
            self.window.focus();
        }
    }
    if (!self.opened_once and (something_to_show or taken.len > 0)) {
        self.opened_once = true;
        self.window.show();
    }
}

/// Brings one of its own parts to the front.
pub fn focusOwn(self: *PanelGroup, owner: *const anyopaque) void {
    for (self.own[0..self.own_len], 0..) |p, i| if (p.owner == owner) {
        self.pick_own = @intCast(i);
    };
    self.window.focus();
}

pub fn draw(self: *PanelGroup) void {
    var buf: [max_panels]*Panel = undefined;
    const taken = panels.take(self.engine, &buf);
    defer panels.release(taken);
    defer self.pick_own = null;
    defer self.pick_label = null;
    if (self.own_len == 0 and taken.len == 0) {
        ui.textDisabled("{s}", .{self.empty});
        return;
    }
    const bar = ui.tabBar("parts") orelse return;
    defer bar.end();
    for (self.own[0..self.own_len], 0..) |p, i| {
        const tab = ui.tabItem(p.label, .{ .select = self.pick_own != null and self.pick_own.? == i }) orelse continue;
        defer tab.end();
        const part = ui.child(p.label, .{ 0, 0 }, .{}) orelse continue;
        defer part.end();
        p.draw(p.owner);
    }
    for (taken) |p| {
        const picked = if (self.pick_label) |h| h == std.hash.Wyhash.hash(0, p.label) else false;
        const tab = ui.tabItem(p.label, .{ .select = picked }) orelse continue;
        defer tab.end();
        p.shown.store(true, .release);
        const part = ui.child(p.label, .{ 0, 0 }, .{}) orelse continue;
        defer part.end();
        panels.drawPanel(p);
    }
}
