//! A docked window of tabs: some of the Workbench's own panels, then the `workbench.plugins` tabs
//! whose `parent` is its name. Plugins name their own, like `FFXIV`; empty is Plugins.

const PanelGroup = @This();

const std = @import("std");

const ui = @import("wraith_ui");

const slots = @import("../../host/slots.zig");
const Group = @import("Group.zig");

const Panel = slots.Entry;

window: ui.Window,
/// Which plugin tabs it shows, by their `parent`. Null for none.
name: ?[]const u8,
own: [2]Group.Part = undefined,
own_len: u8 = 0,
/// What it says when there's nothing in it.
empty: [:0]const u8,
title_buf: [96:0]u8 = @splat(0),
name_buf: [64]u8 = undefined,
/// Its own part to bring to the front next frame.
pick_own: ?u8 = null,
/// A plugin panel to bring to the front next frame, by its label.
pick_label: ?u64 = null,
/// Opened itself once already, so closing it sticks.
opened_once: bool = false,
/// Whether its own parts show, like Classes only once there's C#.
own_shown: bool = true,

/// `title` includes its `###` id.
pub fn init(title: [:0]const u8, name: ?[]const u8, own: []const Group.Part, empty: [:0]const u8) PanelGroup {
    var self: PanelGroup = .{ .window = .{ .title = title }, .name = name, .empty = empty, .own_len = @intCast(own.len) };
    @memcpy(self.own[0..own.len], own);
    return self;
}

/// One a plugin named, titled with it. Null if the name's too long.
pub fn create(gpa: std.mem.Allocator, name: []const u8) !*PanelGroup {
    if (name.len > 64) return error.NameTooLong;
    const self = try gpa.create(PanelGroup);
    self.* = .{ .window = undefined, .name = null, .empty = "Nothing's in it." };
    @memcpy(self.name_buf[0..name.len], name);
    self.name = self.name_buf[0..name.len];
    const title = std.fmt.bufPrintSentinel(&self.title_buf, "{s}###wraith.group.{s}", .{ name, name }, 0) catch unreachable;
    self.window = .{ .title = title };
    return self;
}

/// Whether `p` is one of its tabs.
pub fn has(self: *const PanelGroup, p: *const Panel) bool {
    const name = self.name orelse return false;
    return std.mem.eql(u8, p.parent, name);
}

/// Each frame before drawing, open or not, after the slot's settled: picks up plugins' `focus` and
/// opens itself the first time there's something to show. Workbench thread.
pub fn poll(self: *PanelGroup, something_to_show: bool) void {
    var held = slots.take(.workbench_plugins);
    defer held.end();
    const taken = held.items();
    var any = false;
    for (taken) |p| {
        if (!self.has(p)) continue;
        any = true;
        if (p.focus_wanted.swap(false, .acq_rel)) {
            self.pick_label = std.hash.Wyhash.hash(0, p.label);
            self.window.focus();
        }
    }
    if (!self.opened_once and (something_to_show or any)) {
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
    var held = slots.take(.workbench_plugins);
    defer held.end();
    const taken = held.items();
    defer self.pick_own = null;
    defer self.pick_label = null;
    const own_len: u8 = if (self.own_shown) self.own_len else 0;
    var tabs: usize = 0;
    for (taken) |p| tabs += @intFromBool(self.has(p));
    if (own_len == 0 and tabs == 0) {
        ui.textDisabled("{s}", .{self.empty});
        return;
    }
    // One of its own needs no tab
    if (own_len == 1 and tabs == 0) return self.own[0].draw(self.own[0].owner);
    const bar = ui.tabBar("parts") orelse return;
    defer bar.end();
    for (self.own[0..own_len], 0..) |p, i| {
        const tab = ui.tabItem(p.label, .{ .select = self.pick_own != null and self.pick_own.? == i }) orelse continue;
        defer tab.end();
        const part = ui.child(p.label, .{ 0, 0 }, .{}) orelse continue;
        defer part.end();
        p.draw(p.owner);
    }
    for (taken) |p| {
        if (!self.has(p)) continue;
        const picked = if (self.pick_label) |h| h == std.hash.Wyhash.hash(0, p.label) else false;
        const tab = ui.tabItem(p.label, .{ .select = picked }) orelse continue;
        defer tab.end();
        p.shown.store(true, .release);
        const part = ui.child(p.label, .{ 0, 0 }, .{}) orelse continue;
        defer part.end();
        slots.draw(p, .{});
    }
}
