//! Slots plugins define with `Ui.defineSlot`, for other plugins to add objects of its trait to with
//! `Ui.contributeTo`. A slot's gone with the plugin that defined it, and what's added with the plugin
//! that added it. What's added goes by the slot's id, so it's there again when its plugin reloads.

const std = @import("std");
const core = @import("wraith_core");
const Atomic = @import("tuft_arch").atomic.Value;

const api = @import("wraith_api");
const sync = @import("tuft_sys").sync;

const host = @import("root.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;

const sal = api.salamander;
const W = api.wraith;

const gpa = core.heap.main;

pub const Error = error{ UnknownSlot, InvalidId, AlreadyAdded, WrongTrait, Failed };

/// A slot a plugin defined.
pub const Defined = struct {
    loaded: *Loaded,
    arena: std.heap.ArenaAllocator,
    /// `plugin.id`
    id: []const u8,
    title: []const u8,
    help: []const u8,
    trait: []const u8,
    stopped: Atomic(bool) = .init(false),
    /// What the last `contributions` gave, kept till the next.
    out: std.ArrayList(sal.AnyObject) = .empty,

    pub fn going(self: *const Defined) bool {
        return !self.stopped.load(.acquire);
    }

    pub fn stop(self: *Defined) void {
        self.stopped.store(true, .release);
    }

    /// Its plugin's gone.
    pub fn free(self: *Defined) void {
        self.stop();
        {
            lock.lock();
            defer lock.unlock();
            for (defined.items, 0..) |d, i| if (d == self) {
                _ = defined.swapRemove(i);
                break;
            };
        }
        self.out.deinit(gpa);
        self.arena.deinit();
        gpa.destroy(self);
    }
};

/// What a plugin added to one.
pub const Added = struct {
    loaded: *Loaded,
    /// The slot's `plugin.id`.
    slot: []u8,
    obj: sal.AnyObject,
    seq: u32,
    stopped: Atomic(bool) = .init(false),

    pub fn going(self: *const Added) bool {
        return !self.stopped.load(.acquire);
    }

    /// Its plugin's closing, while it can still be called into, so its object's let go of.
    pub fn stop(self: *Added) void {
        if (self.stopped.swap(true, .acq_rel)) return;
        sal.host().release(self.obj);
    }

    pub fn free(self: *Added) void {
        self.stop();
        {
            lock.lock();
            defer lock.unlock();
            for (added.items, 0..) |a, i| if (a == self) {
                _ = added.orderedRemove(i);
                break;
            };
        }
        gpa.free(self.slot);
        gpa.destroy(self);
    }
};

var lock: sync.RwLock = .{};
/// Under `lock`.
var defined: std.ArrayList(*Defined) = .empty;
/// Under `lock`, in the order added.
var added: std.ArrayList(*Added) = .empty;
var next_seq: Atomic(u32) = .init(0);

var defined_records: host.Owned(Defined) = .{};
var added_records: host.Owned(Added) = .{};

/// Letters, digits, `_`, `-` and `.`.
fn validId(id: []const u8) bool {
    if (id.len == 0) return false;
    for (id) |ch| if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "_-.", ch) == null) return false;
    return true;
}

fn findDefined(id: []const u8) ?*Defined {
    for (defined.items) |d| if (d.going() and std.mem.eql(u8, d.id, id)) return d;
    return null;
}

/// `loaded`'s, as `plugin.id`.
pub fn define(loaded: *Loaded, definition: W.Slot.Definition) Error!*Defined {
    if (!validId(definition.id) or definition.trait.len == 0) return error.InvalidId;
    const d = gpa.create(Defined) catch return error.Failed;
    errdefer gpa.destroy(d);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    d.* = .{
        .loaded = loaded,
        .arena = undefined,
        .id = std.fmt.allocPrint(a, "{s}.{s}", .{ loaded.name, definition.id }) catch return error.Failed,
        .title = a.dupe(u8, definition.title) catch return error.Failed,
        .help = a.dupe(u8, definition.help) catch return error.Failed,
        .trait = a.dupe(u8, definition.trait) catch return error.Failed,
    };
    {
        lock.lock();
        defer lock.unlock();
        // Wraith's own ids stay Wraith's
        if (findDefined(d.id) != null or host.slots.Slot.byId(d.id) != null) return error.AlreadyAdded;
        defined.append(gpa, d) catch return error.Failed;
    }
    d.arena = arena;
    defined_records.add(d) catch {
        lock.lock();
        defer lock.unlock();
        _ = defined.pop();
        return error.Failed;
    };
    return d;
}

/// `obj` in the slot by `id`, if it's the slot's trait. Takes `obj` either way.
pub fn contribute(loaded: *Loaded, id: []const u8, obj: sal.AnyObject) Error!*Added {
    errdefer sal.host().release(obj);
    const table = obj.table orelse return error.WrongTrait;
    {
        lock.lockShared();
        defer lock.unlockShared();
        const d = findDefined(id) orelse return error.UnknownSlot;
        if (!std.mem.eql(u8, sal.headerOf(table).info.name.get(), d.trait)) return error.WrongTrait;
    }
    const a = gpa.create(Added) catch return error.Failed;
    errdefer gpa.destroy(a);
    a.* = .{ .loaded = loaded, .slot = gpa.dupe(u8, id) catch return error.Failed, .obj = obj, .seq = next_seq.fetchAdd(1, .monotonic) };
    errdefer gpa.free(a.slot);
    {
        lock.lock();
        defer lock.unlock();
        added.append(gpa, a) catch return error.Failed;
    }
    added_records.add(a) catch {
        lock.lock();
        defer lock.unlock();
        _ = added.pop();
        return error.Failed;
    };
    return a;
}

/// The one by `plugin.id`, if it's there.
pub fn byId(id: []const u8) ?*Defined {
    lock.lockShared();
    defer lock.unlockShared();
    return findDefined(id);
}

/// What's in `d` now, kept in it till the next call.
pub fn contributions(d: *Defined) []const sal.AnyObject {
    lock.lockShared();
    defer lock.unlockShared();
    d.out.clearRetainingCapacity();
    for (added.items) |a| {
        if (!a.going() or !std.mem.eql(u8, a.slot, d.id)) continue;
        d.out.append(gpa, a.obj) catch break;
    }
    return d.out.items;
}

/// Every slot plugins defined, for `Ui.slots`. In `arena`.
pub fn infos(arena: std.mem.Allocator) ![]W.Slot.Info {
    lock.lockShared();
    defer lock.unlockShared();
    var out: std.ArrayList(W.Slot.Info) = .empty;
    for (defined.items) |d| {
        if (!d.going()) continue;
        try out.append(arena, .{ .id = try arena.dupe(u8, d.id), .title = try arena.dupe(u8, d.title), .help = try arena.dupe(u8, d.help), .thread = .any });
    }
    return out.items;
}

pub const SlotImpl = struct {
    pub fn contributions(d: *Defined) []const sal.AnyObject {
        return plugin_slots.contributions(d);
    }

    /// Its plugin frees it, so this only hides it.
    pub fn remove(d: *Defined) void {
        d.stop();
    }
};

pub const AddedImpl = struct {
    pub fn isOpen(_: *Added) bool {
        return false;
    }

    pub fn focus(_: *Added) void {}

    /// Lets go of its object. Its plugin frees the rest.
    pub fn remove(a: *Added) void {
        a.stop();
    }

    pub fn open(_: *Added, _: []const u8) void {}

    pub fn close(_: *Added, _: []const u8) void {}
};

const plugin_slots = @This();
