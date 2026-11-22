//! Per-frame callbacks and posts on the render thread, per-tick callbacks on the game thread, and
//! waits for tasks.
//!
//! In a task from `ctx.spawn`, waits like `try frame.next(io)` carry on at the same point in a later
//! frame, on the render thread, so the code after them can draw. `frame.toWorker` moves the task to a
//! worker for slow or blocking work, `frame.toGame` to the game thread, and `frame.toRender` brings
//! it back.
//!
//! Ticks run on the game thread. That's the render thread just before each frame, unless a game
//! engine or game plugin drives them from the game's own thread with `driveTicks`.
//!
//! On any other thread, like from `io.concurrent`, waits block that thread. So never wait on the
//! render thread, the game thread or in hooks there.

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const api = @import("wraith_api");
const Owner = @import("Owner.zig");
const timing = @import("timing.zig");
const tasks = @import("tasks.zig");

const sal = api.salamander;
const W = api.wraith;

pub const PostStatus = api.PostStatus;

pub const Error = error{ NoFrames, Failed, OwnerGone, OutOfMemory, Unsupported };

fn frameError(err: anyerror) Error {
    return switch (err) {
        error.NoFrames => error.NoFrames,
        error.Gone => error.OwnerGone,
        error.Unsupported => error.Unsupported,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Failed,
    };
}

pub const WaitError = Error || std.Io.Cancelable || error{
    /// It'd wait for a frame that can't come till it returns.
    OnRenderThread,
    /// It'd hold up the game, maybe for good if the render thread's waiting on it.
    OnGameThread,
};

/// The last thread a frame ran on. 0 till the first.
var render_thread: Atomic(std.Thread.Id) = .init(0);

fn seenRenderThread() void {
    render_thread.store(std.Thread.getCurrentId(), .monotonic);
}

/// True inside frame callbacks, posts and anything else on the render thread once a frame's run.
pub fn onRenderThread() bool {
    const id = render_thread.load(.monotonic);
    return id != 0 and id == std.Thread.getCurrentId();
}

pub const FrameSubscription = struct {
    object: W.FrameSubscription,

    /// Waits for a call in flight, unless it's from inside one.
    pub fn unsubscribe(self: FrameSubscription) void {
        self.object.cancel();
    }
};

/// Calls `func(target)` once a frame on the render thread, inside an ImGui frame, so it can update and
/// draw UI. When the overlay can't draw, the ImGui frame is a headless one nobody sees, so UI calls do nothing.
pub fn onFrame(target: anytype, comptime func: fn (@TypeOf(target)) void) Error!FrameSubscription {
    const T = @TypeOf(target);
    if (@typeInfo(T) != .pointer) @compileError("onFrame expects a pointer, found " ++ @typeName(T));
    const owner = Owner.current() orelse return error.OwnerGone;

    const Wrap = struct {
        fn call(t: T) void {
            seenRenderThread();
            func(t);
        }
    };
    const tick = W.FrameTick.init(target, Wrap.call);
    const sub = owner.root.frame().onFrame(tick) catch |err| return frameError(err);
    return .{ .object = sub };
}

/// Whether this is the game thread, where ticks run. False everywhere till the first tick, and
/// while a new driver's waiting for its first.
pub fn onGameThread() bool {
    const owner = Owner.current() orelse return false;
    return owner.root.frame().onGameThread();
}

/// Calls `func(target)` once a tick on the game thread, where the game's own code runs, like a
/// game engine's main thread. No drawing. That's the render thread just before each frame unless a
/// plugin drives ticks.
pub fn onTick(target: anytype, comptime func: fn (@TypeOf(target)) void) Error!FrameSubscription {
    const T = @TypeOf(target);
    if (@typeInfo(T) != .pointer) @compileError("onTick expects a pointer, found " ++ @typeName(T));
    const owner = Owner.current() orelse return error.OwnerGone;
    const tick = W.GameTick.init(target, func);
    const sub = owner.root.frame().onTick(tick) catch |err| return frameError(err);
    return .{ .object = sub };
}

/// Ticks from the game's own thread, from `driveTicks`.
pub const TickDriver = struct {
    object: W.TickDriver,

    /// Once a game frame, on the game's thread. Runs every `onTick`, and tasks waiting for one.
    /// Does nothing unless it's active.
    pub fn tick(self: TickDriver) void {
        self.object.tick();
    }

    /// Whether its ticks count. A game's plugin wins over a game engine's, which wins over the
    /// rest, and the first to ask wins a tie.
    pub fn active(self: TickDriver) bool {
        return self.object.active();
    }

    /// Hands ticks to the next driver, or back to the render thread. Fine to call twice. It
    /// happens anyway when the plugin goes.
    pub fn release(self: TickDriver) void {
        self.object.release();
    }
};

/// Takes over ticks, for a game engine or game plugin that knows the game's own thread. Ticks wait
/// for its first `tick`, so ask in `start`, before anything subscribes.
pub fn driveTicks() Error!TickDriver {
    const owner = Owner.current() orelse return error.OwnerGone;
    const d = owner.root.frame().driveTicks() catch |err| return frameError(err);
    return .{ .object = d };
}

/// Runs once next frame, from any thread, or with `.cancelled` if the plugin's going first.
/// Never called on error.
pub fn post(target: anytype, comptime func: fn (@TypeOf(target), PostStatus) void) Error!void {
    const T = @TypeOf(target);
    if (@typeInfo(T) != .pointer) @compileError("post expects a pointer, found " ++ @typeName(T));
    const owner = Owner.current() orelse return error.OwnerGone;

    const Next = sal.Plain(W.Frame, "next");
    const Posted = struct {
        target: T,
        promise: Next,

        const gpa = std.heap.smp_allocator;

        fn settled(self: *@This()) void {
            const t = self.target;
            const result = self.promise.take();
            gpa.destroy(self);
            const ran = if (result) |r| if (r) |_| true else |_| false else false;
            if (ran) seenRenderThread();
            func(t, if (ran) .run else .cancelled);
        }
    };
    const promise = owner.root.frame().next();
    if (promise.table == null) return error.OwnerGone;
    // Refused straight away, like with no frames
    if (promise.isSettled()) {
        const result = promise.take() orelse return error.Failed;
        result catch |err| return frameError(err);
        return error.Failed;
    }
    const p = Posted.gpa.create(Posted) catch {
        promise.cancel();
        return error.OutOfMemory;
    };
    p.* = .{ .target = target, .promise = promise };
    promise.then(p, Posted.settled, .now);
}

fn ReturnOf(comptime func: anytype) type {
    return @typeInfo(@TypeOf(func)).@"fn".return_type.?;
}

/// Runs `func(args...)` on the render thread at the start of the next frame and gives back what it returned.
/// It's inside the frame's ImGui frame, so it can draw UI like a frame callback.
/// Cancelling it before it starts means it won't run.
pub fn onRender(io: std.Io, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) WaitError!ReturnOf(func) {
    // A task goes there itself, then back where it was
    if (tasks.current()) |t| {
        const was = t.where;
        try t.park(.render, .{ .frame = t.scheduler.frameCount() + 1 });
        const result = @call(.auto, func, args);
        switch (was) {
            .worker => toWorker(io) catch {},
            .game => toGame(io) catch {},
            .render => {},
        }
        return result;
    }
    if (onRenderThread()) return error.OnRenderThread;
    if (onGameThread()) return error.OnGameThread;
    const R = ReturnOf(func);
    const Args = @TypeOf(args);

    // On the heap so a cancelled task can leave while the post still points here
    const Call = struct {
        io: std.Io,
        args: Args,
        result: R = undefined,
        state: Atomic(State) = .init(.waiting),
        done: std.Io.Event = .unset,
        refs: Atomic(u8) = .init(2),

        const State = enum(u8) { waiting, running, dropped };
        const gpa = std.heap.smp_allocator;

        fn run(self: *@This(), status: PostStatus) void {
            defer self.release();
            defer self.done.set(self.io);
            if (status != .run) return;
            if (self.state.cmpxchgStrong(.waiting, .running, .acq_rel, .acquire) != null) return;
            self.result = @call(.auto, func, self.args);
        }

        fn release(self: *@This()) void {
            if (self.refs.fetchSub(1, .acq_rel) == 1) gpa.destroy(self);
        }
    };

    const call = Call.gpa.create(Call) catch return error.OutOfMemory;
    call.* = .{ .io = io, .args = args };
    post(call, Call.run) catch |err| {
        Call.gpa.destroy(call);
        return err;
    };
    defer call.release();
    call.done.wait(io) catch |err| {
        // Already running means it might be using our args, so let it finish
        if (call.state.cmpxchgStrong(.waiting, .dropped, .acq_rel, .acquire) != null) call.done.waitUncancelable(io);
        return err;
    };
    if (call.state.load(.acquire) != .running) return error.OwnerGone;
    return call.result;
}

fn nothing() void {}

/// Waits for the next frame. A task carries on there on the render thread, and can draw.
pub fn next(io: std.Io) WaitError!void {
    return wait(io, 1);
}

/// Waits `frames` frames.
pub fn wait(io: std.Io, frames: u32) WaitError!void {
    if (frames == 0) return;
    if (tasks.current()) |t| return t.park(.render, .{ .frame = t.scheduler.frameCount() + frames });
    for (0..frames) |_| try onRender(io, nothing, .{});
}

/// A task carries on at the first frame after `duration`, on the render thread. Elsewhere it's `io.sleep`
/// on the awake clock. To sleep on a worker without leaving it, use `io.sleep`.
pub fn delay(io: std.Io, duration: std.Io.Duration) std.Io.Cancelable!void {
    if (tasks.current()) |t| {
        const ns: u64 = @intCast(@max(0, duration.toNanoseconds()));
        return t.park(.render, .{ .deadline = timing.now() +| ns });
    }
    return io.sleep(duration, .awake);
}

pub const MoveError = std.Io.Cancelable || error{
    /// Only tasks from `ctx.spawn` can move.
    NotInTask,
    /// Couldn't get a worker thread, so it's still on the render thread.
    NoWorker,
};

/// Moves the task to a worker thread, keeping its fiber stack. Blocking and slow work is fine. Drawing isn't.
pub fn toWorker(io: std.Io) MoveError!void {
    _ = io;
    const t = tasks.current() orelse return error.NotInTask;
    if (t.where == .worker) return;
    try t.park(.worker, .{ .now = true });
    if (t.no_worker) {
        t.no_worker = false;
        return error.NoWorker;
    }
}

/// Moves the task back to the render thread, where it can draw. It carries on at the next frame's
/// task point, which may still be this frame's.
pub fn toRender(io: std.Io) MoveError!void {
    _ = io;
    const t = tasks.current() orelse return error.NotInTask;
    if (t.where == .render) return;
    try t.park(.render, .{ .now = true });
}

/// Moves the task to the game thread, where the game's own code runs, at its next tick. Engine
/// calls that need the game's main thread work there. Drawing doesn't, and never block there.
/// Frame waits like `next` carry on on the render thread, so come back after them.
pub fn toGame(io: std.Io) MoveError!void {
    _ = io;
    const t = tasks.current() orelse return error.NotInTask;
    if (t.where == .game) return;
    try t.park(.game, .{ .now = true });
}

/// Waits for the next tick. A task carries on there on the game thread.
pub fn nextTick(io: std.Io) MoveError!void {
    _ = io;
    const t = tasks.current() orelse return error.NotInTask;
    try t.park(.game, .{ .now = true });
}

pub const UntilOptions = struct {
    /// Gives up with `error.Timeout` after this long.
    timeout: ?std.Io.Duration = null,
};

/// Waits till `predicate(args...)` is true, checked on the render thread once a frame.
pub fn until(io: std.Io, comptime predicate: anytype, args: std.meta.ArgsTuple(@TypeOf(predicate)), options: UntilOptions) (WaitError || error{Timeout})!void {
    if (ReturnOf(predicate) != bool) @compileError("until wants a predicate that returns bool");
    const deadline: ?u64 = if (options.timeout) |t| timing.now() +| @as(u64, @intCast(@max(0, t.toNanoseconds()))) else null;
    if (tasks.current()) |task| {
        // Lives on the task's stack, which stays put while it's parked
        const Check = struct {
            args: @TypeOf(args),
            fn call(ctx: *anyopaque) bool {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                return @call(.auto, predicate, self.args);
            }
        };
        var check: Check = .{ .args = args };
        try task.park(.render, .{ .predicate = .{ .ctx = &check, .func = Check.call }, .deadline = deadline });
        if (task.timed_out) return error.Timeout;
        return;
    }
    while (!try onRender(io, predicate, args)) {
        if (deadline) |d| if (timing.now() >= d) return error.Timeout;
    }
}

const tests = struct {
    const Fake = @import("testing.zig").Fake;

    const Seen = struct {
        frames: u32 = 0,
        ran: u32 = 0,
        cancelled: u32 = 0,

        fn onFrame(self: *Seen) void {
            self.frames += 1;
        }

        fn onPost(self: *Seen, status: PostStatus) void {
            if (status == .run) self.ran += 1 else self.cancelled += 1;
        }
    };

    test "frames and posts" {
        var fake: Fake = .{};
        fake.attach();
        defer fake.detach();

        var seen: Seen = .{};
        const sub = try onFrame(&seen, Seen.onFrame);
        try post(&seen, Seen.onPost);
        fake.runFrame();
        fake.runFrame();
        try std.testing.expectEqual(2, seen.frames);
        try std.testing.expectEqual(1, seen.ran);
        sub.unsubscribe();
        fake.runFrame();
        try std.testing.expectEqual(2, seen.frames);

        try post(&seen, Seen.onPost);
        fake.cancelPosts();
        fake.runFrame();
        try std.testing.expectEqual(1, seen.ran);
        try std.testing.expectEqual(1, seen.cancelled);
    }

    test "without frames" {
        var fake: Fake = .{ .no_frames = true };
        fake.attach();
        defer fake.detach();
        var seen: Seen = .{};
        try std.testing.expectError(error.NoFrames, post(&seen, Seen.onPost));
        try std.testing.expectError(error.NoFrames, onFrame(&seen, Seen.onFrame));
    }

    const Task = struct {
        done: Atomic(bool) = .init(false),
        ready: Atomic(u32) = .init(0),

        fn add(a: u32, b: u32) u32 {
            return a + b;
        }

        fn readyAt(self: *Task, n: u32) bool {
            return self.ready.fetchAdd(1, .monotonic) + 1 >= n;
        }

        fn awaits(self: *Task, io: std.Io) (WaitError || error{Timeout})!u32 {
            defer self.done.store(true, .release);
            try next(io);
            try wait(io, 2);
            try until(io, readyAt, .{ self, 3 }, .{});
            return onRender(io, add, .{ 2, 3 });
        }

        fn waitsForever(self: *Task, io: std.Io) WaitError!void {
            defer self.done.store(true, .release);
            return next(io);
        }

        fn timesOut(self: *Task, io: std.Io) (WaitError || error{Timeout})!void {
            defer self.done.store(true, .release);
            return until(io, readyAt, .{ self, 1000 }, .{ .timeout = .fromMilliseconds(5) });
        }

        /// Runs frames on this thread till the task's done.
        fn frames(self: *Task, fake: *Fake) void {
            while (!self.done.load(.acquire)) {
                fake.runFrame();
                std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
            }
        }
    };

    test "tasks wait for frames" {
        const io = std.testing.io;
        var fake: Fake = .{};
        fake.attach();
        defer fake.detach();

        var task: Task = .{};
        var future = try io.concurrent(Task.awaits, .{ &task, io });
        task.frames(&fake);
        try std.testing.expectEqual(5, try future.await(io));
        try std.testing.expect(task.ready.load(.monotonic) >= 3);

        // This thread runs the frames now
        try std.testing.expect(onRenderThread());
        try std.testing.expectError(error.OnRenderThread, next(io));

        var slow: Task = .{};
        var timing_out = try io.concurrent(Task.timesOut, .{ &slow, io });
        slow.frames(&fake);
        try std.testing.expectError(error.Timeout, timing_out.await(io));
    }

    test "waits end when posts are cancelled or the task is" {
        const io = std.testing.io;
        var fake: Fake = .{};
        fake.attach();
        defer fake.detach();

        var closing: Task = .{};
        var gone = try io.concurrent(Task.waitsForever, .{ &closing, io });
        while (!closing.done.load(.acquire)) {
            fake.cancelPosts();
            try io.sleep(.fromMilliseconds(1), .awake);
        }
        try std.testing.expectError(error.OwnerGone, gone.await(io));

        // No frames run, so it only ends because it's cancelled
        var cancelled: Task = .{};
        var waiting = try io.concurrent(Task.waitsForever, .{ &cancelled, io });
        try io.sleep(.fromMilliseconds(5), .awake);
        try std.testing.expectError(error.Canceled, waiting.cancel(io));
        // Its post still runs, and frees what it left behind
        fake.runFrame();
    }
};

test {
    _ = tests;
}
