//! The Workbench's tabs: everything in the `workbench` slot, Wraith's own or a plugin's, is a docked
//! window of its own, or one per id for a tab of many, or a tab inside the one it names as its
//! `parent`. Its label's ID part is how ImGui remembers
//! where it was moved, so it only goes to its place the first time, or when it comes back and its
//! spot's gone.

const Tabs = @This();

const std = @import("std");
const core = @import("wraith_core");

const ui = @import("wraith_ui");
const tuft_imgui = @import("tuft_imgui");
const W = @import("wraith_api").wraith;

const c = @import("../imgui.zig").c;
const slots = @import("../../host/slots.zig");

const gpa = core.heap.main;

pub const Tab = struct {
    window: ui.Window,
    /// Its entry's label, which it goes with.
    key: [:0]u8,
    /// Which one, for a tab of many. Null for one of its own.
    id: ?[]u8,
    place: slots.Place,
    /// Lower comes first, then whichever came first.
    order: i32,
    seq: u32,
    /// Made after others of its entry.
    sub: u32 = 0,
    /// Open last frame, so it's docked again if it's come back with nowhere to go.
    was_open: bool = false,
    /// Still in the slot.
    seen: bool = true,
    /// One of many seen closed by a draw, so it goes at the next update.
    closing: bool = false,
    /// For one holding others: the label of the one in front at the last draw, and one to bring there.
    front: Label = .{},
    pick: Label = .{},
};

/// A tab inside another's label, kept by value since its entry can go.
pub const Label = struct {
    buf: [160]u8 = undefined,
    len: usize = 0,

    fn set(self: *Label, text: []const u8) void {
        self.len = @min(text.len, self.buf.len);
        @memcpy(self.buf[0..self.len], text[0..self.len]);
    }

    pub fn is(self: *const Label, text: []const u8) bool {
        return self.len > 0 and std.mem.eql(u8, self.buf[0..self.len], text);
    }
};

/// A tab of many, for View's New.
pub const Kind = struct {
    key: [:0]u8,
    title: [:0]u8,
};

/// The node for a place, asked only when a tab has nowhere to go.
pub const Places = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, place: slots.Place) ?c.ImGuiID,
};

list: std.ArrayList(*Tab) = .empty,
kinds: std.ArrayList(Kind) = .empty,
next_sub: u32 = 1,

pub fn deinit(self: *Tabs) void {
    for (self.list.items) |t| free(t);
    self.list.deinit(gpa);
    for (self.kinds.items) |k| freeKind(k);
    self.kinds.deinit(gpa);
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
    // One inside another brings that to the front, on it
    for (taken) |e| {
        if (e.parent.len == 0 or !e.focus_wanted.swap(false, .acq_rel)) continue;
        const t = parentIn(self, taken, e) orelse continue;
        t.pick.set(e.label);
        t.window.focus();
    }
    for (taken) |e| {
        if (e.parent.len > 0) continue;
        if (!e.multi) {
            const t = self.find(e.label) orelse continue;
            if (e.focus_wanted.swap(false, .acq_rel)) t.window.focus();
            before.func(before.ctx);
            drawOne(t, e, places, taken);
            continue;
        }
        _ = e.focus_wanted.swap(false, .acq_rel);
        // By index, since drawing one can open another, which grows the list. Tabs themselves don't move
        var i: usize = 0;
        while (i < self.list.items.len) : (i += 1) {
            const t = self.list.items[i];
            if (t.id == null or !std.mem.eql(u8, t.key, e.label)) continue;
            before.func(before.ctx);
            self.status(t, e);
            drawOne(t, e, places, taken);
        }
    }
}

/// One of its own, by its entry's label.
pub fn find(self: *const Tabs, label: []const u8) ?*Tab {
    for (self.list.items) |t| if (t.id == null and std.mem.eql(u8, t.key, label)) return t;
    return null;
}

/// The tab `child` is inside, by its `parent`.
pub fn parentOf(self: *const Tabs, child: *const slots.Entry) ?*Tab {
    var held = slots.take(.workbench);
    defer held.end();
    return parentIn(self, held.items(), child);
}

fn parentIn(self: *const Tabs, taken: []const *slots.Entry, child: *const slots.Entry) ?*Tab {
    var buf: [160]u8 = undefined;
    for (taken) |e| if (e.parts and std.mem.eql(u8, e.key(&buf), child.parent)) return self.find(e.label);
    return null;
}

/// Brings `child` to the front of the tab it's inside, from its next draw, without opening it.
pub fn select(self: *const Tabs, child: *const slots.Entry) void {
    const t = self.parentOf(child) orelse return;
    t.pick.set(child.label);
}

/// Whether `child`'s tab is open with it in front, as of the last draw.
pub fn showingPart(self: *const Tabs, child: *const slots.Entry) bool {
    const t = self.parentOf(child) orelse return false;
    return t.window.open and t.front.is(child.label);
}

/// One of a tab of many, by its entry's label and its id.
pub fn findOne(self: *const Tabs, label: []const u8, id: []const u8) ?*Tab {
    for (self.list.items) |t| if (t.id) |have| if (std.mem.eql(u8, have, id) and std.mem.eql(u8, t.key, label)) return t;
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

/// View's New for the tab of many with label `key`: asks it for one, and brings that to the front.
pub fn newOne(self: *Tabs, key: []const u8) void {
    var held = slots.take(.workbench);
    defer held.end();
    for (held.items()) |e| {
        if (!e.multi or !std.mem.eql(u8, e.label, key)) continue;
        var made: ?[]u8 = null;
        const Create = struct {
            fn run(out: *?[]u8, tab: W.WorkbenchTab) void {
                const id = tab.create();
                if (id.len > 0) out.* = gpa.dupe(u8, id) catch null;
            }
        };
        slots.callTab(e, &made, Create.run);
        const id = made orelse return;
        defer gpa.free(id);
        const t = self.open(e, id) catch return;
        t.window.focus();
        return;
    }
}

/// One of a tab of many, made now if it isn't yet, for Wraith's own on the Workbench's thread.
pub fn open(self: *Tabs, e: *const slots.Entry, id: []const u8) !*Tab {
    if (self.findOne(e.label, id)) |t| {
        t.window.open = true;
        t.closing = false;
        return t;
    }
    return self.add(e, id);
}

fn update(self: *Tabs, taken: []const *slots.Entry) void {
    // One of many closed since last time is gone. Not sooner, so its owner can see it closed first
    var gone = self.list.items.len;
    while (gone > 0) {
        gone -= 1;
        const t = self.list.items[gone];
        if (t.closing and !t.window.open) free(self.list.orderedRemove(gone));
    }
    for (self.list.items) |t| t.seen = false;
    var requests: std.ArrayList(slots.Request) = .empty;
    defer requests.deinit(gpa);
    for (taken) |e| {
        // Inside another, so no window of its own
        if (e.parent.len > 0) continue;
        if (!e.multi) {
            const t = self.find(e.label) orelse (self.add(e, null) catch continue);
            t.seen = true;
            continue;
        }
        self.addKind(e);
        for (self.list.items) |t| if (t.id != null and std.mem.eql(u8, t.key, e.label)) {
            t.seen = true;
        };
        e.takeRequests(&requests);
        for (requests.items) |r| {
            defer gpa.free(r.id);
            if (r.open) {
                const t = self.open(e, r.id) catch continue;
                t.window.focus();
            } else if (self.findOne(e.label, r.id)) |t| {
                t.window.close();
            }
        }
        requests.clearRetainingCapacity();
    }
    var i = self.list.items.len;
    while (i > 0) {
        i -= 1;
        if (!self.list.items[i].seen) free(self.list.orderedRemove(i));
    }
    i = self.kinds.items.len;
    while (i > 0) {
        i -= 1;
        const k = self.kinds.items[i];
        const still = for (taken) |e| {
            if (e.multi and std.mem.eql(u8, e.label, k.key)) break true;
        } else false;
        if (!still) freeKind(self.kinds.orderedRemove(i));
    }
}

fn addKind(self: *Tabs, e: *const slots.Entry) void {
    for (self.kinds.items) |k| if (std.mem.eql(u8, k.key, e.label)) return;
    const key = gpa.dupeSentinel(u8, e.label, 0) catch return;
    const title = gpa.dupeSentinel(u8, e.title, 0) catch {
        gpa.free(key);
        return;
    };
    self.kinds.append(gpa, .{ .key = key, .title = title }) catch freeKind(.{ .key = key, .title = title });
}

fn freeKind(k: Kind) void {
    gpa.free(k.key);
    gpa.free(k.title);
}

fn add(self: *Tabs, e: *const slots.Entry, id: ?[]const u8) !*Tab {
    const t = try gpa.create(Tab);
    errdefer gpa.destroy(t);
    const key = try gpa.dupeSentinel(u8, e.label, 0);
    errdefer gpa.free(key);
    const own_id = if (id) |i| try gpa.dupe(u8, i) else null;
    errdefer if (own_id) |i| gpa.free(i);
    const title = try windowTitle(e.label, e.title, own_id);
    // Open from the start, behind what you're looking at
    t.* = .{
        .window = .{ .title = title, .open = true, .flags = .{ .no_focus_on_appearing = true } },
        .key = key,
        .id = own_id,
        .place = e.place,
        .order = e.order,
        .seq = e.seq,
        .sub = if (id != null) self.next_sub else 0,
    };
    if (id != null) self.next_sub += 1;
    // Kept in order, which the default layout and View go by
    var at = self.list.items.len;
    while (at > 0 and comesBefore(t, self.list.items[at - 1])) at -= 1;
    try self.list.insert(gpa, at, t);
    return t;
}

/// `title`, then the entry's ID part, and the id for one of many: `Memory###wraith/wraith/workbench/memory/3`.
fn windowTitle(label: []const u8, title: []const u8, id: ?[]const u8) ![:0]u8 {
    const stable = label[std.mem.indexOf(u8, label, "###") orelse label.len ..];
    if (id) |i| return std.fmt.allocPrintSentinel(gpa, "{s}{s}/{s}", .{ title, stable, i }, 0);
    return std.fmt.allocPrintSentinel(gpa, "{s}{s}", .{ title, stable }, 0);
}

fn comesBefore(a: *const Tab, b: *const Tab) bool {
    if (a.order != b.order) return a.order < b.order;
    if (a.seq != b.seq) return a.seq < b.seq;
    return a.sub < b.sub;
}

fn free(t: *Tab) void {
    gpa.free(t.window.title);
    gpa.free(t.key);
    if (t.id) |i| gpa.free(i);
    gpa.destroy(t);
}

/// One of many's label and dot, from its object, while it's open.
fn status(self: *Tabs, t: *Tab, e: *slots.Entry) void {
    _ = self;
    if (!t.window.open) return;
    const Status = struct {
        tab: *Tab,
        label: []const u8,

        fn run(s: *@This(), tab: W.WorkbenchTab) void {
            const st = tab.status(s.tab.id.?);
            s.tab.window.unsaved = st.unsaved;
            if (st.title.len == 0 or std.mem.eql(u8, s.tab.window.label(), st.title)) return;
            const title = windowTitle(s.label, st.title, s.tab.id) catch return;
            gpa.free(s.tab.window.title);
            s.tab.window.title = title;
        }
    };
    var s: Status = .{ .tab = t, .label = e.label };
    slots.callTab(e, &s, Status.run);
}

fn drawOne(t: *Tab, e: *slots.Entry, places: Places, taken: []const *slots.Entry) void {
    const w = &t.window;
    defer t.was_open = w.open;
    defer t.closing = t.id != null and !w.open;
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
    var flags = w.flags;
    flags.unsaved_document = w.unsaved;
    if (ui.window(w.title, .{ .open = &w.open, .flags = flags })) |scope| {
        defer scope.end();
        e.shown.store(true, .release);
        if (e.parts) drawParts(t, e, taken) else slots.draw(e, .{ .name = t.id orelse "" });
    }
    if (!w.open) closed(t, e);
}

/// The tabs inside one, in their order, the one in front drawn.
fn drawParts(t: *Tab, e: *slots.Entry, taken: []const *slots.Entry) void {
    var buf: [160]u8 = undefined;
    const key = e.key(&buf);
    const any = for (taken) |child| {
        if (std.mem.eql(u8, child.parent, key)) break true;
    } else false;
    defer t.pick.len = 0;
    if (!any) return ui.textDisabled("Nothing's in it yet.", .{});
    const bar = ui.tabBar("parts") orelse return;
    defer bar.end();
    for (taken) |child| {
        if (!std.mem.eql(u8, child.parent, key)) continue;
        const item = ui.tabItem(child.label, .{ .select = t.pick.is(child.label) }) orelse continue;
        defer item.end();
        t.front.set(child.label);
        child.shown.store(true, .release);
        const part = ui.child(child.label, .{ 0, 0 }, .{}) orelse continue;
        defer part.end();
        slots.draw(child, .{});
    }
}

/// Its close button: the object can keep it. One of many that's closed is gone next time.
fn closed(t: *Tab, e: *slots.Entry) void {
    var keep = false;
    const Close = struct {
        keep: *bool,
        id: []const u8,

        fn run(s: *const @This(), tab: W.WorkbenchTab) void {
            s.keep.* = tab.keepOpen(s.id);
        }
    };
    const args: Close = .{ .keep = &keep, .id = t.id orelse "" };
    slots.callTab(e, &args, Close.run);
    if (keep) t.window.open = true;
}
