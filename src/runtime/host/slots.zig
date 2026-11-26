//! Slots, from `slots.sal`: places in Wraith's UI that plugins and Wraith itself add to. Each
//! contribution is an `Entry`, added from any thread and drawn on its slot's. `remove` waits for a draw
//! under way, unless that'd wait on itself: from the drawing thread or from a script.

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const api = @import("wraith_api");
const sync = @import("tuft_sys").sync;

const host = @import("root.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;

const W = api.wraith;
pub const Presentation = W.Slot.Presentation;
pub const Thread = W.Slot.Thread;
pub const PluginDraw = W.Contribution.Draw;

const gpa = std.heap.page_allocator;

/// Every slot Wraith has.
pub const Slot = enum(u8) {
    workbench_plugins,
    workbench_engine,
    settings,
    photo_toolbar,
    photo_scene,
    photo_inspector,
    photo_row,
    photo_menu,
    photo_tools,

    pub fn def(s: Slot) *const Def {
        return defs.getPtrConst(s);
    }

    pub fn byId(id: []const u8) ?Slot {
        for (std.enums.values(Slot)) |s| if (std.mem.eql(u8, s.def().id, id)) return s;
        return null;
    }
};

/// What a slot takes, as `Slot.Info` describes it to plugins.
pub const Def = struct {
    id: []const u8,
    title: []const u8,
    help: []const u8,
    thread: Thread = .render,
    presentations: []const Presentation,
    hierarchy: bool = false,
    kinds: bool = false,
    parents: []const []const u8 = &.{},
    known_kinds: []const []const u8 = &.{},

    fn takes(d: *const Def, p: Presentation) bool {
        return std.mem.indexOfScalar(Presentation, d.presentations, p) != null;
    }
};

const photo_parents = [_][]const u8{ "world", "world/cameras", "world/actors" };
/// A bone isn't in the tree, but has a menu and tools, with its actor as `parent` and its name as `name`
const photo_kinds = [_][]const u8{ "world", "cameras", "camera", "actors", "actor", "bone" };

pub const defs: std.EnumArray(Slot, Def) = .init(.{
    .workbench_plugins = .{ .id = "workbench.plugins", .title = "Workbench: Plugins", .help = "A tab in the Workbench's Plugins group.", .thread = .workbench, .presentations = &.{.tab} },
    .workbench_engine = .{ .id = "workbench.engine", .title = "Workbench: Engine", .help = "A tab beside the engine's Classes, for engine plugins.", .thread = .workbench, .presentations = &.{.tab} },
    .settings = .{ .id = "settings", .title = "Settings", .help = "On the plugin's own page in Settings, after its settings.", .presentations = &.{ .foldout, .@"inline" } },
    .photo_toolbar = .{ .id = "photo.toolbar", .title = "Photo mode: toolbar", .help = "Buttons on Photo mode's toolbar.", .presentations = &.{.@"inline"} },
    .photo_scene = .{ .id = "photo.scene", .title = "Photo mode: scene", .help = "Nodes in Photo mode's scene. A node's draw shows in the inspector while it's picked.", .presentations = &.{.node}, .hierarchy = true, .parents = &photo_parents, .known_kinds = &photo_kinds },
    .photo_inspector = .{ .id = "photo.inspector", .title = "Photo mode: inspector", .help = "Shown for the picked node, or for every node of a kind. One with the id `look` takes the place of Wraith's own Look section.", .presentations = &.{ .foldout, .@"inline" }, .kinds = true, .known_kinds = &photo_kinds },
    .photo_row = .{ .id = "photo.row", .title = "Photo mode: row buttons", .help = "Small buttons at the end of scene rows, for every node of a kind.", .presentations = &.{.@"inline"}, .kinds = true, .known_kinds = &photo_kinds },
    .photo_menu = .{ .id = "photo.menu", .title = "Photo mode: right-click menu", .help = "Items in a right-click menu, for every node of a kind, and for bones in an actor's bones. Draw them with ImGui's MenuItem.", .presentations = &.{.@"inline"}, .kinds = true, .known_kinds = &photo_kinds },
    .photo_tools = .{ .id = "photo.tools", .title = "Photo mode: panel tools", .help = "Buttons along the top of the picked node's panel, for every node of a kind. Kind `bone` goes beside an actor's own while one of its bones is picked.", .presentations = &.{.@"inline"}, .kinds = true, .known_kinds = &photo_kinds },
});

/// What a contribution is drawn for, like the picked node.
pub const Target = struct {
    kind: []const u8 = "",
    id: u64 = 0,
    /// For part of a node, like a bone, the node's id
    parent: u64 = 0,
    name: []const u8 = "",
};

/// Wraith's own drawing, or children of a node.
pub const Native = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, target: Target) void,

    pub fn of(ctx: anytype, comptime func: fn (@TypeOf(ctx), Target) void) Native {
        const T = @TypeOf(ctx);
        return .{ .ctx = @ptrCast(@constCast(ctx)), .func = struct {
            fn call(c: *anyopaque, t: Target) void {
                func(@as(T, @ptrCast(@alignCast(c))), t);
            }
        }.call };
    }
};

pub const Draw = union(enum) {
    plugin: PluginDraw,
    /// A Workbench panel's, which takes no target
    panel: W.WorkbenchPanel.Draw,
    native: Native,
    /// Nothing of its own, like a node that only holds others
    none,
};

/// Where it goes, as `Slot.Placement` says, with the slot looked up.
pub const Placement = struct {
    slot: Slot,
    id: []const u8 = "",
    title: []const u8 = "",
    icon: []const u8 = "",
    parent: []const u8 = "",
    kind: []const u8 = "",
    node: u64 = 0,
    presentation: Presentation = .default,
    order: i32 = 0,
    open: bool = false,
    /// Wraith's own nodes only: rows drawn under it, through `photo.Scene.row`
    children: ?Native = null,
    /// Wraith's own only: shown till something else in the slot has its id for the same kind
    fallback: bool = false,
};

pub const Entry = struct {
    /// The plugin's, unless it's Wraith's own
    loaded: *Loaded = undefined,
    own: bool,
    slot: Slot,
    /// Order added, for ties
    seq: u32,
    arena: std.heap.ArenaAllocator,
    id: []const u8,
    title: [:0]const u8,
    icon: []const u8,
    parent: []const u8,
    kind: []const u8,
    /// Unique across plugins, for tabs and headers
    label: [:0]const u8,
    node: u64,
    presentation: Presentation,
    order: i32,
    open: bool,
    draw: Draw,
    children: ?Native,
    fallback: bool = false,

    /// Draws under way in the low bits, plus `stopped_bit`. Whoever stops it with none under way lets go of `draw`.
    state: Atomic(u32) = .init(0),
    /// `draw`'s been let go of, so nothing of the plugin's runs for it again.
    finished: Atomic(bool) = .init(false),
    let_go: Atomic(bool) = .init(false),
    /// Asked for from any thread, done by whoever draws the slot.
    focus_wanted: Atomic(bool) = .init(false),
    /// Set by the slot's drawer each frame from the frame before, so other threads never see it briefly false.
    shown: Atomic(bool) = .init(false),
    /// Drawn this frame. Drawing thread.
    drawn: bool = false,
    /// Drawing thread.
    warned: bool = false,
    /// How wide it drew last time, for lining row buttons up on the right. Drawing thread.
    width: f32 = 0,
    /// Freed while this thread held it, so its `release` frees it. Only that thread touches it.
    free_pending: bool = false,

    const stopped_bit: u32 = 1 << 31;

    pub fn stopped(self: *const Entry) bool {
        return self.state.load(.acquire) & stopped_bit != 0;
    }

    /// No more draws, waiting for one under way unless that'd wait on itself.
    pub fn stop(self: *Entry) void {
        self.markStopped();
        if (heldHere(self)) return;
        if (!self.own and !std.mem.eql(u8, self.loaded.manifest.providerName(), api.default_provider)) return;
        self.waitFinished();
    }

    /// For Owned, as the plugin goes.
    pub fn free(self: *Entry) void {
        self.markStopped();
        unlist(self);
        // Its owner's closed by now, so a script's draw has given up waiting for its lock
        if (heldHere(self)) {
            self.free_pending = true;
            return;
        }
        self.waitFinished();
        self.destroy();
    }

    pub fn going(self: *Entry) bool {
        return !self.stopped();
    }

    /// The plugin's `remove`: stops it, and Owned frees it with the plugin. Wraith's own are freed now.
    pub fn remove(self: *Entry) void {
        if (self.own) self.free() else self.stop();
    }

    /// Who added it, for Settings' pages and labels.
    pub fn ownerName(self: *const Entry) []const u8 {
        return if (self.own) "Wraith" else self.loaded.displayName();
    }

    fn markStopped(self: *Entry) void {
        const was = self.state.fetchOr(stopped_bit, .acq_rel);
        if (was & stopped_bit != 0) return;
        _ = changes.fetchAdd(1, .release);
        if (was == 0) self.finish();
    }

    fn finish(self: *Entry) void {
        // A take that saw it stopped can bring the count back to 0 after it's finished
        if (self.let_go.swap(true, .acq_rel)) return;
        switch (self.draw) {
            .plugin => |d| d.release(),
            .panel => |d| d.release(),
            .native, .none => {},
        }
        // Last, since a waiting `free` destroys it once it's seen
        self.finished.store(true, .release);
    }

    fn waitFinished(self: *Entry) void {
        while (!self.finished.load(.acquire)) std.Thread.yield() catch {};
    }

    fn destroy(self: *Entry) void {
        self.arena.deinit();
        gpa.destroy(self);
    }

    /// One draw's done.
    fn put(self: *Entry) void {
        const pending = self.free_pending;
        if (self.state.fetchSub(1, .acq_rel) != stopped_bit | 1) return;
        self.finish();
        if (pending) self.destroy();
    }

    /// Whether it shows for a node of `kind`: its own kind, or every kind when it has none.
    pub fn showsFor(self: *const Entry, kind: []const u8) bool {
        return self.kind.len == 0 or std.mem.eql(u8, self.kind, kind);
    }

    /// Picked as a node by this.
    pub fn nodeKind(self: *const Entry) []const u8 {
        return if (self.kind.len > 0) self.kind else self.label;
    }
};

var lock: sync.RwLock = .{};
/// Under `lock`, in the order they were added.
var list: std.ArrayList(*Entry) = .empty;
var records: host.Owned(Entry) = .{};
/// Bumped whenever one's added or goes, so drawers know to look again.
var changes: Atomic(u32) = .init(0);
var next_seq: Atomic(u32) = .init(0);

/// What this thread has from `take` and hasn't let go of, so it never waits on those.
threadlocal var held: std.ArrayList(*Entry) = .empty;

fn heldHere(e: *const Entry) bool {
    return std.mem.indexOfScalar(*Entry, held.items, @constCast(e)) != null;
}

fn unlist(e: *Entry) void {
    lock.lock();
    defer lock.unlock();
    if (std.mem.indexOfScalar(*Entry, list.items, e)) |at| _ = list.orderedRemove(at);
}

pub const AddError = error{ UnknownSlot, NotTaken, InvalidId, AlreadyAdded, Failed };

/// A plugin's, through `slots.sal`. `draw` is released on error.
pub fn add(loaded: *Loaded, placement: Placement, d: Draw) AddError!*Entry {
    const e = make(loaded, false, placement, d) catch |err| {
        releaseDraw(d);
        return err;
    };
    records.add(e) catch {
        releaseDraw(d);
        e.destroy();
        return error.Failed;
    };
    // Owned frees it with the plugin from here on, so failing just stops it
    listIt(e) catch |err| {
        e.stop();
        return if (err == error.AlreadyAdded) error.AlreadyAdded else error.Failed;
    };
    return e;
}

/// Wraith's own. Gone with `remove`.
pub fn addOwn(placement: Placement, d: Draw) AddError!*Entry {
    const e = try make(undefined, true, placement, d);
    listIt(e) catch {
        e.destroy();
        return error.Failed;
    };
    return e;
}

fn releaseDraw(d: Draw) void {
    switch (d) {
        .plugin => |f| f.release(),
        .panel => |f| f.release(),
        .native, .none => {},
    }
}

fn listIt(e: *Entry) !void {
    {
        lock.lock();
        defer lock.unlock();
        if (!e.own and e.id.len > 0) for (list.items) |other| {
            if (other.own or other.loaded != e.loaded or other.slot != e.slot or other.stopped()) continue;
            if (std.mem.eql(u8, other.id, e.id)) return error.AlreadyAdded;
        };
        try list.append(gpa, e);
    }
    _ = changes.fetchAdd(1, .release);
}

fn make(loaded: *Loaded, own: bool, p: Placement, d_: Draw) AddError!*Entry {
    const d = p.slot.def();
    const presentation = if (p.presentation == .default) d.presentations[0] else p.presentation;
    if (!d.takes(presentation)) return error.NotTaken;
    if (p.kind.len > 0 and !d.kinds and presentation != .node) return error.NotTaken;
    if (p.parent.len > 0 and !d.hierarchy) return error.NotTaken;
    if (!validId(p.id)) return error.InvalidId;

    const e = gpa.create(Entry) catch return error.Failed;
    errdefer gpa.destroy(e);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const who = if (own) "wraith" else loaded.name;
    const title = if (p.title.len > 0) p.title else if (own) p.id else loaded.displayName();
    const shown = title[0 .. std.mem.indexOf(u8, title, "##") orelse title.len];
    const seq = next_seq.fetchAdd(1, .monotonic);
    const label = (if (p.id.len > 0)
        std.fmt.allocPrintSentinel(a, "{s}###wraith/{s}/{s}/{s}", .{ shown, who, d.id, p.id }, 0)
    else
        std.fmt.allocPrintSentinel(a, "{s}###wraith/{s}/{s}/#{d}", .{ shown, who, d.id, seq }, 0)) catch return error.Failed;
    e.* = .{
        .loaded = loaded,
        .own = own,
        .slot = p.slot,
        .seq = seq,
        .arena = arena,
        .id = a.dupe(u8, p.id) catch return error.Failed,
        .title = a.dupeSentinel(u8, shown, 0) catch return error.Failed,
        .icon = a.dupe(u8, p.icon) catch return error.Failed,
        .parent = a.dupe(u8, p.parent) catch return error.Failed,
        .kind = a.dupe(u8, p.kind) catch return error.Failed,
        .label = label,
        .node = p.node,
        .presentation = presentation,
        .order = p.order,
        .open = p.open,
        .draw = d_,
        .children = if (own) p.children else null,
        .fallback = own and p.fallback,
    };
    return e;
}

/// Letters, digits, `_`, `-`, `.` and `/`, or empty.
fn validId(id: []const u8) bool {
    if (id.len > 64) return false;
    for (id) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '.' and ch != '/') return false;
    return true;
}

/// Changes whenever the list does.
pub fn version() u32 {
    return changes.load(.acquire);
}

/// A slot's live contributions, in order, each held till `end`.
pub const Taken = struct {
    list: std.ArrayList(*Entry) = .empty,

    pub fn items(self: *const Taken) []*Entry {
        return self.list.items;
    }

    /// Lets go of them. They mustn't be used after.
    pub fn end(self: *Taken) void {
        for (self.list.items) |e| {
            if (std.mem.indexOfScalar(*Entry, held.items, e)) |at| _ = held.swapRemove(at);
            e.put();
        }
        self.list.deinit(gpa);
    }
};

/// The live ones in `slot`, however many. On the slot's thread.
pub fn take(slot: Slot) Taken {
    var out: Taken = .{};
    {
        lock.lockShared();
        defer lock.unlockShared();
        for (list.items) |e| {
            if (e.slot != slot) continue;
            // Out of memory draws what it has rather than nothing
            out.list.ensureUnusedCapacity(gpa, 1) catch break;
            held.ensureUnusedCapacity(gpa, 1) catch break;
            // Held before checking, so a stop either sees it or this sees it's stopped
            if (e.state.fetchAdd(1, .acq_rel) & Entry.stopped_bit != 0) {
                e.put();
                continue;
            }
            out.list.appendAssumeCapacity(e);
            held.appendAssumeCapacity(e);
        }
    }
    std.sort.insertion(*Entry, out.list.items, {}, before);
    return out;
}

fn before(_: void, a: *Entry, b: *Entry) bool {
    return if (a.order != b.order) a.order < b.order else a.seq < b.seq;
}

/// Marks a slot's none showing, for a closed window. On the slot's thread.
pub fn hide(slot: Slot) void {
    lock.lockShared();
    defer lock.unlockShared();
    for (list.items) |e| if (e.slot == slot) {
        e.drawn = false;
        e.shown.store(false, .release);
    };
}

/// Each frame before drawing a slot: what last frame drew becomes `shown`, so it never reads briefly
/// as hidden. Only what `take` gave.
pub fn settle(taken: []const *Entry) void {
    for (taken) |e| {
        e.shown.store(e.drawn, .release);
        e.drawn = false;
    }
}

/// `settle` for a whole slot, once a frame on its thread, before anything draws it.
pub fn settleSlot(slot: Slot) void {
    var taken = take(slot);
    defer taken.end();
    settle(taken.items());
}

/// Draws it for `target` in the current window, scoped to its plugin. Only what `take` gave.
pub fn draw(e: *Entry, target: Target) void {
    if (e.stopped()) return;
    e.drawn = true;
    switch (e.draw) {
        .none => {},
        .native => |n| n.func(n.ctx, target),
        .plugin, .panel => {
            var call: Call = .{ .entry = e, .target = target };
            if (e.slot.def().thread == .workbench)
                host.ui.runInWorkbench(e.loaded, &e.warned, &call, Call.run)
            else
                host.ui.runAs(e.loaded, &e.warned, &call, Call.run);
        },
    }
}

const Call = struct {
    entry: *Entry,
    target: Target,

    fn run(ctx: ?*anyopaque) callconv(.c) void {
        const self: *Call = @ptrCast(@alignCast(ctx.?));
        switch (self.entry.draw) {
            .plugin => |d| d.invoke(.{.{ .kind = .init(self.target.kind), .id = self.target.id, .parent = self.target.parent, .name = .init(self.target.name) }}),
            .panel => |d| d.invoke(.{}),
            .native, .none => {},
        }
    }
};

/// Every slot, as plugins see them. In `a`.
pub fn infos(a: std.mem.Allocator) ![]W.Slot.Info {
    const out = try a.alloc(W.Slot.Info, defs.values.len);
    for (std.enums.values(Slot), out) |s, *o| {
        const d = s.def();
        o.* = .{
            .id = d.id,
            .title = d.title,
            .help = d.help,
            .thread = d.thread,
            .presentations = d.presentations,
            .hierarchy = d.hierarchy,
            .kinds = d.kinds,
            .parents = d.parents,
            .known_kinds = d.known_kinds,
        };
    }
    return out;
}

const tests = struct {
    const testing = std.testing;

    const Counts = struct {
        draws: u32 = 0,
        kind: []const u8 = "",
        contribution: ?W.Contribution = null,
        remove_inside: bool = false,

        fn draw(self: *Counts, target: W.Slot.Target) void {
            self.draws += 1;
            self.kind = target.kind;
            if (self.remove_inside) if (self.contribution) |c| c.remove();
        }
    };

    fn drawAll(slot: Slot, target: Target) usize {
        var got = take(slot);
        defer got.end();
        for (got.items()) |e| draw(e, target);
        return got.items().len;
    }

    test "contributions draw for their target till they're removed or their plugin goes" {
        const sdk = @import("wraith_sdk");
        var a: Loaded = undefined;
        a.initForTest(testing.allocator, "a");
        sdk.Owner.attach(a.root());
        defer sdk.Owner.detach();
        const area = sdk.wraith.root().?.ui();

        var facet: Counts = .{};
        var tab: Counts = .{ .remove_inside = true };
        const got = try area.contribute(.{ .slot = "photo.inspector", .kind = "actor" }, .init(&facet, Counts.draw));
        tab.contribution = try area.contribute(.{ .slot = "workbench.plugins", .title = "Other" }, .init(&tab, Counts.draw));
        try testing.expect(got.table != null);

        try testing.expectEqual(1, drawAll(.photo_inspector, .{ .kind = "actor", .id = 7 }));
        try testing.expectEqual(1, facet.draws);
        // Removing itself from inside its draw doesn't wait on itself
        try testing.expectEqual(1, drawAll(.workbench_plugins, .{}));
        try testing.expectEqual(0, drawAll(.workbench_plugins, .{}));
        try testing.expectEqual(1, tab.draws);

        // Gone with the plugin
        a.owner.close();
        try testing.expectEqual(0, drawAll(.photo_inspector, .{}));
        a.deinitForTest();
    }

    test "what a slot doesn't take is refused" {
        const sdk = @import("wraith_sdk");
        var a: Loaded = undefined;
        a.initForTest(testing.allocator, "a");
        sdk.Owner.attach(a.root());
        defer sdk.Owner.detach();
        const area = sdk.wraith.root().?.ui();
        var c: Counts = .{};
        try testing.expectError(error.UnknownSlot, area.contribute(.{ .slot = "nowhere" }, .init(&c, Counts.draw)));
        try testing.expectError(error.NotTaken, area.contribute(.{ .slot = "workbench.plugins", .presentation = .node }, .init(&c, Counts.draw)));
        try testing.expectError(error.NotTaken, area.contribute(.{ .slot = "settings", .parent = "x" }, .init(&c, Counts.draw)));
        try testing.expectError(error.InvalidId, area.contribute(.{ .slot = "settings", .id = "a b" }, .init(&c, Counts.draw)));
        _ = try area.contribute(.{ .slot = "photo.scene", .id = "lights", .parent = "world" }, .init(&c, Counts.draw));
        // A plugin's items in a row's right-click menu, for every actor
        _ = try area.contribute(.{ .slot = "photo.menu", .kind = "actor" }, .init(&c, Counts.draw));
        try testing.expectError(error.AlreadyAdded, area.contribute(.{ .slot = "photo.scene", .id = "lights" }, .init(&c, Counts.draw)));
        a.owner.close();
        a.deinitForTest();
    }

    const Bone = struct {
        parent: u64 = 0,
        name: [16]u8 = undefined,
        name_len: usize = 0,

        fn draw(self: *Bone, target: W.Slot.Target) void {
            self.parent = target.parent;
            self.name_len = @min(target.name.len, self.name.len);
            @memcpy(self.name[0..self.name_len], target.name[0..self.name_len]);
        }
    };

    test "a bone's tools and menu items are told its actor and name" {
        const sdk = @import("wraith_sdk");
        var a: Loaded = undefined;
        a.initForTest(testing.allocator, "a");
        sdk.Owner.attach(a.root());
        defer sdk.Owner.detach();
        const area = sdk.wraith.root().?.ui();
        var tool: Bone = .{};
        var item: Bone = .{};
        _ = try area.contribute(.{ .slot = "photo.tools", .kind = "bone" }, .init(&tool, Bone.draw));
        _ = try area.contribute(.{ .slot = "photo.menu", .kind = "bone" }, .init(&item, Bone.draw));
        const target: Target = .{ .kind = "bone", .id = 3, .parent = 7, .name = "head" };
        try testing.expectEqual(1, drawAll(.photo_tools, target));
        try testing.expectEqual(1, drawAll(.photo_menu, target));
        for ([_]*Bone{ &tool, &item }) |b| {
            try testing.expectEqual(7, b.parent);
            try testing.expectEqualStrings("head", b.name[0..b.name_len]);
        }
        a.owner.close();
        a.deinitForTest();
    }

    test "plugins can read what each slot takes" {
        const sdk = @import("wraith_sdk");
        var a: Loaded = undefined;
        a.initForTest(testing.allocator, "a");
        sdk.Owner.attach(a.root());
        defer sdk.Owner.detach();
        const all = sdk.wraith.root().?.ui().slots();
        const scene = for (all) |s| {
            if (std.mem.eql(u8, s.id, "photo.scene")) break s;
        } else return error.TestUnexpectedResult;
        try testing.expect(scene.hierarchy);
        try testing.expectEqual(.node, scene.presentations[0]);
        try testing.expectEqualStrings("world/actors", scene.parents[2]);
        a.owner.close();
        a.deinitForTest();
    }

    const Sibling = struct {
        other: ?W.WorkbenchPanel = null,
        draws: u32 = 0,

        fn draw(self: *Sibling) void {
            self.draws += 1;
            if (self.other) |o| o.remove();
        }
    };

    test "a Workbench panel removing another of its group's doesn't wait on itself" {
        const sdk = @import("wraith_sdk");
        var a: Loaded = undefined;
        a.initForTest(testing.allocator, "a");
        sdk.Owner.attach(a.root());
        defer sdk.Owner.detach();
        const area = sdk.wraith.root().?.ui();
        var first: Sibling = .{};
        var second: Sibling = .{};
        _ = area.addWorkbenchPanel(.{ .title = "First" }, .init(&first, Sibling.draw));
        first.other = area.addWorkbenchPanel(.{ .title = "Second" }, .init(&second, Sibling.draw));
        // The second's held for this frame too, so it's skipped rather than waited for
        try testing.expectEqual(2, drawAll(.workbench_plugins, .{}));
        try testing.expectEqual(1, first.draws);
        try testing.expectEqual(0, second.draws);
        try testing.expectEqual(1, drawAll(.workbench_plugins, .{}));
        a.owner.close();
        a.deinitForTest();
    }

    const Slow = struct {
        inside: Atomic(bool) = .init(false),
        go: Atomic(bool) = .init(false),
        done: Atomic(bool) = .init(false),

        fn draw(self: *Slow) void {
            self.inside.store(true, .release);
            while (!self.go.load(.acquire)) std.Thread.yield() catch {};
            self.done.store(true, .release);
        }

        fn remove(panel: W.WorkbenchPanel, removed: *Atomic(bool)) void {
            panel.remove();
            removed.store(true, .release);
        }
    };

    test "removing from another thread waits for a draw under way" {
        const sdk = @import("wraith_sdk");
        var a: Loaded = undefined;
        a.initForTest(testing.allocator, "a");
        sdk.Owner.attach(a.root());
        defer sdk.Owner.detach();
        const area = sdk.wraith.root().?.ui();
        var slow: Slow = .{};
        const panel = area.addWorkbenchPanel(.{ .title = "Slow" }, .init(&slow, Slow.draw));

        var got = take(.workbench_plugins);
        var removed: Atomic(bool) = .init(false);
        const drawing = try std.Thread.spawn(.{}, struct {
            fn run(es: []*Entry) void {
                for (es) |e| draw(e, .{});
            }
        }.run, .{got.items()});
        while (!slow.inside.load(.acquire)) std.Thread.yield() catch {};
        const remover = try std.Thread.spawn(.{}, Slow.remove, .{ panel, &removed });
        try testing.io.sleep(.fromMilliseconds(20), .awake);
        try testing.expect(!removed.load(.acquire));
        slow.go.store(true, .release);
        drawing.join();
        // `take` was this thread's, so letting go is too
        got.end();
        remover.join();
        try testing.expect(removed.load(.acquire));
        try testing.expect(slow.done.load(.acquire));
        try testing.expectEqual(0, drawAll(.workbench_plugins, .{}));
        a.owner.close();
        a.deinitForTest();
    }

    test "a slot with more than any buffer would hold draws them all" {
        var draws: u32 = 0;
        const Own = struct {
            fn draw(n: *u32, _: Target) void {
                n.* += 1;
            }
        };
        var added: [300]*Entry = undefined;
        for (&added) |*e| e.* = try addOwn(.{ .slot = .photo_row }, .{ .native = .of(&draws, Own.draw) });
        defer for (added) |e| e.remove();
        try testing.expectEqual(added.len, drawAll(.photo_row, .{}));
        try testing.expectEqual(added.len, draws);
        // All let go of, so removing never waits on this thread
        try testing.expectEqual(0, held.items.len);
    }

    test "in order, then as added" {
        var n: u32 = 0;
        const Own = struct {
            fn draw(_: *u32, _: Target) void {}
        };
        const late = try addOwn(.{ .slot = .photo_toolbar, .id = "late", .order = 200 }, .{ .native = .of(&n, Own.draw) });
        defer late.remove();
        const first = try addOwn(.{ .slot = .photo_toolbar, .id = "first", .order = 100 }, .{ .native = .of(&n, Own.draw) });
        defer first.remove();
        const second = try addOwn(.{ .slot = .photo_toolbar, .id = "second", .order = 100 }, .none);
        defer second.remove();
        var got = take(.photo_toolbar);
        defer got.end();
        try testing.expectEqual(3, got.items().len);
        try testing.expectEqual(first, got.items()[0]);
        try testing.expectEqual(second, got.items()[1]);
        try testing.expectEqual(late, got.items()[2]);
    }
};

test {
    _ = tests;
}
