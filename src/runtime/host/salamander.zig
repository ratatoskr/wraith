//! Salamander's host for wraith. The runtime's binary is the host, so it outlives every plugin.
//! Each tuft owner, a plugin's or later a script's, has a Salamander owner that closes with it, so
//! nothing calls into code that's going. The render thread has a queue it polls each frame.

const std = @import("std");

const sal = @import("salamander_runtime");
const Owner = @import("tuft_event").Owner;
const sync = @import("tuft_sys").sync;

const Loaded = @import("../PluginLoader.zig").Loaded;

var lock: sync.RwLock = .{};
/// Made on first use, and kept for good like everything the host makes.
var render_queue: sal.Queue = .{};
var render_queue_made: bool = false;

pub fn host(_: *Loaded) sal.Host {
    return sal.host();
}

pub fn owner(loaded: *Loaded) ?*sal.Owner {
    return loaded.owner.salamander();
}

pub fn renderQueue(_: *Loaded) sal.Queue {
    return renderQueueOf();
}

pub fn renderQueueOf() sal.Queue {
    lock.lock();
    defer lock.unlock();
    if (!render_queue_made) {
        render_queue = sal.host().queue() catch return .{};
        render_queue_made = true;
    }
    return render_queue;
}

/// Render thread, each frame.
pub fn pollRender() void {
    lock.lockShared();
    const q = if (render_queue_made) render_queue else null;
    lock.unlockShared();
    if (q) |queue| _ = queue.poll();
}

const testing = std.testing;

const Counter = struct {
    pub const salamander = struct {
        pub const name = "Counter";
        pub const hash: u64 = 1;
        pub const methods: []const sal.Method = &.{.{ .name = "next", .Fn = fn () u32 }};
    };
};

const Count = struct {
    n: u32 = 0,

    pub fn next(self: *Count) u32 {
        self.n += 1;
        return self.n;
    }
};

test "a plugin's objects stop when its owner closes, and its name's free again" {
    var o: Owner = .init("plugin");
    const so = o.salamander().?;
    var c: Count = .{};
    const obj = try sal.host().own(sal.Object(Counter).init(&c, sal.implement(Counter, Count)), so);
    try sal.host().provide("wraith.test.counter", 1, obj);
    const held = sal.host().get(Counter, "wraith.test.counter", 1).?;
    try testing.expectEqual(1, held.call(.next, .{}));

    o.close();
    try testing.expect(!so.isOpen());
    try testing.expectEqual(0, held.call(.next, .{}));
    try testing.expectEqual(null, sal.host().get(Counter, "wraith.test.counter", 1));
    o.release();
}

test "the render queue runs what's posted when polled" {
    const q = renderQueueOf();
    var hits: u32 = 0;
    try q.post(&hits, struct {
        fn f(n: *u32) void {
            n.* += 1;
        }
    }.f);
    try testing.expectEqual(0, hits);
    pollRender();
    try testing.expectEqual(1, hits);
}
