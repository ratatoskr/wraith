//! Frame service. Owners get a callback every frame and can post to the next one.

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const core = @import("wraith_core");
const api = @import("wraith_api");
const sync = @import("tuft_sys").sync;

const host = @import("root.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;

const Bus = core.Event(fn () void);
const W = api.wraith;
/// From `frame.sal`, kept till it's cancelled.
pub const Tick = W.FrameTick;
/// From `frame.sal`, kept till it runs.
pub const Task = W.FrameTask;

var bus: Bus = .init(std.heap.page_allocator);

var frames: Atomic(bool) = .init(false);

/// Turn it off only once `run` can't be running.
pub fn setFrames(on: bool) void {
    frames.store(on, .release);
}

pub fn framesOn() bool {
    return frames.load(.acquire);
}

/// The thread `run` was last called on, or 0.
var render_thread: Atomic(std.Thread.Id) = .init(0);

/// Whether this is the thread frames run on.
pub fn onRenderThread() bool {
    const id = render_thread.load(.monotonic);
    return id != 0 and id == std.Thread.getCurrentId();
}

/// Render thread, each frame, inside the overlay's ImGui frame or a headless one.
pub fn run() void {
    render_thread.store(std.Thread.getCurrentId(), .monotonic);
    bus.fire(.{});
    host.salamander.pollRender();
}

pub const Frame = struct {
    loaded: *Loaded,
    tick: Tick,
    subscription: Bus.Subscription = undefined,
    stopped: Atomic(bool) = .init(false),
    zone: core.timing.Zone = .init("frame"),
    warned: bool = false,

    fn fire(self: *Frame) void {
        const timed = self.zone.begin();
        defer timed.end();
        host.ui.runAs(self.loaded, &self.warned, self, call);
    }

    fn call(ctx: ?*anyopaque) callconv(.c) void {
        const self: *Frame = @ptrCast(@alignCast(ctx.?));
        self.tick.invoke(.{});
    }

    pub fn going(self: *Frame) bool {
        return !self.stopped.load(.acquire);
    }

    pub fn stop(self: *Frame) void {
        if (self.stopped.swap(true, .acq_rel)) return;
        self.subscription.unsubscribe();
        core.timing.registry.remove(&self.zone);
        // Won't be called again
        self.tick.release();
    }

    pub fn free(self: *Frame) void {
        self.stop();
        self.loaded.allocator.destroy(self);
    }
};

var callbacks: host.Owned(Frame) = .{};

/// Its frame callbacks that are still on.
pub fn countOf(loaded: *Loaded) u32 {
    return callbacks.count(&loaded.owner);
}

/// Through `frame.sal`. Released if it fails.
pub fn onFrame(loaded: *Loaded, tick: Tick) api.FrameError!*Frame {
    return subscribe(loaded, tick) catch |err| {
        tick.release();
        return err;
    };
}

fn subscribe(loaded: *Loaded, tick: Tick) api.FrameError!*Frame {
    if (!frames.load(.acquire)) return error.NoFrames;
    const f = try loaded.allocator.create(Frame);
    f.* = .{ .loaded = loaded, .tick = tick };
    f.zone.owner = &loaded.owner;
    core.timing.registry.add(&f.zone);
    f.subscription = bus.subscribeUnscoped(f, Frame.fire) catch {
        core.timing.registry.remove(&f.zone);
        loaded.allocator.destroy(f);
        return error.OutOfMemory;
    };
    callbacks.add(f) catch |err| {
        // Not `free`, since the callback's still the caller's
        f.subscription.unsubscribe();
        core.timing.registry.remove(&f.zone);
        loaded.allocator.destroy(f);
        return if (err == error.OutOfMemory) error.OutOfMemory else error.OwnerGone;
    };
    return f;
}

const Posted = union(enum) {
    sal: Task,
    /// `Frame.next`'s promise.
    next: host.wraith.NextResolver,

    fn run(self: Posted) void {
        switch (self) {
            .sal => |f| {
                f.invoke(.{});
                f.release();
            },
            .next => |r| r.resolve({}),
        }
    }

    fn cancel(self: Posted) void {
        switch (self) {
            // The plugin's going, so there's nobody to tell
            .sal => |f| f.release(),
            .next => |r| r.drop(),
        }
    }
};

/// Runs before frame callbacks, so one sees what was posted for its frame.
const Queue = struct {
    loaded: *Loaded,
    lock: sync.RwLock = .{},
    /// Under `lock`.
    waiting: std.ArrayList(Posted) = .empty,
    running: std.ArrayList(Posted) = .empty,
    /// Under `lock`.
    stopped: bool = false,
    subscription: Bus.Subscription = undefined,
    warned: bool = false,

    fn fire(self: *Queue) void {
        {
            self.lock.lock();
            defer self.lock.unlock();
            if (self.waiting.items.len == 0) return;
            std.mem.swap(std.ArrayList(Posted), &self.waiting, &self.running);
        }
        // Scoped like frame callbacks, since `onRender` posts can draw
        host.ui.runAs(self.loaded, &self.warned, self, runPosts);
        self.running.clearRetainingCapacity();
    }

    fn runPosts(ctx: ?*anyopaque) callconv(.c) void {
        const self: *Queue = @ptrCast(@alignCast(ctx.?));
        for (self.running.items) |p| p.run();
    }

    fn post(self: *Queue, callback: Posted) api.FrameError!void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.stopped) return error.OwnerGone;
        try self.waiting.append(self.loaded.allocator, callback);
    }

    /// What hasn't run gets cancelled.
    pub fn stop(self: *Queue) void {
        {
            self.lock.lock();
            defer self.lock.unlock();
            if (self.stopped) return;
            self.stopped = true;
        }
        self.subscription.unsubscribe();
        var left: std.ArrayList(Posted) = .empty;
        {
            self.lock.lock();
            defer self.lock.unlock();
            std.mem.swap(std.ArrayList(Posted), &self.waiting, &left);
        }
        defer left.deinit(self.loaded.allocator);
        for (left.items) |p| p.cancel();
    }

    pub fn free(self: *Queue) void {
        self.stop();
        self.waiting.deinit(self.loaded.allocator);
        self.running.deinit(self.loaded.allocator);
        self.loaded.allocator.destroy(self);
    }
};

var queues: host.Owned(Queue) = .{};
/// So two threads posting for one owner don't both make a queue.
var creating: sync.RwLock = .{};

/// Through `frame.sal`. Released if it fails.
pub fn post(loaded: *Loaded, task: Task) api.FrameError!void {
    postAny(loaded, .{ .sal = task }) catch |err| {
        task.release();
        return err;
    };
}

/// Settles `resolver` at the start of the next frame. Fails if it can't, leaving it the caller's.
pub fn postNext(loaded: *Loaded, resolver: host.wraith.NextResolver) api.FrameError!void {
    return postAny(loaded, .{ .next = resolver });
}

fn postAny(loaded: *Loaded, callback: Posted) api.FrameError!void {
    if (!frames.load(.acquire)) return error.NoFrames;
    const queue = queues.first(&loaded.owner) orelse try makeQueue(loaded);
    return queue.post(callback);
}

fn makeQueue(loaded: *Loaded) api.FrameError!*Queue {
    creating.lock();
    defer creating.unlock();
    if (queues.first(&loaded.owner)) |q| return q;
    const queue = try loaded.allocator.create(Queue);
    queue.* = .{ .loaded = loaded };
    queue.subscription = bus.subscribeUnscopedOpts(queue, Queue.fire, .{ .priority = 1 }) catch {
        loaded.allocator.destroy(queue);
        return error.OutOfMemory;
    };
    queues.add(queue) catch |err| {
        queue.free();
        return if (err == error.OutOfMemory) error.OutOfMemory else error.OwnerGone;
    };
    return queue;
}

const tests = struct {
    const testing = std.testing;
    const sdk = @import("wraith_sdk");

    const FakePlugin = struct {
        loaded: Loaded,

        fn init(self: *FakePlugin, name: []const u8) void {
            self.loaded.initForTest(testing.allocator, name);
        }

        fn owner(self: *FakePlugin) sdk.Owner {
            return .of(self.loaded.root());
        }
    };

    const Counter = struct {
        frames: u32 = 0,
        ran: u32 = 0,
        cancelled: u32 = 0,
        frames_at_post: u32 = 0,
        repost: bool = false,
        reposted: u32 = 0,

        fn onFrame(self: *Counter) void {
            self.frames += 1;
        }

        fn onPost(self: *Counter, status: sdk.frame.PostStatus) void {
            switch (status) {
                .run => {
                    self.ran += 1;
                    self.frames_at_post = self.frames;
                    if (self.repost) {
                        self.repost = false;
                        sdk.frame.post(self, onReposted) catch unreachable;
                    }
                },
                .cancelled => self.cancelled += 1,
            }
        }

        fn onReposted(self: *Counter, status: sdk.frame.PostStatus) void {
            if (status == .run) self.reposted += 1 else self.cancelled += 1;
        }
    };

    test "frames and posts" {
        setFrames(true);
        defer setFrames(false);
        var a: FakePlugin = undefined;
        a.init("a");
        defer a.loaded.deinitForTest();
        const acting = a.owner().enter();
        defer acting.end();

        var counter: Counter = .{ .repost = true };
        const sub = try sdk.frame.onFrame(&counter, Counter.onFrame);
        try sdk.frame.post(&counter, Counter.onPost);
        try testing.expectEqual(0, counter.ran);
        run();
        try testing.expectEqual(1, counter.frames);
        try testing.expectEqual(1, counter.ran);
        try testing.expectEqual(0, counter.frames_at_post);
        // Posted from inside a post waits a frame
        try testing.expectEqual(0, counter.reposted);
        run();
        try testing.expectEqual(1, counter.ran);
        try testing.expectEqual(1, counter.reposted);
        try testing.expectEqual(2, counter.frames);

        sub.unsubscribe();
        sub.unsubscribe();
        run();
        try testing.expectEqual(2, counter.frames);
    }

    test "posts from other threads" {
        setFrames(true);
        defer setFrames(false);
        var a: FakePlugin = undefined;
        a.init("a");
        defer a.loaded.deinitForTest();

        var counter: Counter = .{};
        const Poster = struct {
            fn post(owner: sdk.Owner, c: *Counter) void {
                const acting = owner.enter();
                defer acting.end();
                for (0..10) |_| sdk.frame.post(c, Counter.onPost) catch unreachable;
            }
        };
        var threads: [4]std.Thread = undefined;
        for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Poster.post, .{ a.owner(), &counter });
        for (threads) |t| t.join();
        run();
        try testing.expectEqual(40, counter.ran);
    }

    test "closing cancels posts" {
        setFrames(true);
        defer setFrames(false);
        var a: FakePlugin = undefined;
        a.init("a");
        var counter: Counter = .{};
        {
            const acting = a.owner().enter();
            defer acting.end();
            _ = try sdk.frame.onFrame(&counter, Counter.onFrame);
            try sdk.frame.post(&counter, Counter.onPost);
            try sdk.frame.post(&counter, Counter.onPost);
        }
        a.loaded.owner.close();
        try testing.expectEqual(2, counter.cancelled);
        {
            const acting = a.owner().enter();
            defer acting.end();
            try testing.expectError(error.OwnerGone, sdk.frame.post(&counter, Counter.onPost));
            try testing.expectError(error.OwnerGone, sdk.frame.onFrame(&counter, Counter.onFrame));
        }
        run();
        try testing.expectEqual(0, counter.ran);
        try testing.expectEqual(0, counter.frames);
        a.loaded.deinitForTest();
    }

    test "no frames, no callbacks" {
        var a: FakePlugin = undefined;
        a.init("a");
        defer a.loaded.deinitForTest();
        const acting = a.owner().enter();
        defer acting.end();
        var counter: Counter = .{};
        try testing.expectError(error.NoFrames, sdk.frame.post(&counter, Counter.onPost));
        try testing.expectError(error.NoFrames, sdk.frame.onFrame(&counter, Counter.onFrame));
    }
};

test {
    _ = tests;
}
