//! Debug register watches for owners. Hits queue up from the exception, then go out at the start of
//! each frame on the render thread.

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const core = @import("wraith_core");
const api = @import("wraith_api");
const disasm = @import("tuft_asm").disasm;
const hook = @import("tuft_hook");
const Memory = @import("tuft_mem").Memory;
const sys = @import("tuft_sys");

const host = @import("root.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;

const watch = hook.watch;
const Inbox = core.Mailbox(watch.Hit, 128);

const Delivery = struct {
    hit: *const watch.Hit,
    info: api.WatchHit,
};

const Bus = core.Event(fn (delivery: *const Delivery) void);

/// How often running watches get put on threads started since.
const refresh_ns = std.time.ns_per_s;

var started_lock: sys.sync.RwLock = .{};
/// `watch` is initialized while it's set.
var started: bool = false;
var hit_sub: watch.Event.Subscription = undefined;
var bus: Bus = .init(std.heap.page_allocator);
var inbox: Inbox = .{};
/// Render thread only, too big for a stack.
var drained: [Inbox.capacity]watch.Hit = undefined;
var live: Atomic(u32) = .init(0);
var last_refresh_ns: u64 = 0;
/// Hits from it are us reading, not the game.
var own: sys.thread.CodeRange = .{ .start = 0, .len = 0 };

/// From `watches.sal`, kept till the watch is removed.
pub const Handler = api.wraith.WatchHandler;
const cpu_regs = @import("cpu.zig");

pub const Record = struct {
    loaded: *Loaded,
    /// Null once it's not ours to release.
    handler: ?Handler,
    watched: watch.Watch,
    slot: watch.Slot,
    subscription: Bus.Subscription = undefined,
    stopped: Atomic(bool) = .init(false),

    fn receive(self: *Record, d: *const Delivery) void {
        if (self.stopped.load(.acquire)) return;
        if (d.hit.slot != self.slot or !std.meta.eql(d.hit.watch, self.watched)) return;
        const f = self.handler orelse return;
        f.invoke(.{ .{ .address = d.info.address, .instruction = d.info.instruction, .ip = d.info.ip, .thread = d.info.thread }, cpu_regs.copy(&d.hit.cpu) });
    }

    pub fn stop(self: *Record) void {
        if (self.stopped.swap(true, .acq_rel)) return;
        self.subscription.unsubscribe();
        watch.remove(self.slot);
        _ = live.fetchSub(1, .acq_rel);
        if (self.handler) |f| f.release();
        self.handler = null;
    }

    pub fn free(self: *Record) void {
        self.stop();
        self.loaded.allocator.destroy(self);
    }
};

var records: host.Owned(Record) = .{};

/// Through `watches.sal`. Released if it fails.
pub fn add(loaded: *Loaded, address: usize, len: u8, kind: api.WatchKind, handler: Handler) api.WatchError!*Record {
    return watchWith(loaded, address, len, kind, handler) catch |err| {
        handler.release();
        return err;
    };
}

fn watchWith(loaded: *Loaded, address: usize, len: u8, kind: api.WatchKind, handler: Handler) api.WatchError!*Record {
    try start();
    const w: watch.Watch = .{ .address = address, .len = len, .on = switch (kind) {
        .write => .write,
        .access => .access,
        .execute => .execute,
    } };
    const record = try loaded.allocator.create(Record);
    record.* = .{ .loaded = loaded, .handler = handler, .watched = w, .slot = undefined };
    record.subscription = bus.subscribeUnscoped(record, Record.receive) catch {
        loaded.allocator.destroy(record);
        return error.OutOfMemory;
    };
    record.slot = watch.add(w) catch |err| {
        record.subscription.unsubscribe();
        loaded.allocator.destroy(record);
        return switch (err) {
            error.NoFreeSlot => error.NoFreeSlot,
            error.Misaligned => error.Misaligned,
            error.InvalidLength => error.InvalidLength,
            error.NotInitialized => error.WatchesUnavailable,
            else => error.WatchFailed,
        };
    };
    _ = live.fetchAdd(1, .acq_rel);
    records.add(record) catch |err| {
        // The handler's still the caller's
        record.handler = null;
        record.free();
        return if (err == error.OutOfMemory) error.OutOfMemory else error.OwnerGone;
    };
    return record;
}

fn start() api.WatchError!void {
    started_lock.lock();
    defer started_lock.unlock();
    if (started) return;
    watch.init(std.heap.page_allocator) catch return error.WatchesUnavailable;
    hit_sub = watch.subscribeUnscoped(&inbox, onHit) catch {
        watch.deinit();
        return error.OutOfMemory;
    };
    const base = sys.module.selfBase();
    own = .{ .start = base, .len = sys.module.imageSize(base) catch 0 };
    started = true;
}

/// Hits from Wraith's own code count too, for tests, where that's what's watched. After a watch's
/// been added.
pub fn hearOwnCode() void {
    own = .{ .start = 0, .len = 0 };
}

/// Once every owner's gone, like when the game closes.
pub fn shutdown() void {
    started_lock.lock();
    defer started_lock.unlock();
    if (!started) return;
    hit_sub.unsubscribe();
    watch.deinit();
    _ = inbox.drain(&drained);
    started = false;
}

/// On whichever game thread hit, inside the exception. Just queue it.
fn onHit(box: *Inbox, hit: *const watch.Hit) void {
    box.pushCoalesced(hit.*, sameSpot) catch {};
}

/// The same instruction hitting again on the same thread before anyone looked.
fn sameSpot(newer: watch.Hit, older: watch.Hit) bool {
    return newer.slot == older.slot and newer.thread_id == older.thread_id and newer.cpu.ip() == older.cpu.ip();
}

/// Render thread, each frame.
pub fn deliver() void {
    if (live.load(.acquire) == 0) {
        _ = inbox.drain(&drained);
        return;
    }
    for (inbox.drain(&drained)) |*hit| {
        const ip = hit.cpu.ip();
        if (own.contains(ip)) continue;
        const at = if (hit.watch.on == .execute) ip else if (instructionBefore(ip)) |insn| ip - insn.len else ip;
        const d: Delivery = .{ .hit = hit, .info = .{ .address = hit.watch.address, .instruction = at, .ip = ip, .thread = hit.thread_id } };
        bus.fire(.{&d});
    }
    const now = core.timing.now();
    if (now -% last_refresh_ns < refresh_ns) return;
    last_refresh_ns = now;
    watch.refresh();
}

/// Reads less if the page before isn't there.
fn instructionBefore(ip: usize) ?disasm.Instruction {
    var buf: [64]u8 = undefined;
    for ([_]usize{ 64, 32, 16 }) |len| {
        const code = buf[0..len];
        Memory.local.read(ip -% len, code) catch continue;
        return disasm.before(code, ip);
    }
    return null;
}

const tests = struct {
    const testing = std.testing;
    const sdk = @import("wraith_sdk");

    var value: u32 align(8) = 0;

    noinline fn poke(to: *volatile u32, v: u32) void {
        to.* = v;
    }

    test "through watches.sal, with the registers" {
        defer shutdown();
        var loaded: Loaded = undefined;
        loaded.initForTest(testing.allocator, "test");
        sdk.Owner.attach(loaded.root());
        defer sdk.Owner.detach();

        const Typed = struct {
            hits: u32 = 0,
            ip: usize = 0,
            address: usize = 0,

            fn on(self: *@This(), hit: api.wraith.WatchHit, regs: cpu_regs.Cpu) void {
                self.hits += 1;
                self.ip = cpu_regs.ip(&regs);
                self.address = hit.address;
            }
        };
        var seen: Typed = .{};
        const list = sdk.wraith.root().?.watches();
        const w = try list.add(@intFromPtr(&value), 4, .write, Handler.init(&seen, Typed.on));
        try testing.expectError(error.Misaligned, list.add(@intFromPtr(&value) + 1, 4, .write, Handler.init(&seen, Typed.on)));
        own = .{ .start = 0, .len = 0 };
        poke(&value, 1);
        deliver();
        try testing.expectEqual(1, seen.hits);
        try testing.expectEqual(@intFromPtr(&value), seen.address);
        try testing.expect(seen.ip != 0);

        w.remove();
        poke(&value, 2);
        deliver();
        try testing.expectEqual(1, seen.hits);

        // And ones still on stop with the owner
        _ = try list.add(@intFromPtr(&value), 4, .write, Handler.init(&seen, Typed.on));
        loaded.deinitForTest();
        poke(&value, 3);
        deliver();
        try testing.expectEqual(1, seen.hits);
        try testing.expectEqual(0, live.load(.acquire));
        host.wraith.forget(&loaded);
    }
};

test {
    _ = tests;
}
