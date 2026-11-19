//! Diagnostics service. Lists plugin timing zones and heaps under the plugin's owner.

const std = @import("std");

const core = @import("wraith_core");
const Owner = @import("tuft_event").Owner;

const Loaded = @import("../PluginLoader.zig").Loaded;

const log = core.log.scoped(.wraith_runtime);

/// Ignored once `plugin` is released.
pub fn addZone(loaded: *Loaded, zone: *core.timing.Zone) void {
    const lease = keeping(loaded) orelse return;
    defer lease.end();
    core.timing.registry.addShared(zone, &loaded.owner) catch log.warn("No memory to list a zone for {s}", .{loaded.name});
}

pub fn removeZone(zone: usize) void {
    core.timing.registry.removeShared(@ptrFromInt(zone));
}

pub fn addHeap(loaded: *Loaded, heap: *core.heap.Usage) void {
    const lease = keeping(loaded) orelse return;
    defer lease.end();
    core.heap.registry.addShared(heap, &loaded.owner) catch log.warn("No memory to list a heap for {s}", .{loaded.name});
}

pub fn removeHeap(heap: usize) void {
    core.heap.registry.removeShared(@ptrFromInt(heap));
}

fn keeping(loaded: *Loaded) ?Owner.Lease {
    return watch.lease(&listener, &loaded.owner, .data);
}

var watch: Owner.Watch(*u8, .{ .released = released }) = .{};
var listener: u8 = 0;

fn released(_: *u8, owner: *Owner) void {
    core.timing.registry.removeOwner(owner);
    core.heap.registry.removeOwner(owner);
}

const tests = struct {
    const testing = std.testing;
    const sdk = @import("wraith_sdk");

    fn listed(name: []const u8, owner: *const Owner) bool {
        var out: [256]core.timing.Stats = undefined;
        const n = core.timing.registry.snapshot(&out);
        for (out[0..n]) |s| {
            if (std.mem.eql(u8, s.name(), name) and s.owner == owner) return true;
        }
        return false;
    }

    test "zones listed until release" {
        var loaded: Loaded = undefined;
        loaded.initForTest(testing.allocator, "kai");
        sdk.Owner.attach(loaded.root());
        defer sdk.Owner.detach();

        {
            const t = sdk.timing.scope("sdk timing test");
            defer t.end();
        }
        try testing.expect(listed("sdk timing test", &loaded.owner));

        // Closed and stopping, so it can't list more, but what it listed stays till it's released
        loaded.owner.close();
        var late: sdk.timing.Zone = .init("late zone");
        sdk.timing.list(&late);
        try testing.expect(!listed("late zone", &loaded.owner));
        try testing.expect(listed("sdk timing test", &loaded.owner));

        loaded.owner.release();
        try testing.expect(!listed("sdk timing test", &loaded.owner));
    }
};

test {
    _ = tests;
}
