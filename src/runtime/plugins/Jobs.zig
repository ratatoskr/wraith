//! Runs loads and unloads in order on a worker thread, off the render thread.

const Jobs = @This();

const std = @import("std");

const core = @import("wraith_core");
const tuft_sys = @import("tuft_sys");

const PluginLoader = @import("../PluginLoader.zig");
const lifecycle = @import("lifecycle.zig");

const log = core.log.scoped(.wraith_runtime);

pub const Op = enum {
    load,
    unload,
    reload,
    rescan,
    /// Loads the plugins waiting for .NET
    wake,
};

pub const Job = struct {
    loader: *PluginLoader,
    id: u64,

    /// Don't call on the render or window thread, unloading waits for their callbacks.
    pub fn wait(self: Job) !void {
        return self.loader.jobs.wait(self.id);
    }
};

const Request = struct { id: u64, op: Op, name: []u8 };
const Result = struct { id: u64 = 0, err: ?anyerror = null };

lock: tuft_sys.sync.RwLock = .{},
pending: std.ArrayList(Request) = .empty,
worker: ?std.Thread = null,
running: bool = false,
/// Set under `lock` with the queue, so `busy` is exact.
active: bool = false,
closed: bool = false,
next_id: u64 = 1,
done_through: u64 = 0,
results: [64]Result = @splat(.{}),

fn loaderOf(self: *Jobs) *PluginLoader {
    return @alignCast(@fieldParentPtr("jobs", self));
}

pub fn add(self: *Jobs, op: Op, name: []const u8) !Job {
    const loader = self.loaderOf();
    const owned = try loader.allocator.dupe(u8, name);
    errdefer loader.allocator.free(owned);

    self.lock.lock();
    defer self.lock.unlock();
    if (self.closed) return error.ShuttingDown;
    const id = self.next_id;
    try self.pending.append(loader.allocator, .{ .id = id, .op = op, .name = owned });
    errdefer _ = self.pending.pop();

    if (!self.running) {
        if (self.worker) |w| w.join();
        self.worker = null;
        self.worker = try std.Thread.spawn(.{}, work, .{self});
        self.running = true;
    }
    self.next_id += 1;
    return .{ .loader = loader, .id = id };
}

pub fn busy(self: *Jobs) bool {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    return self.active or self.pending.items.len != 0;
}

fn work(self: *Jobs) void {
    const loader = self.loaderOf();
    while (true) {
        const req = blk: {
            self.lock.lock();
            defer self.lock.unlock();
            if (self.closed or self.pending.items.len == 0) {
                self.running = false;
                return;
            }
            self.active = true; // under the same lock that takes it off the queue
            break :blk self.pending.orderedRemove(0);
        };
        defer loader.allocator.free(req.name);

        var err: ?anyerror = null;
        lifecycle.run(loader, req.op, req.name) catch |e| {
            err = e;
            log.err("Couldn't {t} plugin {s}: {t}", .{ req.op, req.name, e });
        };
        self.finish(req.id, err);
    }
}

fn finish(self: *Jobs, id: u64, err: ?anyerror) void {
    self.lock.lock();
    defer self.lock.unlock();
    self.results[@intCast(id % self.results.len)] = .{ .id = id, .err = err };
    self.done_through = id;
    self.active = false;
}

fn wait(self: *Jobs, id: u64) !void {
    while (true) {
        {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            if (self.done_through >= id) {
                const result = self.results[@intCast(id % self.results.len)];
                // Only overwritten after 64 more jobs, so assume it went fine
                if (result.id != id) return;
                if (result.err) |err| return err;
                return;
            }
        }
        self.loaderOf().io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
}

/// Lets the running job finish and cancels the rest.
pub fn stop(self: *Jobs) void {
    const allocator = self.loaderOf().allocator;
    const running = blk: {
        self.lock.lock();
        defer self.lock.unlock();
        self.closed = true;
        defer self.worker = null;
        break :blk self.worker;
    };
    if (running) |w| w.join();

    self.lock.lock();
    defer self.lock.unlock();
    for (self.pending.items) |r| {
        self.results[@intCast(r.id % self.results.len)] = .{ .id = r.id, .err = error.Cancelled };
        self.done_through = r.id;
        allocator.free(r.name);
    }
    self.pending.deinit(allocator);
    self.pending = .empty;
}
