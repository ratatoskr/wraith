//! A fake Wraith for tests, with frames you run yourself. Missing areas give `Unsupported` or zero.
//!
//!     var fake: sdk.testing.Fake = .{};
//!     fake.attach();
//!     defer fake.detach();
//!     fake.runFrame();

const std = @import("std");

const api = @import("wraith_api");
const Owner = @import("Owner.zig");

const sal = api.salamander;
const W = api.wraith;

/// A table with what `Impl` has. The rest are null, so calling them gives `Unsupported` or zero.
pub fn partial(comptime Desc: type, comptime Impl: type) *const sal.Table(Desc) {
    return &struct {
        const table: sal.Table(Desc) = blk: {
            @setEvalBranchQuota(100_000);
            var t: sal.Table(Desc) = undefined;
            t.salamander_info = sal.infoOf(Desc);
            t.salamander_owner = null;
            for (Desc.salamander.methods) |m| {
                @field(t, m.name) = if (@hasDecl(Impl, m.name)) sal.entryFor(m, @field(Impl, m.name)) else null;
            }
            break :blk t;
        };
    }.table;
}

const Next = sal.Plain(W.Threads, "nextDraw");
const NextResolver = ResolverOf(Next);
const Delay = sal.Plain(W.Threads, "delay");

fn ResolverOf(comptime P: type) type {
    return @FieldType(@typeInfo(@typeInfo(@TypeOf(P.make)).@"fn".return_type.?).error_union.payload, "resolver");
}

pub const Fake = struct {
    /// `post` and `onDraw` refuse, like in a game whose frames the overlay can't hook.
    no_frames: bool = false,
    frame_stats: W.Display.Stats = std.mem.zeroes(W.Display.Stats),
    frame_times: []const f32 = &.{},
    debug_enabled: bool = true,

    logs: u32 = 0,
    last_level: std.log.Level = .info,
    last_scope_buf: [64]u8 = undefined,
    last_scope_len: usize = 0,
    last_message_buf: [2048]u8 = undefined,
    last_message_len: usize = 0,

    scans: u32 = 0,
    last_outcome: W.Diagnostics.ScanOutcome = .found,
    zones: u32 = 0,
    heaps: u32 = 0,

    images: [16]FakeImage = undefined,
    images_len: usize = 0,

    ticks: [16]Tick = undefined,
    ticks_len: usize = 0,
    /// Like a plugin driving ticks: `runFrame` leaves them to `runTick`.
    driven: bool = false,
    game_thread: std.Thread.Id = 0,
    lock: std.Io.Mutex = .init,
    nexts: std.ArrayList(NextResolver) = .empty,
    /// The thread `runFrame` last ran on.
    render_thread: std.Thread.Id = 0,
    /// Where hops and delays resume: render in `runFrame`, game in `runTick`. Made on first use.
    render_queue: sal.Queue = .{},
    game_queue: sal.Queue = .{},
    /// Under `lock`.
    delays: std.ArrayList(Delayed) = .empty,

    const Delayed = struct {
        at: u64,
        resolver: ResolverOf(Delay),
    };

    const Thread = enum { render, game, worker };

    const FakeImage = struct {
        size: W.Image.Size,
        live: bool,
    };

    pub fn imageCount(self: *const Fake) usize {
        var n: usize = 0;
        for (self.images[0..self.images_len]) |i| n += @intFromBool(i.live);
        return n;
    }

    const Tick = struct {
        tick: union(enum) { frame: W.Threads.Draw, game: W.Threads.Tick },
        live: bool,
    };

    const gpa = std.heap.smp_allocator;

    pub fn root(self: *Fake) Owner.Wraith {
        return .init(self, partial(W.Api, Areas));
    }

    pub fn attach(self: *Fake) void {
        Owner.attach(self.root());
    }

    /// Drops what's still posted, like the plugin going.
    pub fn detach(self: *Fake) void {
        Owner.detach();
        self.cancelPosts();
        self.nexts.deinit(gpa);
        for (self.delays.items) |d| d.resolver.drop();
        self.delays.deinit(gpa);
    }

    fn here(self: *Fake) Thread {
        const me = std.Thread.getCurrentId();
        if (@atomicLoad(std.Thread.Id, &self.render_thread, .monotonic) == me) return .render;
        if (@atomicLoad(std.Thread.Id, &self.game_thread, .monotonic) == me) return .game;
        return .worker;
    }

    /// Where code carries on on `thread`. Null for a worker, which carries on wherever it settles.
    fn queueOf(self: *Fake, thread: Thread) ?sal.Queue {
        self.lock.lockUncancelable(std.testing.io);
        defer self.lock.unlock(std.testing.io);
        const q = switch (thread) {
            .render => &self.render_queue,
            .game => &self.game_queue,
            .worker => return null,
        };
        if (q.table == null) q.* = sal.host().queue() catch return null;
        return q.*;
    }

    fn poll(self: *Fake, thread: Thread) void {
        const q = blk: {
            self.lock.lockUncancelable(std.testing.io);
            defer self.lock.unlock(std.testing.io);
            break :blk switch (thread) {
                .render => self.render_queue,
                .game => self.game_queue,
                .worker => return,
            };
        };
        if (q.table != null) _ = q.poll();
    }

    fn checkDelays(self: *Fake) void {
        const now = @import("timing.zig").now();
        var due: std.ArrayList(ResolverOf(Delay)) = .empty;
        defer due.deinit(gpa);
        {
            self.lock.lockUncancelable(std.testing.io);
            defer self.lock.unlock(std.testing.io);
            var i: usize = 0;
            while (i < self.delays.items.len) {
                if (self.delays.items[i].at > now) {
                    i += 1;
                    continue;
                }
                due.append(gpa, self.delays.swapRemove(i).resolver) catch return;
            }
        }
        for (due.items) |r| r.settle({});
    }

    pub fn lastScope(self: *const Fake) []const u8 {
        return self.last_scope_buf[0..self.last_scope_len];
    }

    pub fn lastMessage(self: *const Fake) []const u8 {
        return self.last_message_buf[0..self.last_message_len];
    }

    /// Ticks unless `driven`, settles posts, then runs draw callbacks, like a runtime frame.
    pub fn runFrame(self: *Fake) void {
        @atomicStore(std.Thread.Id, &self.render_thread, std.Thread.getCurrentId(), .monotonic);
        if (!self.driven) self.runTick();
        var due: std.ArrayList(NextResolver) = .empty;
        defer due.deinit(gpa);
        {
            self.lock.lockUncancelable(std.testing.io);
            defer self.lock.unlock(std.testing.io);
            std.mem.swap(std.ArrayList(NextResolver), &self.nexts, &due);
        }
        for (due.items) |r| r.resolve({});
        // What carries on here goes with the posts, before draw callbacks, like the plugin's own queue
        self.checkDelays();
        self.poll(.render);
        var i: usize = 0;
        while (i < self.ticks_len) : (i += 1) {
            if (!self.ticks[i].live) continue;
            switch (self.ticks[i].tick) {
                .frame => |t| t.invoke(.{}),
                .game => {},
            }
        }
    }

    /// Runs `onTick` callbacks, with this as the game thread.
    pub fn runTick(self: *Fake) void {
        @atomicStore(std.Thread.Id, &self.game_thread, std.Thread.getCurrentId(), .monotonic);
        var i: usize = 0;
        while (i < self.ticks_len) : (i += 1) {
            if (!self.ticks[i].live) continue;
            switch (self.ticks[i].tick) {
                .game => |t| t.invoke(.{}),
                .frame => {},
            }
        }
        self.checkDelays();
        self.poll(.game);
    }

    /// Drops what's posted, so it's cancelled.
    pub fn cancelPosts(self: *Fake) void {
        var due: std.ArrayList(NextResolver) = .empty;
        defer due.deinit(gpa);
        {
            self.lock.lockUncancelable(std.testing.io);
            defer self.lock.unlock(std.testing.io);
            std.mem.swap(std.ArrayList(NextResolver), &self.nexts, &due);
        }
        for (due.items) |r| r.drop();
    }

    const Areas = struct {
        pub fn threads(self: *Fake) W.Threads {
            return .init(self, partial(W.Threads, Threads));
        }

        pub fn display(self: *Fake) W.Display {
            return .init(self, partial(W.Display, Display));
        }

        pub fn log(self: *Fake) W.Log {
            return .init(self, partial(W.Log, Logs));
        }

        pub fn images(self: *Fake) W.Images {
            return .init(self, partial(W.Images, Images));
        }

        pub fn diagnostics(self: *Fake) W.Diagnostics {
            return .init(self, partial(W.Diagnostics, Diagnostics));
        }
    };

    const Threads = struct {
        pub fn onDraw(self: *Fake, draw: W.Threads.Draw) sal.Plain(W.Threads, "onDraw") {
            if (self.no_frames) return error.NoFrames;
            if (self.ticks_len == self.ticks.len) return error.Failed;
            self.ticks[self.ticks_len] = .{ .tick = .{ .frame = draw }, .live = true };
            self.ticks_len += 1;
            return .init(&self.ticks[self.ticks_len - 1], partial(W.Threads.Subscription, Subscription));
        }

        pub fn onTick(self: *Fake, tick: W.Threads.Tick) sal.Plain(W.Threads, "onTick") {
            if (self.ticks_len == self.ticks.len) return error.Failed;
            self.ticks[self.ticks_len] = .{ .tick = .{ .game = tick }, .live = true };
            self.ticks_len += 1;
            return .init(&self.ticks[self.ticks_len - 1], partial(W.Threads.Subscription, Subscription));
        }

        pub fn onGameThread(self: *Fake) bool {
            const id = @atomicLoad(std.Thread.Id, &self.game_thread, .monotonic);
            return id != 0 and id == std.Thread.getCurrentId();
        }

        pub fn nextDraw(self: *Fake) Next {
            const pair = Next.make() catch return .{};
            if (self.no_frames) {
                pair.resolver.fail(error.NoFrames);
                return pair.promise;
            }
            self.lock.lockUncancelable(std.testing.io);
            defer self.lock.unlock(std.testing.io);
            self.nexts.append(gpa, pair.resolver) catch pair.resolver.drop();
            return pair.promise;
        }

        pub fn toRender(self: *Fake) sal.Plain(W.Threads, "toRender") {
            return hop(self, "toRender", .render, false);
        }

        pub fn toGame(self: *Fake) sal.Plain(W.Threads, "toGame") {
            return hop(self, "toGame", .game, false);
        }

        pub fn toWorker(self: *Fake) sal.Plain(W.Threads, "toWorker") {
            return hop(self, "toWorker", .worker, false);
        }

        pub fn nextTick(self: *Fake) sal.Plain(W.Threads, "nextTick") {
            return hop(self, "nextTick", .game, true);
        }

        /// Like the runtime's: right here if it's there already unless `always`.
        fn hop(self: *Fake, comptime name: []const u8, to: Thread, always: bool) sal.Plain(W.Threads, name) {
            const P = sal.Plain(W.Threads, name);
            const pair = P.make() catch return .{};
            if (!always and self.here() == to) {
                pair.resolver.settle({});
                return pair.promise;
            }
            if (self.no_frames and to != .worker) {
                pair.resolver.fail(error.NoFrames);
                return pair.promise;
            }
            if (self.queueOf(to)) |q| pair.resolver.carryOn(q);
            pair.resolver.settle({});
            return pair.promise;
        }

        pub fn delay(self: *Fake, ms: u32) Delay {
            const pair = Delay.make() catch return .{};
            if (self.no_frames) {
                pair.resolver.fail(error.NoFrames);
                return pair.promise;
            }
            if (self.queueOf(self.here())) |q| pair.resolver.carryOn(q);
            const at = @import("timing.zig").now() +| @as(u64, ms) * std.time.ns_per_ms;
            self.lock.lockUncancelable(std.testing.io);
            defer self.lock.unlock(std.testing.io);
            self.delays.append(gpa, .{ .at = at, .resolver = pair.resolver }) catch pair.resolver.drop();
            return pair.promise;
        }
    };

    const Display = struct {
        pub fn frameStats(self: *Fake) W.Display.Stats {
            return self.frame_stats;
        }

        pub fn times(self: *Fake) []const f32 {
            return self.frame_times;
        }
    };

    const Images = struct {
        const Made = sal.Plain(W.Images, "create");

        fn add(self: *Fake, width: u32, height: u32) Made {
            if (self.images_len == self.images.len) return error.Failed;
            self.images[self.images_len] = .{ .size = .{ .width = width, .height = height }, .live = true };
            self.images_len += 1;
            return .init(&self.images[self.images_len - 1], partial(W.Image, Image));
        }

        pub fn create(self: *Fake, width: u32, height: u32, rgba: []const u8) Made {
            if (rgba.len != @as(usize, width) * height * 4) return error.InvalidImage;
            return add(self, width, height);
        }

        pub fn decode(self: *Fake, bytes: []const u8) Made {
            const pixels = @import("tuft_image").decode(std.testing.allocator, bytes) catch return error.InvalidImage;
            defer pixels.deinit(std.testing.allocator);
            return add(self, pixels.width, pixels.height);
        }
    };

    const Image = struct {
        pub fn dimensions(i: *FakeImage) W.Image.Size {
            return if (i.live) i.size else .{ .width = 0, .height = 0 };
        }

        pub fn destroy(i: *FakeImage) void {
            i.live = false;
        }
    };

    const Subscription = struct {
        pub fn cancel(t: *Tick) void {
            t.live = false;
        }
    };

    const Logs = struct {
        pub fn write(self: *Fake, level: W.Log.Level, scope: []const u8, message: []const u8) void {
            self.logs += 1;
            self.last_level = switch (level) {
                .err => .err,
                .warn => .warn,
                .info => .info,
                else => .debug,
            };
            self.last_scope_len = @min(scope.len, self.last_scope_buf.len);
            @memcpy(self.last_scope_buf[0..self.last_scope_len], scope[0..self.last_scope_len]);
            self.last_message_len = @min(message.len, self.last_message_buf.len);
            @memcpy(self.last_message_buf[0..self.last_message_len], message[0..self.last_message_len]);
        }

        pub fn enabled(self: *Fake, level: W.Log.Level) bool {
            return level != .debug or self.debug_enabled;
        }
    };

    const Diagnostics = struct {
        pub fn addZone(self: *Fake, _: usize, _: u32) void {
            self.zones += 1;
        }

        pub fn removeZone(self: *Fake, _: usize) void {
            self.zones -|= 1;
        }

        pub fn addHeap(self: *Fake, _: usize, _: u32) void {
            self.heaps += 1;
        }

        pub fn removeHeap(self: *Fake, _: usize) void {
            self.heaps -|= 1;
        }

        pub fn recordScan(self: *Fake, scan: W.Diagnostics.SignatureScan) void {
            self.scans += 1;
            self.last_outcome = scan.outcome;
        }

        pub fn recordScanFrom(self: *Fake, scan: W.Diagnostics.ScanRecord) void {
            self.scans += 1;
            self.last_outcome = scan.outcome;
        }
    };
};
