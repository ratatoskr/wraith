//! Heap stats for the Memory window: named heaps, and which timing zone each allocation came from.

const std = @import("std");
const builtin = @import("builtin");

const atomic = @import("tuft_arch").atomic;
const Owner = @import("tuft_event").Owner;
const Message = @import("tuft_text").Message;
const Atomic = @import("tuft_arch").atomic.Value;
const sync = @import("tuft_sys").sync;
const timing = @import("timing.zig");

pub const Op = enum { alloc, resize, remap, free };

/// Laid out like C, like `timing.Zone`, with its own `version`.
pub const Usage = extern struct {
    pub const Snapshot = Stats;
    pub const version: u32 = 2;

    name_ptr: [*]const u8,
    name_len: usize,
    /// Null means the runtime. Set it before adding.
    owner: ?*const Owner = null,
    live_bytes: u64 = 0,
    peak_bytes: u64 = 0,
    live_allocs: u64 = 0,
    allocs: u64 = 0,
    frees: u64 = 0,
    /// Indexed by `Op`.
    ops: [4]timing.Zone = .{ .init("alloc"), .init("resize"), .init("remap"), .init("free") },
    /// The heap it takes from, if that's tracked too, so its bytes are counted there as well
    within: ?*const Usage = null,
    next: ?*Usage = null,

    pub fn init(text: []const u8) Usage {
        return .{ .name_ptr = text.ptr, .name_len = text.len };
    }

    pub fn name(self: *const Usage) []const u8 {
        return self.name_ptr[0..self.name_len];
    }

    pub fn time(self: *Usage, op: Op) timing.Measure {
        return self.ops[@backingInt(op)].measure();
    }

    pub fn allocated(self: *Usage, len: usize) void {
        _ = atomic.rmw(u64, &self.allocs, .Add, 1, .monotonic);
        _ = atomic.rmw(u64, &self.live_allocs, .Add, 1, .monotonic);
        self.grew(len);
    }

    pub fn freed(self: *Usage, len: usize) void {
        _ = atomic.rmw(u64, &self.frees, .Add, 1, .monotonic);
        _ = atomic.rmw(u64, &self.live_allocs, .Sub, 1, .monotonic);
        self.shrank(len);
    }

    pub fn resized(self: *Usage, old: usize, new: usize) void {
        if (new > old) self.grew(new - old) else self.shrank(old - new);
    }

    fn grew(self: *Usage, n: usize) void {
        const live = atomic.rmw(u64, &self.live_bytes, .Add, n, .monotonic) + n;
        _ = atomic.rmw(u64, &self.peak_bytes, .Max, live, .monotonic);
    }

    fn shrank(self: *Usage, n: usize) void {
        _ = atomic.rmw(u64, &self.live_bytes, .Sub, n, .monotonic);
    }

    /// For sources that keep their own counts, like tuft's mapped pages.
    pub fn mirror(self: *Usage, live_bytes: u64, allocs: u64, frees: u64) void {
        atomic.store(u64, &self.live_bytes, live_bytes, .monotonic);
        _ = atomic.rmw(u64, &self.peak_bytes, .Max, live_bytes, .monotonic);
        atomic.store(u64, &self.allocs, allocs, .monotonic);
        atomic.store(u64, &self.frees, frees, .monotonic);
        atomic.store(u64, &self.live_allocs, allocs -| frees, .monotonic);
    }
};

/// Names are copied since the heap might go away.
pub const Stats = struct {
    id: usize,
    live_bytes: u64,
    peak_bytes: u64,
    live_allocs: u64,
    allocs: u64,
    frees: u64,
    /// Indexed by `Op`.
    ops: [4]timing.Figures,
    name_text: Message(32) = .{},
    /// Only compare it, don't follow it, it might be gone.
    owner: ?*const Owner = null,
    owner_text: Message(32) = .{},
    /// What it's inside, empty for none. Its bytes are in that one's too
    within_text: Message(32) = .{},

    pub fn name(self: *const Stats) []const u8 {
        return self.name_text.message();
    }

    pub fn within(self: *const Stats) []const u8 {
        return self.within_text.message();
    }

    pub fn ownerName(self: *const Stats) []const u8 {
        return self.owner_text.message();
    }

    pub fn of(usage: *const Usage, owner: ?*const Owner) Stats {
        var s: Stats = .{
            .id = @intFromPtr(usage),
            .live_bytes = atomic.load(u64, &usage.live_bytes, .monotonic),
            .peak_bytes = atomic.load(u64, &usage.peak_bytes, .monotonic),
            .live_allocs = atomic.load(u64, &usage.live_allocs, .monotonic),
            .allocs = atomic.load(u64, &usage.allocs, .monotonic),
            .frees = atomic.load(u64, &usage.frees, .monotonic),
            .ops = @splat(.{}),
        };
        for (&s.ops, &usage.ops) |*f, *zone| f.* = zone.figures();
        s.name_text.set(usage.name());
        // Owners unlist their nodes when released, so this owner is still alive
        s.owner = owner;
        s.owner_text.set(if (s.owner) |o| o.name else "");
        // Lives as long as the runtime, like every heap that's inside it
        s.within_text.set(if (usage.within) |w| w.name() else "");
        return s;
    }
};

pub const Registry = @import("registry.zig").Registry(Usage);

/// Each DLL linking wraith_core gets its own.
pub var registry: Registry = .{};

/// The runtime's main heap, from anywhere, so a module's constant can be it. Set once at startup;
/// till then, and in tests, it's `smp_allocator`.
pub const main: std.mem.Allocator = .{ .ptr = @ptrCast(&main_heap), .vtable = &main_vtable };

var main_heap: struct { child: ?std.mem.Allocator = null, usage: ?*const Usage = null } = .{};

/// Before anything's allocated on `main`, since what was must be freed by what made it.
pub fn setMain(tracked: *TrackedAllocator) void {
    main_heap = .{ .child = tracked.allocator(), .usage = &tracked.usage };
}

fn mainChild() std.mem.Allocator {
    return main_heap.child orelse std.heap.smp_allocator;
}

const main_vtable: std.mem.Allocator.VTable = .{
    .alloc = struct {
        fn f(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            return mainChild().rawAlloc(len, alignment, ret_addr);
        }
    }.f,
    .resize = struct {
        fn f(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            return mainChild().rawResize(memory, alignment, new_len, ret_addr);
        }
    }.f,
    .remap = struct {
        fn f(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            return mainChild().rawRemap(memory, alignment, new_len, ret_addr);
        }
    }.f,
    .free = struct {
        fn f(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            mainChild().rawFree(memory, alignment, ret_addr);
        }
    }.f,
};

/// `child`, counted in the Memory window under `name` from the first time it's used. Like
/// `timing.scope`, so it's fine as a module's constant. Over `main`, it's shown inside it.
pub fn named(comptime name: []const u8, comptime child: std.mem.Allocator) std.mem.Allocator {
    const Static = struct {
        var tracked: TrackedAllocator = .{ .child = child, .usage = .init(name), .listed = .init(0), .inside_main = child.vtable == &main_vtable };
    };
    return Static.tracked.allocator();
}

/// Can't move while listed.
pub const TrackedAllocator = struct {
    child: std.mem.Allocator,
    usage: Usage,
    /// For `named` ones, which list themselves: 0 not yet, 1 listing, 2 listed. Null for ones added by hand
    listed: ?Atomic(u8) = null,
    /// Taking from `main`, whose heap counts these against zones already
    inside_main: bool = false,

    /// `name` must outlive the allocator.
    pub fn init(self: *TrackedAllocator, child: std.mem.Allocator, name: []const u8) void {
        self.* = .{ .child = child, .usage = .init(name) };
    }

    fn listOnce(self: *TrackedAllocator) void {
        const l = &(self.listed orelse return);
        if (l.load(.acquire) == 2) return;
        if (l.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return;
        if (self.inside_main) self.usage.within = main_heap.usage;
        registry.add(&self.usage);
        l.store(2, .release);
    }

    pub fn allocator(self: *TrackedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn timed(ctx: *anyopaque, op: Op) struct { *TrackedAllocator, timing.Measure } {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));
        return .{ self, self.usage.time(op) };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self, const t = timed(ctx, .alloc);
        defer t.end();
        const ptr = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.listOnce();
        self.usage.allocated(len);
        if (!self.inside_main) attribute(len);
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self, const t = timed(ctx, .resize);
        defer t.end();
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.usage.resized(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self, const t = timed(ctx, .remap);
        defer t.end();
        const ptr = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.usage.resized(memory.len, new_len);
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self, const t = timed(ctx, .free);
        defer t.end();
        self.child.rawFree(memory, alignment, ret_addr);
        self.usage.freed(memory.len);
    }
};

// Which zone allocations came from

/// Allocations made outside every zone, so the zones' add up to the heaps'.
pub const unscoped = struct {
    pub var allocs: u64 = 0;
    pub var bytes: u64 = 0;
};

/// What's been made outside every zone so far.
pub fn unscopedCounts() struct { allocs: u64, bytes: u64 } {
    return .{ .allocs = atomic.load(u64, &unscoped.allocs, .monotonic), .bytes = atomic.load(u64, &unscoped.bytes, .monotonic) };
}

/// An allocation on a tracked heap, counted against this thread's innermost zone.
fn attribute(len: usize) void {
    if (tracing.load(.monotonic) and traced.load(.monotonic) == @intFromPtr(timing.innermost())) traceHere();
    if (timing.innermost()) |z| {
        _ = atomic.rmw(u64, &z.allocs, .Add, 1, .monotonic);
        _ = atomic.rmw(u64, &z.alloc_bytes, .Add, len, .monotonic);
        return;
    }
    _ = atomic.rmw(u64, &unscoped.allocs, .Add, 1, .monotonic);
    _ = atomic.rmw(u64, &unscoped.bytes, .Add, len, .monotonic);
}

/// Where a zone's allocations come from, or those outside every zone, by call stack.
pub const Trace = struct {
    pub const depth = 16;
    frames: [depth]usize = @splat(0),
    len: u8 = 0,
    count: u64 = 0,

    pub fn addresses(t: *const Trace) []const usize {
        return t.frames[0..t.len];
    }
};

/// Off till asked, since walking the stack is slow.
pub var tracing: Atomic(bool) = .init(false);
/// The zone traced, by address, only ever compared. 0 for outside every zone
var traced: Atomic(usize) = .init(0);

/// Traces `zone`'s allocations from now on, or those outside every zone for null, starting afresh.
pub fn traceZone(zone: ?*const timing.Zone) void {
    traced.store(@intFromPtr(zone), .monotonic);
    clearTraces();
}

/// What `traceZone` was given, by address. 0 for outside every zone.
pub fn tracedZone() usize {
    return traced.load(.monotonic);
}
var kept: [64]Trace = @splat(.{});
var traces_used: usize = 0;
/// Ones seen after every slot was taken
var traces_missed: u64 = 0;
var traces_lock: sync.Mutex = .{};

/// Walks the loaded unwind tables only, so it's cheap on stack and reads no files, since game threads have little stack.
extern "kernel32" fn RtlCaptureStackBackTrace(skip: u32, count: u32, frames: [*]?*anyopaque, hash: ?*u32) callconv(.winapi) u16;

noinline fn traceHere() void {
    var raw: [Trace.depth]?*anyopaque = undefined;
    const n: usize = if (comptime builtin.os.tag == .windows) RtlCaptureStackBackTrace(1, Trace.depth, &raw, null) else 0;
    var buf: [Trace.depth]usize = undefined;
    for (raw[0..n], buf[0..n]) |r, *b| b.* = @intFromPtr(r);
    const got = buf[0..n];
    traces_lock.lock();
    defer traces_lock.unlock();
    for (kept[0..traces_used]) |*t| {
        if (std.mem.eql(usize, t.addresses(), got)) {
            t.count += 1;
            return;
        }
    }
    if (traces_used == kept.len) {
        traces_missed += 1;
        return;
    }
    const t = &kept[traces_used];
    traces_used += 1;
    t.* = .{ .len = @intCast(got.len), .count = 1 };
    @memcpy(t.frames[0..got.len], got);
}

/// The traces so far, most first, and how many didn't fit.
pub fn traces(out: []Trace) struct { len: usize, missed: u64 } {
    traces_lock.lock();
    const n = @min(out.len, traces_used);
    @memcpy(out[0..n], kept[0..n]);
    const missed = traces_missed;
    traces_lock.unlock();
    // Insertion, since block sort keeps hundreds of these on the stack
    std.sort.insertion(Trace, out[0..n], {}, struct {
        fn more(_: void, a: Trace, b: Trace) bool {
            return a.count > b.count;
        }
    }.more);
    return .{ .len = n, .missed = missed };
}

pub fn clearTraces() void {
    traces_lock.lock();
    defer traces_lock.unlock();
    traces_used = 0;
    traces_missed = 0;
}

const tests = struct {
    test "TrackedAllocator stats" {
        var heaps: Registry = .{};
        var tracked: TrackedAllocator = undefined;
        tracked.init(std.testing.allocator, "heap");
        heaps.add(&tracked.usage);
        const a = tracked.allocator();

        const small = try a.alloc(u8, 16);
        var big = try a.alloc(u8, 100);
        try std.testing.expectEqual(116, tracked.usage.live_bytes);
        try std.testing.expectEqual(2, tracked.usage.live_allocs);
        big = try a.realloc(big, 400);
        try std.testing.expectEqual(416, tracked.usage.live_bytes);
        a.free(big);
        a.free(small);
        try std.testing.expectEqual(0, tracked.usage.live_bytes);
        try std.testing.expectEqual(0, tracked.usage.live_allocs);
        try std.testing.expectEqual(416, tracked.usage.peak_bytes);
        try std.testing.expect(tracked.usage.allocs >= 2);
        try std.testing.expectEqual(tracked.usage.allocs, tracked.usage.frees);
        var out: [4]Stats = undefined;
        try std.testing.expectEqual(1, heaps.snapshot(&out));
        try std.testing.expectEqualStrings("heap", out[0].name());
        try std.testing.expectEqual(2, out[0].ops[@backingInt(Op.free)].calls);
        try std.testing.expectEqual(tracked.usage.allocs, out[0].ops[@backingInt(Op.alloc)].calls);

        heaps.remove(&tracked.usage);
        try std.testing.expectEqual(0, heaps.snapshot(&out));
    }
};

const attribution_tests = struct {
    const testing = std.testing;

    test "allocations count against the innermost zone, and outside every zone after it ends" {
        var outer: timing.Zone = .init("outer");
        var inner: timing.Zone = .init("inner");
        const before = unscoped.allocs;
        attribute(8);
        {
            const o = outer.begin();
            defer o.end();
            attribute(16);
            {
                const i = inner.begin();
                defer i.end();
                attribute(32);
            }
        }
        try testing.expectEqual(before + 1, unscoped.allocs);
        try testing.expectEqual(1, outer.allocs);
        try testing.expectEqual(16, outer.alloc_bytes);
        try testing.expectEqual(1, inner.allocs);
        try testing.expectEqual(32, inner.alloc_bytes);
    }

    noinline fn allocateHere() void {
        attribute(1);
    }

    test "allocations outside every zone are traced by stack while asked" {
        clearTraces();
        defer clearTraces();
        attribute(1);
        var out: [64]Trace = undefined;
        try testing.expectEqual(0, traces(&out).len);
        tracing.store(true, .monotonic);
        defer tracing.store(false, .monotonic);
        // The same place twice is one trace. One call site run twice, since an unrolled loop is two places
        var times: usize = 2;
        std.mem.doNotOptimizeAway(&times);
        for (0..times) |_| allocateHere();
        try testing.expect(traces(&out).len >= 1);
        try testing.expectEqual(2, out[0].count);
        var z: timing.Zone = .init("z");
        const t = z.begin();
        attribute(1);
        t.end();
        _ = traces(&out);
        try testing.expectEqual(2, out[0].count);
        // A zone's own, once it's the one traced
        traceZone(&z);
        defer traceZone(null);
        const t2 = z.begin();
        attribute(1);
        t2.end();
        attribute(1);
        try testing.expectEqual(1, traces(&out).len);
        try testing.expectEqual(1, out[0].count);
    }

    test "a heap over main takes from it, and counts against zones only once" {
        var base: TrackedAllocator = undefined;
        base.init(testing.allocator, "base");
        const saved = main_heap;
        setMain(&base);
        defer main_heap = saved;
        var tracked_pool: TrackedAllocator = .{ .child = main, .usage = .init("pool test"), .listed = .init(0), .inside_main = true };
        defer registry.remove(&tracked_pool.usage);
        const pool = tracked_pool.allocator();
        var z: timing.Zone = .init("z");
        const t = z.begin();
        const bytes = try pool.alloc(u8, 24);
        t.end();
        try testing.expectEqual(1, base.usage.allocs);
        try testing.expectEqual(1, z.allocs);
        pool.free(bytes);
        try testing.expectEqual(0, base.usage.live_bytes);
        var out: [64]Stats = undefined;
        for (out[0..registry.snapshot(&out)]) |st| {
            if (std.mem.eql(u8, st.name(), "pool test")) try testing.expectEqualStrings("base", st.within());
        }
    }

    test "a named heap lists itself once it's used, and keeps its name" {
        const a = named("heap test", std.testing.allocator);
        var out: [64]Stats = undefined;
        var found = false;
        for (out[0..registry.snapshot(&out)]) |st| found = found or std.mem.eql(u8, st.name(), "heap test");
        try testing.expect(!found);
        const bytes = try a.alloc(u8, 10);
        a.free(bytes);
        for (out[0..registry.snapshot(&out)]) |st| {
            if (!std.mem.eql(u8, st.name(), "heap test")) continue;
            found = true;
            try testing.expectEqual(1, st.allocs);
            try testing.expectEqual(1, st.frees);
        }
        try testing.expect(found);
    }
};

test {
    _ = attribution_tests;
    _ = tests;
}
