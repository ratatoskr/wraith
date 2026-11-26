//! Lists of a plugin's things that Wraith shows, from `list.sal`. Picks are kept by id and name, so
//! they survive id changes. Buttons call the plugin on the render thread.

const std = @import("std");

const api = @import("wraith_api");
const ui = @import("wraith_ui");
const sync = @import("tuft_sys").sync;

const host = @import("root.zig");
const settings = @import("settings.zig");
const scratch = @import("scratch.zig");
const icons = @import("../ui/icons.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;
const Owner = @import("tuft_event").Owner;
const leases = @import("leases.zig");
const Registry = @import("../settings/Registry.zig");

const W = api.wraith;
pub const Pick = W.ItemList.Pick;

const allocator = std.heap.page_allocator;

/// What a Wraith feature uses a list for. Plain ones are just the plugin's.
pub const Purpose = enum { plain, cameras };

/// What the list's buttons call. Each one there gives it its button.
pub const Handlers = struct {
    add: ?W.ItemList.Add = null,
    remove: ?W.ItemList.Remove = null,
    rename: ?W.ItemList.Rename = null,

    pub fn release(h: *Handlers) void {
        if (h.add) |f| f.release();
        if (h.remove) |f| f.release();
        if (h.rename) |f| f.release();
        h.* = .{};
    }
};

/// Names are kept and matched up to this long.
const max_name = 63;

pub const Name = struct {
    buf: [max_name]u8 = undefined,
    len: u8 = 0,

    pub fn init(s: []const u8) Name {
        var n: Name = .{ .len = @intCast(@min(s.len, max_name)) };
        @memcpy(n.buf[0..n.len], s[0..n.len]);
        return n;
    }

    pub fn get(n: *const Name) []const u8 {
        return n.buf[0..n.len];
    }

    fn matches(n: *const Name, s: []const u8) bool {
        return std.mem.eql(u8, n.get(), s[0..@min(s.len, max_name)]);
    }
};

pub const Item = struct {
    id: u64,
    name: []const u8,
    detail: []const u8,
    current: bool = false,
};

/// What's listed and what's picked, without the plugin, so it's easy to test. Not locked.
pub const State = struct {
    pick: Pick,
    current_by_default: bool,
    /// The plugin's, copied into `arena`
    items: []Item = &.{},
    arena: std.heap.ArenaAllocator = .init(allocator),
    /// What the player picked, in order. Id 0 is only known by name so far, like from last time
    chosen: std.ArrayList(Chosen) = .empty,

    pub const Chosen = struct { id: u64, name: Name };

    pub fn deinit(s: *State) void {
        s.arena.deinit();
        s.chosen.deinit(allocator);
    }

    /// Copies them in, and points picks known by name at what's now called that.
    pub fn set(s: *State, items: anytype) !void {
        var next: std.heap.ArenaAllocator = .init(allocator);
        errdefer next.deinit();
        const a = next.allocator();
        const out = try a.alloc(Item, items.len);
        for (items, out) |it, *o| o.* = .{
            .id = it.id,
            .name = try a.dupe(u8, textOf(it.name)),
            .detail = try a.dupe(u8, textOf(it.detail)),
            .current = if (@hasField(@TypeOf(it), "current")) it.current else false,
        };
        s.arena.deinit();
        s.arena = next;
        s.items = out;
        s.rematch();
    }

    /// Points picks whose id isn't listed at the first unpicked item with their name. Missing ones keep their id.
    fn rematch(s: *State) void {
        for (s.chosen.items) |*c| {
            if (s.indexOf(c.id) != null) continue;
            for (s.items) |it| {
                if (it.id == 0 or !c.name.matches(it.name) or s.isChosen(it.id)) continue;
                c.id = it.id;
                break;
            }
        }
    }

    pub fn indexOf(s: *const State, id: u64) ?usize {
        if (id == 0) return null;
        for (s.items, 0..) |it, i| if (it.id == id) return i;
        return null;
    }

    fn isChosen(s: *const State, id: u64) bool {
        for (s.chosen.items) |c| if (c.id == id) return true;
        return false;
    }

    fn picks(s: *const State) bool {
        return s.pick == .one or s.pick == .many;
    }

    /// Picked and listed, or the default.
    pub fn isSelected(s: *const State, id: u64) bool {
        if (!s.picks() or s.indexOf(id) == null) return false;
        for (s.chosen.items) |c| if (c.id == id) return true;
        const d = s.byDefault() orelse return false;
        return s.items[d].id == id;
    }

    /// The default when nothing picked is listed: the current one, else the first.
    pub fn byDefault(s: *const State) ?usize {
        if (!s.current_by_default or !s.picks() or s.items.len == 0) return null;
        for (s.chosen.items) |c| if (s.indexOf(c.id) != null) return null;
        for (s.items, 0..) |it, i| if (it.current) return i;
        return 0;
    }

    /// What `selected` gives: picked and listed, in order picked, or the default.
    pub fn selected(s: *const State, a: std.mem.Allocator) ![]u64 {
        var out: std.ArrayList(u64) = .empty;
        if (!s.picks()) return out.toOwnedSlice(a);
        for (s.chosen.items) |c| if (s.indexOf(c.id) != null) try out.append(a, c.id);
        if (out.items.len == 0) if (s.byDefault()) |d| try out.append(a, s.items[d].id);
        return out.toOwnedSlice(a);
    }

    /// False if nothing changed.
    pub fn select(s: *State, id: u64) !bool {
        switch (s.pick) {
            .one => {
                if (id == 0) {
                    if (s.chosen.items.len == 0) return false;
                    s.chosen.clearRetainingCapacity();
                    return true;
                }
                const i = s.indexOf(id) orelse return false;
                if (s.chosen.items.len == 1 and s.chosen.items[0].id == id) return false;
                s.chosen.clearRetainingCapacity();
                try s.chosen.append(allocator, .{ .id = id, .name = .init(s.items[i].name) });
                return true;
            },
            .many => {
                const i = s.indexOf(id) orelse return false;
                if (s.isChosen(id)) return false;
                try s.chosen.append(allocator, .{ .id = id, .name = .init(s.items[i].name) });
                return true;
            },
            // Unknown ones too, from a newer plugin
            .none, _ => return false,
        }
    }

    pub fn deselect(s: *State, id: u64) bool {
        for (s.chosen.items, 0..) |c, i| if (c.id == id) {
            _ = s.chosen.orderedRemove(i);
            return true;
        };
        return false;
    }

    /// Names, one a line, for the setting.
    fn saved(s: *const State, a: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        for (s.chosen.items, 0..) |c, i| {
            if (i > 0) try out.append(a, '\n');
            try out.appendSlice(a, c.name.get());
        }
        return out.items;
    }

    /// From the setting, known by name till they're listed.
    fn load(s: *State, text: []const u8) !void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try s.chosen.append(allocator, .{ .id = 0, .name = .init(line) });
            if (s.pick == .one) break;
        }
        s.rematch();
    }
};

fn textOf(s: anytype) []const u8 {
    return if (@TypeOf(s) == []const u8) s else s.get();
}

/// One plugin's list.
pub const Record = struct {
    loaded: *Loaded,
    purpose: Purpose,
    id: []u8,
    /// Its title and current label, owned
    arena: std.heap.ArenaAllocator,
    title: []const u8,
    current_label: []const u8,
    handlers: Handlers,
    /// Hidden, with what's picked, for next time.
    keep: ?*Registry.Setting = null,

    lock: sync.RwLock = .{},
    state: State,
    closed: bool = false,
    /// Counts changes, for anyone drawing it.
    version: u32 = 0,

    // Render thread only from here down
    /// What's being renamed, and its new name so far.
    renaming: u64 = 0,
    rename_buf: [max_name + 1]u8 = undefined,

    /// Calls into the plugin stop, and it's not listed any more.
    pub fn stop(self: *Record) void {
        self.lock.lock();
        const was = self.closed;
        self.closed = true;
        var handlers = self.handlers;
        self.handlers = .{};
        self.lock.unlock();
        if (was) return;
        handlers.release();
        if (self.keep) |k| if (settings.registryOf()) |r| r.remove(k);
        self.keep = null;
    }

    pub fn free(self: *Record) void {
        self.stop();
        self.state.deinit();
        allocator.free(self.id);
        self.arena.deinit();
        allocator.destroy(self);
    }

    pub fn going(self: *Record) bool {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return !self.closed;
    }

    fn hasItems(self: *Record) bool {
        return self.count() > 0;
    }

    pub fn count(self: *Record) usize {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return self.state.items.len;
    }

    pub fn set(self: *Record, items: anytype) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.closed) return;
        self.state.set(items) catch return;
        self.version +%= 1;
    }

    /// Good till the thread's next call that gives something back.
    pub fn selected(self: *Record) []const u64 {
        const a = scratch.begin();
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return self.state.selected(a) catch &.{};
    }

    /// The first that's picked, or 0.
    pub fn firstSelected(self: *Record) u64 {
        var buf: [512]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        self.lock.lockShared();
        defer self.lock.unlockShared();
        const ids = self.state.selected(fba.allocator()) catch return 0;
        return if (ids.len > 0) ids[0] else 0;
    }

    pub fn select(self: *Record, id: u64) void {
        self.change(.select, id);
    }

    pub fn deselect(self: *Record, id: u64) void {
        self.change(.deselect, id);
    }

    fn change(self: *Record, how: enum { select, deselect }, id: u64) void {
        var buf: [1024]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        const text = blk: {
            self.lock.lock();
            defer self.lock.unlock();
            if (self.closed) return;
            const changed = switch (how) {
                .select => self.state.select(id) catch false,
                .deselect => self.state.deselect(id),
            };
            if (!changed) return;
            self.version +%= 1;
            break :blk self.state.saved(fba.allocator()) catch return;
        };
        if (self.keep) |k| if (settings.registryOf()) |r| r.set(k, .{ .text = text }) catch {};
    }

    /// Which buttons the plugin asked for.
    pub const Has = struct { add: bool, remove: bool, rename: bool };

    /// A copy of what's listed and picked, so nothing's locked while calling into the plugin.
    pub const Snapshot = struct { pick: Pick, items: []Item, picked: []bool, has: Has };

    /// In `a`. Null once it's closed.
    pub fn snapshot(self: *Record, a: std.mem.Allocator) ?Snapshot {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        if (self.closed) return null;
        const items = a.alloc(Item, self.state.items.len) catch return null;
        const picked = a.alloc(bool, items.len) catch return null;
        for (self.state.items, items, picked) |it, *o, *p| {
            o.* = .{ .id = it.id, .name = a.dupe(u8, it.name) catch return null, .detail = a.dupe(u8, it.detail) catch return null, .current = it.current };
            p.* = self.state.isSelected(it.id);
        }
        const h = self.handlers;
        return .{ .pick = self.state.pick, .items = items, .picked = picked, .has = .{ .add = h.add != null, .remove = h.remove != null, .rename = h.rename != null } };
    }

    /// Render thread. With `titled`, its title goes over it. The plugin mustn't go while it's drawing.
    pub fn draw(self: *Record, titled: bool) void {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const snap = self.snapshot(a) orelse return;
        const pick, const items, const picked, const has = .{ snap.pick, snap.items, snap.picked, snap.has };
        const scope = ui.id(@as(*const Record, self));
        defer scope.end();
        if (titled) ui.text("{s}", .{self.title});

        var wants: Wants = .{};
        if (pick == .one) {
            self.drawCombo(a, items, picked);
            if (has.rename) {
                ui.sameLine();
                const at = std.mem.indexOfScalar(bool, picked, true);
                const none = ui.disabled(at == null);
                defer none.end();
                if (ui.iconButton(icons.pencil ++ "##rename", "Rename it")) self.startRename(items[at.?]);
            }
            if (has.remove) {
                ui.sameLine();
                const at = std.mem.indexOfScalar(bool, picked, true);
                const none = ui.disabled(at == null);
                defer none.end();
                if (ui.iconButton(icons.trash ++ "##remove", "Remove it")) wants.remove = items[at.?].id;
            }
            if (has.add) {
                ui.sameLine();
                if (ui.iconButton(icons.plus ++ "##add", "Add one")) wants.add = true;
            }
        } else {
            if (items.len == 0) ui.textDisabled("None", .{});
            for (items, picked) |it, p| self.drawRow(a, it, p, pick, has.rename, has.remove, &wants);
            if (has.add and ui.iconButton(icons.plus ++ "##add", "Add one")) wants.add = true;
        }
        self.drawRename();

        if (wants.add) self.callAdd();
        if (wants.remove) |id| self.callRemove(id);
    }

    const Wants = struct {
        add: bool = false,
        remove: ?u64 = null,
    };

    fn labelOf(self: *const Record, a: std.mem.Allocator, it: Item) [:0]const u8 {
        return if (it.current)
            std.fmt.allocPrintSentinel(a, "{s}  ({s})##{d}", .{ it.name, self.current_label, it.id }, 0) catch ""
        else
            std.fmt.allocPrintSentinel(a, "{s}##{d}", .{ it.name, it.id }, 0) catch "";
    }

    fn drawCombo(self: *Record, a: std.mem.Allocator, items: []const Item, picked: []const bool) void {
        const at = std.mem.indexOfScalar(bool, picked, true);
        const preview: [:0]const u8 = if (at) |i| self.labelOf(a, items[i]) else if (items.len == 0) "None" else "Nothing";
        // Room for the buttons beside it
        ui.setNextItemWidth(-ui.frameHeight() * 4);
        const combo = ui.comboBegin("##pick", preview, .{}) orelse return;
        defer combo.end();
        for (items, picked) |it, p| {
            if (ui.selectable(self.labelOf(a, it), p)) self.select(it.id);
            if (it.detail.len > 0) ui.tooltip("{s}", .{it.detail});
        }
    }

    fn drawRow(self: *Record, a: std.mem.Allocator, it: Item, picked: bool, pick: Pick, rename: bool, remove: bool, wants: *Wants) void {
        if (remove) {
            const button = std.fmt.allocPrintSentinel(a, icons.x ++ "##remove{d}", .{it.id}, 0) catch return;
            if (ui.iconButton(button, "Remove it")) wants.remove = it.id;
            ui.sameLine();
        }
        if (rename) {
            const button = std.fmt.allocPrintSentinel(a, icons.pencil ++ "##rename{d}", .{it.id}, 0) catch return;
            if (ui.iconButton(button, "Rename it")) self.startRename(it);
            ui.sameLine();
        }
        if (pick == .many) {
            var on = picked;
            if (ui.checkbox(self.labelOf(a, it), &on)) if (on) self.select(it.id) else self.deselect(it.id);
        } else {
            ui.text("{s}", .{it.name});
            if (it.current) {
                ui.sameLine();
                ui.textDisabled("({s})", .{self.current_label});
            }
        }
        if (it.detail.len > 0) ui.tooltip("{s}", .{it.detail});
    }

    /// Opens the rename popup, which `drawRename` draws. Both under the same ImGui id.
    pub fn startRename(self: *Record, it: Item) void {
        self.renaming = it.id;
        const n = @min(it.name.len, max_name);
        @memcpy(self.rename_buf[0..n], it.name[0..n]);
        self.rename_buf[n] = 0;
        ui.openPopup("##renaming");
    }

    pub fn drawRename(self: *Record) void {
        const pop = ui.popup("##renaming") orelse return;
        defer pop.end();
        if (ui.isWindowAppearing()) ui.raw("ImGui_SetKeyboardFocusHere")();
        ui.setNextItemWidth(ui.scaled(220));
        const entered = ui.inputTextWith("##name", &self.rename_buf, .{ .flags = .{ .enter_returns_true = true, .auto_select_all = true } });
        ui.sameLine();
        if (entered or ui.button("Rename")) {
            const name = std.mem.sliceTo(&self.rename_buf, 0);
            if (name.len > 0) self.callRename(self.renaming, name);
            ui.raw("ImGui_CloseCurrentPopup")();
        }
    }

    /// Unlocked, since the plugin's likely to call `set`.
    pub fn callAdd(self: *Record) void {
        const f = blk: {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            break :blk self.handlers.add orelse return;
        };
        f.invoke(.{});
    }

    pub fn callRemove(self: *Record, id: u64) void {
        const f = blk: {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            break :blk self.handlers.remove orelse return;
        };
        f.invoke(.{id});
        self.deselect(id);
    }

    fn callRename(self: *Record, id: u64, name: []const u8) void {
        const f = blk: {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            break :blk self.handlers.rename orelse return;
        };
        f.invoke(.{ id, name });
    }
};

var records: host.Owned(Record) = .{};

pub const OpenError = error{ InvalidId, AlreadyOpen, Failed };

pub const Options = struct {
    title: []const u8 = "",
    pick: Pick,
    current_by_default: bool = false,
    remember: bool = false,
    current_label: []const u8 = "",
};

/// Through `list.sal`. On error, the handlers are still the caller's.
pub fn open(loaded: *Loaded, id: []const u8, purpose: Purpose, options: Options, handlers: Handlers) OpenError!*Record {
    if (!validId(id)) return error.InvalidId;
    if (find(loaded, id) != null) return error.AlreadyOpen;
    const record = allocator.create(Record) catch return error.Failed;
    errdefer allocator.destroy(record);
    const own_id = allocator.dupe(u8, id) catch return error.Failed;
    errdefer allocator.free(own_id);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const title = a.dupe(u8, if (options.title.len > 0) options.title else id) catch return error.Failed;
    const current_label = a.dupe(u8, if (options.current_label.len > 0) options.current_label else "Current") catch return error.Failed;
    record.* = .{
        .loaded = loaded,
        .purpose = purpose,
        .id = own_id,
        .arena = arena,
        .title = title,
        .current_label = current_label,
        .handlers = handlers,
        .state = .{ .pick = options.pick, .current_by_default = options.current_by_default },
    };
    if (options.remember and record.state.picks()) if (settings.registryOf()) |r| {
        var buf: [160]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}.list.{s}", .{ loaded.name, id }) catch return error.InvalidId;
        record.keep = r.add(.{ .id = key, .name = title, .group = loaded.displayName(), .scope = .game, .hidden = true, .kind = .{ .text = "" } }, .{}) catch null;
        if (record.keep) |k| record.state.load(r.get(k).text) catch {};
    };
    records.add(record) catch {
        if (record.keep) |k| if (settings.registryOf()) |r| r.remove(k);
        record.state.deinit();
        return error.Failed;
    };
    return record;
}

fn matchId(r: *Record, id: []const u8) bool {
    return std.mem.eql(u8, r.id, id) and r.going();
}

/// The plugin's, if it's open.
pub fn find(loaded: *Loaded, id: []const u8) ?*Record {
    return records.findWhere(&loaded.owner, id, matchId);
}

/// A list with its plugin kept from going till `end`.
pub const Held = struct {
    record: *Record,
    lease: Owner.Lease,

    pub fn end(self: Held) void {
        self.lease.end();
    }
};

/// The free camera's list: the camera holder's, if it has something in it.
pub fn cameras() ?Held {
    var out: ?Held = null;
    _ = leases.withHolder(.camera, &out, camerasOf);
    return out;
}

fn camerasOf(out: *?Held, holder: *leases.Lease) void {
    const r = records.findWhere(&holder.loaded.owner, @as([]const u8, cameras_id), matchId) orelse return;
    if (r.purpose != .cameras or !r.hasItems()) return;
    const lease = records.lease(&r.loaded.owner) orelse return;
    out.* = .{ .record = r, .lease = lease };
}

/// What the free camera's list is called, for each plugin.
pub const cameras_id = "wraith.cameras";

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '.') return false;
    return true;
}

const testing = std.testing;

const TestItem = struct { id: u64, name: []const u8, detail: []const u8 = "", current: bool = false };

fn selectedOf(s: *const State) ![]u64 {
    return s.selected(testing.allocator);
}

fn expectSelected(s: *const State, want: []const u64) !void {
    const got = try selectedOf(s);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u64, want, got);
}

test "the current one counts as picked till the player picks another, and again once that's gone" {
    var s: State = .{ .pick = .one, .current_by_default = true };
    defer s.deinit();
    try expectSelected(&s, &.{});
    // Nothing current, so the first
    try s.set(&[_]TestItem{ .{ .id = 1, .name = "Main Camera" }, .{ .id = 2, .name = "Cutscene" } });
    try expectSelected(&s, &.{1});
    try s.set(&[_]TestItem{ .{ .id = 1, .name = "Main Camera" }, .{ .id = 2, .name = "Cutscene", .current = true } });
    try expectSelected(&s, &.{2});
    try testing.expectEqual(1, s.byDefault());

    try testing.expect(try s.select(1));
    try expectSelected(&s, &.{1});
    try testing.expectEqual(null, s.byDefault());
    try testing.expect(!try s.select(1));

    // Gone, so it's the current one again, but the pick's kept for when it's back
    try s.set(&[_]TestItem{.{ .id = 2, .name = "Cutscene", .current = true }});
    try expectSelected(&s, &.{2});
    try s.set(&[_]TestItem{ .{ .id = 1, .name = "Main Camera" }, .{ .id = 2, .name = "Cutscene", .current = true } });
    try expectSelected(&s, &.{1});

    // 0 goes back to the default
    try testing.expect(try s.select(0));
    try expectSelected(&s, &.{2});
}

test "a pick carries over by name when its id changes" {
    var s: State = .{ .pick = .one, .current_by_default = true };
    defer s.deinit();
    try s.set(&[_]TestItem{ .{ .id = 1, .name = "Main Camera" }, .{ .id = 2, .name = "Photo" } });
    _ = try s.select(2);
    // The scene loads again, with new addresses
    try s.set(&[_]TestItem{ .{ .id = 10, .name = "Main Camera" }, .{ .id = 20, .name = "Photo" } });
    try expectSelected(&s, &.{20});
}

test "what's picked is kept by name for next time" {
    var buf: [256]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const text = blk: {
        var s: State = .{ .pick = .many, .current_by_default = false };
        defer s.deinit();
        try s.set(&[_]TestItem{ .{ .id = 1, .name = "Key" }, .{ .id = 2, .name = "Fill" }, .{ .id = 3, .name = "Rim" } });
        _ = try s.select(3);
        _ = try s.select(1);
        break :blk try s.saved(fba.allocator());
    };
    try testing.expectEqualStrings("Rim\nKey", text);

    var s: State = .{ .pick = .many, .current_by_default = false };
    defer s.deinit();
    try s.load(text);
    try expectSelected(&s, &.{});
    try s.set(&[_]TestItem{ .{ .id = 7, .name = "Key" }, .{ .id = 8, .name = "Rim" } });
    try expectSelected(&s, &.{ 8, 7 });
}

test "many picks in order, without a default, and none picks nothing" {
    var s: State = .{ .pick = .many, .current_by_default = false };
    defer s.deinit();
    try s.set(&[_]TestItem{ .{ .id = 1, .name = "A" }, .{ .id = 2, .name = "B" } });
    try expectSelected(&s, &.{});
    _ = try s.select(2);
    _ = try s.select(1);
    try expectSelected(&s, &.{ 2, 1 });
    try testing.expect(s.deselect(2));
    try expectSelected(&s, &.{1});
    // Not listed
    try testing.expect(!try s.select(9));

    var plain: State = .{ .pick = .none, .current_by_default = true };
    defer plain.deinit();
    try plain.set(&[_]TestItem{.{ .id = 1, .name = "A" }});
    try testing.expect(!try plain.select(1));
    try expectSelected(&plain, &.{});
}

test "two picks with the same name each find their own" {
    var s: State = .{ .pick = .many, .current_by_default = false };
    defer s.deinit();
    try s.load("Camera\nCamera");
    try s.set(&[_]TestItem{ .{ .id = 4, .name = "Camera" }, .{ .id = 5, .name = "Camera" } });
    try expectSelected(&s, &.{ 4, 5 });
}

const tests = struct {
    test "a plugin's lists, through list.sal, with the free camera's from the plugin holding the camera" {
        const sdk = @import("wraith_sdk");
        const r = try Registry.create(testing.allocator, .{});
        defer r.destroy();
        settings.setRegistry(r);
        defer settings.setRegistry(null);

        var engine: Loaded = undefined;
        engine.initForTest(testing.allocator, "unity");
        engine.manifest.value.gameEngine = .{ .id = "unity" };
        var game: Loaded = undefined;
        game.initForTest(testing.allocator, "kai");
        game.manifest.value.game = .{};

        sdk.Owner.attach(engine.root());
        const root = sdk.wraith.root().?;
        const lights = try root.lists().open("lights", .{ .title = "Lights", .pick = .many, .remember = true }, null, null, null);
        try testing.expectError(error.AlreadyOpen, root.lists().open("lights", .{ .pick = .one }, null, null, null));
        try testing.expectError(error.InvalidId, root.lists().open("no spaces", .{ .pick = .one }, null, null, null));
        lights.set(&.{ .{ .id = 1, .name = "Key" }, .{ .id = 2, .name = "Rim" } });
        lights.select(2);
        try testing.expectEqualSlices(u64, &.{2}, lights.selected());
        // Kept for next time, hidden, for just this game
        const kept = r.find("unity.list.lights").?;
        try testing.expect(kept.def.hidden);
        try testing.expectEqualStrings("Rim", r.get(kept).text);

        const engine_cams = root.camera().cameras(null, null);
        // The same list each time, and not remembered
        try testing.expectEqual(engine_cams.data, root.camera().cameras(null, null).data);
        try testing.expectEqual(null, r.find("unity.list.wraith.cameras"));
        engine_cams.set(&.{ .{ .id = 10, .name = "Main Camera" }, .{ .id = 11, .name = "UI", .current = true } });
        try testing.expectEqualSlices(u64, &.{11}, engine_cams.selected());
        // Only once it holds the camera
        try testing.expectEqual(null, cameras());
        _ = try root.camera().claim(null);
        {
            const held = cameras().?;
            defer held.end();
            try testing.expectEqual(&engine.owner, &held.record.loaded.owner);
            try testing.expectEqualStrings("On screen", held.record.current_label);
            held.record.select(10);
        }
        try testing.expectEqualSlices(u64, &.{10}, engine_cams.selected());
        // Lights aren't cameras
        try testing.expectEqual(.plain, find(&engine, "lights").?.purpose);
        sdk.Owner.detach();

        // A game's plugin holding the camera has its cameras shown, once they have something in them
        sdk.Owner.attach(game.root());
        const game_root = sdk.wraith.root().?;
        const game_cams = game_root.camera().cameras(null, null);
        _ = try game_root.camera().claim(null);
        try testing.expectEqual(null, cameras());
        game_cams.set(&.{.{ .id = 20, .name = "Player" }});
        {
            const held = cameras().?;
            defer held.end();
            try testing.expectEqual(&game.owner, &held.record.loaded.owner);
        }
        sdk.Owner.detach();
        game.deinitForTest();
        {
            const held = cameras().?;
            defer held.end();
            try testing.expectEqual(&engine.owner, &held.record.loaded.owner);
        }

        // Gone with the plugin, what's picked kept
        engine.deinitForTest();
        try testing.expectEqual(null, cameras());
        try testing.expectEqual(null, r.find("unity.list.lights"));
        try testing.expectEqualStrings("Rim", r.stores[1].values.get("unity.list.lights").?.text);
    }
};

test {
    _ = tests;
}
