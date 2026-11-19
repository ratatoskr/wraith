//! Heap stats for the Memory window.

const std = @import("std");

const atomic = @import("tuft_arch").atomic;
const Owner = @import("tuft_event").Owner;
const Message = @import("tuft_text").Message;
const timing = @import("timing.zig");

pub const Op = enum { alloc, resize, remap, free };

/// Laid out like C, like `timing.Zone`, with its own `version`.
pub const Usage = extern struct {
    pub const Snapshot = Stats;
    pub const version: u32 = 1;

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
    next: ?*Usage = null,

    pub fn init(text: []const u8) Usage {
        return .{ .name_ptr = text.ptr, .name_len = text.len };
    }

    pub fn name(self: *const Usage) []const u8 {
        return self.name_ptr[0..self.name_len];
    }

    pub fn time(self: *Usage, op: Op) timing.Scope {
        return self.ops[@backingInt(op)].begin();
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

    pub fn name(self: *const Stats) []const u8 {
        return self.name_text.message();
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
        return s;
    }
};

pub const Registry = @import("registry.zig").Registry(Usage);

/// Each DLL linking wraith_core gets its own.
pub var registry: Registry = .{};

/// Can't move while listed.
pub const TrackedAllocator = struct {
    child: std.mem.Allocator,
    usage: Usage,

    /// `name` must outlive the allocator.
    pub fn init(self: *TrackedAllocator, child: std.mem.Allocator, name: []const u8) void {
        self.* = .{ .child = child, .usage = .init(name) };
    }

    pub fn allocator(self: *TrackedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn timed(ctx: *anyopaque, op: Op) struct { *TrackedAllocator, timing.Scope } {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));
        return .{ self, self.usage.time(op) };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self, const t = timed(ctx, .alloc);
        defer t.end();
        const ptr = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.usage.allocated(len);
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

test {
    _ = tests;
}
