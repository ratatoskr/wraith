//! The runtime's message bus, between it and workbench sessions. Delivered on the next frame.

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const core = @import("wraith_core");
const api = @import("wraith_api");
const sync = @import("tuft_sys").sync;

const Bus = core.Event(fn (message: *const api.Message) void);

var bus: Bus = .init(std.heap.page_allocator);

const max_queued = 1024;

var frames: Atomic(bool) = .init(false);
/// Nothing gets queued without one.
var live: Atomic(u32) = .init(0);

var queue_lock: sync.RwLock = .{};
/// Under `queue_lock`.
var queued: std.ArrayList(*Queued) = .empty;
/// Only touched by `deliver`, and by `setFrames` once frames stopped.
var delivering: std.ArrayList(*Queued) = .empty;

const list_allocator = std.heap.page_allocator;

/// Turn it off only once `deliver` can't be running.
pub fn setFrames(on: bool) void {
    frames.store(on, .release);
    if (on) return;
    queue_lock.lock();
    defer queue_lock.unlock();
    for (queued.items) |q| q.destroy();
    queued.clearAndFree(list_allocator);
    delivering.clearAndFree(list_allocator);
}

/// Render thread, each frame.
pub fn deliver() void {
    {
        queue_lock.lock();
        defer queue_lock.unlock();
        if (queued.items.len == 0) return;
        std.mem.swap(std.ArrayList(*Queued), &queued, &delivering);
    }
    for (delivering.items) |q| {
        bus.fire(.{&q.message});
        q.destroy();
    }
    delivering.clearRetainingCapacity();
}

const Queued = struct {
    allocator: std.mem.Allocator,
    message: api.Message,
    bytes: []u8,

    fn create(allocator: std.mem.Allocator, message: api.Message) !*Queued {
        const self = try allocator.create(Queued);
        errdefer allocator.destroy(self);
        const bytes = try std.mem.concat(allocator, u8, &.{ message.topic, message.payload, message.from });
        const payload_at = message.topic.len;
        const from_at = payload_at + message.payload.len;
        self.* = .{
            .allocator = allocator,
            .bytes = bytes,
            .message = .{
                .topic = bytes[0..payload_at],
                .payload = bytes[payload_at..from_at],
                .from = bytes[from_at..],
            },
        };
        return self;
    }

    fn destroy(self: *Queued) void {
        self.allocator.free(self.bytes);
        self.allocator.destroy(self);
    }
};

/// Any thread.
pub fn publishFromRuntime(topic: []const u8, payload: []const u8) api.MessageError!void {
    if (!api.validTopic(topic)) return error.InvalidTopic;
    if (!frames.load(.acquire) or live.load(.acquire) == 0) return;
    const q = try Queued.create(std.heap.smp_allocator, .{ .topic = topic, .payload = payload, .from = api.script.runtime });
    errdefer q.destroy();
    queue_lock.lock();
    defer queue_lock.unlock();
    if (queued.items.len >= max_queued) return error.QueueFull;
    try queued.append(list_allocator, q);
}

/// Gets every message on the render thread, so filter by topic.
pub const RuntimeSubscription = struct {
    inner: Bus.Subscription,

    /// Waits for a delivery in flight.
    pub fn unsubscribe(self: RuntimeSubscription) void {
        self.inner.unsubscribe();
        _ = live.fetchSub(1, .acq_rel);
    }
};

pub fn subscribeRuntime(ctx: anytype, comptime func: fn (@TypeOf(ctx), *const api.Message) void) !RuntimeSubscription {
    const inner = try bus.subscribeUnscoped(ctx, func);
    _ = live.fetchAdd(1, .acq_rel);
    return .{ .inner = inner };
}

const tests = struct {
    const testing = std.testing;

    const Heard = struct {
        count: u32 = 0,
        from: [16]u8 = undefined,
        from_len: usize = 0,

        fn on(self: *Heard, message: *const api.Message) void {
            if (!api.topicMatches("test.*", message.topic)) return;
            self.count += 1;
            self.from_len = @min(message.from.len, self.from.len);
            @memcpy(self.from[0..self.from_len], message.from[0..self.from_len]);
        }
    };

    test "delivered the next frame, never inside the publish" {
        setFrames(true);
        defer setFrames(false);
        var heard: Heard = .{};
        const sub = try subscribeRuntime(&heard, Heard.on);
        try publishFromRuntime("test.a", "{}");
        try publishFromRuntime("other", "{}");
        try testing.expectError(error.InvalidTopic, publishFromRuntime("test.*", ""));
        try testing.expectEqual(0, heard.count);
        deliver();
        try testing.expectEqual(1, heard.count);
        try testing.expectEqualStrings(api.script.runtime, heard.from[0..heard.from_len]);
        sub.unsubscribe();
        try publishFromRuntime("test.a", "{}");
        deliver();
        try testing.expectEqual(1, heard.count);
        try testing.expectEqual(0, live.load(.acquire));
    }
};

test {
    _ = tests;
}
