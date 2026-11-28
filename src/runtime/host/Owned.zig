//! Things services made for owners that call into their code, cleaned up with the owner. Tagged with
//! `Loaded.making`, so part of an owner, like a session's tweak, can be stopped alone.

const std = @import("std");
const core = @import("wraith_core");
const Atomic = @import("tuft_arch").atomic.Value;

const Owner = @import("tuft_event").Owner;
const sync = @import("tuft_sys").sync;

/// Every list, so `stopTagged` reaches them all. They're globals, so they're never taken out.
var lists_lock: sync.RwLock = .{};
var lists: [64]List = undefined;
var lists_len: usize = 0;

const List = struct {
    ctx: *anyopaque,
    stop: *const fn (ctx: *anyopaque, owner: *const Owner, tag: u32) void,
};

/// Stops what `owner` made while `making` was `tag`, in every list. Not 0, which is everything else.
pub fn stopTagged(owner: *const Owner, tag: u32) void {
    std.debug.assert(tag != 0);
    var copy: [lists.len]List = undefined;
    const n = blk: {
        lists_lock.lockShared();
        defer lists_lock.unlockShared();
        @memcpy(copy[0..lists_len], lists[0..lists_len]);
        break :blk lists_len;
    };
    for (copy[0..n]) |l| l.stop(l.ctx, owner, tag);
}

/// Cleans up an owner's things kept elsewhere, like in `Names`, once `when` happens. Hold a lease while
/// adding. `.closing` is for calls into its code, `.released` for data readable till then.
pub fn OnGone(comptime when: enum { closing, released }, comptime gone: fn (*Owner) void) type {
    return struct {
        const Self = @This();

        watch: Owner.Watch(*Self, if (when == .closing) .{ .closing = on } else .{ .released = on }) = .{},

        fn on(_: *Self, owner: *Owner) void {
            gone(owner);
        }

        pub fn lease(self: *Self, owner: *Owner) ?Owner.Lease {
            return self.watch.lease(self, owner, if (when == .closing) .calls else .data);
        }
    };
}

pub fn Owned(comptime Record: type) type {
    return struct {
        const Self = @This();

        const Entry = struct {
            record: *Record,
            stopped: bool = false,
            tag: u32 = 0,
        };

        lock: sync.RwLock = .{},
        entries: std.ArrayList(Entry) = .empty,
        watch: Owner.Watch(*Self, .{ .closing = closing, .released = released }) = .{},
        listed: Atomic(bool) = .init(false),

        const allocator = core.heap.main;

        pub fn lease(self: *Self, owner: *Owner) ?Owner.Lease {
            return self.watch.lease(self, owner, .calls);
        }

        /// The caller still owns `record` on error.
        pub fn add(self: *Self, record: *Record) !void {
            const held = self.lease(&record.loaded.owner) orelse return error.OwnerClosed;
            defer held.end();
            try self.addLeased(record);
        }

        pub fn addLeased(self: *Self, record: *Record) !void {
            self.list();
            self.lock.lock();
            defer self.lock.unlock();
            try self.entries.append(allocator, .{ .record = record, .tag = record.loaded.making.load(.monotonic) });
        }

        fn list(self: *Self) void {
            if (self.listed.load(.acquire)) return;
            lists_lock.lock();
            defer lists_lock.unlock();
            if (self.listed.load(.acquire)) return;
            if (lists_len == lists.len) @panic("wraith: too many Owned lists");
            lists[lists_len] = .{ .ctx = self, .stop = stopTag };
            lists_len += 1;
            self.listed.store(true, .release);
        }

        fn stopTag(ctx: *anyopaque, owner: *const Owner, tag: u32) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            while (self.nextTagged(owner, tag)) |record| record.stop();
        }

        fn nextTagged(self: *Self, owner: *const Owner, tag: u32) ?*Record {
            self.lock.lock();
            defer self.lock.unlock();
            for (self.entries.items) |*e| {
                if (&e.record.loaded.owner != owner or e.tag != tag or e.stopped) continue;
                e.stopped = true;
                return e.record;
            }
            return null;
        }

        pub fn first(self: *Self, owner: *const Owner) ?*Record {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            for (self.entries.items) |e| {
                if (&e.record.loaded.owner == owner) return e.record;
            }
            return null;
        }

        pub fn findWhere(self: *Self, owner: *const Owner, key: anytype, comptime match: fn (*Record, @TypeOf(key)) bool) ?*Record {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            for (self.entries.items) |e| {
                if (&e.record.loaded.owner == owner and match(e.record, key)) return e.record;
            }
            return null;
        }

        /// Whoever owns it.
        pub fn findAny(self: *Self, key: anytype, comptime match: fn (*Record, @TypeOf(key)) bool) ?*Record {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            for (self.entries.items) |e| {
                if (match(e.record, key)) return e.record;
            }
            return null;
        }

        /// Calls `call` on the first live match, its owner kept from closing meanwhile. False if none.
        pub fn callAny(self: *Self, key: anytype, comptime match: fn (*Record, @TypeOf(key)) bool, comptime call: fn (*Record) void) bool {
            const record, const held = blk: {
                self.lock.lockShared();
                defer self.lock.unlockShared();
                for (self.entries.items) |e| {
                    if (e.stopped or !match(e.record, key)) continue;
                    if (@hasDecl(Record, "going") and !e.record.going()) continue;
                    const l = self.lease(&e.record.loaded.owner) orelse return false;
                    break :blk .{ e.record, l };
                }
                return false;
            };
            defer held.end();
            call(record);
            return true;
        }

        /// What `owner` has that's still going. A record with `going` says whether it is.
        pub fn count(self: *Self, owner: *const Owner) u32 {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            var n: u32 = 0;
            for (self.entries.items) |e| {
                if (&e.record.loaded.owner != owner or e.stopped) continue;
                if (@hasDecl(Record, "going") and !e.record.going()) continue;
                n += 1;
            }
            return n;
        }

        fn closing(self: *Self, owner: *Owner) void {
            // Unlocked, since stopping waits for a call in flight which may call back in
            while (self.next(owner, .stop)) |record| record.stop();
        }

        fn released(self: *Self, owner: *Owner) void {
            while (self.next(owner, .free)) |record| record.free();
        }

        fn next(self: *Self, owner: *const Owner, comptime what: enum { stop, free }) ?*Record {
            self.lock.lock();
            defer self.lock.unlock();
            for (self.entries.items, 0..) |*e, i| {
                if (&e.record.loaded.owner != owner) continue;
                switch (what) {
                    .stop => if (!e.stopped) {
                        e.stopped = true;
                        return e.record;
                    },
                    .free => {
                        const record = e.record;
                        _ = self.entries.swapRemove(i);
                        // Back to the heap once the last goes, so nothing's left at shutdown
                        if (self.entries.items.len == 0) self.entries.clearAndFree(allocator);
                        return record;
                    },
                }
            }
            return null;
        }
    };
}
