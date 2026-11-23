//! Game speed, like Cheat Engine's speedhack, for games without a plugin that handles their speed.
//! Wraith only speeds games up this way, since games cap their frame rate with the same clocks, so
//! slowing them slows the frame rate, and Wraith's windows drawn with it. The clocks games time
//! their frames with are hooked,
//! and each reads as where it was when the speed last changed, plus the real time since times the
//! speed. Calls from Wraith's own code and its plugins' still get the real time, so Wraith's UI,
//! timers and frame stats don't change. Nothing's hooked till the speed first isn't 1.
//!
//! Nearly every game reads its time from the hooked clocks. A few read the CPU's counter or
//! Windows' shared time page themselves, which can't be hooked.

const std = @import("std");
const builtin = @import("builtin");
const tuft_arch = @import("tuft_arch");
const sync = @import("tuft_sys").sync;

const clocks = if (builtin.os.tag == .windows) @import("win/clocks.zig") else struct {
    pub fn install() !void {
        return error.Unsupported;
    }
    pub fn now(_: Clock) ?u64 {
        return null;
    }
    pub fn uninstall() void {}
};

const Atomic = tuft_arch.atomic.Value;

pub const min = 0.01;
pub const max = 100;

/// The kinds of clock, each in its own units. `ticks` is milliseconds, `counter` the performance
/// counter's ticks, and `multimedia` milliseconds that wrap at 32 bits.
pub const Clock = enum { counter, ticks, multimedia };

/// Where a clock's fake time picks up from, as of the last change.
const Base = struct {
    real: Atomic(u64) = .init(0),
    fake: Atomic(u64) = .init(0),
};

/// Readers retry while it's odd, or if it changed while they read.
var seq: Atomic(u32) = .init(0);
var speed_bits: Atomic(u64) = .init(@bitCast(@as(f64, 1)));
var bases: std.EnumArray(Clock, Base) = .initFill(.{});
/// Whether a clock's hooked yet, and so has a base
var live: std.EnumArray(Clock, Atomic(bool)) = .initFill(.init(false));
/// One writer at a time
var writer: sync.RwLock = .{};
var install_lock: sync.RwLock = .{};
var installed = false;

pub fn get() f64 {
    return @bitCast(speed_bits.load(.acquire));
}

/// Hooks the clocks the first time it isn't 1. Clamped to `min` and `max`.
pub fn set(speed: f64) !void {
    const s = std.math.clamp(speed, min, max);
    if (s != 1) try install();
    writer.lock();
    defer writer.unlock();
    const old = get();
    if (s == old) return;
    _ = seq.fetchAdd(1, .acq_rel);
    defer _ = seq.fetchAdd(1, .acq_rel);
    for (std.enums.values(Clock)) |c| if (live.get(c).load(.acquire)) {
        const real = clocks.now(c) orelse continue;
        const b = bases.getPtr(c);
        const f = scaled(b.real.load(.monotonic), b.fake.load(.monotonic), old, real, c);
        b.real.store(real, .monotonic);
        b.fake.store(f, .monotonic);
    };
    speed_bits.store(@bitCast(s), .release);
}

/// For the hooks, once `c`'s hooked, with its real time now. It carries on from there.
pub fn start(c: Clock, real: u64) void {
    writer.lock();
    defer writer.unlock();
    _ = seq.fetchAdd(1, .acq_rel);
    defer _ = seq.fetchAdd(1, .acq_rel);
    const b = bases.getPtr(c);
    b.real.store(real, .monotonic);
    b.fake.store(real, .monotonic);
    live.getPtr(c).store(true, .release);
}

/// Puts the clocks back before Wraith goes. The game's time jumps back to the real time, which
/// most games take in their stride.
pub fn stop() void {
    install_lock.lock();
    defer install_lock.unlock();
    if (!installed) return;
    clocks.uninstall();
    installed = false;
    writer.lock();
    defer writer.unlock();
    for (std.enums.values(Clock)) |c| live.getPtr(c).store(false, .release);
    speed_bits.store(@bitCast(@as(f64, 1)), .release);
}

fn install() !void {
    install_lock.lock();
    defer install_lock.unlock();
    if (installed) return;
    try clocks.install();
    installed = true;
}

/// For the hooks: what `c` should read, given its real time.
pub fn fake(c: Clock, real: u64) u64 {
    if (!live.get(c).load(.acquire)) return real;
    const b = bases.getPtr(c);
    while (true) {
        const before = seq.load(.acquire);
        if (before & 1 != 0) {
            std.atomic.spinLoopHint();
            continue;
        }
        const r = b.real.load(.monotonic);
        const f = b.fake.load(.monotonic);
        const s: f64 = @bitCast(speed_bits.load(.monotonic));
        if (seq.load(.acquire) == before) return scaled(r, f, s, real, c);
    }
}

fn scaled(real_base: u64, fake_base: u64, speed: f64, real: u64, c: Clock) u64 {
    if (c == .multimedia) {
        // Milliseconds since boot in 32 bits, which wrap every 49 days
        const since: u32 = @truncate(real -% real_base);
        const moved: u32 = @intFromFloat(@as(f64, @floatFromInt(since)) * speed);
        return @as(u32, @truncate(fake_base)) +% moved;
    }
    // A clock read just before a change can come in after it
    if (real < real_base) return fake_base;
    return fake_base + @as(u64, @intFromFloat(@as(f64, @floatFromInt(real - real_base)) * speed));
}

/// Code that gets the real time: Wraith's own, and its native plugins'. Any thread.
pub const own = struct {
    const Range = struct {
        start: Atomic(usize) = .init(0),
        len: Atomic(usize) = .init(0),
    };
    var ranges: [64]Range = @splat(.{});

    pub fn add(start_at: usize, len: usize) void {
        if (start_at == 0 or len == 0) return;
        for (&ranges) |*r| {
            if (r.start.cmpxchgStrong(0, start_at, .acq_rel, .acquire) == null) {
                r.len.store(len, .release);
                return;
            }
        }
    }

    pub fn remove(start_at: usize) void {
        for (&ranges) |*r| if (r.start.load(.acquire) == start_at) {
            r.len.store(0, .release);
            r.start.store(0, .release);
        };
    }

    pub fn contains(at: usize) bool {
        for (&ranges) |*r| {
            const s = r.start.load(.acquire);
            if (s != 0 and at >= s and at - s < r.len.load(.acquire)) return true;
        }
        return false;
    }
};

const testing = std.testing;

test "time runs at the speed since it changed, and never goes back" {
    // Twice as fast from 100, then half from 200
    try testing.expectEqual(100, scaled(100, 100, 2, 100, .counter));
    try testing.expectEqual(300, scaled(100, 100, 2, 200, .counter));
    try testing.expectEqual(325, scaled(200, 300, 0.5, 250, .counter));
    // Read just before the change, so it holds where the change put it
    try testing.expectEqual(300, scaled(200, 300, 0.5, 150, .counter));
}

test "the multimedia clock wraps at 32 bits" {
    const near_end: u64 = std.math.maxInt(u32) - 10;
    // 20 real milliseconds on, past the wrap, at double speed
    try testing.expectEqual(29, scaled(near_end, near_end, 2, near_end + 20, .multimedia));
    try testing.expectEqual(29, scaled(near_end, near_end, 2, 9, .multimedia));
}

test "own code is known by where it is" {
    own.add(0x1000, 0x100);
    defer own.remove(0x1000);
    try testing.expect(own.contains(0x1000));
    try testing.expect(own.contains(0x10ff));
    try testing.expect(!own.contains(0x1100));
    try testing.expect(!own.contains(0xfff));
}

test "the game's clocks run at its speed, and Wraith's don't" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const tuft_hook = @import("tuft_hook");
    const module = @import("tuft_sys").module;
    try tuft_hook.init(testing.allocator);
    defer tuft_hook.deinit();
    defer stop();
    try set(4);
    try testing.expectEqual(4, get());

    const kernel32 = module.findBase("kernel32.dll").?;
    const qpc: *const fn (*i64) callconv(.winapi) i32 = @ptrFromInt(module.findExport(kernel32, "QueryPerformanceCounter").?);
    const ticks: *const fn () callconv(.winapi) u64 = @ptrFromInt(module.findExport(kernel32, "GetTickCount64").?);
    const Read = struct {
        fn counter(f: *const fn (*i64) callconv(.winapi) i32) u64 {
            var v: i64 = 0;
            _ = f(&v);
            return @bitCast(v);
        }
    };

    // This test is Wraith's own code, so it keeps real time
    {
        const c0 = Read.counter(qpc);
        const r0 = clocks.now(.counter).?;
        @import("tuft_sys").thread.sleepMs(50);
        const ratio = @as(f64, @floatFromInt(Read.counter(qpc) - c0)) / @as(f64, @floatFromInt(clocks.now(.counter).? - r0));
        try testing.expect(ratio > 0.9 and ratio < 1.1);
    }

    // As the game, it runs four times as fast
    const self_base = module.selfBase();
    own.remove(self_base);
    defer own.add(self_base, module.imageSize(self_base) catch 0);
    const c0 = Read.counter(qpc);
    const r0 = clocks.now(.counter).?;
    const t0 = ticks();
    const tr0 = clocks.now(.ticks).?;
    @import("tuft_sys").thread.sleepMs(200);
    const c1 = Read.counter(qpc);
    const r1 = clocks.now(.counter).?;
    const t1 = ticks();
    const tr1 = clocks.now(.ticks).?;
    const counter_ratio = @as(f64, @floatFromInt(c1 - c0)) / @as(f64, @floatFromInt(r1 - r0));
    try testing.expect(counter_ratio > 3.6 and counter_ratio < 4.4);
    // Tick counts move every 16ms or so
    const ticks_ratio = @as(f64, @floatFromInt(t1 - t0)) / @as(f64, @floatFromInt(tr1 - tr0));
    try testing.expect(ticks_ratio > 3 and ticks_ratio < 5);

    // Slowing down carries on from where it got to, without going back
    try set(0.5);
    const c2 = Read.counter(qpc);
    try testing.expect(c2 >= c1);
}
