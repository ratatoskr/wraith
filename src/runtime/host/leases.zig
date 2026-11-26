//! Leases on parts of the game only one plugin can handle at a time, see `lease.sal` and `ranked`.
//! Hand-overs run under the part's lock. Plugins are told after, outside it, so they can call back in.

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;
const sync = @import("tuft_sys").sync;
const Owner = @import("tuft_event").Owner;

const api = @import("wraith_api");
const core = @import("wraith_core");

const host = @import("root.zig");
const ranked = @import("ranked.zig");
const game_area = @import("game_area.zig");
const photo_area = @import("photo_area.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;

const W = api.wraith;
const log = core.log.scoped(.wraith_runtime);

pub const Part = enum {
    /// Ticks from the game's own thread, see `frame`.
    ticks,
    /// The game's speed, see `game_area`.
    speed,
    /// The game's camera, for the free camera, see `photo_area`.
    camera,
    /// The game's characters' skeletons, for posing, see `photo_area`.
    posing,
    /// The game's view and output color space, see `frame`.
    view,

    fn what(self: Part) []const u8 {
        return switch (self) {
            .ticks => "ticks",
            .speed => "the game's speed",
            .camera => "the camera",
            .posing => "posing",
            .view => "the view",
        };
    }
};

/// One plugin's claim on a part, and what the part keeps for it till it holds it.
pub const Lease = struct {
    loaded: *Loaded,
    part: Part,
    changed: ?W.Lease.Changed,
    /// It's let go, or its plugin's going. Under the part's lock.
    released: bool = false,

    /// `speed`'s: gets the speed while it holds it.
    speed: ?W.Game.SpeedHandler = null,
    /// `camera`'s, from `setWorld`, given to the free camera once it holds it. Under the part's lock.
    world: ?W.FreeCamera.World = null,
    /// `view`'s, from `setColorSpace`. Under the part's lock.
    color_space: ?W.ColorSpace = null,
    /// `ticks`': `core.timing.now()` when it got them or last ticked.
    last_tick: Atomic(u64) = .init(0),
    warned: Atomic(bool) = .init(false),

    pub fn held(self: *const Lease) bool {
        return holder(self.part) == self;
    }

    /// From the plugin. Not told, since it asked.
    pub fn release(self: *Lease) void {
        drop(self, true);
    }

    /// As its plugin closes, for `Owned`. Nothing's called on it any more.
    pub fn stop(self: *Lease) void {
        drop(self, false);
    }

    /// Once its plugin's released, for `Owned`.
    pub fn free(self: *Lease) void {
        drop(self, false);
        if (self.changed) |c| c.release();
        if (self.speed) |s| s.release();
        self.loaded.allocator.destroy(self);
    }
};

fn leaseKey(l: *Lease) usize {
    return @intFromPtr(l);
}

const Slot = struct {
    lock: sync.RwLock = .{},
    /// Under `lock`.
    leases: ranked.Ranked(*Lease, leaseKey) = .{},
    /// The best of `leases`, set under `lock`.
    holder: Atomic(?*Lease) = .init(null),
    /// Its plugin, to compare without following `holder`, which could be going.
    holder_loaded: Atomic(?*const Loaded) = .init(null),
};

var slots: std.EnumArray(Part, Slot) = .initFill(.{});
var records: host.Owned(Lease) = .{};

/// Who holds `part`. Only follow it while its plugin can't go, like from its own calls or `withHolder`.
pub fn holder(part: Part) ?*Lease {
    return slots.getPtr(part).holder.load(.acquire);
}

/// Whether `loaded` holds `part`. Safe from anywhere.
pub fn holds(loaded: *const Loaded, part: Part) bool {
    return slots.getPtr(part).holder_loaded.load(.acquire) == loaded;
}

/// `loaded`'s lease on `part` if it holds it. Only for `loaded`'s own calls, while it can't go.
pub fn heldBy(loaded: *const Loaded, part: Part) ?*Lease {
    if (!holds(loaded, part)) return null;
    const h = holder(part) orelse return null;
    return if (h.loaded == loaded) h else null;
}

/// `f` on `loaded`'s best lease on `part`, under the part's lock, so it's set before a hand-over.
/// False if it has none.
pub fn withLease(loaded: *const Loaded, part: Part, ctx: anytype, comptime f: fn (@TypeOf(ctx), *Lease) void) bool {
    const slot = slots.getPtr(part);
    slot.lock.lock();
    defer slot.lock.unlock();
    var found: ?*Lease = null;
    for (slot.leases.entries.items) |e| {
        if (e.value.loaded != loaded) continue;
        if (found == null or e.value == slot.holder.load(.acquire)) found = e.value;
    }
    f(ctx, found orelse return false);
    return true;
}

/// `f` on whoever holds `part`, with the part's lock held shared so it can't go meanwhile.
pub fn withHolder(part: Part, ctx: anytype, comptime f: fn (@TypeOf(ctx), *Lease) void) bool {
    const slot = slots.getPtr(part);
    slot.lock.lockShared();
    defer slot.lock.unlockShared();
    const h = slot.holder.load(.acquire) orelse return false;
    f(ctx, h);
    return true;
}

/// The name of the plugin holding `part`, copied into `buf`, or null if nobody does.
pub fn holderName(part: Part, buf: []u8) ?[]const u8 {
    const slot = slots.getPtr(part);
    slot.lock.lockShared();
    defer slot.lock.unlockShared();
    const h = slot.holder.load(.acquire) orelse return null;
    const n = @min(h.loaded.name.len, buf.len);
    @memcpy(buf[0..n], h.loaded.name[0..n]);
    return buf[0..n];
}

pub const ClaimError = error{ OutOfMemory, OwnerGone };

/// `speed` is `speed`'s handler, which the lease owns from here, even if it fails.
pub fn claim(loaded: *Loaded, part: Part, changed: ?W.Lease.Changed, speed: ?W.Game.SpeedHandler) ClaimError!*Lease {
    const l = loaded.allocator.create(Lease) catch {
        if (changed) |c| c.release();
        if (speed) |s| s.release();
        return error.OutOfMemory;
    };
    l.* = .{ .loaded = loaded, .part = part, .changed = changed, .speed = speed };
    records.add(l) catch |err| {
        if (changed) |c| c.release();
        if (speed) |s| s.release();
        loaded.allocator.destroy(l);
        return if (err == error.OutOfMemory) error.OutOfMemory else error.OwnerGone;
    };
    var change: Change = .{ .part = part };
    {
        const slot = slots.getPtr(part);
        slot.lock.lock();
        defer slot.lock.unlock();
        _ = slot.leases.put(std.heap.page_allocator, l, .of(loaded)) catch {
            // `Owned` frees it with the plugin
            l.released = true;
            return error.OutOfMemory;
        };
        change = repickLocked(part, true);
    }
    change.tell();
    return l;
}

fn drop(l: *Lease, by_plugin: bool) void {
    var change: Change = .{ .part = l.part };
    {
        const slot = slots.getPtr(l.part);
        slot.lock.lock();
        defer slot.lock.unlock();
        if (l.released) return;
        l.released = true;
        _ = slot.leases.take(@intFromPtr(l));
        // Its plugin's still there to put back what it did only if it let go itself
        change = repickLocked(l.part, by_plugin);
    }
    change.tell();
}

/// Who lost the part and who got it, to tell them once the part's lock's let go.
const Change = struct {
    part: Part,
    lost: ?*Lease = null,
    lost_lease: ?Owner.Lease = null,
    got: ?*Lease = null,
    got_lease: ?Owner.Lease = null,

    fn tell(self: Change) void {
        if (self.lost) |l| if (self.lost_lease) |held| {
            defer held.end();
            if (l.changed) |c| c.invoke(.{false});
        };
        if (self.got) |l| if (self.got_lease) |held| {
            defer held.end();
            if (l.changed) |c| c.invoke(.{true});
        };
    }
};

/// Hands `part` to the best lease, if that's changed. `before_live` if the old one can still be called.
/// Needs the part's lock.
fn repickLocked(part: Part, before_live: bool) Change {
    const slot = slots.getPtr(part);
    const before = slot.holder.load(.acquire);
    const after = slot.leases.best();
    if (before == after) return .{ .part = part };
    slot.holder.store(after, .release);
    slot.holder_loaded.store(if (after) |a| a.loaded else null, .release);
    const live_before = if (before) |b| before_live or !b.released else false;
    handOver(part, if (live_before) before else null, after);
    if (after) |a| {
        log.info("{s} has {s} now", .{ a.loaded.name, part.what() });
    } else log.info("Nobody has {s} now", .{part.what()});

    var change: Change = .{ .part = part };
    // Lost to a better one, rather than let go
    if (before) |b| if (!b.released) {
        change.lost = b;
        change.lost_lease = records.lease(&b.loaded.owner);
    };
    if (after) |a| {
        change.got = a;
        change.got_lease = records.lease(&a.loaded.owner);
    }
    return change;
}

/// The part's own code, as it changes hands. `before` is null if it can't be called any more.
fn handOver(part: Part, before: ?*Lease, after: ?*Lease) void {
    switch (part) {
        .ticks => host.frame.ticksHandedOver(after),
        .speed => game_area.speedHandedOver(before, after),
        .camera => photo_area.cameraHandedOver(after),
        .posing => photo_area.posingHandedOver(before),
        .view => host.frame.viewHandedOver(after),
    }
}

test "the best placed claim holds a part, and it's handed on as they go" {
    const testing = std.testing;
    var engine: Loaded = undefined;
    engine.initForTest(testing.allocator, "unity");
    engine.manifest.value.gameEngine = .{ .id = "unity" };
    var game: Loaded = undefined;
    game.initForTest(testing.allocator, "kai");
    game.manifest.value.game = .{ .ids = &.{"kai"} };

    const Told = struct {
        got: u32 = 0,
        lost: u32 = 0,
        fn changed(self: *@This(), held: bool) void {
            if (held) self.got += 1 else self.lost += 1;
        }
    };
    var engine_told: Told = .{};
    var game_told: Told = .{};

    const e = try claim(&engine, .posing, W.Lease.Changed.init(&engine_told, Told.changed), null);
    try testing.expect(e.held());
    try testing.expect(holds(&engine, .posing));
    try testing.expectEqual(1, engine_told.got);

    const g = try claim(&game, .posing, W.Lease.Changed.init(&game_told, Told.changed), null);
    try testing.expect(g.held());
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("kai", holderName(.posing, &buf).?);
    try testing.expectEqual(null, holderName(.speed, &buf));
    try testing.expect(!e.held());
    try testing.expectEqual(1, engine_told.lost);
    try testing.expectEqual(1, game_told.got);

    // Letting go hands it back, and isn't told
    g.release();
    g.release();
    try testing.expect(e.held());
    try testing.expectEqual(0, game_told.lost);
    try testing.expectEqual(2, engine_told.got);

    // Its plugin going does too
    engine.deinitForTest();
    host.wraith.forget(&engine);
    try testing.expectEqual(null, holder(.posing));
    game.deinitForTest();
    host.wraith.forget(&game);
}
