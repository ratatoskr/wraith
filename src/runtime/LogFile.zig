//! The runtime's log file, one per game process. Callers only copy the line into a queue, so a render thread
//! never waits on the disk. A thread of ours writes it out within a few ms, and `flush` empties it on a crash.

const LogFile = @This();

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const core = @import("wraith_core");
const platform = @import("wraith_platform");
const tuft_sys = @import("tuft_sys");

const LogHistory = @import("LogHistory.zig");
const Files = @import("Files.zig");

pub const keep = 20;

/// Guards `file` and draining.
lock: tuft_sys.sync.RwLock = .{},
file: ?platform.fs.AppendFile = null,
queue: Queue = .{},
/// What draining copies into, under `lock`.
chunk: [64 << 10]u8 = undefined,
writer: ?std.Thread = null,
stopping: Atomic(bool) = .init(false),
/// Between `open` and `close`.
accepting: Atomic(bool) = .init(false),
path_buf: [1024]u8 = undefined,
path_len: usize = 0,

pub var global: LogFile = .{};

pub fn open(self: *LogFile, allocator: std.mem.Allocator, io: std.Io, dir: []const u8, exe: []const u8, pid: u32, history: ?*LogHistory) !void {
    self.close();
    const exe_name = std.fs.path.basename(exe);
    const stem = if (std.ascii.endsWithIgnoreCase(exe_name, ".exe")) exe_name[0 .. exe_name.len - 4] else exe_name;
    var name_buf: [300]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "{s}-{d}.log", .{ stem, pid });
    const full = try std.fmt.bufPrint(&self.path_buf, "{s}{c}{s}", .{ dir, std.fs.path.sep, name });
    self.path_len = full.len;

    // std's file calls want more stack than this thread may have
    var preparing = try io.concurrent(prepare, .{ allocator, io, dir, name });
    try preparing.await(io);

    const file = try platform.fs.AppendFile.open(full);
    {
        self.lock.lock();
        defer self.lock.unlock();
        self.file = file;
    }
    self.accepting.store(true, .release);
    // Without it, lines still get written by `flush` and `close`
    self.writer = std.Thread.spawn(.{}, writeOut, .{self}) catch null;

    const t = platform.time.localNow();
    var line_buf: [512]u8 = undefined;
    self.writeRaw(std.fmt.bufPrint(&line_buf, "--- {s} (pid {d}), {d}-{d:0>2}-{d:0>2} ---\r\n", .{ exe_name, pid, t.year, t.month, t.day }) catch return);
    if (history) |h| {
        var entries: [16]LogHistory.Entry = undefined;
        var seq: u64 = 0;
        while (true) {
            const got = h.readSince(seq, &entries);
            if (got.len == 0) break;
            for (got) |*e| self.writeLine(e.level, @tagName(e.subsystem), e.message());
            seq = got[got.len - 1].seq + 1;
        }
    }
}

/// Writes what's queued and closes it. Safe to call twice.
pub fn close(self: *LogFile) void {
    self.accepting.store(false, .release);
    if (self.writer) |w| {
        self.stopping.store(true, .release);
        w.join();
        self.writer = null;
        self.stopping.store(false, .release);
    }
    self.flush();
    self.lock.lock();
    defer self.lock.unlock();
    const file = self.file orelse return;
    file.close();
    self.file = null;
}

/// Writes everything queued so far, on this thread. For a crash, where the writer might not get to it.
pub fn flush(self: *LogFile) void {
    while (self.drain()) {}
}

pub fn path(self: *const LogFile) []const u8 {
    return self.path_buf[0..self.path_len];
}

pub fn write(self: *LogFile, record: *const core.log.Record) void {
    self.writeLine(record.level, record.scope, record.message);
}

fn writeLine(self: *LogFile, level: std.log.Level, scope: []const u8, message: []const u8) void {
    const t = platform.time.localNow();
    var buf: [core.log.max_message_len + 160]u8 = undefined;
    var w: std.Io.Writer = .fixed(buf[0 .. buf.len - 5]);
    w.print("{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} {s: <5} ({s}): {s}", .{ t.hour, t.minute, t.second, t.millisecond, @tagName(level), scope, message }) catch {};
    const n = w.buffered().len;
    const end: []const u8 = if (n == buf.len - 5) "...\r\n" else "\r\n";
    @memcpy(buf[n..][0..end.len], end);
    self.writeRaw(buf[0 .. n + end.len]);
}

fn writeRaw(self: *LogFile, bytes: []const u8) void {
    // Before `open` there's nowhere for it to go, and `open` writes the history then
    if (!self.accepting.load(.acquire)) return;
    self.queue.push(bytes);
}

fn writeOut(self: *LogFile) void {
    // Or every line written shows on the IO page
    Files.ignoreThread();
    while (!self.stopping.load(.acquire)) {
        if (!self.drain()) tuft_sys.thread.sleepMs(5);
    }
}

/// False once there's nothing left.
fn drain(self: *LogFile) bool {
    self.lock.lock();
    defer self.lock.unlock();
    const file = self.file orelse return false;
    const taken = self.queue.take(&self.chunk);
    if (taken.dropped > 0) {
        var buf: [96]u8 = undefined;
        file.write(std.fmt.bufPrint(&buf, "(dropped {d} line(s), the log couldn't keep up)\r\n", .{taken.dropped}) catch "");
    }
    if (taken.bytes.len == 0) return false;
    file.write(taken.bytes);
    return true;
}

/// Lines waiting to be written. Whole lines go in or none, so a full queue drops lines, not halves.
const Queue = struct {
    const size = 256 << 10;

    busy: Atomic(bool) = .init(false),
    bytes: [size]u8 = undefined,
    /// Both only count up. `head - tail` is what's queued.
    head: usize = 0,
    tail: usize = 0,
    dropped: u32 = 0,

    fn push(self: *Queue, line: []const u8) void {
        self.acquire();
        defer self.release();
        if (line.len > size - (self.head - self.tail)) {
            self.dropped +|= 1;
            return;
        }
        const at = self.head % size;
        const first = @min(line.len, size - at);
        @memcpy(self.bytes[at..][0..first], line[0..first]);
        @memcpy(self.bytes[0 .. line.len - first], line[first..]);
        self.head += line.len;
    }

    const Taken = struct { bytes: []const u8, dropped: u32 };

    fn take(self: *Queue, out: []u8) Taken {
        self.acquire();
        defer self.release();
        const n = @min(out.len, self.head - self.tail);
        const at = self.tail % size;
        const first = @min(n, size - at);
        @memcpy(out[0..first], self.bytes[at..][0..first]);
        @memcpy(out[first..n], self.bytes[0 .. n - first]);
        self.tail += n;
        defer self.dropped = 0;
        return .{ .bytes = out[0..n], .dropped = self.dropped };
    }

    fn acquire(self: *Queue) void {
        while (self.busy.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn release(self: *Queue) void {
        self.busy.store(false, .release);
    }
};
fn prepare(allocator: std.mem.Allocator, io: std.Io, dir: []const u8, own: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, dir);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    prune(arena.allocator(), io, dir, keep - 1, own) catch |err| {
        core.log.scoped(.wraith_runtime).warn("Couldn't delete old logs in {s}: {t}", .{ dir, err });
    };
}

fn prune(arena: std.mem.Allocator, io: std.Io, dir_path: []const u8, count: usize, except: []const u8) !void {
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    const Log = struct { name: []const u8, mtime: i96 };
    var logs: std.ArrayList(Log) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.ascii.endsWithIgnoreCase(entry.name, ".log")) continue;
        if (std.ascii.eqlIgnoreCase(entry.name, except)) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        try logs.append(arena, .{ .name = try arena.dupe(u8, entry.name), .mtime = stat.mtime.nanoseconds });
    }
    if (logs.items.len <= count) return;
    std.mem.sort(Log, logs.items, {}, struct {
        fn newerFirst(_: void, a: Log, b: Log) bool {
            return a.mtime > b.mtime;
        }
    }.newerFirst);
    // One still open by another game can't be deleted
    for (logs.items[count..]) |old| dir.deleteFile(io, old.name) catch {};
}

const tests = struct {
    const testing = std.testing;
    const io = testing.io;

    test "appends a line per message" {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
        defer testing.allocator.free(root);
        const dir = try std.fs.path.join(testing.allocator, &.{ root, "logs" });
        defer testing.allocator.free(dir);

        // Too big for the stack, with its queue
        const S = struct {
            var log: LogFile = .{};
        };
        const log = &S.log;
        for (0..2) |run| {
            try log.open(testing.allocator, io, dir, "C:\\Games\\Kai.exe", 42, null);
            log.write(&.{ .level = .warn, .subsystem = .runtime, .scope = "wraith_runtime", .message = if (run == 0) "first" else "second" });
            log.close();
        }
        log.write(&.{ .level = .err, .subsystem = .runtime, .scope = "x", .message = "after closing" });

        const text = try std.Io.Dir.cwd().readFileAlloc(io, log.path(), testing.allocator, .limited(4096));
        defer testing.allocator.free(text);
        try testing.expect(std.mem.endsWith(u8, log.path(), "Kai-42.log"));
        var lines = std.mem.splitSequence(u8, std.mem.trimEnd(u8, text, "\r\n"), "\r\n");
        var n: usize = 0;
        while (lines.next()) |line| : (n += 1) {
            switch (n) {
                0, 2 => try testing.expect(std.mem.startsWith(u8, line, "--- Kai.exe (pid 42), ")),
                1, 3 => try testing.expect(std.mem.endsWith(u8, line, if (n == 1) " warn  (wraith_runtime): first" else " warn  (wraith_runtime): second")),
                else => return error.TooManyLines,
            }
        }
        try testing.expectEqual(4, n);
    }

    test "queue wraps, and drops whole lines when full" {
        // Too big for the stack
        const S = struct {
            var q: Queue = .{};
            var out: [Queue.size]u8 = undefined;
        };
        const q = &S.q;
        const out = &S.out;
        const line: [1000]u8 = @splat('x');
        // Most of the way round, so the next ones wrap
        for (0..200) |_| q.push(&line);
        try testing.expectEqual(200 * line.len, q.take(out).bytes.len);
        for (0..262) |_| q.push(&line);
        q.push(&line);
        const taken = q.take(out);
        try testing.expectEqual(262 * line.len, taken.bytes.len);
        try testing.expectEqual(1, taken.dropped);
        for (taken.bytes) |b| try testing.expectEqual('x', b);
    }

    test "pruning keeps the newest" {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const names = [_][]const u8{ "a-1.log", "b-2.log", "c-3.log", "d-4.log", "notes.txt" };
        for (names, 0..) |name, i| {
            const file = try tmp.dir.createFile(io, name, .{});
            defer file.close(io);
            try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = @as(i96, @intCast(i + 1)) * std.time.ns_per_hour } } });
        }
        const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
        defer testing.allocator.free(root);
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        try prune(arena.allocator(), io, root, 2, "a-1.log");

        for (names, [_]bool{ true, false, true, true, true }) |name, kept| {
            const exists = if (tmp.dir.access(io, name, .{})) |_| true else |_| false;
            try testing.expectEqual(kept, exists);
        }
    }
};

test {
    _ = tests;
}
