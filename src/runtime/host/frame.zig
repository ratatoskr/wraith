//! Frame service. Owners get a callback every frame and can post to the next one. Ticks are the
//! game thread's frames. With no driver they run on the render thread just before each frame. A
//! game engine or game plugin that knows the game's own thread drives them from there instead.

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const core = @import("wraith_core");
const api = @import("wraith_api");
const sync = @import("tuft_sys").sync;

const host = @import("root.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;
const Owner = @import("tuft_event").Owner;
const OnGone = @import("Owned.zig").OnGone;
const gfx = @import("tuft_gfx");

const Bus = core.Event(fn () void);
const W = api.wraith;
const log = core.log.scoped(.wraith_runtime);
/// From `frame.sal`, kept till it's cancelled.
pub const Tick = W.FrameTick;
/// From `frame.sal`, kept till it's cancelled.
pub const GameTick = W.GameTick;
/// From `frame.sal`, kept till it runs.
pub const Task = W.FrameTask;

var bus: Bus = .init(std.heap.page_allocator);
var tick_bus: Bus = .init(std.heap.page_allocator);

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

/// Render thread, each frame, inside the overlay's ImGui frame or a headless one. Ticks first,
/// unless a driver has them.
pub fn run() void {
    render_thread.store(std.Thread.getCurrentId(), .monotonic);
    const driven = blk: {
        // Shared, so the driver can't be freed under us
        drivers_lock.lockShared();
        defer drivers_lock.unlockShared();
        const d = active.load(.acquire) orelse break :blk false;
        d.checkStalled();
        break :blk true;
    };
    if (!driven) tickNow();
    bus.fire(.{});
    host.salamander.pollRender();
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
var game_view: W.GameView = .{ .view = .identity, .projection = .identity, .known = false };
/// `core.timing.now()` when it was set, under `view_lock`.
var view_at: u64 = 0;
/// Older than this and it's not known any more, since the plugin's stopped saying.
const view_ns = std.time.ns_per_s;

pub fn setView(view_: W.Mat4, projection: W.Mat4) void {
    view_lock.lock();
    defer view_lock.unlock();
    game_view = .{ .view = view_, .projection = projection, .known = true };
    view_at = core.timing.now();
}

pub fn view() W.GameView {
    view_lock.lockShared();
    defer view_lock.unlockShared();
    var v = game_view;
    v.known = v.known and core.timing.now() -| view_at < view_ns;
    return v;
}

/// Whose `setColorSpace` it is, so it goes with them.
var hint_owner: Atomic(usize) = .init(0);
var hint_cleanup: OnGone(.closing, hintGone) = .{};

pub fn setColorSpace(loaded: *Loaded, space: W.ColorSpace) void {
    const lease = hint_cleanup.lease(&loaded.owner) orelse return;
    defer lease.end();
    hint_owner.store(@intFromPtr(&loaded.owner), .release);
    gfx.color_space_hint.set(switch (space) {
        .srgb => .srgb,
        .scrgb => .scrgb,
        .hdr10 => .hdr10,
        _ => null,
    });
}

fn hintGone(owner: *Owner) void {
    if (hint_owner.cmpxchgStrong(@intFromPtr(owner), 0, .acq_rel, .acquire) == null) gfx.color_space_hint.set(null);
}

/// Skipped if a tick's already running on another thread.
fn tickNow() void {
    if (ticking.swap(true, .acquire)) return;
    defer ticking.store(false, .release);
    game_thread.store(std.Thread.getCurrentId(), .monotonic);
    tick_bus.fire(.{});
}

/// A plugin that ticks from the game's own thread. The best-ranked one is `active`.
pub const Driver = struct {
    loaded: *Loaded,
    /// A game's plugin 2, a game engine's 1, the rest 0.
    rank: u8,
    /// Ties go to the lowest.
    order: u64,
    released: bool = false,
    /// `core.timing.now()`, when it became active or last ticked.
    last_tick: Atomic(u64) = .init(0),
    warned: Atomic(bool) = .init(false),

    /// How long an active driver can go without ticking before it's logged.
    const stall_ns = 30 * std.time.ns_per_s;

    pub fn tick(self: *Driver) void {
        if (active.load(.acquire) != self) return;
        self.last_tick.store(core.timing.now(), .monotonic);
        tickNow();
    }

    pub fn isActive(self: *Driver) bool {
        return active.load(.acquire) == self;
    }

    /// Render thread, while it's active.
    fn checkStalled(self: *Driver) void {
        if (self.warned.load(.monotonic)) return;
        if (core.timing.now() -| self.last_tick.load(.monotonic) < stall_ns) return;
        if (self.warned.swap(true, .monotonic)) return;
        log.warn("{s} drives ticks but hasn't ticked in {d}s, so nothing's running on the game thread", .{ self.loaded.name, stall_ns / std.time.ns_per_s });
    }

    pub fn release(self: *Driver) void {
        drivers_lock.lock();
        defer drivers_lock.unlock();
        if (self.released) return;
        self.released = true;
        if (std.mem.indexOfScalar(*Driver, drivers.items, self)) |at| _ = drivers.orderedRemove(at);
        pickActive();
    }

    pub fn stop(self: *Driver) void {
        self.release();
    }

    pub fn free(self: *Driver) void {
        self.release();
        self.loaded.allocator.destroy(self);
    }
};

var drivers_lock: sync.RwLock = .{};
/// Under `drivers_lock`.
var drivers: std.ArrayList(*Driver) = .empty;
var next_order: u64 = 0;
var active: Atomic(?*Driver) = .init(null);
var driver_records: host.Owned(Driver) = .{};

/// Under `drivers_lock`.
fn pickActive() void {
    var best: ?*Driver = null;
    for (drivers.items) |d| {
        if (best == null or d.rank > best.?.rank or (d.rank == best.?.rank and d.order < best.?.order)) best = d;
    }
    if (active.load(.acquire) == best) return;
    if (best) |b| {
        b.last_tick.store(core.timing.now(), .monotonic);
        log.info("{s} drives ticks now", .{b.loaded.name});
    } else log.info("Ticks are back on the render thread", .{});
    // Not the game thread till the new one ticks
    game_thread.store(0, .monotonic);
    active.store(best, .release);
}

fn rankOf(loaded: *const Loaded) u8 {
    const m = loaded.manifest.value;
    if (m.game != null) return 2;
    if (m.gameEngine != null) return 1;
    return 0;
}

/// Through `frame.sal`.
pub fn driveTicks(loaded: *Loaded) api.FrameError!*Driver {
    const d = try loaded.allocator.create(Driver);
    d.* = .{ .loaded = loaded, .rank = rankOf(loaded), .order = 0 };
    driver_records.add(d) catch |err| {
        loaded.allocator.destroy(d);
        return if (err == error.OutOfMemory) error.OutOfMemory else error.OwnerGone;
    };
    drivers_lock.lock();
    defer drivers_lock.unlock();
    d.order = next_order;
    next_order += 1;
    drivers.append(std.heap.page_allocator, d) catch {
        // Owned frees it with the plugin
        d.released = true;
        return error.OutOfMemory;
    };
    pickActive();
    return d;
}

pub const Frame = struct {
    loaded: *Loaded,
    callback: Callback,
    subscription: Bus.Subscription = undefined,
    stopped: Atomic(bool) = .init(false),
    zone: core.timing.Zone,
    warned: bool = false,

    pub const Callback = union(enum) {
        /// Render thread, and can draw.
        frame: Tick,
        /// Game thread, and can't.
        game: GameTick,
    };

    fn fire(self: *Frame) void {
        const timed = self.zone.begin();
        defer timed.end();
        switch (self.callback) {
            .frame => host.ui.runAs(self.loaded, &self.warned, self, call),
            .game => |t| t.invoke(.{}),
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
        self.subscription.unsubscribe();
        core.timing.registry.remove(&self.zone);
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

/// Its frame callbacks that are still on.
pub fn countOf(loaded: *Loaded) u32 {
    return callbacks.count(&loaded.owner);
}

/// Through `frame.sal`. Released if it fails.
pub fn onFrame(loaded: *Loaded, tick: Tick) api.FrameError!*Frame {
    if (!frames.load(.acquire)) {
        tick.release();
        return error.NoFrames;
    }
    return subscribe(loaded, .{ .frame = tick }, &bus) catch |err| {
        tick.release();
        return err;
    };
}

/// Through `frame.sal`. Released if it fails. Fine without frames, since a driver can tick.
pub fn onTick(loaded: *Loaded, tick: GameTick) api.FrameError!*Frame {
    return subscribe(loaded, .{ .game = tick }, &tick_bus) catch |err| {
        tick.release();
        return err;
    };
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

        fn onFrame(self: *Order) void {
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
        const frame_sub = try sdk.frame.onFrame(&order, Order.onFrame);
        defer frame_sub.unsubscribe();
        const tick_sub = try sdk.frame.onTick(&order, Order.onTick);
        defer tick_sub.unsubscribe();
        run();
        run();
        try testing.expectEqualStrings("tftf", order.seen[0..order.n]);
        try testing.expect(order.game_thread);
        try testing.expect(sdk.frame.onGameThread());
    }

    fn tickOn(driver: sdk.frame.TickDriver) void {
        driver.tick();
    }

    test "the game's view, as its plugin last set it, till it's stale" {
        var a: FakePlugin = undefined;
        a.init("a");
        defer a.loaded.deinitForTest();
        const acting = a.owner().enter();
        defer acting.end();
        const math = sdk.math;

        try testing.expectEqual(null, sdk.frame.view());
        const moved = math.Mat4.translation(.{ .x = 2 });
        sdk.frame.setView(moved, .identity);
        const v = sdk.frame.view().?;
        try testing.expectEqual(moved, v.view);
        // A plugin that's stopped saying doesn't leave an old one
        view_at -|= 2 * view_ns;
        try testing.expectEqual(null, sdk.frame.view());
    }

    test "a plugin's colour space hint goes with it" {
        var a: FakePlugin = undefined;
        a.init("a");
        {
            const acting = a.owner().enter();
            defer acting.end();
            sdk.frame.setColorSpace(.hdr10);
        }
        try testing.expectEqual(gfx.ColorSpace.hdr10, gfx.color_space_hint.get().?);
        a.loaded.owner.close();
        try testing.expectEqual(null, gfx.color_space_hint.get());
        a.loaded.deinitForTest();
    }

    test "drivers take ticks by rank, and hand them back as they go" {
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
            break :blk try sdk.frame.onTick(&order, Order.onTick);
        };
        defer sub.unsubscribe();

        const engine_driver = blk: {
            const acting = engine.owner().enter();
            defer acting.end();
            break :blk try sdk.frame.driveTicks();
        };
        try testing.expect(engine_driver.active());
        // Ticks wait for the driver now
        run();
        try testing.expectEqual(0, order.n);
        try testing.expect(!onGameThread());

        // From its own thread, which is the game thread now
        const t = try std.Thread.spawn(.{}, tickOn, .{engine_driver});
        t.join();
        try testing.expectEqual(1, order.n);
        try testing.expect(order.game_thread);
        try testing.expect(order.ticked_on != std.Thread.getCurrentId());
        try testing.expect(!onGameThread());

        // A plain plugin asking later doesn't win over a game engine's
        const plain_driver = blk: {
            const acting = a.owner().enter();
            defer acting.end();
            break :blk try sdk.frame.driveTicks();
        };
        try testing.expect(!plain_driver.active());
        plain_driver.tick();
        try testing.expectEqual(1, order.n);

        // A game's plugin does, even later
        {
            const acting = game.owner().enter();
            defer acting.end();
            _ = try sdk.frame.driveTicks();
        }
        try testing.expect(!engine_driver.active());
        engine_driver.tick();
        try testing.expectEqual(1, order.n);

        // The game's plugin going hands back to the engine's, then the plain one, then the render thread
        game.loaded.owner.close();
        game.loaded.deinitForTest();
        try testing.expect(engine_driver.active());
        engine_driver.release();
        engine_driver.release();
        try testing.expect(plain_driver.active());
        plain_driver.tick();
        try testing.expectEqual(2, order.n);
        plain_driver.release();
        run();
        try testing.expectEqual(3, order.n);
        try testing.expect(onGameThread());
        engine.loaded.deinitForTest();
    }
};

test {
    _ = tests;
}
