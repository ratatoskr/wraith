//! Plugin tasks as fibers over Wraith's promises. A wait parks the task and resumes it on whichever
//! thread the promise settles on. Never block on the render or game thread.

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const sys = @import("tuft_sys");

const Owner = @import("Owner.zig");
const rt = @import("salamander_runtime");
const threads = @import("threads.zig");
const timing = @import("timing.zig");

const log = @import("log.zig").scoped(.wraith_sdk);

pub const Where = enum(u8) { render, worker, game };

pub const SpawnError = error{ OutOfMemory, FiberFailed, Canceled, OwnerGone };

threadlocal var running: ?*Task = null;
/// Set on the plugin's own workers, to their scheduler.
threadlocal var own_worker: ?*Scheduler = null;

/// The task on this thread. Not inlined: a task can move threads, staling a cached thread-local.
pub noinline fn current() ?*Task {
    return running;
}

noinline fn ownWorker() ?*Scheduler {
    return own_worker;
}

/// What a parked task is waiting for.
const Park = union(enum) {
    /// A promise from Wraith, which carries on where Wraith says. The task takes it.
    promise: rt.core.Promise,
    /// The scheduler's own, to get a woken task where it waited. Settled once it's carried on there.
    hop: rt.core.Promise,
    /// `wake`, from anywhere.
    signal,
    /// One of the plugin's own workers.
    worker,
    /// Not parked.
    none,
};

const State = enum(u8) {
    /// Someone's running it, or about to.
    running,
    /// Parked on a promise, with `waiter` listening.
    awaiting,
    /// Parked till `wake`, or with nowhere to go once cancelled. Whoever claims it runs it.
    parked,
    done,
};

pub const Task = struct {
    fiber: sys.fiber.Fiber = undefined,
    scheduler: *Scheduler,
    run: *const fn (task: *Task) void,
    free: *const fn (task: *Task) void,
    /// Where it runs, or will once it's resumed.
    where: Where = .render,
    park_on: Park = .none,
    state: Atomic(State) = .init(.running),
    /// Under `awaiting`.
    waiter: ?*Waiter = null,
    /// For a `signal` park.
    ready: Atomic(bool) = .init(false),
    /// Set when it couldn't get to a worker.
    no_worker: bool = false,

    /// From inside it. Returns once `wake` resumes it on `where`, or the scheduler stops.
    pub fn parkUntilWoken(self: *Task, where: Where) error{Canceled}!void {
        return self.yield(.signal, where);
    }

    /// Before handing out `wake`, for `parkUntilWoken`.
    pub fn prepareSignal(self: *Task) void {
        self.ready.store(false, .release);
    }

    /// Any thread. Resumes `parkUntilWoken` where it asked, at the next frame or tick, or on a worker.
    pub fn wake(self: *Task) void {
        self.ready.store(true, .release);
        if (self.state.cmpxchgStrong(.parked, .running, .acq_rel, .acquire) != null) return;
        if (self.scheduler.route(self)) self.scheduler.step(self);
    }

    /// From inside it: off its stack till `park` says, then back on `where`.
    fn yield(self: *Task, on: Park, where: Where) error{Canceled}!void {
        if (self.scheduler.canceled.load(.acquire)) return error.Canceled;
        self.park_on = on;
        self.where = where;
        self.fiber.yield();
        if (self.scheduler.canceled.load(.acquire)) return error.Canceled;
    }

    fn entry(f: *sys.fiber.Fiber) void {
        const self: *Task = @alignCast(@fieldParentPtr("fiber", f));
        self.run(self);
    }

    /// Lets go of what it parked on, once it's carrying on.
    fn unpark(self: *Task) void {
        switch (self.park_on) {
            .hop => |h| {
                _ = h.take(null);
                h.release();
            },
            else => {},
        }
        self.park_on = .none;
    }
};

/// Listens for a parked task's promise. Heap-allocated, since a queue may run it after the task's gone.
/// Whoever moves it from `parked` to `claimed` runs the task.
const Waiter = struct {
    task: *Task,
    state: Atomic(Phase) = .init(.registering),
    /// The thread registering it, where settling straight away just goes round again.
    on: std.Thread.Id,
    /// The promise's and the task's.
    refs: Atomic(u8) = .init(2),

    const Phase = enum(u8) { registering, parked, woken, claimed };
    const gpa = std.heap.smp_allocator;

    fn settled(w: *Waiter) void {
        defer w.release();
        while (true) switch (w.state.load(.acquire)) {
            .registering => {
                if (w.on == std.Thread.getCurrentId() and w.state.cmpxchgStrong(.registering, .woken, .acq_rel, .acquire) == null) return;
                std.atomic.spinLoopHint();
            },
            .parked => {
                const task = w.task;
                const scheduler = task.scheduler;
                // Left parked, so cancelling takes it on its own thread
                if (scheduler.canceled.load(.acquire)) return;
                if (w.state.cmpxchgStrong(.parked, .claimed, .acq_rel, .acquire) != null) continue;
                scheduler.claimed(task, w);
                if (scheduler.route(task)) scheduler.step(task);
                return;
            },
            .woken, .claimed => return,
        };
    }

    fn release(w: *Waiter) void {
        if (w.refs.fetchSub(1, .acq_rel) == 1) gpa.destroy(w);
    }
};

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    owner: Owner,
    /// The plugin's own workers, so cancelling it reaches blocking calls on them.
    group: *std.Io.Group,
    stack_size: usize = std.Thread.SpawnConfig.default_stack_size,
    lock: sys.sync.RwLock = .{},
    /// Under `lock`.
    tasks: std.ArrayList(*Task) = .empty,
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
    }

    /// Runs `func(args...)` as a task from the next frame, or on a worker without frames. Errors are logged.
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
        const acting = self.owner.enter();
        defer acting.end();
        {
            self.lock.lock();
            defer self.lock.unlock();
            if (!self.zones_listed) {
                timing.list(&self.resumed_zone);
                timing.list(&self.worker_zone);
                self.zones_listed = true;
            }
            try self.tasks.append(self.allocator, &c.task);
        }
        const task = &c.task;
        const start = self.owner.root.threads().nextDraw();
        // Refused straight away, like with no frames
        if (start.table == null or start.isSettled()) {
            if (start.table != null) _ = start.take();
            task.where = .worker;
            if (self.toOwnWorker(task)) self.step(task);
            return;
        }
        const raw: rt.core.Promise = .{ .data = start.data, .table = start.table };
        task.park_on = .{ .hop = raw };
        if (self.listen(task, raw)) self.step(task);
    }

    /// Runs `task`, which this thread has claimed, till it parks or ends.
    fn step(self: *Scheduler, task: *Task) void {
        const acting = self.owner.enter();
        defer acting.end();
        const zone = if (ownWorker() == self) &self.worker_zone else &self.resumed_zone;
        while (true) {
            {
                const timed = zone.begin();
                defer timed.end();
                const previous = running;
                running = task;
                task.fiber.resumeHere();
                running = previous;
            }
            if (task.fiber.finished) return self.finish(task);
            // Off its stack now, so whatever it parked on can resume it anywhere
            if (!self.parked(task)) return;
        }
    }

    /// Just after `task` parked on this thread. True if it carries on right here.
    fn parked(self: *Scheduler, task: *Task) bool {
        switch (task.park_on) {
            .worker => return self.toOwnWorker(task),
            .none => return true,
            .promise, .hop => |p| return self.listen(task, p),
            .signal => {
                task.state.store(.parked, .release);
                // Woken before it was off its stack
                if (!task.ready.load(.acquire)) return false;
                if (task.state.cmpxchgStrong(.parked, .running, .acq_rel, .acquire) != null) return false;
                return self.route(task);
            },
        }
    }

    /// Waits for `p`. True if it settled while registering, so `task` carries on right here.
    fn listen(self: *Scheduler, task: *Task, p: rt.core.Promise) bool {
        _ = self;
        const w = Waiter.gpa.create(Waiter) catch {
            // Out of memory, so it waits right here
            while (!p.isSettled()) std.Thread.yield() catch {};
            task.unpark();
            return true;
        };
        w.* = .{ .task = task, .on = std.Thread.getCurrentId() };
        task.waiter = w;
        task.state.store(.awaiting, .release);
        p.then(rt.Task.init(w, Waiter.settled), .{});
        if (w.state.cmpxchgStrong(.registering, .parked, .acq_rel, .acquire) == null) return false;
        task.state.store(.running, .release);
        task.waiter = null;
        w.release();
        task.unpark();
        return true;
    }

    /// `task` was claimed through `w`.
    fn claimed(self: *Scheduler, task: *Task, w: *Waiter) void {
        _ = self;
        task.waiter = null;
        task.state.store(.running, .release);
        w.release();
        task.unpark();
    }

    /// Gets a claimed `task` to where it carries on. True if that's right here, so the caller runs it.
    fn route(self: *Scheduler, task: *Task) bool {
        if (self.canceled.load(.acquire)) {
            // Cancelling takes it from here
            task.state.store(.parked, .release);
            return false;
        }
        if (task.where == .worker) {
            if (ownWorker() == self) return true;
            return self.toOwnWorker(task);
        }
        // A wake can come from any thread, so it resumes at the next frame or tick
        if (task.park_on != .signal) return true;
        const f = self.owner.root.threads();
        const hop = if (task.where == .render) f.nextDraw() else f.nextTick();
        if (hop.table == null) return true;
        const raw: rt.core.Promise = .{ .data = hop.data, .table = hop.table };
        task.park_on = .{ .hop = raw };
        return self.listen(task, raw);
    }

    /// Sends `task` to one of the plugin's workers. True if it couldn't, so it carries on here.
    fn toOwnWorker(self: *Scheduler, task: *Task) bool {
        task.state.store(.running, .release);
        if (!self.canceled.load(.acquire)) {
            if (self.group.concurrent(self.io, onWorker, .{ self, task })) |_| return false else |_| {}
        }
        task.no_worker = true;
        if (self.canceled.load(.acquire)) {
            task.state.store(.parked, .release);
            return false;
        }
        return true;
    }

    fn onWorker(self: *Scheduler, task: *Task) void {
        const previous = own_worker;
        own_worker = self;
        defer own_worker = previous;
        task.where = .worker;
        self.step(task);
    }

    /// Frees it unless `cancel` has it.
    fn finish(self: *Scheduler, task: *Task) void {
        const mine = blk: {
            self.lock.lock();
            defer self.lock.unlock();
            const i = std.mem.indexOfScalar(*Task, self.tasks.items, task) orelse break :blk false;
            _ = self.tasks.swapRemove(i);
            break :blk true;
        };
        if (!mine) return task.state.store(.done, .release);
        task.fiber.deinit();
        task.free(task);
    }

    /// Cancels every task, running their `defer`s on this thread. Call before `stop`, once nothing spawns.
    pub fn cancel(self: *Scheduler) void {
        if (self.canceled.swap(true, .acq_rel)) return;
        const acting = self.owner.enter();
        defer acting.end();
        // Workers first, with their blocking calls cancelled
        self.group.cancel(self.io);
        var left: std.ArrayList(*Task) = .empty;
        defer left.deinit(self.allocator);
        {
            self.lock.lock();
            defer self.lock.unlock();
            std.mem.swap(std.ArrayList(*Task), &left, &self.tasks);
            if (self.zones_listed) {
                timing.unlist(&self.resumed_zone);
                timing.unlist(&self.worker_zone);
                self.zones_listed = false;
            }
        }
        for (left.items) |task| {
            if (self.take(task)) self.unwind(task);
            task.fiber.deinit();
            task.free(task);
        }
    }

    /// Claims `task` for `cancel` once it's parked, waiting for it to get there. False if it ended.
    fn take(self: *Scheduler, task: *Task) bool {
        _ = self;
        var tries: u32 = 0;
        while (true) : (tries += 1) {
            switch (task.state.load(.acquire)) {
                .done => return false,
                .parked => if (task.state.cmpxchgStrong(.parked, .running, .acq_rel, .acquire) == null) return true,
                .awaiting => if (task.waiter) |w| if (w.state.cmpxchgStrong(.parked, .claimed, .acq_rel, .acquire) == null) {
                    // Its waiter may never run now
                    const p = switch (task.park_on) {
                        .promise, .hop => |p| p,
                        else => null,
                    };
                    task.waiter = null;
                    task.state.store(.running, .release);
                    w.release();
                    if (task.park_on == .hop) {
                        p.?.cancel();
                        task.park_on = .none;
                    }
                    return true;
                },
                .running => {},
            }
            if (tries == 5000) log.warn("Waiting for a task to stop running so it can be cancelled", .{});
            std.Thread.yield() catch {};
        }
    }

    /// Runs a cancelled task here till it ends. Its waits fail straight away.
    fn unwind(self: *Scheduler, task: *Task) void {
        _ = self;
        var tries: u32 = 0;
        while (!task.fiber.finished and tries < 1000) : (tries += 1) {
            const previous = running;
            running = task;
            task.fiber.resumeHere();
            running = previous;
        }
        if (!task.fiber.finished) log.warn("A task kept going after being cancelled, so it was dropped mid-way", .{});
    }
};

/// What `wait` gives: the promise's result, or that the wait was given up.
pub fn Waited(comptime P: type) type {
    const Extra = error{ Canceled, OnRenderThread, OnGameThread };
    const A = rt.Awaited(P.Value);
    return switch (@typeInfo(A)) {
        .error_union => |eu| (eu.error_set || Extra)!eu.payload,
        else => Extra!A,
    };
}

/// Waits for an `async` Wraith call, like `try sdk.tasks.wait(w.images().load(path))`.
/// Blocks outside a task, so never on the render or game thread.
pub fn wait(promise: anytype) Waited(@TypeOf(promise)) {
    if (promise.table == null) return promise.take().?;
    const t = current() orelse {
        if (threads.onRenderThread()) return error.OnRenderThread;
        if (threads.onGameThread()) return error.OnGameThread;
        return promise.wait();
    };
    if (!promise.isSettled()) try park(t, promise, t.where);
    return promise.take().?;
}

/// Parks `t` on `promise`, resuming on `to`, even if settled. `t` takes ownership.
pub fn park(t: *Task, promise: anytype, to: Where) error{Canceled}!void {
    const was = t.where;
    t.yield(.{ .promise = .{ .data = promise.data, .table = promise.table } }, to) catch |err| {
        promise.cancel();
        t.where = was;
        return err;
    };
}

/// From inside a task: on to one of the plugin's own workers. Error if it couldn't get one.
pub fn toOwnWorker(t: *Task) error{ Canceled, NoWorker }!void {
    if (t.where == .worker) return;
    const was = t.where;
    try t.yield(.worker, .worker);
    if (t.no_worker) {
        t.no_worker = false;
        t.where = was;
        return error.NoWorker;
    }
}

const tests = struct {
    const testing = std.testing;
    const Fake = @import("testing.zig").Fake;

    const Rig = struct {
        fake: Fake = .{},
        group: std.Io.Group = .init,
        scheduler: Scheduler = undefined,
        /// Frames run so far.
        frames: Atomic(u32) = .init(0),

        fn init(self: *Rig) void {
            self.fake.attach();
            self.scheduler = .init(testing.allocator, testing.io, Owner.own().?, &self.group);
        }

        fn deinit(self: *Rig) void {
            self.scheduler.cancel();
            self.scheduler.deinit();
            self.fake.detach();
        }

        fn frame(self: *Rig) void {
            _ = self.frames.fetchAdd(1, .acq_rel);
            self.fake.runFrame();
        }

        /// Frames on this thread, the render thread here, till `done` or it gives up.
        fn runUntil(self: *Rig, done: *const Atomic(bool)) !void {
            for (0..2000) |_| {
                if (done.load(.acquire)) return;
                self.frame();
                try testing.io.sleep(.fromMilliseconds(1), .awake);
            }
            return error.TimedOut;
        }
    };

    fn threadId() u32 {
        return @intCast(std.Thread.getCurrentId());
    }

    const Flow = struct {
        frames: [8]u32 = @splat(0),
        threads: [8]u32 = @splat(0),
        n: usize = 0,
        sum: u32 = 0,
        go: Atomic(bool) = .init(false),
        done: Atomic(bool) = .init(false),

        fn note(self: *Flow, rig: *Rig) void {
            self.frames[self.n] = rig.frames.load(.acquire);
            self.threads[self.n] = threadId();
            self.n += 1;
        }

        fn add(a: u32, b: u32) u32 {
            return a + b;
        }

        fn going(self: *Flow) bool {
            return self.go.load(.acquire);
        }

        fn run(self: *Flow, rig: *Rig, io: std.Io) !void {
            defer self.done.store(true, .release);
            self.note(rig);
            try threads.nextDraw(io);
            self.note(rig);
            try threads.waitDraws(io, 2);
            self.note(rig);
            try threads.toWorker(io);
            self.note(rig);
            // Back to the render thread to run it, then back here
            self.sum = try threads.onRender(io, add, .{ 2, 3 });
            self.note(rig);
            try threads.toRender(io);
            self.note(rig);
            try threads.until(io, going, .{self}, .{});
            self.note(rig);
        }
    };

    test "tasks carry on at later frames, and move between threads" {
        var rig: Rig = .{};
        rig.init();
        defer rig.deinit();
        var flow: Flow = .{};
        try rig.scheduler.spawn(Flow.run, .{ &flow, &rig, testing.io });
        // Nothing runs till a frame does
        try testing.expectEqual(0, flow.n);

        rig.frame();
        rig.frame();
        try testing.expectEqual(2, flow.n);
        try testing.expectEqualSlices(u32, &.{ 1, 2 }, flow.frames[0..2]);
        rig.frame();
        rig.frame();
        try testing.expectEqual(4, flow.frames[2]);
        while (flow.n < 6) {
            rig.frame();
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

    const GameHop = struct {
        threads: [4]u32 = @splat(0),
        on_game: [4]bool = @splat(false),
        n: usize = 0,
        done: Atomic(bool) = .init(false),

        fn note(self: *GameHop) void {
            self.threads[self.n] = threadId();
            self.on_game[self.n] = threads.onGameThread();
            self.n += 1;
        }

        fn run(self: *GameHop, io: std.Io) !void {
            defer self.done.store(true, .release);
            try threads.toGame(io);
            self.note();
            // Frame waits carry on on the render thread
            try threads.nextDraw(io);
            self.note();
            try threads.toGame(io);
            try threads.nextTick(io);
            self.note();
            try threads.toRender(io);
            self.note();
        }

        fn ticks(self: *GameHop, fake: *Fake) void {
            while (!self.done.load(.acquire)) {
                fake.runTick();
                testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
            }
        }
    };

    test "tasks move to the game thread and back" {
        var rig: Rig = .{};
        rig.fake.driven = true;
        rig.init();
        defer rig.deinit();
        var hop: GameHop = .{};
        try rig.scheduler.spawn(GameHop.run, .{ &hop, testing.io });
        // Its own thread, like a game engine's main thread
        const ticker = try std.Thread.spawn(.{}, GameHop.ticks, .{ &hop, &rig.fake });
        defer ticker.join();
        try rig.runUntil(&hop.done);

        const me = threadId();
        try testing.expectEqual(4, hop.n);
        try testing.expect(hop.threads[0] != me);
        try testing.expect(hop.on_game[0]);
        try testing.expectEqual(me, hop.threads[1]);
        try testing.expect(!hop.on_game[1]);
        try testing.expectEqual(hop.threads[0], hop.threads[2]);
        try testing.expect(hop.on_game[2]);
        try testing.expectEqual(me, hop.threads[3]);
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
                try threads.toWorker(io);
                self.thread = threadId();
                self.sum = useStack();
                try threads.toRender(io);
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
        cleaned_up: Atomic(bool) = .init(false),
        err: ?anyerror = null,

        fn run(self: *Forever, io: std.Io) !void {
            defer self.cleaned_up.store(true, .release);
            threads.delay(io, .fromSeconds(3600)) catch |err| {
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
        rig.frame();
        rig.frame();
        try testing.expect(!forever.cleaned_up.load(.acquire));
        const zones = rig.fake.zones;
        rig.scheduler.cancel();
        try testing.expect(forever.cleaned_up.load(.acquire));
        try testing.expectEqual(zones - 2, rig.fake.zones);
        try testing.expectEqual(error.Canceled, forever.err.?);
        try testing.expectError(error.Canceled, rig.scheduler.spawn(Forever.run, .{ &forever, testing.io }));
    }

    test "without frames, tasks start on a worker, and cancelling reaches their blocking calls" {
        var rig: Rig = .{};
        rig.init();
        defer rig.deinit();
        rig.fake.no_frames = true;
        const Started = struct {
            thread: Atomic(u32) = .init(0),
            forever: Forever = .{},
            fn run(self: *@This(), io: std.Io) !void {
                self.thread.store(threadId(), .release);
                // Sleeps on the plugin's own worker, on its `io`
                return self.forever.run(io);
            }
        };
        var started: Started = .{};
        try rig.scheduler.spawn(Started.run, .{ &started, testing.io });
        while (started.thread.load(.acquire) == 0) try testing.io.sleep(.fromMilliseconds(1), .awake);
        try testing.expect(started.thread.load(.acquire) != threadId());
        rig.scheduler.cancel();
        try testing.expect(started.forever.cleaned_up.load(.acquire));
        try testing.expectEqual(error.Canceled, started.forever.err.?);
    }

    const Awaiting = struct {
        done: Atomic(bool) = .init(false),
        thread: u32 = 0,

        fn run(self: *Awaiting) !void {
            defer self.done.store(true, .release);
            // Any `async` call, here the next frame's
            try wait(Owner.current().?.root.threads().nextDraw());
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

    const OnWorker = struct {
        done: Atomic(bool) = .init(false),
        worker: u32 = 0,
        after: u32 = 0,

        fn run(self: *OnWorker, io: std.Io) !void {
            defer self.done.store(true, .release);
            try threads.toWorker(io);
            self.worker = threadId();
            try wait(Owner.current().?.root.threads().nextDraw());
            self.after = threadId();
        }
    };

    test "a task on a worker carries on on one after it waits" {
        var rig: Rig = .{};
        rig.init();
        defer rig.deinit();
        var on: OnWorker = .{};
        try rig.scheduler.spawn(OnWorker.run, .{ &on, testing.io });
        try rig.runUntil(&on.done);
        try testing.expect(on.worker != threadId());
        try testing.expect(on.after != threadId());
    }

    const Woken = struct {
        task: Atomic(?*Task) = .init(null),
        thread: u32 = 0,
        done: Atomic(bool) = .init(false),

        fn run(self: *Woken) !void {
            defer self.done.store(true, .release);
            const t = current().?;
            t.prepareSignal();
            self.task.store(t, .release);
            try t.parkUntilWoken(.render);
            self.thread = threadId();
        }

        fn wakeIt(self: *Woken) void {
            while (self.task.load(.acquire) == null) std.Thread.yield() catch {};
            self.task.load(.acquire).?.wake();
        }
    };

    test "a wake from another thread carries on where the task waited, at the next frame" {
        var rig: Rig = .{};
        rig.init();
        defer rig.deinit();
        var woken: Woken = .{};
        try rig.scheduler.spawn(Woken.run, .{&woken});
        rig.frame();
        const waker = try std.Thread.spawn(.{}, Woken.wakeIt, .{&woken});
        waker.join();
        try testing.expect(!woken.done.load(.acquire));
        try rig.runUntil(&woken.done);
        try testing.expectEqual(threadId(), woken.thread);
    }
};

test {
    _ = tests;
}
