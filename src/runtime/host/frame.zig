//! Frame service: per-frame callbacks and posts. Ticks are the game thread's frames, run on the
//! render thread before each frame unless a plugin drives them from the game's own thread.

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const core = @import("wraith_core");
const api = @import("wraith_api");
const sync = @import("tuft_sys").sync;

const host = @import("root.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;
const leases = @import("leases.zig");
const gfx = @import("tuft_gfx");

const Bus = core.Event(fn () void);
pub const Subscription = Bus.Subscription;
const W = api.wraith;
const log = core.log.scoped(.wraith_runtime);
/// From `threads.sal`, kept till it's cancelled.
pub const Draw = W.Threads.Draw;
/// From `threads.sal`, kept till it's cancelled.
pub const Tick = W.Threads.Tick;
/// From `threads.sal`, kept till it runs.
pub const Task = W.Threads.Task;
/// From `threads.sal`, kept till the plugin's gone.
pub const Stopping = W.Threads.Stopping;

var bus: Bus = .init(core.heap.main);
var tick_bus: Bus = .init(core.heap.main);

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

/// Render thread, each frame, inside an ImGui frame. Ticks first, unless a driver has them.
pub fn run() void {
    render_thread.store(std.Thread.getCurrentId(), .monotonic);
    last_run.store(core.timing.now(), .monotonic);
    const has_driver = leases.withHolder(.ticks, {}, checkStalled);
    if (!has_driver) tickNow();
    bus.fire(.{});
    host.salamander.pollRender();
    host.threads.checkDelays();
}

/// The thread ticks last ran on, or 0. Cleared when a driver takes over, till its first tick.
var game_thread: Atomic(std.Thread.Id) = .init(0);
/// So two drivers handing over never tick at once.
var ticking: Atomic(bool) = .init(false);

pub fn onGameThread() bool {
    const id = game_thread.load(.monotonic);
    return id != 0 and id == std.Thread.getCurrentId();
}

/// What the game's camera showed last, from its plugin.
var view_lock: sync.RwLock = .{};
var game_view: W.Display.View = .{ .viewMatrix = .identity, .projection = .identity, .known = false };
/// `core.timing.now()` when it was set, under `view_lock`.
var view_at: u64 = 0;
/// Older than this and it's not known any more, since the plugin's stopped saying.
const view_ns = std.time.ns_per_s;

/// Through `display.sal`. Only the plugin holding the view's count.
pub fn setViewFrom(loaded: *const Loaded, view_: W.Mat4, projection: W.Mat4) void {
    if (!leases.holds(loaded, .view)) return;
    setView(view_, projection);
}

pub fn setView(view_: W.Mat4, projection: W.Mat4) void {
    view_lock.lock();
    defer view_lock.unlock();
    game_view = .{ .viewMatrix = view_, .projection = projection, .known = true };
    view_at = core.timing.now();
}

pub fn view() W.Display.View {
    view_lock.lockShared();
    defer view_lock.unlockShared();
    var v = game_view;
    v.known = v.known and core.timing.now() -| view_at < view_ns;
    return v;
}

/// Through `display.sal`. Kept with the plugin's lease on the view, and only used while it holds it.
pub fn setColorSpace(loaded: *Loaded, space: W.ColorSpace) void {
    _ = leases.withLease(loaded, .view, space, keepColorSpace);
}

fn keepColorSpace(space: W.ColorSpace, lease: *leases.Lease) void {
    lease.color_space = space;
    if (lease.held()) hintColorSpace(space);
}

/// As the view changes hands, from `leases`: the new one's color space, or none.
pub fn viewHandedOver(after: ?*leases.Lease) void {
    hintColorSpace(if (after) |a| a.color_space else null);
    // The one before's isn't the game's any more, till the new one says
    view_lock.lock();
    defer view_lock.unlock();
    game_view.known = false;
}

fn hintColorSpace(space: ?W.ColorSpace) void {
    gfx.color_space_hint.set(if (space) |s| switch (s) {
        .srgb => .srgb,
        .scrgb => .scrgb,
        .hdr10 => .hdr10,
        _ => null,
    } else null);
}

pub const TickSubscription = Bus.Subscription;

/// For the runtime's own code, not a plugin's. `f(ctx)` runs each tick, on the game thread.
pub fn subscribeTicks(ctx: anytype, comptime f: fn (@TypeOf(ctx)) void) !TickSubscription {
    return tick_bus.subscribeUnscoped(ctx, f);
}

/// A tick with no frame, for tests.
pub fn tickForTests() void {
    tickNow();
}

/// Skipped if a tick's already running on another thread.
fn tickNow() void {
    if (ticking.swap(true, .acquire)) return;
    defer ticking.store(false, .release);
    game_thread.store(std.Thread.getCurrentId(), .monotonic);
    last_run.store(core.timing.now(), .monotonic);
    tick_bus.fire(.{});
    host.salamander.pollGame();
    host.threads.checkDelays();
}

/// How long the plugin holding ticks can go without ticking before it's logged.
const stall_ns = 30 * std.time.ns_per_s;

/// Render thread, while `lease` holds ticks.
fn checkStalled(_: void, lease: *leases.Lease) void {
    if (lease.warned.load(.monotonic)) return;
    if (core.timing.now() -| lease.last_tick.load(.monotonic) < stall_ns) return;
    if (lease.warned.swap(true, .monotonic)) return;
    log.warn("{s} has ticks but hasn't ticked in {d}s, so nothing's running on the game thread", .{ lease.loaded.name, stall_ns / std.time.ns_per_s });
}

/// Whether a plugin drives ticks from the game's own thread.
pub fn driven() bool {
    return leases.holder(.ticks) != null;
}

/// As ticks change hands, from `leases`.
pub fn ticksHandedOver(after: ?*leases.Lease) void {
    if (after) |a| a.last_tick.store(core.timing.now(), .monotonic);
    // Not the game thread till the new one ticks
    game_thread.store(0, .monotonic);
}

/// Through `threads.sal`, from the game's own thread. Only the plugin holding ticks' count.
pub fn tickFrom(loaded: *Loaded) void {
    const h = leases.heldBy(loaded, .ticks) orelse return;
    h.last_tick.store(core.timing.now(), .monotonic);
    tickNow();
}

pub const Frame = struct {
    loaded: *Loaded,
    callback: Callback,
    subscription: Bus.Subscription = undefined,
    stopped: Atomic(bool) = .init(false),
    zone: core.timing.Zone,
    warned: bool = false,
    /// For `stopping`, once the plugin's said it's done.
    finished: Atomic(bool) = .init(false),

    pub const Callback = union(enum) {
        /// Render thread, and can draw.
        frame: Draw,
        /// Game thread, and can't.
        game: Tick,
        /// Once, as the plugin's about to stop. On no bus.
        stopping: Stopping,
    };

    fn fire(self: *Frame) void {
        const timed = self.zone.begin();
        defer timed.end();
        switch (self.callback) {
            .frame => host.ui.runAs(self.loaded, &self.warned, self, call),
            .game => |t| t.invoke(.{}),
            .stopping => {},
        }
    }

    fn call(ctx: ?*anyopaque) callconv(.c) void {
        const self: *Frame = @ptrCast(@alignCast(ctx.?));
        self.callback.frame.invoke(.{});
    }

    pub fn going(self: *Frame) bool {
        return !self.stopped.load(.acquire);
    }

    pub fn stop(self: *Frame) void {
        if (self.stopped.swap(true, .acq_rel)) return;
        if (self.callback != .stopping) {
            self.subscription.unsubscribe();
            core.timing.registry.remove(&self.zone);
        }
        // Nothing waits on one that's gone
        self.finished.store(true, .release);
        // Won't be called again
        switch (self.callback) {
            inline else => |c| c.release(),
        }
    }

    pub fn free(self: *Frame) void {
        self.stop();
        self.loaded.allocator.destroy(self);
    }
};

var callbacks: host.Owned(Frame) = .{};

/// Its draw callbacks that are still on.
pub fn countOf(loaded: *Loaded) u32 {
    return callbacks.count(&loaded.owner);
}

/// Through `threads.sal`. Released if it fails.
pub fn onDraw(loaded: *Loaded, draw: Draw) api.FrameError!*Frame {
    if (!frames.load(.acquire)) {
        draw.release();
        return error.NoFrames;
    }
    return subscribe(loaded, .{ .frame = draw }, &bus) catch |err| {
        draw.release();
        return err;
    };
}

/// Every frame with the plugins' callbacks, for what Wraith draws for them, like their windows.
pub fn subscribeFrames(ctx: anytype, comptime fire: fn (@TypeOf(ctx)) void) !Bus.Subscription {
    return bus.subscribeUnscoped(ctx, fire);
}

/// Through `threads.sal`. Released if it fails. Fine without frames, since a driver can tick.
pub fn onTick(loaded: *Loaded, tick: Tick) api.FrameError!*Frame {
    return subscribe(loaded, .{ .game = tick }, &tick_bus) catch |err| {
        tick.release();
        return err;
    };
}

/// Through `threads.sal`. Released if it fails.
pub fn onStopping(loaded: *Loaded, stopping: Stopping) api.FrameError!*Frame {
    const f = loaded.allocator.create(Frame) catch {
        stopping.release();
        return error.OutOfMemory;
    };
    f.* = .{ .loaded = loaded, .callback = .{ .stopping = stopping }, .zone = .init("stopping") };
    callbacks.add(f) catch |err| {
        stopping.release();
        loaded.allocator.destroy(f);
        return if (err == error.OutOfMemory) error.OutOfMemory else error.OwnerGone;
    };
    return f;
}

/// How long plugins get to wind down.
const stopping_ns = std.time.ns_per_s;

/// Before `loaded`'s owner closes: calls its `onStopping`s and waits up to a second for them, if
/// frames or ticks can carry their tasks on meanwhile.
pub fn runStopping(loaded: *Loaded, done_table: *const anyopaque) void {
    var found: std.ArrayList(*Frame) = .empty;
    defer found.deinit(loaded.allocator);
    {
        callbacks.lock.lockShared();
        defer callbacks.lock.unlockShared();
        for (callbacks.entries.items) |e| {
            const f = e.record;
            if (e.stopped or f.loaded != loaded or f.callback != .stopping or !f.going()) continue;
            // Out of memory, the rest are stopped without winding down
            found.append(loaded.allocator, f) catch break;
        }
    }
    if (found.items.len == 0) return;
    for (found.items) |f| f.callback.stopping.invoke(.{.{ .data = @intFromPtr(f), .table = done_table }});
    if (!canWaitForTasks()) return;
    const start = core.timing.now();
    while (core.timing.now() -| start < stopping_ns) {
        for (found.items) |f| {
            if (!f.finished.load(.acquire)) break;
        } else return;
        @import("tuft_sys").thread.sleepMs(1);
    }
    log.warn("{s} took over a second to wind down, so it's stopped anyway", .{loaded.name});
}

/// `core.timing.now()` at the last frame or tick.
var last_run: Atomic(u64) = .init(0);

/// Whether frames or ticks will carry tasks on while this thread waits. Not while closing or stuck loading.
fn canWaitForTasks() bool {
    if (onRenderThread() or onGameThread()) return false;
    return core.timing.now() -| last_run.load(.monotonic) < 250 * std.time.ns_per_ms;
}

fn subscribe(loaded: *Loaded, callback: Frame.Callback, on: *Bus) api.FrameError!*Frame {
    const f = try loaded.allocator.create(Frame);
    f.* = .{ .loaded = loaded, .callback = callback, .zone = .init(if (callback == .frame) "frame" else "tick") };
    f.zone.owner = &loaded.owner;
    core.timing.registry.add(&f.zone);
    f.subscription = on.subscribeUnscoped(f, Frame.fire) catch {
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
    /// Code waiting on a promise, carrying on here. See `PluginQueue`.
    waiter: api.salamander.Task,

    fn run(self: Posted) void {
        switch (self) {
            .sal => |f| {
                f.invoke(.{});
                f.release();
            },
            .next => |r| r.resolve({}),
            .waiter => |t| t.invoke(.{}),
        }
    }

    fn cancel(self: Posted) void {
        switch (self) {
            // The plugin's going, so there's nobody to tell
            .sal => |f| f.release(),
            .next => |r| r.drop(),
            // Its code's going, so it isn't called
            .waiter => {},
        }
    }
};

/// The plugin's posts as a Salamander queue, adopted by its owner. Runs at the next frame inside the
/// plugin's frame, so it can draw.
pub const PluginQueue = struct {
    pub fn post(loaded: *Loaded, task: api.salamander.Task) bool {
        postAny(loaded, .{ .waiter = task }) catch return false;
        return true;
    }

    pub fn poll(_: *Loaded) u32 {
        return 0;
    }
};

/// Runs before draw callbacks, so one sees what was posted for its frame.
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
        // Scoped like draw callbacks, since `onRender` posts can draw
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

/// Through `threads.sal`. Released if it fails.
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

        fn onDraw(self: *Counter) void {
            self.frames += 1;
        }

        fn onPost(self: *Counter, status: sdk.threads.PostStatus) void {
            switch (status) {
                .run => {
                    self.ran += 1;
                    self.frames_at_post = self.frames;
                    if (self.repost) {
                        self.repost = false;
                        sdk.threads.post(self, onReposted) catch unreachable;
                    }
                },
                .cancelled => self.cancelled += 1,
            }
        }

        fn onReposted(self: *Counter, status: sdk.threads.PostStatus) void {
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
        const sub = try sdk.threads.onDraw(&counter, Counter.onDraw);
        try sdk.threads.post(&counter, Counter.onPost);
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

    test "a plugin winds down before it stops, which waits for it, but never on the game thread" {
        const sleepMs = @import("tuft_sys").thread.sleepMs;
        var a: FakePlugin = undefined;
        a.init("a");
        defer a.loaded.deinitForTest();
        const State = struct {
            done: ?W.Threads.WindDown = null,
            calls: Atomic(u32) = .init(0),

            fn stopping(self: *@This(), done: W.Threads.WindDown) void {
                self.done = done;
                _ = self.calls.fetchAdd(1, .acq_rel);
            }
        };
        var state: State = .{};
        {
            const acting = a.owner().enter();
            defer acting.end();
            _ = try sdk.wraith.root().?.threads().onStopping(W.Threads.Stopping.init(&state, State.stopping));
        }
        // Ticking lately, and this is the game thread, which mustn't wait on itself
        tickForTests();
        host.wraith.runStopping(&a.loaded);
        try testing.expectEqual(1, state.calls.load(.acquire));

        const Waiter = struct {
            fn run(loaded: *Loaded, finished: *Atomic(bool)) void {
                host.wraith.runStopping(loaded);
                finished.store(true, .release);
            }
        };
        var finished: Atomic(bool) = .init(false);
        const t = try std.Thread.spawn(.{}, Waiter.run, .{ &a.loaded, &finished });
        while (state.calls.load(.acquire) < 2) sleepMs(1);
        sleepMs(20);
        try testing.expect(!finished.load(.acquire));
        state.done.?.done();
        t.join();
        try testing.expect(finished.load(.acquire));
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
                for (0..10) |_| sdk.threads.post(c, Counter.onPost) catch unreachable;
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
            _ = try sdk.threads.onDraw(&counter, Counter.onDraw);
            try sdk.threads.post(&counter, Counter.onPost);
            try sdk.threads.post(&counter, Counter.onPost);
        }
        a.loaded.owner.close();
        try testing.expectEqual(2, counter.cancelled);
        {
            const acting = a.owner().enter();
            defer acting.end();
            try testing.expectError(error.OwnerGone, sdk.threads.post(&counter, Counter.onPost));
            try testing.expectError(error.OwnerGone, sdk.threads.onDraw(&counter, Counter.onDraw));
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
        try testing.expectError(error.NoFrames, sdk.threads.post(&counter, Counter.onPost));
        try testing.expectError(error.NoFrames, sdk.threads.onDraw(&counter, Counter.onDraw));
    }

    const Order = struct {
        seen: [8]u8 = undefined,
        n: usize = 0,
        game_thread: bool = false,
        ticked_on: std.Thread.Id = 0,

        fn onTick(self: *Order) void {
            self.seen[self.n] = 't';
            self.n += 1;
            self.game_thread = onGameThread();
            self.ticked_on = std.Thread.getCurrentId();
        }

        fn onDraw(self: *Order) void {
            self.seen[self.n] = 'f';
            self.n += 1;
        }
    };

    test "without a driver, each tick runs on the render thread just before its frame" {
        setFrames(true);
        defer setFrames(false);
        var a: FakePlugin = undefined;
        a.init("a");
        defer a.loaded.deinitForTest();
        const acting = a.owner().enter();
        defer acting.end();

        var order: Order = .{};
        const frame_sub = try sdk.threads.onDraw(&order, Order.onDraw);
        defer frame_sub.unsubscribe();
        const tick_sub = try sdk.threads.onTick(&order, Order.onTick);
        defer tick_sub.unsubscribe();
        run();
        run();
        try testing.expectEqualStrings("tftf", order.seen[0..order.n]);
        try testing.expect(order.game_thread);
        try testing.expect(sdk.threads.onGameThread());
    }

    /// What `p` does from the game's thread each frame, if it holds ticks.
    fn tickAs(p: *FakePlugin) void {
        const acting = p.owner().enter();
        defer acting.end();
        sdk.threads.tick();
    }

    /// Where a promise settled, taken there.
    fn Seen(comptime P: type) type {
        return struct {
            promise: P,
            on: Atomic(std.Thread.Id) = .init(0),
            done: Atomic(bool) = .init(false),

            fn watch(self: *@This()) void {
                self.promise.then(self, settled, .now);
            }

            fn settled(self: *@This()) void {
                _ = self.promise.take();
                self.on.store(std.Thread.getCurrentId(), .release);
                self.done.store(true, .release);
            }

            fn waitDone(self: *@This()) void {
                while (!self.done.load(.acquire)) std.Thread.yield() catch {};
            }
        };
    }

    fn seen(promise: anytype) Seen(@TypeOf(promise)) {
        return .{ .promise = promise };
    }

    test "hops carry on on their own thread, and other awaits where they were made" {
        setFrames(true);
        defer setFrames(false);
        host.wraith.setIo(testing.io);
        defer host.wraith.setIo(null);
        defer host.threads.stop();
        var a: FakePlugin = undefined;
        a.init("a");
        defer a.loaded.deinitForTest();
        var b: FakePlugin = undefined;
        b.init("b");
        defer b.loaded.deinitForTest();
        const acting = a.owner().enter();
        defer acting.end();
        const f = sdk.wraith.root().?.threads();
        // Without a driver, this is the render thread and ticks run on it too
        run();
        const me = std.Thread.getCurrentId();

        var worker = seen(f.toWorker());
        worker.watch();
        worker.waitDone();
        try testing.expect(worker.on.load(.acquire) != me);

        var render = seen(f.toRender());
        render.watch();
        // Already there
        try testing.expect(render.done.load(.acquire));

        var tick = seen(f.nextTick());
        tick.watch();
        try testing.expect(!tick.done.load(.acquire));
        run();
        try testing.expect(tick.done.load(.acquire));
        try testing.expectEqual(me, tick.on.load(.acquire));

        var later = seen(f.delay(0));
        later.watch();
        try testing.expect(!later.done.load(.acquire));
        run();
        try testing.expectEqual(me, later.on.load(.acquire));

        // From a worker back to the render thread, at its next frame
        const Back = struct {
            fn go(owner: sdk.Owner, out: *Seen(api.salamander.Plain(sdk.api.wraith.Threads, "toRender"))) void {
                const on = owner.enter();
                defer on.end();
                out.* = seen(sdk.wraith.root().?.threads().toRender());
                out.watch();
            }
        };
        var back: Seen(api.salamander.Plain(sdk.api.wraith.Threads, "toRender")) = undefined;
        const t = try std.Thread.spawn(.{}, Back.go, .{ a.owner(), &back });
        t.join();
        try testing.expect(!back.done.load(.acquire));
        run();
        try testing.expectEqual(me, back.on.load(.acquire));

        // b holds a lock a waits for here, and lets go on a worker. a still carries on here
        const lock = blk: {
            const by_b = b.owner().enter();
            defer by_b.end();
            const l = sdk.wraith.root().?.sync().newLock();
            try testing.expect(sdk.wraith.root().?.sync().tryLock(l));
            break :blk l;
        };
        var waited = seen(sdk.wraith.root().?.sync().lock(lock));
        waited.watch();
        const Unlock = struct {
            fn go(owner: sdk.Owner, l: sdk.api.wraith.Sync.Lock) void {
                const on = owner.enter();
                defer on.end();
                sdk.wraith.root().?.sync().unlock(l);
            }
        };
        const u = try std.Thread.spawn(.{}, Unlock.go, .{ b.owner(), lock });
        u.join();
        try testing.expect(!waited.done.load(.acquire));
        run();
        try testing.expectEqual(me, waited.on.load(.acquire));
    }

    test "carrying on on the render thread is inside the plugin's frame, so it can draw" {
        setFrames(true);
        defer setFrames(false);
        host.wraith.setIo(testing.io);
        defer host.wraith.setIo(null);
        defer host.threads.stop();
        var a: FakePlugin = undefined;
        a.init("a");
        defer a.loaded.deinitForTest();
        const acting = a.owner().enter();
        defer acting.end();
        const Frames = struct {
            n: Atomic(u32) = .init(0),
            /// `n` when the hop carried on.
            at: Atomic(u32) = .init(std.math.maxInt(u32)),
            promise: api.salamander.Plain(sdk.api.wraith.Threads, "toRender") = .{},

            fn onDraw(self: *@This()) void {
                _ = self.n.fetchAdd(1, .acq_rel);
            }

            fn settled(self: *@This()) void {
                _ = self.promise.take();
                self.at.store(self.n.load(.acquire), .release);
            }

            fn go(owner: sdk.Owner, self: *@This()) void {
                const on = owner.enter();
                defer on.end();
                self.promise = sdk.wraith.root().?.threads().toRender();
                self.promise.then(self, settled, .now);
            }
        };
        var counted: Frames = .{};
        const sub = try sdk.threads.onDraw(&counted, Frames.onDraw);
        defer sub.unsubscribe();
        run();
        const t = try std.Thread.spawn(.{}, Frames.go, .{ a.owner(), &counted });
        t.join();
        run();
        // With the plugin's posts, which run just before its draw callbacks in the same scope
        try testing.expectEqual(1, counted.at.load(.acquire));
        try testing.expectEqual(2, counted.n.load(.acquire));
    }

    test "the game's view, as its plugin last set it, till it's stale" {
        var a: FakePlugin = undefined;
        a.init("a");
        defer a.loaded.deinitForTest();
        const acting = a.owner().enter();
        defer acting.end();
        const math = sdk.math;

        try testing.expectEqual(null, sdk.display.view());
        const moved = math.Mat4.translation(.{ .x = 2 });
        // Only the plugin holding the view's count
        sdk.display.setView(moved, .identity);
        try testing.expectEqual(null, sdk.display.view());
        const lease = try sdk.display.claimView(.none);
        defer lease.release();
        sdk.display.setView(moved, .identity);
        const v = sdk.display.view().?;
        try testing.expectEqual(moved, v.view);
        // A plugin that's stopped saying doesn't leave an old one
        view_at -|= 2 * view_ns;
        try testing.expectEqual(null, sdk.display.view());
    }

    test "a plugin's colour space hint goes with its lease on the view" {
        var a: FakePlugin = undefined;
        a.init("a");
        var game: FakePlugin = undefined;
        game.init("game");
        game.loaded.manifest.value.game = .{};
        {
            const acting = a.owner().enter();
            defer acting.end();
            sdk.display.setColorSpace(.hdr10);
            try testing.expectEqual(null, gfx.color_space_hint.get());
            _ = try sdk.display.claimView(.none);
            sdk.display.setColorSpace(.hdr10);
        }
        try testing.expectEqual(gfx.ColorSpace.hdr10, gfx.color_space_hint.get().?);

        // Kept for when the game's plugin gets the view, and the engine's goes back once it goes
        {
            const acting = game.owner().enter();
            defer acting.end();
            const lease = try sdk.display.claimView(.none);
            try testing.expect(lease.held());
            try testing.expectEqual(null, gfx.color_space_hint.get());
            sdk.display.setColorSpace(.scrgb);
        }
        try testing.expectEqual(gfx.ColorSpace.scrgb, gfx.color_space_hint.get().?);
        game.loaded.owner.close();
        game.loaded.deinitForTest();
        try testing.expectEqual(gfx.ColorSpace.hdr10, gfx.color_space_hint.get().?);
        a.loaded.owner.close();
        try testing.expectEqual(null, gfx.color_space_hint.get());
        a.loaded.deinitForTest();
    }

    test "the best placed plugin holds ticks, and hands them back as they go" {
        setFrames(true);
        defer setFrames(false);
        var a: FakePlugin = undefined;
        a.init("a");
        defer a.loaded.deinitForTest();
        var engine: FakePlugin = undefined;
        engine.init("engine");
        engine.loaded.manifest.value.gameEngine = .{ .id = "unity" };
        var game: FakePlugin = undefined;
        game.init("game");
        game.loaded.manifest.value.game = .{};

        var order: Order = .{};
        const sub = blk: {
            const acting = a.owner().enter();
            defer acting.end();
            break :blk try sdk.threads.onTick(&order, Order.onTick);
        };
        defer sub.unsubscribe();

        const engine_ticks = blk: {
            const acting = engine.owner().enter();
            defer acting.end();
            break :blk try sdk.threads.claimTicks(.none);
        };
        try testing.expect(engine_ticks.held());
        // Ticks wait for it now
        run();
        try testing.expectEqual(0, order.n);
        try testing.expect(!onGameThread());

        // From its own thread, which is the game thread now
        const t = try std.Thread.spawn(.{}, tickAs, .{&engine});
        t.join();
        try testing.expectEqual(1, order.n);
        try testing.expect(order.game_thread);
        try testing.expect(order.ticked_on != std.Thread.getCurrentId());
        try testing.expect(!onGameThread());

        // A plain plugin asking later doesn't win over a game engine's
        const plain_ticks = blk: {
            const acting = a.owner().enter();
            defer acting.end();
            break :blk try sdk.threads.claimTicks(.none);
        };
        try testing.expect(!plain_ticks.held());
        tickAs(&a);
        try testing.expectEqual(1, order.n);

        // A game's plugin does, even later
        {
            const acting = game.owner().enter();
            defer acting.end();
            _ = try sdk.threads.claimTicks(.none);
        }
        try testing.expect(!engine_ticks.held());
        tickAs(&engine);
        try testing.expectEqual(1, order.n);

        // The game's plugin going hands back to the engine's, then the plain one, then the render thread
        game.loaded.owner.close();
        game.loaded.deinitForTest();
        try testing.expect(engine_ticks.held());
        engine_ticks.release();
        engine_ticks.release();
        try testing.expect(plain_ticks.held());
        tickAs(&a);
        try testing.expectEqual(2, order.n);
        plain_ticks.release();
        run();
        try testing.expectEqual(3, order.n);
        try testing.expect(onGameThread());
        engine.loaded.deinitForTest();
    }
};

test {
    _ = tests;
}
