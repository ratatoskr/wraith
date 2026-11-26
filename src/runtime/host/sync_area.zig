//! The `sync` area: locks shared between plugins, see sync.sal. A plugin going drops its locks, hands
//! on what it held and drops what it waited for. A `Lock` object is just an id.

const std = @import("std");

const api = @import("wraith_api");
const Owner = @import("tuft_event").Owner;
const sync = @import("tuft_sys").sync;

const OnGone = @import("Owned.zig").OnGone;
const wraith = @import("wraith.zig");
const threads = @import("threads.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;

const sal = api.salamander;
const W = api.wraith;

pub const Sync = W.Sync;
pub const Lock = W.Sync.Lock;

const allocator = std.heap.smp_allocator;

const LockPromise = sal.Plain(Sync, "lock");
// Settles back on the thread that asked
const Resolver = threads.Back(wraith.ResolverOf(LockPromise));

/// What `Lock` objects point at. Really a lock's id.
pub const Handle = opaque {};

const Waiting = struct {
    who: *Owner,
    resolver: Resolver,
};

const Record = struct {
    id: usize,
    maker: *Owner,
    holder: ?*Owner = null,
    /// Oldest first
    queue: std.ArrayList(Waiting) = .empty,
};

/// Over every lock. Held only briefly, and never while settling, which can call back in.
var guard: sync.RwLock = .{};
var records: std.ArrayList(*Record) = .empty;
var next_id: usize = 1;

/// What to settle or drop once `guard`'s let go.
const After = struct {
    settle: std.ArrayList(Resolver) = .empty,
    fail: std.ArrayList(Resolver) = .empty,

    fn run(self: *After) void {
        for (self.settle.items) |r| r.settle({});
        for (self.fail.items) |r| r.drop();
        self.settle.deinit(allocator);
        self.fail.deinit(allocator);
    }
};

fn find(id: usize) ?*Record {
    for (records.items) |r| if (r.id == id) return r;
    return null;
}

fn idOf(lock: Lock) usize {
    return lock.data;
}

/// Gives it to the longest waiter still waiting, or nobody. Needs `guard`.
fn handOn(r: *Record, after: *After) void {
    r.holder = null;
    while (r.queue.items.len > 0) {
        const w = r.queue.orderedRemove(0);
        if (w.resolver.cancelled()) {
            after.fail.append(allocator, w.resolver) catch w.resolver.drop();
            continue;
        }
        r.holder = w.who;
        after.settle.append(allocator, w.resolver) catch w.resolver.settle({});
        return;
    }
}

var cleanup: OnGone(.closing, gone) = .{};

fn gone(owner: *Owner) void {
    var after: After = .{};
    defer after.run();
    guard.lock();
    defer guard.unlock();
    var i: usize = 0;
    while (i < records.items.len) {
        const r = records.items[i];
        if (r.maker == owner) {
            for (r.queue.items) |w| after.fail.append(allocator, w.resolver) catch w.resolver.drop();
            r.queue.deinit(allocator);
            allocator.destroy(r);
            _ = records.swapRemove(i);
            continue;
        }
        var j: usize = 0;
        while (j < r.queue.items.len) {
            if (r.queue.items[j].who != owner) {
                j += 1;
                continue;
            }
            const w = r.queue.orderedRemove(j);
            after.fail.append(allocator, w.resolver) catch w.resolver.drop();
        }
        if (r.holder == owner) handOn(r, &after);
        i += 1;
    }
    if (records.items.len == 0) {
        records.deinit(allocator);
        records = .empty;
    }
}

pub const SyncImpl = struct {
    pub fn newLock(loaded: *Loaded) Lock {
        const t = wraith.tablesOf(loaded) orelse return .{};
        const lease = cleanup.lease(&loaded.owner) orelse return .{};
        defer lease.end();
        const r = allocator.create(Record) catch return .{};
        guard.lock();
        defer guard.unlock();
        r.* = .{ .id = next_id, .maker = &loaded.owner };
        records.append(allocator, r) catch {
            allocator.destroy(r);
            return .{};
        };
        next_id += 1;
        return .init(@as(*Handle, @ptrFromInt(r.id)), t.lock);
    }

    pub fn lock(loaded: *Loaded, l: Lock) LockPromise {
        const pair = LockPromise.make() catch return .{};
        const back: Resolver = .of(pair.resolver, loaded);
        var after: After = .{};
        defer after.run();
        const lease = cleanup.lease(&loaded.owner) orelse {
            back.drop();
            return pair.promise;
        };
        defer lease.end();
        guard.lock();
        defer guard.unlock();
        const me = &loaded.owner;
        const r = find(idOf(l)) orelse {
            after.fail.append(allocator, back) catch back.drop();
            return pair.promise;
        };
        const waiting = for (r.queue.items) |w| {
            if (w.who == me) break true;
        } else false;
        if (r.holder == me or waiting) {
            back.fail(error.AlreadyHeld);
        } else if (r.holder == null) {
            r.holder = me;
            after.settle.append(allocator, back) catch back.settle({});
        } else {
            r.queue.append(allocator, .{ .who = me, .resolver = back }) catch back.fail(error.Failed);
        }
        return pair.promise;
    }

    pub fn tryLock(loaded: *Loaded, l: Lock) bool {
        const lease = cleanup.lease(&loaded.owner) orelse return false;
        defer lease.end();
        guard.lock();
        defer guard.unlock();
        const r = find(idOf(l)) orelse return false;
        if (r.holder != null) return false;
        r.holder = &loaded.owner;
        return true;
    }

    pub fn unlock(loaded: *Loaded, l: Lock) void {
        var after: After = .{};
        defer after.run();
        guard.lock();
        defer guard.unlock();
        const r = find(idOf(l)) orelse return;
        if (r.holder != &loaded.owner) return;
        handOn(r, &after);
    }
};

pub const LockImpl = struct {
    pub fn held(handle: *Handle) bool {
        guard.lockShared();
        defer guard.unlockShared();
        const r = find(@intFromPtr(handle)) orelse return false;
        return r.holder != null;
    }
};

test "locks are handed on in turn, and go with their plugins" {
    const testing = std.testing;
    var a: Loaded = undefined;
    a.initForTest(testing.allocator, "kai");
    var b: Loaded = undefined;
    b.initForTest(testing.allocator, "rean");
    defer {
        wraith.forget(&b);
        wraith.forget(&a);
    }
    const isHeld = struct {
        fn f(l: Lock) bool {
            return LockImpl.held(@ptrFromInt(l.data));
        }
    }.f;

    const l = SyncImpl.newLock(&a);
    try testing.expect(l.table != null);
    try testing.expect(!isHeld(l));

    try SyncImpl.lock(&a, l).wait();
    try testing.expect(isHeld(l));
    try testing.expectError(error.AlreadyHeld, SyncImpl.lock(&a, l).wait());
    try testing.expect(!SyncImpl.tryLock(&b, l));
    const b_waits = SyncImpl.lock(&b, l);
    try testing.expect(!b_waits.isSettled());
    // Only its holder lets go of it
    SyncImpl.unlock(&b, l);
    try testing.expect(!b_waits.isSettled());
    SyncImpl.unlock(&a, l);
    try b_waits.wait();
    try testing.expect(!SyncImpl.tryLock(&a, l));

    // b goes holding it, so it's handed on
    const a_waits = SyncImpl.lock(&a, l);
    b.deinitForTest();
    try a_waits.wait();
    // and a waiting plugin that goes is dropped from the line
    var c: Loaded = undefined;
    c.initForTest(testing.allocator, "estelle");
    const c_waits = SyncImpl.lock(&c, l);
    c.deinitForTest();
    wraith.forget(&c);
    try testing.expectError(error.Gone, c_waits.wait());
    SyncImpl.unlock(&a, l);
    try testing.expect(!isHeld(l));

    // a goes, and its locks with it, failing whoever waited
    var d: Loaded = undefined;
    d.initForTest(testing.allocator, "joshua");
    try testing.expect(SyncImpl.tryLock(&a, l));
    const d_waits = SyncImpl.lock(&d, l);
    a.deinitForTest();
    try testing.expectError(error.Gone, d_waits.wait());
    try testing.expectError(error.Gone, SyncImpl.lock(&d, l).wait());
    try testing.expect(!SyncImpl.tryLock(&d, l));
    d.deinitForTest();
    wraith.forget(&d);
    try testing.expectEqual(0, records.items.len);
}
