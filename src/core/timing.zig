//! Scoped timings on the OS's high-res monotonic clock.

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

/// Laid out like C, since plugins list theirs and the runtime reads them. Change `version` when the
/// fields change, so a plugin built against another layout isn't read.
pub const Zone = extern struct {
    pub const Snapshot = Stats;
    pub const version: u32 = 1;

    name_ptr: [*]const u8,
    name_len: usize,
    /// Null means the runtime. Set it before adding.
    owner: ?*const Owner = null,
    calls: u64 = 0,
    total_ns: u64 = 0,
    max_ns: u64 = 0,
    last_ns: u64 = 0,
    next: ?*Zone = null,

    pub fn init(text: []const u8) Zone {
        return .{ .name_ptr = text.ptr, .name_len = text.len };
    }

    pub fn name(self: *const Zone) []const u8 {
        return self.name_ptr[0..self.name_len];
    }

    pub fn begin(self: *Zone) Scope {
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
        inline for (.{ "calls", "total_ns", "max_ns", "last_ns" }) |field| atomic.store(u64, &@field(self, field), 0, .monotonic);
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

    pub fn end(self: Scope) void {
        self.zone.record(now() -| self.start);
    }
};

pub const Stats = struct {
    id: usize,
    calls: u64,
    total_ns: u64,
    max_ns: u64,
    last_ns: u64,
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
        var s: Stats = .{ .id = @intFromPtr(zone), .calls = f.calls, .total_ns = f.total_ns, .max_ns = f.max_ns, .last_ns = f.last_ns };
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
};

test {
    _ = tests;
}
