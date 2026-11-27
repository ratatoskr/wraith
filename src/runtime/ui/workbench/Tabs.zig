//! The Workbench's tabs: everything in the `workbench` slot, Wraith's own or a plugin's, is a docked
//! window of its own. Its label's ID part is how ImGui remembers where it was moved, so it only goes
//! to its place the first time, or when it comes back and its spot's gone.

const Tabs = @This();

const std = @import("std");

const ui = @import("wraith_ui");
const tuft_imgui = @import("tuft_imgui");

const c = @import("../imgui.zig").c;
const slots = @import("../../host/slots.zig");

const gpa = std.heap.smp_allocator;

pub const Tab = struct {
    window: ui.Window,
    place: slots.Place,
    /// Lower comes first, then whichever came first.
    order: i32,
    seq: u32,
    /// Open last frame, so it's docked again if it's come back with nowhere to go.
    was_open: bool = false,
    /// Still in the slot.
    seen: bool = true,
};

/// The node for a place, asked only when a tab has nowhere to go.
pub const Places = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, place: slots.Place) ?c.ImGuiID,
};

list: std.ArrayList(*Tab) = .empty,

pub fn deinit(self: *Tabs) void {
    for (self.list.items) |t| free(t);
    self.list.deinit(gpa);
}

/// A window for what's new in the slot, and none for what's gone. Workbench thread.
pub fn sync(self: *Tabs) void {
    var held = slots.take(.workbench);
    defer held.end();
    self.update(held.items());
}

/// Each frame on the Workbench's thread. `before` runs before each window.
pub fn draw(self: *Tabs, places: Places, before: ui.WindowSystem.Hook) void {
    var held = slots.take(.workbench);
    defer held.end();
    const taken = held.items();
    slots.settle(taken);
    self.update(taken);
    for (taken) |e| {
        const t = self.find(e.label) orelse continue;
        if (e.focus_wanted.swap(false, .acq_rel)) t.window.focus();
        before.func(before.ctx);
        drawOne(t, e, places);
    }
}

/// Its window, by its label.
pub fn find(self: *const Tabs, label: []const u8) ?*Tab {
    for (self.list.items) |t| if (std.mem.eql(u8, t.window.title, label)) return t;
    return null;
}

/// Where an open one of `place` is docked, as of last frame.
pub fn nodeOf(self: *const Tabs, place: slots.Place) ?c.ImGuiID {
    for (self.list.items) |t| {
        if (t.place != place or !t.was_open) continue;
        const node = tuft_imgui.dock.of(t.window.title) orelse continue;
        if (tuft_imgui.dock.exists(node)) return node;
    }
    return null;
}

fn update(self: *Tabs, taken: []const *slots.Entry) void {
    for (self.list.items) |t| t.seen = false;
    for (taken) |e| {
        const t = self.find(e.label) orelse (self.add(e) catch continue);
        t.seen = true;
    }
    var i = self.list.items.len;
    while (i > 0) {
        i -= 1;
        if (!self.list.items[i].seen) free(self.list.orderedRemove(i));
    }
}

fn add(self: *Tabs, e: *const slots.Entry) !*Tab {
    const t = try gpa.create(Tab);
    errdefer gpa.destroy(t);
    const title = try gpa.dupeSentinel(u8, e.label, 0);
    errdefer gpa.free(title);
    // Open from the start, behind what you're looking at
    t.* = .{ .window = .{ .title = title, .open = true, .flags = .{ .no_focus_on_appearing = true } }, .place = e.place, .order = e.order, .seq = e.seq };
    // Kept in order, which the default layout and View go by
    var at = self.list.items.len;
    while (at > 0 and comesBefore(t, self.list.items[at - 1])) at -= 1;
    try self.list.insert(gpa, at, t);
    return t;
}

fn comesBefore(a: *const Tab, b: *const Tab) bool {
    return if (a.order != b.order) a.order < b.order else a.seq < b.seq;
}

fn free(t: *Tab) void {
    gpa.free(t.window.title);
    gpa.destroy(t);
}

fn drawOne(t: *Tab, e: *slots.Entry, places: Places) void {
    const w = &t.window;
    defer t.was_open = w.open;
    if (!w.open) return;
    // New, or back from closed: to its place, unless ImGui still has a spot for it
    if (!t.was_open) {
        const kept = if (tuft_imgui.dock.of(w.title)) |n| tuft_imgui.dock.exists(n) else false;
        if (!kept) if (places.func(places.ctx, t.place)) |n| c.ImGui_SetNextWindowDockID(n, c.ImGuiCond_Always);
    }
    if (w.raise) {
        w.raise = false;
        ui.setNextWindowFocus();
    }
    const scope = ui.window(w.title, .{ .open = &w.open, .flags = w.flags }) orelse return;
    defer scope.end();
    e.shown.store(true, .release);
    slots.draw(e, .{});
}
