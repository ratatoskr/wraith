//! Where plugin code runs: the render thread, the game thread or a worker. The same for every
//! language: an async call carries on on the thread that made it, and the hops in `frame.sal` on
//! another. Promises say so themselves, through their resolver's `carryOn`, so it holds however
//! the waiter waits, even when it comes after the promise settled.

const std = @import("std");

const sal = @import("wraith_api").salamander;
const sync = @import("tuft_sys").sync;

const host = @import("root.zig");

const gpa = std.heap.smp_allocator;

pub const Thread = enum {
    render,
    game,
    /// Any other, like Wraith's workers or a plugin's own
    worker,
};

/// The thread this is, as far as plugins are concerned.
pub fn here() Thread {
    if (host.frame.onRenderThread()) return .render;
    if (host.frame.onGameThread()) return .game;
    return .worker;
}

/// Whether `thread` is the one this is. Any worker counts as any other.
pub fn isHere(thread: Thread) bool {
    return here() == thread;
}

/// Whether something polls `thread`'s queue. Without frames nothing polls the render thread's,
/// like in a headless test, and without them or a driver nothing polls the game thread's.
pub fn reachable(thread: Thread) bool {
    return switch (thread) {
        .render => host.frame.framesOn(),
        .game => host.frame.framesOn() or host.frame.driven(),
        .worker => true,
    };
}

var lock: sync.Mutex = .{};
/// Workers' jobs, waited for by `stop`.
var group: std.Io.Group = .init;
var stopped: bool = false;

/// Runs `task` on `thread`: at the render thread's next frame, the game thread's next tick, or
/// on a worker now. Fails only when it can't, leaving `task` the caller's.
pub fn post(thread: Thread, task: sal.Task) error{Failed}!void {
    queueOf(thread).postTask(task) catch return error.Failed;
}

/// What runs on `thread`, as a queue, for a resolver's `carryOn`.
pub fn queueOf(thread: Thread) sal.Queue {
    return switch (thread) {
        .render => host.salamander.renderQueueOf(),
        .game => host.salamander.gameQueueOf(),
        .worker => .{ .data = @intFromPtr(&workers), .table = sal.implement(sal.core.Queue, Workers) },
    };
}

/// Wraith's workers as a queue. Posting runs it on one now.
const Workers = struct {
    pub fn post(_: *Workers, task: sal.Task) bool {
        const io = host.wraith.ioOf() orelse return false;
        lock.lock();
        defer lock.unlock();
        if (stopped) return false;
        group.concurrent(io, runTask, .{task}) catch return false;
        return true;
    }

    pub fn poll(_: *Workers) u32 {
        return 0;
    }
};
var workers: Workers = .{};

fn runTask(task: sal.Task) void {
    task.invoke(.{});
}

/// Waits for what's running on workers, posting no more meanwhile. Before `io` goes, once plugins
/// have.
pub fn stop() void {
    const io = host.wraith.ioOf() orelse return;
    lock.lock();
    stopped = true;
    lock.unlock();
    group.await(io) catch {};
    lock.lock();
    defer lock.unlock();
    group = .init;
    stopped = false;
}

/// Has whoever waits on `r`'s promise carry on on `thread`. Not when nothing polls it, so then
/// they carry on wherever it settles.
pub fn carryOn(r: anytype, thread: Thread) void {
    if (reachable(thread)) r.carryOn(queueOf(thread));
}

/// What `delay` settles, soonest last.
var delays: std.ArrayList(Delay) = .empty;
var delays_lock: sync.Mutex = .{};

const Delay = struct {
    at: u64,
    task: sal.Task,
};

/// Runs `task` once `ns` have gone by, from the next frame or tick after. Fails leaving it the
/// caller's.
pub fn after(ns: u64, task: sal.Task) error{Failed}!void {
    const at = @import("wraith_core").timing.now() +| ns;
    delays_lock.lock();
    defer delays_lock.unlock();
    var i = delays.items.len;
    while (i > 0 and delays.items[i - 1].at < at) i -= 1;
    delays.insert(gpa, i, .{ .at = at, .task = task }) catch return error.Failed;
}

/// Runs what's due. Each frame and tick.
pub fn checkDelays() void {
    const now = @import("wraith_core").timing.now();
    while (true) {
        const due = blk: {
            delays_lock.lock();
            defer delays_lock.unlock();
            const last = delays.getLastOrNull() orelse return;
            if (last.at > now) return;
            break :blk delays.pop().?;
        };
        due.task.invoke(.{});
    }
}

/// An async call's resolver, which carries on on the thread that made it, wherever it settles.
/// Made where the call's made, and used like the resolver.
pub fn Back(comptime R: type) type {
    return struct {
        const Self = @This();
        const Result = @typeInfo(@TypeOf(R.settle)).@"fn".param_types[1].?;

        r: R,

        pub fn of(r: R) Self {
            carryOn(r, here());
            return .{ .r = r };
        }

        pub fn settle(self: Self, result: Result) void {
            self.r.settle(result);
        }

        pub fn fail(self: Self, err: anyerror) void {
            self.r.fail(err);
        }

        pub fn drop(self: Self) void {
            self.r.drop();
        }

        pub fn cancelled(self: Self) bool {
            return self.r.cancelled();
        }

        /// See the resolver's.
        pub fn hold(self: *const Self, text: []const u8) error{OutOfMemory}![]const u8 {
            return self.r.hold(text);
        }

        pub fn allocator(self: *const Self) std.mem.Allocator {
            return self.r.allocator();
        }
    };
}
