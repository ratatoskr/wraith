//! Recent log messages for the Log window, in a fixed ring.

const LogHistory = @This();

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const core = @import("wraith_core");
const Message = @import("tuft_text").Message;

pub const capacity = 1024;
pub const max_text = 240;

pub const Entry = struct {
    seq: u64,
    time_ns: u64,
    level: std.log.Level,
    subsystem: core.log.Subsystem,
    text: Message(max_text),

    pub fn message(self: *const Entry) []const u8 {
        return self.text.message();
    }
};

lock: Atomic(bool) = .init(false),
entries: [capacity]Entry = undefined,
next_seq: u64 = 0,
/// Times are shown relative to this.
start_ns: u64 = 0,

pub var global: LogHistory = .{};

pub const sink: core.log.Sink = .{ .write = record };

fn record(r: *const core.log.Record) void {
    global.add(r.level, r.subsystem, r.message);
    core.log.default_sink.write(r);
}

pub fn add(self: *LogHistory, level: std.log.Level, subsystem: core.log.Subsystem, text: []const u8) void {
    const time = core.timing.now();
    self.acquire();
    defer self.release();
    if (self.next_seq == 0) self.start_ns = time;
    const e = &self.entries[@intCast(self.next_seq % capacity)];
    e.* = .{ .seq = self.next_seq, .time_ns = time -| self.start_ns, .level = level, .subsystem = subsystem, .text = .{} };
    e.text.set(text);
    self.next_seq += 1;
}

/// How many have been added, ever. The next one's `seq`.
pub fn count(self: *LogHistory) u64 {
    self.acquire();
    defer self.release();
    return self.next_seq;
}

/// Next time, read from the last one's `seq + 1`.
pub fn readSince(self: *LogHistory, seq: u64, out: []Entry) []Entry {
    self.acquire();
    defer self.release();
    const oldest = self.next_seq -| capacity;
    const start = @max(seq, oldest);
    const n: usize = @intCast(@min(self.next_seq -| start, out.len));
    for (out[0..n], 0..) |*dest, i| dest.* = self.entries[@intCast((start + i) % capacity)];
    return out[0..n];
}

fn acquire(self: *LogHistory) void {
    while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn release(self: *LogHistory) void {
    self.lock.store(false, .release);
}

const tests = struct {
    test "readSince returns what's new" {
        const history = try std.testing.allocator.create(LogHistory);
        defer std.testing.allocator.destroy(history);
        history.* = .{};

        history.add(.info, .runtime, "one");
        history.add(.warn, .plugin, "two");
        var out: [4]Entry = undefined;
        const got = history.readSince(0, &out);
        try std.testing.expectEqual(2, got.len);
        try std.testing.expectEqualStrings("one", got[0].message());
        try std.testing.expectEqual(.plugin, got[1].subsystem);
        try std.testing.expectEqual(0, history.readSince(got[1].seq + 1, &out).len);

        for (0..capacity + 5) |_| history.add(.debug, .core, "filler");
        const kept = history.readSince(0, &out);
        try std.testing.expectEqual(history.next_seq - capacity, kept[0].seq);
    }

    test "long messages are cut" {
        const history = try std.testing.allocator.create(LogHistory);
        defer std.testing.allocator.destroy(history);
        history.* = .{};
        const long: [max_text + 50]u8 = @splat('x');
        history.add(.err, .ui, &long);
        var out: [1]Entry = undefined;
        try std.testing.expectEqual(max_text, history.readSince(0, &out)[0].message().len);
    }
};

test {
    _ = tests;
}
