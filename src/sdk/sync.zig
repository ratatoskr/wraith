//! Locks within a plugin. `Mutex` parks tasks instead of blocking; elsewhere the thread waits.
//! Keep held sections short. Not reentrant. For cross-plugin locks see the `sync` area.

const std = @import("std");

const atomic = @import("tuft_arch").atomic;
const sys = @import("tuft_sys");

const tasks = @import("tasks.zig");

const Inner = sys.sync.Mutex;

/// Tuft's reader-writer lock; blocks rather than parks. Not reentrant.
pub const RwLock = sys.sync.RwLock;
/// Wakes one waiter per `set`, like a thread waiting for rare work.
pub const Signal = sys.sync.Signal;

pub const Mutex = struct {
    inner: Inner = .{},

    /// Fails only in a task whose plugin's stopping, and then it isn't yours.
    pub fn lock(self: *Mutex) error{Canceled}!void {
        if (self.inner.tryLock()) return;
        const t = tasks.current() orelse return self.inner.lock();
        var w: TaskWaiter = .{ .task = t };
        // Before it's in line, so a wake straight after isn't missed
        t.prepareSignal();
        if (self.inner.lockOr(&w.waiter)) return;
        t.parkUntilWoken(t.where) catch |err| {
            if (self.inner.cancel(&w.waiter)) return err;
            // It was handed over as it gave up, so pass it on
            w.waitHanded();
            self.inner.unlock();
            return err;
        };
        w.waitHanded();
    }

    pub fn tryLock(self: *Mutex) bool {
        return self.inner.tryLock();
    }

    /// Hands it to whoever's waited longest.
    pub fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }
};

const TaskWaiter = struct {
    waiter: Inner.Waiter = .{ .wake = wake },
    task: *tasks.Task,
    handed: atomic.Value(bool) = .init(false),

    fn wake(w: *Inner.Waiter) void {
        const self: *TaskWaiter = @alignCast(@fieldParentPtr("waiter", w));
        self.task.wake();
        // Last, since it's off the waiter's stack once this is seen
        self.handed.store(true, .release);
    }

    /// The task's resumed or giving up, so `wake` is running or about to.
    fn waitHanded(self: *TaskWaiter) void {
        while (!self.handed.load(.acquire)) std.atomic.spinLoopHint();
    }
};

const tests = struct {
    const testing = std.testing;
    const threads = @import("threads.zig");
    const Owner = @import("Owner.zig");
    const Fake = @import("testing.zig").Fake;

    test "threads take turns" {
        var m: Mutex = .{};
        var count: u32 = 0;
        const Adder = struct {
            fn run(lock: *Mutex, n: *u32) void {
                for (0..10_000) |_| {
                    lock.lock() catch unreachable;
                    n.* += 1;
                    lock.unlock();
                }
            }
        };
        var workers: [4]std.Thread = undefined;
        for (&workers) |*t| t.* = try std.Thread.spawn(.{}, Adder.run, .{ &m, &count });
        for (workers) |t| t.join();
        try testing.expectEqual(40_000, count);
        try testing.expect(m.tryLock());
        try testing.expect(!m.tryLock());
        m.unlock();
    }

    test "a task waits for it without holding up the render thread" {
        var fake: Fake = .{};
        fake.attach();
        defer fake.detach();
        var group: std.Io.Group = .init;
        var scheduler: tasks.Scheduler = .init(testing.allocator, testing.io, Owner.own().?, &group);
        defer {
            scheduler.cancel();
            scheduler.deinit();
        }
        const Waiter = struct {
            got: atomic.Value(bool) = .init(false),
            fn run(self: *@This(), lock: *Mutex) !void {
                try lock.lock();
                self.got.store(true, .release);
                lock.unlock();
            }
        };
        var m: Mutex = .{};
        try testing.expect(m.tryLock());
        var waiter: Waiter = .{};
        try scheduler.spawn(Waiter.run, .{ &waiter, &m });
        // Frames go on while it's parked
        for (0..5) |_| fake.runFrame();
        try testing.expect(!waiter.got.load(.acquire));
        m.unlock();
        for (0..200) |_| {
            if (waiter.got.load(.acquire)) break;
            fake.runFrame();
            try testing.io.sleep(.fromMilliseconds(1), .awake);
        }
        try testing.expect(waiter.got.load(.acquire));
    }

    test "a waiting task's wait ends when its plugin stops" {
        var fake: Fake = .{};
        fake.attach();
        defer fake.detach();
        var group: std.Io.Group = .init;
        var scheduler: tasks.Scheduler = .init(testing.allocator, testing.io, Owner.own().?, &group);
        defer scheduler.deinit();
        const Waiter = struct {
            err: ?anyerror = null,
            fn run(self: *@This(), lock: *Mutex) !void {
                lock.lock() catch |err| {
                    self.err = err;
                    return err;
                };
                lock.unlock();
            }
        };
        var m: Mutex = .{};
        try testing.expect(m.tryLock());
        var waiter: Waiter = .{};
        try scheduler.spawn(Waiter.run, .{ &waiter, &m });
        for (0..3) |_| fake.runFrame();
        scheduler.cancel();
        try testing.expectEqual(error.Canceled, waiter.err.?);
        m.unlock();
    }
};

test {
    _ = tests;
}
