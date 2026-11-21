//! Tweaks plugins add. `Tweaks` lists them with the project's own and calls back when they're
//! turned on or off, or a field changes.

const std = @import("std");

const api = @import("wraith_api");
const input = @import("wraith_platform").input;
const sync = @import("tuft_sys").sync;
const Atomic = @import("tuft_arch").atomic.Value;
const Owner = @import("tuft_event").Owner;

const host = @import("root.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;

const allocator = std.heap.page_allocator;
const sal = api.salamander;
const W = api.wraith;
/// From `tweaks.sal`, kept till the tweak's gone.
pub const Handler = W.TweakHandler;

pub const Entry = struct {
    owner: *Owner,
    /// `plugin:id`, what `Tweaks` and the settings know it by.
    name: []const u8,
    /// The plugin's name.
    plugin: []const u8,
    /// Its title, for people.
    plugin_title: []const u8,
    id: []const u8,
    /// Parsed, in `arena` like the names. Like a file's, with no sections.
    def: api.tweak.Tweak,
    handler: Handler,
    arena: std.heap.ArenaAllocator,
    /// The list's, plus one for each call in flight.
    refs: Atomic(u32) = .init(1),

    fn release(self: *Entry) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.handler.release();
        var arena = self.arena;
        arena.deinit();
    }
};

var lock: sync.RwLock = .{};
var entries: std.ArrayList(*Entry) = .empty;
/// Bumped when the list or a definition changes.
var generation: Atomic(u32) = .init(1);

var watch: Owner.Watch(*u8, .{ .closing = closing }) = .{};
var listener: u8 = 0;

/// Calls in flight on this thread, which removing can't wait for.
threadlocal var calling: u32 = 0;

pub fn version() u32 {
    return generation.load(.acquire);
}

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '.') return false;
    return true;
}

/// Lists it, replacing one with the same id. Under the owner's lease.
fn place(owner: *Owner, entry: *Entry) api.TweakError!void {
    const old = blk: {
        lock.lock();
        defer lock.unlock();
        for (entries.items) |*e| if (e.*.owner == owner and std.mem.eql(u8, e.*.id, entry.id)) {
            const was = e.*;
            e.* = entry;
            break :blk was;
        };
        try entries.append(allocator, entry);
        break :blk null;
    };
    _ = generation.fetchAdd(1, .release);
    if (old) |e| finish(e);
}

/// Through `tweaks.sal`. The handler's released if it fails.
pub fn add(loaded: *Loaded, definition: W.TweakDefinition, handler: Handler) api.TweakError!void {
    const entry = typed(loaded, definition, handler) catch |err| {
        handler.release();
        return err;
    };
    errdefer entry.release();
    const lease = watch.lease(&listener, &loaded.owner, .calls) orelse return error.OwnerGone;
    defer lease.end();
    try place(&loaded.owner, entry);
}

fn typed(loaded: *Loaded, d: W.TweakDefinition, handler: Handler) api.TweakError!*Entry {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const fields = try a.alloc(api.TweakField, d.fields.len);
    for (d.fields, fields) |f, *out| {
        const choices = try a.alloc(api.tweak.Choice, f.choices.len);
        for (f.choices, choices) |ch, *c| c.* = .{ .value = ch.value, .label = try a.dupe(u8, ch.label) };
        out.* = .{
            .name = try a.dupe(u8, f.name),
            .type = switch (f.type) {
                inline .f64, .f32, .i64, .i32, .i16, .i8, .u64, .u32, .u16, .u8, .bool => |t| @field(api.tweak.Type, @tagName(t)),
                else => return error.InvalidDefinition,
            },
            .value = f.value,
            .label = try a.dupe(u8, f.label),
            .toggle = f.toggle,
            .hex = f.hex,
            .min = if (f.has_min) f.min else null,
            .max = if (f.has_max) f.max else null,
            .key = try a.dupe(u8, f.key),
            .choices = choices,
        };
    }
    return build(&arena, &loaded.owner, loaded.name, loaded.displayName(), .{
        .id = try a.dupe(u8, d.id),
        .title = try a.dupe(u8, d.title),
        .key = try a.dupe(u8, d.key),
        .mode = if (d.mode == .action) .action else .toggle,
        .fields = fields,
    }, handler);
}

/// Takes `arena` once it's made, which `def` points into.
fn build(arena: *std.heap.ArenaAllocator, owner: *Owner, plugin: []const u8, plugin_title: []const u8, def: api.TweakDefinition, handler: Handler) api.TweakError!*Entry {
    const a = arena.allocator();
    if (!validId(def.id)) return error.InvalidId;
    const fields = try a.alloc(api.tweak.Field, def.fields.len);
    for (fields, def.fields) |*dst, src| {
        if (src.name.len == 0) return error.InvalidDefinition;
        dst.* = .{
            .name = src.name,
            .type = src.type,
            .value = src.value,
            .label = if (src.label.len > 0) src.label else src.name,
            .toggle = src.toggle,
            .hex = src.hex,
            .min = src.min,
            .max = src.max,
            .key = try chord(src.key),
            .choices = src.choices,
        };
    }
    const entry = try a.create(Entry);
    entry.* = .{
        .owner = owner,
        .name = try std.fmt.allocPrint(a, "{s}:{s}", .{ plugin, def.id }),
        .plugin = try a.dupe(u8, plugin),
        .plugin_title = try a.dupe(u8, plugin_title),
        .id = def.id,
        .def = .{ .title = if (def.title.len > 0) def.title else null, .key = try chord(def.key), .mode = def.mode, .fields = fields },
        .handler = handler,
        .arena = undefined,
    };
    entry.arena = arena.*;
    return entry;
}

fn chord(text: []const u8) api.TweakError!?input.Chord {
    if (text.len == 0) return null;
    return api.tweak.parseChord(text) orelse error.InvalidDefinition;
}

pub fn remove(loaded: *Loaded, id: []const u8) void {
    removeFor(&loaded.owner, id);
}

pub fn removeFor(owner: *Owner, id: []const u8) void {
    const entry = blk: {
        lock.lock();
        defer lock.unlock();
        for (entries.items, 0..) |e, i| if (e.owner == owner and std.mem.eql(u8, e.id, id)) {
            break :blk entries.orderedRemove(i);
        };
        return;
    };
    _ = generation.fetchAdd(1, .release);
    finish(entry);
}

/// Waits for its calls unless one of them is ours, then lets it go.
fn finish(entry: *Entry) void {
    if (calling == 0) while (entry.refs.load(.acquire) > 1) std.Thread.yield() catch {};
    entry.release();
}

fn closing(_: *u8, owner: *Owner) void {
    var gone: std.ArrayList(*Entry) = .empty;
    defer gone.deinit(allocator);
    {
        lock.lock();
        defer lock.unlock();
        var i: usize = 0;
        while (i < entries.items.len) {
            const e = entries.items[i];
            if (e.owner != owner) {
                i += 1;
                continue;
            }
            gone.append(allocator, e) catch {
                i += 1;
                continue;
            };
            _ = entries.orderedRemove(i);
        }
    }
    if (gone.items.len > 0) _ = generation.fetchAdd(1, .release);
    for (gone.items) |e| finish(e);
}

/// Hold it short and don't call anything that adds or removes. Entries stay put until `end`.
pub fn read() Reading {
    lock.lockShared();
    return .{ .entries = entries.items };
}

pub const Reading = struct {
    entries: []const *Entry,

    pub fn end(_: Reading) void {
        lock.unlockShared();
    }
};

pub const Result = enum { ok, failed, gone };

/// Render thread, with no locks held, since the plugin can add and remove from inside.
pub fn call(name: []const u8, event: api.TweakEvent, problem: *api.TweakProblem) Result {
    const entry = blk: {
        lock.lockShared();
        defer lock.unlockShared();
        for (entries.items) |e| if (std.mem.eql(u8, e.name, name)) {
            _ = e.refs.fetchAdd(1, .acq_rel);
            break :blk e;
        };
        return .gone;
    };
    defer entry.release();
    if (!entry.owner.isOpen()) return .gone;
    calling += 1;
    defer calling -= 1;
    entry.handler.invoke(.{.{
        .kind = switch (event.kind) {
            inline else => |k| @field(W.TweakEventKind, @tagName(k)),
        },
        .field = .init(event.field),
        .value = event.value,
    }}) catch |err| {
        if (err == error.Gone) return .gone;
        const why = sal.host().explanation(@errorName(err));
        problem.set(if (why.len > 0) why else @errorName(err));
        return .failed;
    };
    return .ok;
}

// Turning tweaks on and off by name, for scripts and plugins

/// What every tweak's box showed on the last tick, and what's been asked for since. `Tweaks`
/// keeps one, and the host's calls reach the one that's up. Its lock is only held briefly and
/// nothing else is taken under it, so any thread can call in, from inside any callback.
pub const Switches = struct {
    lock: sync.RwLock = .{},
    /// By name. Names are ours.
    states: std.StringHashMapUnmanaged(bool) = .empty,
    /// Oldest first. Names are ours.
    asked: std.ArrayList(Switch) = .empty,

    pub const Switch = struct {
        name: []u8,
        on: bool,
    };

    pub fn deinit(self: *Switches) void {
        var it = self.states.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        self.states.deinit(allocator);
        freeAll(&self.asked);
    }

    /// What was last asked for it counts, else how it was on the last tick.
    pub fn isOn(self: *Switches, name: []const u8) api.TweakSwitchError!bool {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        var i = self.asked.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.asked.items[i].name, name)) return self.asked.items[i].on;
        }
        return self.states.get(name) orelse error.NotFound;
    }

    /// Done on the next tick.
    pub fn ask(self: *Switches, name: []const u8, on: bool) api.TweakSwitchError!void {
        self.lock.lock();
        defer self.lock.unlock();
        if (!self.states.contains(name)) return error.NotFound;
        const owned = try allocator.dupe(u8, name);
        errdefer allocator.free(owned);
        try self.asked.append(allocator, .{ .name = owned, .on = on });
    }

    /// What's been asked for, oldest first, for `freeAll`.
    pub fn take(self: *Switches) std.ArrayList(Switch) {
        self.lock.lock();
        defer self.lock.unlock();
        const list = self.asked;
        self.asked = .empty;
        return list;
    }

    /// Takes every box as it is now, and adds the ones that changed to `changed` in `arena`.
    /// One that's new isn't a change.
    pub fn update(self: *Switches, now: []const Switch, arena: std.mem.Allocator, changed: *std.ArrayList(Switch)) !void {
        self.lock.lock();
        defer self.lock.unlock();
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(arena);
        for (now) |s| {
            try seen.put(arena, s.name, {});
            if (self.states.getPtr(s.name)) |was| {
                if (was.* != s.on) try changed.append(arena, s);
                was.* = s.on;
                continue;
            }
            const owned = try allocator.dupe(u8, s.name);
            errdefer allocator.free(owned);
            try self.states.put(allocator, owned, s.on);
        }
        // Gone, like a renamed file
        var gone: std.ArrayList([]const u8) = .empty;
        var it = self.states.keyIterator();
        while (it.next()) |k| if (!seen.contains(k.*)) try gone.append(arena, k.*);
        for (gone.items) |k| {
            const kv = self.states.fetchRemove(k).?;
            allocator.free(kv.key);
        }
    }

    pub fn freeAll(list: *std.ArrayList(Switch)) void {
        for (list.items) |s| allocator.free(s.name);
        list.deinit(allocator);
    }
};

var current_lock: sync.RwLock = .{};
var current: ?*Switches = null;

/// The project's, while it's up. Null takes it away if it's `was`.
pub fn useSwitches(switches: ?*Switches, was: ?*Switches) void {
    current_lock.lock();
    defer current_lock.unlock();
    if (switches != null or current == was) current = switches;
}

// Hearing boxes switch

const Bus = @import("wraith_core").Event(fn (name: []const u8, on: bool) void);
var bus: Bus = .init(allocator);

pub const Switched = W.TweakSwitched;

pub const Listener = struct {
    loaded: *Loaded,
    handler: Switched,
    subscription: Bus.Subscription = undefined,
    stopped: Atomic(bool) = .init(false),

    fn fire(self: *Listener, name: []const u8, on: bool) void {
        self.handler.invoke(.{ name, on });
    }

    pub fn going(self: *Listener) bool {
        return !self.stopped.load(.acquire);
    }

    /// Waits for a call in flight, unless it's this one.
    pub fn stop(self: *Listener) void {
        if (self.stopped.swap(true, .acq_rel)) return;
        self.subscription.unsubscribe();
        self.handler.release();
    }

    pub fn free(self: *Listener) void {
        self.stop();
        allocator.destroy(self);
    }
};

var listeners: host.Owned(Listener) = .{};

/// Released if it fails.
pub fn onSwitched(loaded: *Loaded, handler: Switched) error{ OutOfMemory, OwnerGone }!*Listener {
    const l = allocator.create(Listener) catch {
        handler.release();
        return error.OutOfMemory;
    };
    l.* = .{ .loaded = loaded, .handler = handler };
    l.subscription = bus.subscribeUnscoped(l, Listener.fire) catch {
        allocator.destroy(l);
        handler.release();
        return error.OutOfMemory;
    };
    listeners.add(l) catch |err| {
        l.free();
        return if (err == error.OutOfMemory) error.OutOfMemory else error.OwnerGone;
    };
    return l;
}

/// Tells everyone listening that a box changed. Render thread.
pub fn announce(name: []const u8, on: bool) void {
    bus.fire(.{ name, on });
}

pub fn isOn(_: *Loaded, name: []const u8) api.TweakSwitchError!bool {
    return isOnNamed(name);
}

pub fn setOn(_: *Loaded, name: []const u8, on: bool) api.TweakSwitchError!void {
    return setOnNamed(name, on);
}

pub fn isOnNamed(name: []const u8) api.TweakSwitchError!bool {
    current_lock.lockShared();
    defer current_lock.unlockShared();
    const s = current orelse return error.NotFound;
    return s.isOn(name);
}

pub fn setOnNamed(name: []const u8, on: bool) api.TweakSwitchError!void {
    current_lock.lockShared();
    defer current_lock.unlockShared();
    const s = current orelse return error.NotFound;
    return s.ask(name, on);
}

test "switches count what's asked and say what changed" {
    const testing = std.testing;
    var s: Switches = .{};
    defer s.deinit();
    useSwitches(&s, null);
    defer useSwitches(null, &s);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var changed: std.ArrayList(Switches.Switch) = .empty;

    try testing.expectError(error.NotFound, isOnNamed("kai/God mode"));
    var god = "kai/God mode".*;
    var fly = "fly".*;
    try s.update(&.{ .{ .name = &god, .on = false }, .{ .name = &fly, .on = true } }, a, &changed);
    try testing.expectEqual(0, changed.items.len);
    try testing.expect(!try isOnNamed("kai/God mode"));
    try setOnNamed("kai/God mode", true);
    try testing.expectError(error.NotFound, setOnNamed("nope", true));
    try testing.expect(try isOnNamed("kai/God mode"));
    var asked = s.take();
    defer Switches.freeAll(&asked);
    try testing.expectEqual(1, asked.items.len);
    try testing.expect(!try isOnNamed("kai/God mode"));

    try s.update(&.{.{ .name = &god, .on = true }}, a, &changed);
    try testing.expectEqual(1, changed.items.len);
    try testing.expectEqualStrings("kai/God mode", changed.items[0].name);
    try testing.expectError(error.NotFound, isOnNamed("fly"));
}

test "through tweaks.sal, failing with why" {
    const testing = std.testing;
    const sdk = @import("wraith_sdk");
    var loaded: Loaded = undefined;
    loaded.initForTest(testing.allocator, "kai");
    sdk.Owner.attach(loaded.root());
    defer sdk.Owner.detach();
    const list = sdk.wraith.root().?.tweaks();

    const Seen = struct {
        changes: u32 = 0,
        last: f64 = 0,
        ready: bool = false,

        fn handle(self: *@This(), event: W.TweakEvent) error{ InvalidId, InvalidDefinition, NotFound, Failed }!void {
            switch (event.kind) {
                .changed => {
                    self.changes += 1;
                    self.last = event.value;
                },
                .on => if (!self.ready) return sal.host().explain(error.Failed, "no player yet", .{}),
                else => {},
            }
        }
    };
    var seen: Seen = .{};
    const fields = [_]W.TweakField{.{ .name = "speed", .value = 2, .has_min = true, .min = 1 }};
    try list.add(.{ .id = "boost", .title = "Boost", .key = "F8", .fields = &fields }, Handler.init(&seen, Seen.handle));
    try testing.expectError(error.InvalidId, list.add(.{ .id = "no spaces" }, Handler.init(&seen, Seen.handle)));
    try testing.expectError(error.InvalidDefinition, list.add(.{ .id = "bad", .key = "NotAKey" }, Handler.init(&seen, Seen.handle)));

    {
        const r = read();
        defer r.end();
        try testing.expectEqual(1, r.entries.len);
        try testing.expectEqualStrings("kai:boost", r.entries[0].name);
        try testing.expectEqual(1, r.entries[0].def.fields[0].min.?);
        try testing.expectEqual(null, r.entries[0].def.fields[0].max);
    }
    var problem: api.TweakProblem = .{};
    try testing.expectEqual(.ok, call("kai:boost", .{ .kind = .changed, .field = "speed", .value = 3 }, &problem));
    try testing.expectEqual(3, seen.last);
    try testing.expectEqual(.failed, call("kai:boost", .{ .kind = .on }, &problem));
    try testing.expectEqualStrings("no player yet", problem.message());
    seen.ready = true;
    try testing.expectEqual(.ok, call("kai:boost", .{ .kind = .on }, &problem));

    list.remove("boost");
    try testing.expectEqual(.gone, call("kai:boost", .{ .kind = .off }, &problem));
    try list.add(.{ .id = "again" }, Handler.init(&seen, Seen.handle));
    loaded.deinitForTest();
    host.wraith.forget(&loaded);
    try testing.expectEqual(.gone, call("kai:again", .{ .kind = .off }, &problem));
}
