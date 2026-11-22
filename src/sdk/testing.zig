//! A pretend Wraith for tests: a root with frames you run yourself, a log and diagnostics you can
//! look at. Areas it doesn't have give `Unsupported` or zero, like an older Wraith.
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

const Next = sal.Plain(W.Frame, "next");
const NextResolver = @FieldType(@typeInfo(@typeInfo(@TypeOf(Next.make)).@"fn".return_type.?).error_union.payload, "resolver");

pub const Fake = struct {
    /// `post` and `onFrame` refuse, like in a game whose frames the overlay can't hook.
    no_frames: bool = false,
    frame_stats: W.FrameStats = std.mem.zeroes(W.FrameStats),
    frame_times: []const f32 = &.{},
    debug_enabled: bool = true,

    logs: u32 = 0,
    last_level: std.log.Level = .info,
    last_scope_buf: [64]u8 = undefined,
    last_scope_len: usize = 0,
    last_message_buf: [2048]u8 = undefined,
    last_message_len: usize = 0,

    scans: u32 = 0,
    last_outcome: W.ScanOutcome = .found,
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

    const FakeImage = struct {
        size: W.ImageSize,
        live: bool,
    };

    pub fn imageCount(self: *const Fake) usize {
        var n: usize = 0;
        for (self.images[0..self.images_len]) |i| n += @intFromBool(i.live);
        return n;
    }

    const Tick = struct {
        tick: union(enum) { frame: W.FrameTick, game: W.GameTick },
        live: bool,
    };

    const gpa = std.heap.smp_allocator;

    pub fn root(self: *Fake) Owner.Wraith {
        return .init(self, partial(W.Wraith, Areas));
    }

    pub fn attach(self: *Fake) void {
        Owner.attach(self.root());
    }

    /// Drops what's still posted, like the plugin going.
    pub fn detach(self: *Fake) void {
        Owner.detach();
        self.cancelPosts();
        self.nexts.deinit(gpa);
    }

    pub fn lastScope(self: *const Fake) []const u8 {
        return self.last_scope_buf[0..self.last_scope_len];
    }

    pub fn lastMessage(self: *const Fake) []const u8 {
        return self.last_message_buf[0..self.last_message_len];
    }

    /// Ticks unless `driven`, settles what's posted, then runs frame callbacks, like the runtime's
    /// frames.
    pub fn runFrame(self: *Fake) void {
        if (!self.driven) self.runTick();
        var due: std.ArrayList(NextResolver) = .empty;
        defer due.deinit(gpa);
        {
            self.lock.lockUncancelable(std.testing.io);
            defer self.lock.unlock(std.testing.io);
            std.mem.swap(std.ArrayList(NextResolver), &self.nexts, &due);
        }
        for (due.items) |r| r.resolve({});
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
        pub fn frame(self: *Fake) W.Frame {
            return .init(self, partial(W.Frame, Frames));
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

    const Frames = struct {
        pub fn onFrame(self: *Fake, tick: W.FrameTick) sal.Plain(W.Frame, "onFrame") {
            if (self.no_frames) return error.NoFrames;
            if (self.ticks_len == self.ticks.len) return error.Failed;
            self.ticks[self.ticks_len] = .{ .tick = .{ .frame = tick }, .live = true };
            self.ticks_len += 1;
            return .init(&self.ticks[self.ticks_len - 1], partial(W.FrameSubscription, Subscription));
        }

        pub fn onTick(self: *Fake, tick: W.GameTick) sal.Plain(W.Frame, "onTick") {
            if (self.ticks_len == self.ticks.len) return error.Failed;
            self.ticks[self.ticks_len] = .{ .tick = .{ .game = tick }, .live = true };
            self.ticks_len += 1;
            return .init(&self.ticks[self.ticks_len - 1], partial(W.FrameSubscription, Subscription));
        }

        pub fn onGameThread(self: *Fake) bool {
            const id = @atomicLoad(std.Thread.Id, &self.game_thread, .monotonic);
            return id != 0 and id == std.Thread.getCurrentId();
        }

        pub fn next(self: *Fake) Next {
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

        pub fn stats(self: *Fake) W.FrameStats {
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
        pub fn size(i: *FakeImage) W.ImageSize {
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
        pub fn write(self: *Fake, level: W.LogLevel, scope: []const u8, message: []const u8) void {
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

        pub fn enabled(self: *Fake, level: W.LogLevel) bool {
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

        pub fn recordScan(self: *Fake, scan: W.SignatureScan) void {
            self.scans += 1;
            self.last_outcome = scan.outcome;
        }
    };
};
