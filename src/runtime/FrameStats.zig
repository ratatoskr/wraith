//! Time from one present to the next, for fps, lows and hitches.
//! Recording never blocks or allocates. Stats get worked out at most a few times a second, by whoever asks.

const FrameStats = @This();

const std = @import("std");
const atomic = @import("tuft_arch").atomic;

const api = @import("wraith_api");
const core = @import("wraith_core");

pub const Stats = api.FrameStats;

/// Every frame for `max_window_seconds` up to about 540 fps. Faster than that and the window's shorter.
pub const capacity = 16384;
pub const min_window_seconds = 0.5;
pub const max_window_seconds = 30;
pub const min_hitch_factor = 1.2;
pub const max_hitch_factor = 10;
/// How old `stats` can be before it's worked out again.
const refresh_ns = 250 * std.time.ns_per_ms;

/// Microseconds. `count % capacity` is the next one written, over the oldest.
times_us: [capacity]u32 = @splat(0),
/// Frames ever recorded.
count: atomic.Value(u64) = .init(0),
/// `count` at the last reset. Older frames aren't counted.
since: atomic.Value(u64) = .init(0),
total_us: atomic.Value(u64) = .init(0),
min_us: atomic.Value(u32) = .init(std.math.maxInt(u32)),
max_us: atomic.Value(u32) = .init(0),
window_ms: atomic.Value(u32) = .init(5000),
hitch_x100: atomic.Value(u32) = .init(200),

// Render thread only
last_ns: u64 = 0,

/// Only one reader works them out at a time. The rest get the last ones.
computing: atomic.Value(bool) = .init(false),
/// Under `computing`, so it's not on anyone's stack.
scratch: [capacity]f32 = undefined,
/// Two, so a reader copying one never sees it half written.
cache: [2]Stats = .{ .{}, .{} },
current: atomic.Value(u8) = .init(0),
/// 0 means work them out next time.
computed_ns: atomic.Value(u64) = .init(0),

/// Once a present, at `now` from `core.timing.now`. Render thread.
pub fn record(self: *FrameStats, now: u64) void {
    defer self.last_ns = now;
    if (self.last_ns == 0 or now <= self.last_ns) return;
    const us: u32 = @intCast(@min((now - self.last_ns) / std.time.ns_per_us, std.math.maxInt(u32)));
    const n = self.count.load(.monotonic);
    atomic.store(u32, &self.times_us[slot(n)], us, .monotonic);
    self.count.store(n + 1, .release);
    _ = self.total_us.fetchAdd(us, .monotonic);
    _ = self.min_us.fetchMin(us, .monotonic);
    _ = self.max_us.fetchMax(us, .monotonic);
}

/// Starts the totals and the window over. Any thread.
pub fn reset(self: *FrameStats) void {
    self.since.store(self.count.load(.acquire), .release);
    self.total_us.store(0, .monotonic);
    self.min_us.store(std.math.maxInt(u32), .monotonic);
    self.max_us.store(0, .monotonic);
    self.computed_ns.store(0, .release);
}

/// How far back the stats look. Any thread.
pub fn setWindow(self: *FrameStats, seconds: f32) void {
    const s = std.math.clamp(seconds, min_window_seconds, max_window_seconds);
    self.window_ms.store(@intFromFloat(s * 1000), .monotonic);
    self.computed_ns.store(0, .release);
}

pub fn window(self: *const FrameStats) f32 {
    return @as(f32, @floatFromInt(self.window_ms.load(.monotonic))) / 1000;
}

/// Frames this many times the median count as hitches. Any thread.
pub fn setHitchFactor(self: *FrameStats, factor: f32) void {
    const f = std.math.clamp(factor, min_hitch_factor, max_hitch_factor);
    self.hitch_x100.store(@intFromFloat(f * 100), .monotonic);
    self.computed_ns.store(0, .release);
}

pub fn hitchFactor(self: *const FrameStats) f32 {
    return @as(f32, @floatFromInt(self.hitch_x100.load(.monotonic))) / 100;
}

/// At most `refresh_ns` old. Any thread, never blocks.
pub fn stats(self: *FrameStats) Stats {
    const now = core.timing.now();
    const computed = self.computed_ns.load(.acquire);
    if (computed == 0 or now -| computed >= refresh_ns) self.refresh(now);
    return self.cache[self.current.load(.acquire)];
}

fn refresh(self: *FrameStats, now: u64) void {
    if (self.computing.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return;
    defer self.computing.store(false, .release);
    const next = 1 - self.current.load(.monotonic);
    self.cache[next] = self.compute();
    self.current.store(next, .release);
    self.computed_ns.store(@max(now, 1), .release);
}

/// Under `computing`.
fn compute(self: *FrameStats) Stats {
    const count = self.count.load(.acquire);
    const since = @min(self.since.load(.acquire), count);
    const factor = self.hitchFactor();
    var out: Stats = .{ .hitch_factor = factor };

    const frames = count - since;
    out.total_frames = @intCast(@min(frames, std.math.maxInt(usize)));
    if (frames > 0) {
        out.total_avg_ms = @floatCast(@as(f64, @floatFromInt(self.total_us.load(.monotonic))) / @as(f64, @floatFromInt(frames)) / 1000);
        out.total_min_ms = ms(self.min_us.load(.monotonic));
        out.total_max_ms = ms(self.max_us.load(.monotonic));
    }

    // Newest back, till the window's full
    const available = @min(frames, capacity);
    const window_us = @as(u64, self.window_ms.load(.monotonic)) * std.time.us_per_ms;
    var n: usize = 0;
    var sum_us: u64 = 0;
    while (n < available and sum_us < window_us) : (n += 1) {
        const us = atomic.load(u32, &self.times_us[slot(count - 1 - n)], .monotonic);
        self.scratch[n] = ms(us);
        sum_us += us;
    }
    if (n == 0) return out;
    const sorted = self.scratch[0..n];
    std.mem.sort(f32, sorted, {}, std.sort.asc(f32));

    const avg = @as(f32, @floatFromInt(sum_us)) / @as(f32, @floatFromInt(n)) / 1000;
    out.window_seconds = @as(f32, @floatFromInt(sum_us)) / std.time.us_per_s;
    out.frames = @intCast(n);
    out.avg_ms = avg;
    out.fps = fps(avg);
    out.min_ms = sorted[0];
    out.max_ms = sorted[n - 1];
    out.p50_ms = percentile(sorted, 0.5);
    out.p95_ms = percentile(sorted, 0.95);
    out.p99_ms = percentile(sorted, 0.99);
    out.low_1_fps = fps(out.p99_ms);
    out.low_01_fps = fps(percentile(sorted, 0.999));
    const limit = out.p50_ms * factor;
    for (sorted) |t| {
        if (t > limit) out.hitches += 1;
    }
    return out;
}

/// The newest frame times in ms into `out`, oldest first. Gives the part it wrote. Any thread.
pub fn times(self: *const FrameStats, out: []f32) []f32 {
    const count = self.count.load(.acquire);
    const since = @min(self.since.load(.acquire), count);
    const n = @min(out.len, count - since, capacity);
    for (out[0..n], 0..) |*t, i| t.* = ms(atomic.load(u32, &self.times_us[slot(count - n + i)], .monotonic));
    return out[0..n];
}

/// Where frame number `i` lives.
fn slot(i: u64) usize {
    return @intCast(i % capacity);
}

/// Nearest rank.
fn percentile(sorted: []const f32, p: f32) f32 {
    const rank: usize = @intFromFloat(@ceil(p * @as(f32, @floatFromInt(sorted.len))));
    return sorted[std.math.clamp(rank, 1, sorted.len) - 1];
}

fn ms(us: u32) f32 {
    return @as(f32, @floatFromInt(us)) / 1000;
}

fn fps(frame_ms: f32) f32 {
    return if (frame_ms > 0) 1000 / frame_ms else 0;
}

const tests = struct {
    const testing = std.testing;

    fn feed(f: *FrameStats, frame_ms: []const f32) void {
        var now: u64 = if (f.last_ns == 0) 1_000_000 else f.last_ns;
        if (f.last_ns == 0) f.record(now);
        for (frame_ms) |t| {
            now += @intFromFloat(t * std.time.ns_per_ms);
            f.record(now);
        }
    }

    test "window stats" {
        const f = try testing.allocator.create(FrameStats);
        defer testing.allocator.destroy(f);
        f.* = .{};
        // 98 frames at 10 ms and two hitches
        var frame_ms: [100]f32 = @splat(10);
        frame_ms[40] = 50;
        frame_ms[70] = 30;
        feed(f, &frame_ms);

        const s = f.stats();
        try testing.expectEqual(100, s.frames);
        try testing.expectEqual(100, s.total_frames);
        try testing.expectApproxEqAbs(10.6, s.avg_ms, 0.001);
        try testing.expectApproxEqAbs(1000.0 / 10.6, s.fps, 0.01);
        try testing.expectEqual(10, s.min_ms);
        try testing.expectEqual(50, s.max_ms);
        try testing.expectEqual(10, s.p50_ms);
        try testing.expectEqual(10, s.p95_ms);
        try testing.expectEqual(30, s.p99_ms);
        try testing.expectApproxEqAbs(1000.0 / 30.0, s.low_1_fps, 0.01);
        try testing.expectEqual(20, s.low_01_fps);
        try testing.expectEqual(2, s.hitches);
        try testing.expectApproxEqAbs(1.06, s.window_seconds, 0.001);

        // Cached until it's stale or something changes
        feed(f, &.{ 100, 100 });
        try testing.expectEqual(100, f.stats().frames);
        f.setHitchFactor(4);
        try testing.expectEqual(102, f.stats().frames);
        try testing.expectEqual(3, f.stats().hitches);
    }

    test "window length and reset" {
        const f = try testing.allocator.create(FrameStats);
        defer testing.allocator.destroy(f);
        f.* = .{};
        f.setWindow(1);
        const frame_ms: [300]f32 = @splat(10);
        feed(f, &frame_ms);
        var s = f.stats();
        // Just the newest second's worth
        try testing.expectEqual(100, s.frames);
        try testing.expectEqual(300, s.total_frames);

        var out: [4]f32 = undefined;
        try testing.expectEqual(4, f.times(&out).len);

        f.reset();
        s = f.stats();
        try testing.expectEqual(0, s.frames);
        try testing.expectEqual(0, s.total_frames);
        try testing.expectEqual(0, f.times(&out).len);
        feed(f, &.{ 20, 40 });
        // Cached for a moment, so ask again
        f.computed_ns.store(0, .release);
        s = f.stats();
        try testing.expectEqual(2, s.total_frames);
        try testing.expectEqual(30, s.total_avg_ms);
        try testing.expectEqual(20, s.total_min_ms);
        try testing.expectEqualSlices(f32, &.{ 20, 40 }, f.times(&out));

        f.setWindow(1000);
        try testing.expectEqual(max_window_seconds, f.window());
    }

    test "wraps past capacity" {
        const f = try testing.allocator.create(FrameStats);
        defer testing.allocator.destroy(f);
        f.* = .{};
        f.setWindow(max_window_seconds);
        const frame_ms: [capacity + 10]f32 = @splat(1);
        feed(f, &frame_ms);
        const s = f.stats();
        try testing.expectEqual(capacity, s.frames);
        try testing.expectEqual(capacity + 10, s.total_frames);
    }
};

test {
    _ = tests;
}
