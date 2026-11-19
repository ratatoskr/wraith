//! Plugin tasks as fibers. A task starts on the render thread at the next frame. Waiting for a frame,
//! a message, a key or a capture parks it, and it carries on at the same point in a later frame, still
//! able to draw. `frame.toWorker` moves it to a worker thread for slow or blocking work and
//! `frame.toRender` brings it back. Code on the render thread holds up the game, so never block there.

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const sys = @import("tuft_sys");
const atomic = @import("tuft_arch").atomic;

const Owner = @import("Owner.zig");
const rt = @import("salamander_runtime");
const frame = @import("frame.zig");
const timing = @import("timing.zig");

const log = @import("log.zig").scoped(.wraith_sdk);

pub const Where = enum(u8) { render, worker };

pub const SpawnError = error{ OutOfMemory, FiberFailed, Canceled, OwnerGone };

/// What a parked task waits for. Any one of them resumes it.
pub const Wait = struct {
    /// Right away, at the next chance.
    now: bool = false,
    /// Once this many frames have run in all.
    frame: ?u64 = null,
    /// `timing.now()`. With `predicate` it's a timeout.
    deadline: ?u64 = null,
    /// Checked on the render thread each frame.
    predicate: ?Predicate = null,
    /// Once `wake` is called.
    signal: bool = false,
};

pub const Predicate = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque) bool,
};

threadlocal var running: ?*Task = null;

/// The task running on this thread, if it's one of ours. Not inlined, since a task can move threads
/// and a cached thread-local address would be the old thread's.
pub noinline fn current() ?*Task {
    return running;
}

pub const Task = struct {
    fiber: sys.fiber.Fiber = undefined,
    scheduler: *Scheduler,
    run: *const fn (task: *Task) void,
    free: *const fn (task: *Task) void,
    /// Where it runs, or will once it's resumed.
    where: Where = .render,
    wait: Wait = .{ .now = true },
    ready: Atomic(bool) = .init(false),
    state: Atomic(State) = .init(.parked),
    /// Set when a `predicate` wait ran out of time.
    timed_out: bool = false,
    /// Set when it couldn't get to a worker.
    no_worker: bool = false,

    const State = enum(u8) { parked, running, on_worker, done };

    /// From inside it. Resumes on `where` once `until` says. The scheduler stopping ends every wait.
    pub fn park(self: *Task, where: Where, until: Wait) error{Canceled}!void {
        if (self.scheduler.canceled.load(.acquire)) return error.Canceled;
        self.where = where;
        self.wait = until;
        self.timed_out = false;
        self.fiber.yield();
        if (self.scheduler.canceled.load(.acquire)) return error.Canceled;
    }

    /// Before handing out `wake`, for a `signal` wait.
    pub fn prepareSignal(self: *Task) void {
        self.ready.store(false, .release);
    }

    /// Any thread. Resumes a `signal` wait at the next frame.
    pub fn wake(self: *Task) void {
        self.ready.store(true, .release);
    }

    fn entry(f: *sys.fiber.Fiber) void {
        const self: *Task = @alignCast(@fieldParentPtr("fiber", f));
        self.run(self);
    }

    const Woke = enum { ok, timed_out };

    fn due(self: *Task, now: u64, frames: u64) ?Woke {
        if (self.scheduler.canceled.load(.acquire)) return .ok;
        const w = self.wait;
        if (w.now) return .ok;
        if (w.signal and self.ready.load(.acquire)) return .ok;
        if (w.frame) |f| if (frames >= f) return .ok;
        if (w.predicate) |p| if (p.func(p.ctx)) return .ok;
        if (w.deadline) |d| if (now >= d) return if (w.predicate != null) .timed_out else .ok;
        return null;
    }
};

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    owner: Owner,
    /// Worker hops run in it, so cancelling it reaches blocking calls on workers.
    group: *std.Io.Group,
    stack_size: usize = std.Thread.SpawnConfig.default_stack_size,
    lock: sys.sync.RwLock = .{},
    /// Under `lock`.
    tasks: std.ArrayList(*Task) = .empty,
    /// Render thread.
    batch: std.ArrayList(*Task) = .empty,
    /// Frames run so far.
    frames: atomic.Value(u64) = .init(0),
    /// Under `lock`.
    subscription: ?frame.FrameSubscription = null,
    /// No frames here, so tasks start on workers and render waits only end by cancelling.
    no_frames: bool = false,
    canceled: Atomic(bool) = .init(false),
    /// Inside the host's frame zone, so Timings shows what time went to resumed tasks.
    resumed_zone: timing.Zone = .init("task resumed"),
    worker_zone: timing.Zone = .init("task on worker"),
    /// Under `lock`.
    zones_listed: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, owner: Owner, group: *std.Io.Group) Scheduler {
        return .{ .allocator = allocator, .io = io, .owner = owner, .group = group };
    }

    /// After `cancel`.
    pub fn deinit(self: *Scheduler) void {
        self.tasks.deinit(self.allocator);
        self.batch.deinit(self.allocator);
    }

    pub fn frameCount(self: *const Scheduler) u64 {
        return self.frames.load(.acquire);
    }

    /// Runs `func(args...)` as a task, from the next frame. `func` returns `void` or an error union,
    /// whose errors get logged.
    pub fn spawn(self: *Scheduler, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) SpawnError!void {
        if (self.canceled.load(.acquire)) return error.Canceled;
        const Args = @TypeOf(args);
        const Closure = struct {
            task: Task,
            args: Args,

            fn run(task: *Task) void {
                const c: *@This() = @fieldParentPtr("task", task);
                const result = @call(.auto, func, c.args);
                switch (@typeInfo(@TypeOf(result))) {
                    .void => {},
                    .error_union => if (result) |_| {} else |err| {
                        const any: anyerror = err;
                        if (any != error.Canceled and any != error.OwnerGone) log.err("A task failed: {t}", .{any});
                    },
                    else => @compileError("A task returns void or an error union, found " ++ @typeName(@TypeOf(result))),
                }
            }

            fn free(task: *Task) void {
                const c: *@This() = @fieldParentPtr("task", task);
                c.task.scheduler.allocator.destroy(c);
            }
        };
        const c = try self.allocator.create(Closure);
        c.* = .{ .task = .{ .scheduler = self, .run = Closure.run, .free = Closure.free }, .args = args };
        c.task.fiber.init(Task.entry, .{ .stack_size = self.stack_size }) catch {
            self.allocator.destroy(c);
            return error.FiberFailed;
        };
        errdefer {
            c.task.fiber.deinit();
            self.allocator.destroy(c);
        }

        self.lock.lock();
        const start_on_worker = blk: {
            defer self.lock.unlock();
            if (self.subscription == null and !self.no_frames) {
                const acting = self.owner.enter();
                defer acting.end();
                if (!self.zones_listed) {
                    timing.list(&self.resumed_zone);
                    timing.list(&self.worker_zone);
                    self.zones_listed = true;
                }
                self.subscription = frame.onFrame(self, pump) catch |err| switch (err) {
                    error.NoFrames, error.Unsupported, error.Failed => sub: {
                        self.no_frames = true;
                        break :sub null;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                    error.OwnerGone => return error.OwnerGone,
                };
            }
            try self.tasks.append(self.allocator, &c.task);
            break :blk self.no_frames;
        };
        if (start_on_worker) self.sendToWorker(&c.task);
    }

    /// Render thread, once a frame, as the owner.
    fn pump(self: *Scheduler) void {
        const frames = self.frames.fetchAdd(1, .acq_rel) + 1;
        const now = timing.now();
        {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            self.batch.clearRetainingCapacity();
            self.batch.appendSlice(self.allocator, self.tasks.items) catch return;
        }
        // Ones resumed here and parked again wait for the next frame
        for (self.batch.items) |task| {
            if (task.state.load(.acquire) != .parked or task.where != .render) continue;
            const woke = task.due(now, frames) orelse continue;
            task.timed_out = woke == .timed_out;
            const timed = self.resumed_zone.begin();
            defer timed.end();
            self.step(task);
        }
        self.reap();
    }

    /// Runs it on this thread till it parks or ends, then sends it where it asked to go.
    fn step(self: *Scheduler, task: *Task) void {
        const previous = running;
        running = task;
        task.state.store(.running, .release);
        task.fiber.resumeHere();
        running = previous;
        // Only now is it off this thread, so only now can another pick it up
        if (task.fiber.finished) {
            task.state.store(.done, .release);
        } else if (task.where == .worker) {
            self.sendToWorker(task);
        } else {
            task.state.store(.parked, .release);
        }
    }

    fn sendToWorker(self: *Scheduler, task: *Task) void {
        task.state.store(.on_worker, .release);
        if (!self.canceled.load(.acquire)) {
            if (self.group.concurrent(self.io, hop, .{ self, task })) |_| return else |_| {}
            task.no_worker = true;
        }
        // It carries on on the render thread instead
        task.where = .render;
        task.wait = .{ .now = true };
        task.state.store(.parked, .release);
    }

    fn hop(self: *Scheduler, task: *Task) void {
        const acting = self.owner.enter();
        defer acting.end();
        while (true) {
            const previous = running;
            running = task;
            task.state.store(.running, .release);
            {
                const timed = self.worker_zone.begin();
                defer timed.end();
                task.fiber.resumeHere();
            }
            running = previous;
            if (task.fiber.finished) {
                task.state.store(.done, .release);
                return;
            }
            // Asked for a worker again while on one, so keep it here
            if (task.where == .worker and !self.canceled.load(.acquire)) continue;
            task.where = .render;
            task.state.store(.parked, .release);
            return;
        }
    }

    fn reap(self: *Scheduler) void {
        self.lock.lock();
        defer self.lock.unlock();
        var i: usize = 0;
        while (i < self.tasks.items.len) {
            const task = self.tasks.items[i];
            if (task.state.load(.acquire) != .done) {
                i += 1;
                continue;
            }
            _ = self.tasks.swapRemove(i);
            task.fiber.deinit();
            task.free(task);
        }
    }

    /// Ends every task. Their waits fail with `error.Canceled` so their `defer`s run, here on this thread.
    /// Call before the plugin's `stop`, and once nothing else will spawn.
    pub fn cancel(self: *Scheduler) void {
        if (self.canceled.swap(true, .acq_rel)) return;
        const acting = self.owner.enter();
        defer acting.end();
        // Waits for a frame in flight
        const subscription = blk: {
            self.lock.lock();
            defer self.lock.unlock();
            const s = self.subscription;
            self.subscription = null;
            break :blk s;
        };
        if (subscription) |s| s.unsubscribe();
        // Workers too, with their blocking calls cancelled
        self.group.cancel(self.io);
        if (self.zones_listed) {
            timing.unlist(&self.resumed_zone);
            timing.unlist(&self.worker_zone);
            self.zones_listed = false;
        }

        var left: std.ArrayList(*Task) = .empty;
        defer left.deinit(self.allocator);
        {
            self.lock.lock();
            defer self.lock.unlock();
            std.mem.swap(std.ArrayList(*Task), &left, &self.tasks);
        }
        for (left.items) |task| {
            var tries: u32 = 0;
            while (!task.fiber.finished and tries < 1000) : (tries += 1) {
                const previous = running;
                running = task;
                task.fiber.resumeHere();
                running = previous;
            }
            if (!task.fiber.finished) log.warn("A task kept going after being cancelled, so it was dropped mid-way", .{});
            task.fiber.deinit();
            task.free(task);
        }
    }
};

/// What `wait` gives: the promise's result, or that the wait was given up.
pub fn Waited(comptime P: type) type {
    const Extra = error{ Canceled, OnRenderThread };
    const A = rt.Awaited(P.Value);
    return switch (@typeInfo(A)) {
        .error_union => |eu| (eu.error_set || Extra)!eu.payload,
        else => Extra!A,
    };
}

/// Waits for an `async` call into Wraith, like `try sdk.tasks.wait(w.frame().next())`. A task parks
/// and carries on on the render thread at the frame after it settles. Elsewhere it blocks, so never
/// on the render thread. A task that's cancelled lets go of it.
pub fn wait(promise: anytype) Waited(@TypeOf(promise)) {
    if (promise.table == null) return promise.take().?;
    const t = current() orelse {
        if (frame.onRenderThread()) return error.OnRenderThread;
        return promise.wait();
    };
    if (!promise.isSettled()) {
        // On the heap, since the promise can settle after a cancelled task's gone
        const Waiter = struct {
            task: *Task,
            refs: Atomic(u8) = .init(2),
            const gpa = std.heap.smp_allocator;

            fn settled(self: *@This()) void {
                self.task.wake();
                self.release();
            }

            fn release(self: *@This()) void {
                if (self.refs.fetchSub(1, .acq_rel) == 1) gpa.destroy(self);
            }
        };
        const waiter = Waiter.gpa.create(Waiter) catch return promise.wait();
        waiter.* = .{ .task = t };
        t.prepareSignal();
        promise.then(waiter, Waiter.settled, .now);
        const parked = t.park(.render, .{ .signal = true });
        waiter.release();
        parked catch |err| {
            promise.cancel();
            return err;
        };
    }
    return promise.take().?;
}

const tests = struct {
    const testing = std.testing;
    const Fake = @import("testing.zig").Fake;

    const Rig = struct {
        fake: Fake = .{},
        group: std.Io.Group = .init,
        scheduler: Scheduler = undefined,

        fn init(self: *Rig) void {
            self.fake.attach();
            self.scheduler = .init(testing.allocator, testing.io, Owner.own().?, &self.group);
        }

        fn deinit(self: *Rig) void {
            self.scheduler.cancel();
            self.scheduler.deinit();
            self.fake.detach();
        }

        /// Frames on this thread, the render thread here, till `done` or it gives up.
        fn runUntil(self: *Rig, done: *const Atomic(bool)) !void {
            for (0..2000) |_| {
                if (done.load(.acquire)) return;
                self.fake.runFrame();
                try testing.io.sleep(.fromMilliseconds(1), .awake);
            }
            return error.TimedOut;
        }
    };

    fn threadId() u32 {
        return @intCast(std.Thread.getCurrentId());
    }

    const Flow = struct {
        frames: [8]u64 = @splat(0),
        threads: [8]u32 = @splat(0),
        n: usize = 0,
        sum: u32 = 0,
        go: Atomic(bool) = .init(false),
        done: Atomic(bool) = .init(false),

        fn note(self: *Flow, s: *Scheduler) void {
            self.frames[self.n] = s.frameCount();
            self.threads[self.n] = threadId();
            self.n += 1;
        }

        fn add(a: u32, b: u32) u32 {
            return a + b;
        }

        fn going(self: *Flow) bool {
            return self.go.load(.acquire);
        }

        fn run(self: *Flow, s: *Scheduler, io: std.Io) !void {
            defer self.done.store(true, .release);
            self.note(s);
            try frame.next(io);
            self.note(s);
            try frame.wait(io, 2);
            self.note(s);
            try frame.toWorker(io);
            self.note(s);
            // Back to the render thread to run it, then back here
            self.sum = try frame.onRender(io, add, .{ 2, 3 });
            self.note(s);
            try frame.toRender(io);
            self.note(s);
            try frame.until(io, going, .{self}, .{});
            self.note(s);
        }
    };

    test "tasks carry on at later frames, and move between threads" {
        var rig: Rig = .{};
        rig.init();
        defer rig.deinit();
        var flow: Flow = .{};
        try rig.scheduler.spawn(Flow.run, .{ &flow, &rig.scheduler, testing.io });
        // Nothing runs till a frame does
        try testing.expectEqual(0, flow.n);

        rig.fake.runFrame();
        rig.fake.runFrame();
        try testing.expectEqual(2, flow.n);
        try testing.expectEqualSlices(u64, &.{ 1, 2 }, flow.frames[0..2]);
        rig.fake.runFrame();
        rig.fake.runFrame();
        try testing.expectEqual(4, flow.frames[2]);
        while (flow.n < 6) {
            rig.fake.runFrame();
            try testing.io.sleep(.fromMilliseconds(1), .awake);
        }
        flow.go.store(true, .release);
        try rig.runUntil(&flow.done);

        const me = threadId();
        try testing.expectEqualSlices(u32, &.{ me, me, me }, flow.threads[0..3]);
        try testing.expect(flow.threads[3] != me);
        try testing.expect(flow.threads[4] != me);
        try testing.expectEqual(me, flow.threads[5]);
        try testing.expectEqual(me, flow.threads[6]);
        try testing.expectEqual(5, flow.sum);
        // Resumes show in Timings, apart from the frame
        try testing.expect(rig.scheduler.resumed_zone.figures().calls >= 6);
        try testing.expect(rig.scheduler.worker_zone.figures().calls >= 1);
    }

    test "worker fibers have room for large stack frames" {
        const Large = struct {
            done: Atomic(bool) = .init(false),
            thread: u32 = 0,
            sum: u64 = 0,

            noinline fn useStack() u64 {
                var bytes: [2 << 20]u8 = undefined;
                @memset(&bytes, 1);
                std.mem.doNotOptimizeAway(&bytes);
                var sum: u64 = 0;
                for (bytes) |b| sum += b;
                return sum;
            }

            fn run(self: *@This(), io: std.Io) !void {
                defer self.done.store(true, .release);
                try frame.toWorker(io);
                self.thread = threadId();
                self.sum = useStack();
                try frame.toRender(io);
            }
        };
        var rig: Rig = .{};
        rig.init();
        defer rig.deinit();
        var large: Large = .{};
        try rig.scheduler.spawn(Large.run, .{ &large, testing.io });
        try rig.runUntil(&large.done);
        try testing.expect(large.thread != threadId());
        try testing.expectEqual(@as(u64, 2 << 20), large.sum);
    }

    const Forever = struct {
        cleaned_up: bool = false,
        err: ?anyerror = null,

        fn run(self: *Forever, io: std.Io) !void {
            defer self.cleaned_up = true;
            frame.delay(io, .fromSeconds(3600)) catch |err| {
                self.err = err;
                return err;
            };
        }
    };

    test "cancelling ends waits and runs defers" {
        var rig: Rig = .{};
        rig.init();
        defer rig.deinit();
        var forever: Forever = .{};
        try rig.scheduler.spawn(Forever.run, .{ &forever, testing.io });
        rig.fake.runFrame();
        rig.fake.runFrame();
        try testing.expect(!forever.cleaned_up);
        const zones = rig.fake.zones;
        rig.scheduler.cancel();
        try testing.expect(forever.cleaned_up);
        try testing.expectEqual(zones - 2, rig.fake.zones);
        try testing.expectEqual(error.Canceled, forever.err.?);
        try testing.expectError(error.Canceled, rig.scheduler.spawn(Forever.run, .{ &forever, testing.io }));
    }

    test "without frames, tasks start on a worker" {
        var rig: Rig = .{};
        rig.init();
        defer rig.deinit();
        rig.fake.no_frames = true;
        const Started = struct {
            thread: Atomic(u32) = .init(0),
            forever: Forever = .{},
            fn run(self: *@This(), io: std.Io) !void {
                self.thread.store(threadId(), .release);
                return self.forever.run(io);
            }
        };
        var started: Started = .{};
        try rig.scheduler.spawn(Started.run, .{ &started, testing.io });
        while (started.thread.load(.acquire) == 0) try testing.io.sleep(.fromMilliseconds(1), .awake);
        try testing.expect(started.thread.load(.acquire) != threadId());
        rig.scheduler.cancel();
        try testing.expect(started.forever.cleaned_up);
    }

    const Awaiting = struct {
        done: Atomic(bool) = .init(false),
        thread: u32 = 0,

        fn run(self: *Awaiting) !void {
            defer self.done.store(true, .release);
            // Any `async` call, here the next frame's
            try wait(Owner.current().?.root.frame().next());
            self.thread = threadId();
        }
    };

    test "tasks wait for async calls" {
        var rig: Rig = .{};
        rig.init();
        defer rig.deinit();
        var awaiting: Awaiting = .{};
        try rig.scheduler.spawn(Awaiting.run, .{&awaiting});
        try rig.runUntil(&awaiting.done);
        try testing.expectEqual(threadId(), awaiting.thread);
    }
};

test {
    _ = tests;
}
