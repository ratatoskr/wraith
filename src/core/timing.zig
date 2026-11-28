//! Scoped timings on the OS's high-res monotonic clock. A zone's scope is its thread's current one
//! till it ends, so `heap` can count allocations against it.

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;
const atomic = @import("tuft_arch").atomic;
const clock = @import("tuft_sys").clock;
const Owner = @import("tuft_event").Owner;
const Message = @import("tuft_text").Message;

/// Same clock for every thread and module in the process.
pub fn now() u64 {
    return clock.nanos();
}

/// C layout, read across the plugin boundary. Bump `version` when the fields change.
pub const Zone = extern struct {
    pub const Snapshot = Stats;
    pub const version: u32 = 2;

    name_ptr: [*]const u8,
    name_len: usize,
    /// Null means the runtime. Set it before adding.
    owner: ?*const Owner = null,
    calls: u64 = 0,
    total_ns: u64 = 0,
    max_ns: u64 = 0,
    last_ns: u64 = 0,
    /// Kept by `heap`: allocations on tracked heaps while it was its thread's innermost, and their bytes
    allocs: u64 = 0,
    alloc_bytes: u64 = 0,
    next: ?*Zone = null,

    pub fn init(text: []const u8) Zone {
        return .{ .name_ptr = text.ptr, .name_len = text.len };
    }

    pub fn name(self: *const Zone) []const u8 {
        return self.name_ptr[0..self.name_len];
    }

    /// Timed, and its thread's current zone till it ends.
    pub fn begin(self: *Zone) Scope {
        const parent = current;
        current = self;
        return .{ .zone = self, .start = now(), .parent = parent };
    }

    /// Timed only, for what mustn't take allocations as its own, like a heap's calls.
    pub fn measure(self: *Zone) Measure {
        return .{ .zone = self, .start = now() };
    }

    pub fn record(self: *Zone, ns: u64) void {
        _ = atomic.rmw(u64, &self.calls, .Add, 1, .monotonic);
        _ = atomic.rmw(u64, &self.total_ns, .Add, ns, .monotonic);
        atomic.store(u64, &self.last_ns, ns, .monotonic);
        _ = atomic.rmw(u64, &self.max_ns, .Max, ns, .monotonic);
    }

    pub fn figures(self: *const Zone) Figures {
        return .{
            .calls = atomic.load(u64, &self.calls, .monotonic),
            .total_ns = atomic.load(u64, &self.total_ns, .monotonic),
            .max_ns = atomic.load(u64, &self.max_ns, .monotonic),
            .last_ns = atomic.load(u64, &self.last_ns, .monotonic),
        };
    }

    pub fn reset(self: *Zone) void {
        inline for (.{ "calls", "total_ns", "max_ns", "last_ns", "allocs", "alloc_bytes" }) |field| atomic.store(u64, &@field(self, field), 0, .monotonic);
    }
};

pub const Figures = struct {
    calls: u64 = 0,
    total_ns: u64 = 0,
    max_ns: u64 = 0,
    last_ns: u64 = 0,
};

pub const Scope = struct {
    zone: *Zone,
    start: u64,
    parent: ?*Zone,

    pub fn end(self: Scope) void {
        self.zone.record(now() -| self.start);
        current = self.parent;
    }
};

pub const Measure = struct {
    zone: *Zone,
    start: u64,

    pub fn end(self: Measure) void {
        self.zone.record(now() -| self.start);
    }
};

/// This thread's innermost zone, while one's scope is open.
threadlocal var current: ?*Zone = null;

/// What this thread's allocations count against, if anything.
pub fn innermost() ?*Zone {
    return current;
}

pub const Stats = struct {
    id: usize,
    calls: u64,
    total_ns: u64,
    max_ns: u64,
    last_ns: u64,
    allocs: u64,
    alloc_bytes: u64,
    name_text: Message(48) = .{},
    /// Only compare it, don't follow it, it might be gone.
    owner: ?*const Owner = null,
    owner_text: Message(32) = .{},

    pub fn name(self: *const Stats) []const u8 {
        return self.name_text.message();
    }

    pub fn ownerName(self: *const Stats) []const u8 {
        return self.owner_text.message();
    }

    pub fn of(zone: *const Zone, owner: ?*const Owner) Stats {
        const f = zone.figures();
        var s: Stats = .{ .id = @intFromPtr(zone), .calls = f.calls, .total_ns = f.total_ns, .max_ns = f.max_ns, .last_ns = f.last_ns, .allocs = atomic.load(u64, &zone.allocs, .monotonic), .alloc_bytes = atomic.load(u64, &zone.alloc_bytes, .monotonic) };
        s.name_text.set(zone.name());
        // Owners unlist their nodes when released, so this owner is still alive
        s.owner = owner;
        s.owner_text.set(if (s.owner) |o| o.name else "");
        return s;
    }
};

/// Adding and removing take a lock. Recording never does.
pub const Registry = @import("registry.zig").Registry(Zone);

/// Each DLL linking wraith_core gets its own.
pub var registry: Registry = .{};

pub fn scope(comptime name: []const u8) Scope {
    const Static = struct {
        var zone: Zone = .init(name);
        var listed: Atomic(u8) = .init(0);
    };
    if (Static.listed.load(.acquire) != 2) listOnce(&Static.zone, &Static.listed);
    return Static.zone.begin();
}

fn listOnce(zone: *Zone, listed: *Atomic(u8)) void {
    if (listed.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return;
    registry.add(zone);
    listed.store(2, .release);
}

const tests = struct {
    test "zone accumulates" {
        var zone: Zone = .init("test");
        zone.record(5);
        zone.record(20);
        zone.record(10);
        try std.testing.expectEqual(3, zone.calls);
        try std.testing.expectEqual(35, zone.total_ns);
        try std.testing.expectEqual(20, zone.max_ns);
        try std.testing.expectEqual(10, zone.last_ns);
        zone.reset();
        try std.testing.expectEqual(0, zone.calls);
    }

    test "registry lists zones" {
        var r: Registry = .{};
        var kai: Owner = .init("kai");
        var a: Zone = .init("a");
        var b: Zone = .init("b");
        b.owner = &kai;
        r.add(&a);
        r.add(&b);
        b.record(7);

        var out: [4]Stats = undefined;
        try std.testing.expectEqual(2, r.snapshot(&out));
        try std.testing.expectEqualStrings("b", out[0].name());
        try std.testing.expectEqual(&kai, out[0].owner.?);
        try std.testing.expectEqualStrings("kai", out[0].ownerName());
        try std.testing.expectEqual(7, out[0].total_ns);
        try std.testing.expectEqualStrings("a", out[1].name());
        try std.testing.expectEqualStrings("", out[1].ownerName());

        r.remove(&b);
        r.remove(&b);
        try std.testing.expectEqual(1, r.snapshot(&out));
        try std.testing.expectEqualStrings("a", out[0].name());

        var c: Zone = .init("c");
        var d: Zone = .init("d");
        c.owner = &kai;
        d.owner = &kai;
        r.add(&c);
        r.add(&d);
        // Like a plugin's, listed by view with the owner kept here
        var e: Zone = .init("e");
        e.record(3);
        try r.addShared(&e, &kai);
        try std.testing.expectEqual(4, r.snapshot(&out));
        try std.testing.expectEqualStrings("e", out[0].name());
        try std.testing.expectEqual(&kai, out[0].owner.?);
        try std.testing.expectEqual(3, out[0].total_ns);
        r.removeOwner(&kai);
        try std.testing.expectEqual(1, r.snapshot(&out));
    }

    test "scope timing" {
        const first = now();
        for (0..2) |_| {
            const t = scope("timing test");
            defer t.end();
        }
        try std.testing.expect(now() >= first);

        var out: [64]Stats = undefined;
        const n = registry.snapshot(&out);
        var found: ?Stats = null;
        for (out[0..n]) |s| {
            if (std.mem.eql(u8, s.name(), "timing test")) found = s;
        }
        try std.testing.expectEqual(2, found.?.calls);
    }
    test "a scope is its thread's innermost till it ends, and measuring leaves it alone" {
        var outer: Zone = .init("outer");
        var inner: Zone = .init("inner");
        var call: Zone = .init("heap call");
        try std.testing.expectEqual(null, innermost());
        const o = outer.begin();
        try std.testing.expectEqual(&outer, innermost().?);
        {
            const i = inner.begin();
            defer i.end();
            const m = call.measure();
            try std.testing.expectEqual(&inner, innermost().?);
            m.end();
        }
        try std.testing.expectEqual(&outer, innermost().?);
        o.end();
        try std.testing.expectEqual(null, innermost());
    }
};

test {
    _ = tests;
}
