//! Frame captures. Owners ask for the next frame drawn at a point, and the overlay copies it only then.

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const core = @import("wraith_core");
const api = @import("wraith_api");
const sync = @import("tuft_sys").sync;
const gfx = @import("tuft_gfx");
const tuft_capture = @import("tuft_imgui").capture;

const host = @import("root.zig");
const frame = @import("frame.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;

pub const Point = api.CapturePoint;

pub const Event = union(enum) {
    /// Copying started, so what's asked for now waits for the next one.
    started: Point,
    done: struct { point: Point, image: *const api.Image },
    failed: Point,
};

const Bus = core.Event(fn (event: *const Event) void);

var bus: Bus = .init(core.heap.main);

/// Waiting requests per point, so the overlay knows what to copy.
var wanted: [2]Atomic(u32) = @splat(.init(0));

pub const Subscription = Bus.Subscription;

/// For Wraith's own captures, like screenshots. `fire` gets every event, on the render thread.
pub fn watch(ctx: anytype, comptime fire: fn (@TypeOf(ctx), *const Event) void) !Subscription {
    return bus.subscribeUnscoped(ctx, fire);
}

/// Has the overlay copy the next frame at `point`. `unwant` once it's `started` or not wanted.
pub fn want(point: Point) void {
    _ = wanted[@backingInt(point)].fetchAdd(1, .acq_rel);
}

pub fn unwant(point: Point) void {
    _ = wanted[@backingInt(point)].fetchSub(1, .acq_rel);
}

/// Render thread, from the overlay.
pub fn wants(point: Point) bool {
    return wanted[@backingInt(point)].load(.acquire) != 0;
}

/// Render thread, from the overlay.
pub fn deliver(event: Event) void {
    bus.fire(.{&event});
}

/// The overlay's events, from the render thread.
pub fn fromOverlay(event: tuft_capture.Event, graphics: gfx.Api) void {
    switch (event) {
        .started => |point| deliver(.{ .started = pointOf(point) }),
        .failed => |point| deliver(.{ .failed = pointOf(point) }),
        .done => |image| {
            const converted: api.Image = .{
                .width = image.width,
                .height = image.height,
                .pitch = image.pitch,
                .format = switch (image.format) {
                    inline else => |f| @field(api.PixelFormat, @tagName(f)),
                },
                .native_format = image.native_format,
                .graphics_api = switch (graphics) {
                    inline .d3d9, .d3d10, .d3d11, .d3d12, .vulkan, .opengl => |g| @field(api.GraphicsApi, @tagName(g)),
                    _ => .unknown,
                },
                .color_space = switch (image.color_space) {
                    .scrgb => .scrgb,
                    .hdr10 => .hdr10,
                    else => .srgb,
                },
                .sdr_white_nits = image.sdr_white_nits,
                .pixels = image.pixels,
            };
            deliver(.{ .done = .{ .point = pointOf(image.point), .image = &converted } });
        },
    }
}

pub fn overlayWants(point: tuft_capture.Point) bool {
    return wants(pointOf(point));
}

fn pointOf(point: tuft_capture.Point) Point {
    return switch (point) {
        .before => .before_overlay,
        .after => .after_overlay,
    };
}

/// Fails everything asked for so far, like when the overlay can't draw at all.
pub fn failAll() void {
    deliver(.{ .failed = .before_overlay });
    deliver(.{ .failed = .after_overlay });
}

const sal = api.salamander;
const W = api.wraith;
/// What `display.sal`'s `capture` gives.
pub const Promise = sal.Plain(W.Display, "capture");
// Settles back on the thread that asked
const Request = @import("threads.zig").Back(@import("wraith.zig").ResolverOf(Promise));

/// Settles with a copy of the frame in a blob, which the taker owns.
fn settle(r: Request, image: *const api.Image) void {
    const pixels = sal.blobs.copy(image.pixels) catch return r.fail(error.Failed);
    r.settle(.{
        .width = image.width,
        .height = image.height,
        .pitch = image.pitch,
        .format = switch (image.format) {
            inline else => |f| @field(W.PixelFormat, @tagName(f)),
        },
        .native_format = image.native_format,
        .graphics_api = switch (image.graphics_api) {
            inline else => |g| @field(W.GraphicsApi, @tagName(g)),
        },
        .color_space = switch (image.color_space) {
            inline else => |c| @field(W.ColorSpace, @tagName(c)),
        },
        .sdr_white_nits = image.sdr_white_nits,
        .pixels = pixels,
    });
}

/// One owner's requests.
const Queue = struct {
    loaded: *Loaded,
    lock: sync.RwLock = .{},
    /// Under `lock`. Waiting for a copy to start, then for it to land.
    waiting: [2]std.ArrayList(Request) = @splat(.empty),
    taken: [2]std.ArrayList(Request) = @splat(.empty),
    /// Only touched while firing.
    running: std.ArrayList(Request) = .empty,
    /// Under `lock`.
    stopped: bool = false,
    subscription: Bus.Subscription = undefined,

    fn fire(self: *Queue, event: *const Event) void {
        switch (event.*) {
            .started => |point| {
                const p = @backingInt(point);
                self.lock.lock();
                defer self.lock.unlock();
                const moving = self.waiting[p].items.len;
                if (moving == 0) return;
                self.taken[p].appendSlice(self.loaded.allocator, self.waiting[p].items) catch {
                    // They wait for the next copy instead
                    return;
                };
                self.waiting[p].clearRetainingCapacity();
                _ = wanted[p].fetchSub(@intCast(moving), .acq_rel);
            },
            .done => |d| {
                self.take(d.point, false);
                for (self.running.items) |r| settle(r, d.image);
                self.running.clearRetainingCapacity();
            },
            .failed => |point| {
                self.take(point, true);
                for (self.running.items) |r| r.fail(error.Failed);
                self.running.clearRetainingCapacity();
            },
        }
    }

    /// Into `running`.
    fn take(self: *Queue, point: Point, waiting_too: bool) void {
        const p = @backingInt(point);
        self.lock.lock();
        defer self.lock.unlock();
        std.mem.swap(std.ArrayList(Request), &self.taken[p], &self.running);
        if (!waiting_too) return;
        const moving = self.waiting[p].items.len;
        if (moving == 0) return;
        self.running.appendSlice(self.loaded.allocator, self.waiting[p].items) catch return;
        self.waiting[p].clearRetainingCapacity();
        _ = wanted[p].fetchSub(@intCast(moving), .acq_rel);
    }

    fn capture(self: *Queue, point: Point, request: Request) api.FrameError!void {
        const p = @backingInt(point);
        self.lock.lock();
        defer self.lock.unlock();
        if (self.stopped) return error.OwnerGone;
        try self.waiting[p].append(self.loaded.allocator, request);
        _ = wanted[p].fetchAdd(1, .acq_rel);
    }

    /// What hasn't landed gets cancelled.
    pub fn stop(self: *Queue) void {
        {
            self.lock.lock();
            defer self.lock.unlock();
            if (self.stopped) return;
            self.stopped = true;
        }
        self.subscription.unsubscribe();
        var left: std.ArrayList(Request) = .empty;
        defer left.deinit(self.loaded.allocator);
        {
            self.lock.lock();
            defer self.lock.unlock();
            for (&self.waiting, &self.taken, 0..) |*waiting, *taken, p| {
                _ = wanted[p].fetchSub(@intCast(waiting.items.len), .acq_rel);
                left.appendSlice(self.loaded.allocator, waiting.items) catch {};
                left.appendSlice(self.loaded.allocator, taken.items) catch {};
                waiting.clearRetainingCapacity();
                taken.clearRetainingCapacity();
            }
        }
        // The plugin's going, so nobody's waiting
        for (left.items) |r| r.drop();
    }

    pub fn free(self: *Queue) void {
        self.stop();
        const allocator = self.loaded.allocator;
        for (&self.waiting, &self.taken) |*waiting, *taken| {
            waiting.deinit(allocator);
            taken.deinit(allocator);
        }
        self.running.deinit(allocator);
        allocator.destroy(self);
    }
};

var queues: host.Owned(Queue) = .{};
var creating: sync.RwLock = .{};

/// Through `display.sal`. Settles on the render thread once the frame's copied.
pub fn capture(loaded: *Loaded, point: Point) Promise {
    const pair = Promise.make() catch return .{};
    if (!loaded.allows(.capture)) {
        pair.resolver.fail(host.wraith.undeclared(error.NotDeclared, "capture"));
        return pair.promise;
    }
    if (!frame.framesOn()) {
        pair.resolver.fail(error.NoFrames);
        return pair.promise;
    }
    const queue = queues.first(&loaded.owner) orelse (makeQueue(loaded) catch {
        pair.resolver.fail(error.Failed);
        return pair.promise;
    });
    queue.capture(point, .of(pair.resolver, loaded)) catch pair.resolver.fail(error.Failed);
    return pair.promise;
}

fn makeQueue(loaded: *Loaded) api.FrameError!*Queue {
    creating.lock();
    defer creating.unlock();
    if (queues.first(&loaded.owner)) |q| return q;
    const queue = try loaded.allocator.create(Queue);
    queue.* = .{ .loaded = loaded };
    queue.subscription = bus.subscribeUnscoped(queue, Queue.fire) catch {
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

    const zeros: [16]u8 = .{ 1, 2, 3, 4 } ++ @as([12]u8, @splat(0));
    const image: api.Image = .{ .width = 4, .height = 1, .pitch = 16, .format = .rgba8, .graphics_api = .d3d11, .pixels = &zeros };

    fn start(loaded: *Loaded) sal.Object(W.Display) {
        loaded.initForTest(testing.allocator, "a");
        sdk.Owner.attach(loaded.root());
        return sdk.wraith.root().?.display();
    }

    fn stop(loaded: *Loaded) void {
        loaded.deinitForTest();
        host.wraith.forget(loaded);
        sdk.Owner.detach();
    }

    test "requests get the copy that starts after them, which they own" {
        frame.setFrames(true);
        defer frame.setFrames(false);
        var a: Loaded = undefined;
        const f = start(&a);
        defer stop(&a);

        const first = f.capture(.after_overlay);
        try testing.expect(wants(.after_overlay) and !wants(.before_overlay));
        deliver(.{ .started = .after_overlay });
        try testing.expect(!wants(.after_overlay));
        // Asked while that one's in flight, so it waits for the next
        const second = f.capture(.after_overlay);
        deliver(.{ .done = .{ .point = .after_overlay, .image = &image } });
        const got = (try first.take().?);
        defer got.pixels.release();
        try testing.expectEqual(4, got.width);
        try testing.expectEqual(.d3d11, got.graphics_api);
        try testing.expectEqualSlices(u8, &zeros, got.pixels.bytes());
        try testing.expectEqual(null, second.take());

        deliver(.{ .failed = .after_overlay });
        try testing.expectError(error.Failed, second.take().?);
        try testing.expect(!wants(.after_overlay));
    }

    test "closing drops requests" {
        frame.setFrames(true);
        defer frame.setFrames(false);
        var a: Loaded = undefined;
        const f = start(&a);
        const before = f.capture(.before_overlay);
        const after = f.capture(.after_overlay);
        deliver(.{ .started = .after_overlay });
        stop(&a);
        try testing.expectError(error.Gone, before.take().?);
        try testing.expectError(error.Gone, after.take().?);
        try testing.expect(!wants(.before_overlay));
        deliver(.{ .done = .{ .point = .after_overlay, .image = &image } });
    }

    test "captures from the overlay" {
        const Rig = @import("../testing/Rig.zig");
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        try rig.runPluginFrames();
        var a: Loaded = undefined;
        const f = start(&a);
        defer stop(&a);

        const before = f.capture(.before_overlay);
        const after = f.capture(.after_overlay);
        // The software renderer on CI can take a while, so give it time rather than a frame count
        const begun = core.timing.now();
        while ((!before.isSettled() or !after.isSettled()) and core.timing.now() - begun < 10 * std.time.ns_per_s) rig.present();
        const b = try (before.take() orelse return error.TestUnexpectedResult);
        defer b.pixels.release();
        const shot = try (after.take() orelse return error.TestUnexpectedResult);
        defer shot.pixels.release();
        try testing.expectEqual(.d3d11, shot.graphics_api);
        try testing.expectEqual(.rgba8, shot.format);
        try testing.expect(shot.width > 0 and shot.pixels.bytes().len >= shot.pitch * shot.height);
        try testing.expect(!wants(.before_overlay) and !wants(.after_overlay));
    }

    test "no frames, no captures" {
        var a: Loaded = undefined;
        const f = start(&a);
        defer stop(&a);
        try testing.expectError(error.NoFrames, f.capture(.before_overlay).take().?);
    }

    test "a plugin that doesn't declare capture can't, one that does can" {
        const Manifest = @import("../Manifest.zig");
        var a: Loaded = undefined;
        const f = start(&a);
        defer stop(&a);
        a.manifest = try Manifest.parse(testing.allocator, "{ \"id\": \"kai\", \"provider\": \"native\" }", "wraith.json");
        defer a.manifest.deinit();
        try testing.expectError(error.NotDeclared, f.capture(.before_overlay).take().?);
        a.manifest.deinit();
        a.manifest = try Manifest.parse(testing.allocator, "{ \"id\": \"kai\", \"provider\": \"native\", \"permissions\": { \"capture\": true } }", "wraith.json");
        // Past the check, there are no frames
        try testing.expectError(error.NoFrames, f.capture(.before_overlay).take().?);
    }
};

test {
    _ = tests;
}
