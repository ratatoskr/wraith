//! The game's file I/O, through tuft's VFS. Keeps recent activity for the workbench's IO page.

const Files = @This();

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const core = @import("wraith_core");
pub const Vfs = @import("tuft_vfs");
const Message = @import("tuft_text").Message;

const log = core.log.scoped(.wraith_runtime);

pub const capacity = 4096;
pub const max_path = 240;

pub const Op = enum(u8) {
    open,
    /// An open that failed, or that a listener refused.
    fail,
    read,
    write,
    /// A write a listener refused.
    refused,
    close,
};

pub const Entry = struct {
    seq: u64 = 0,
    time_ns: u64 = 0,
    op: Op,
    /// `Vfs.File.id`, 0 for a failed open.
    file: u64,
    thread: u32,
    /// Back to back reads or writes of a file add up in one entry.
    count: u32 = 1,
    bytes: u64 = 0,
    /// The system's status for `fail`, like an NTSTATUS.
    status: u32 = 0,
    virtual: bool = false,
    /// Opened somewhere else than asked, by a listener.
    redirected: bool = false,
    path: Message(max_path) = .{},
};

lock: Atomic(bool) = .init(false),
entries: [capacity]Entry = undefined,
next_seq: u64 = 0,
start_ns: u64 = 0,
/// Off stops new entries, not the VFS.
recording: Atomic(bool) = .init(true),
vfs: ?*Vfs = null,
subs: Subs = .{},

const Subs = struct {
    opened: ?@FieldType(Vfs, "opened").Subscription = null,
    open_failed: ?@FieldType(Vfs, "open_failed").Subscription = null,
    read: ?@FieldType(Vfs, "read").Subscription = null,
    write: ?@FieldType(Vfs, "write").Subscription = null,
    closed: ?@FieldType(Vfs, "closed").Subscription = null,
};

pub var global: Files = .{};

/// Hooks the file calls. Nothing happens if that fails, besides a warning.
pub fn start(self: *Files, allocator: std.mem.Allocator) void {
    const vfs = Vfs.init(allocator) catch |err| {
        log.warn("Can't watch the game's files: {t}", .{err});
        return;
    };
    self.vfs = vfs;
    // Last, so it sees what other listeners did
    const last: @import("tuft_event").event.Options = .{ .priority = std.math.minInt(i32) };
    inline for (.{ "opened", "open_failed", "read", "write", "closed" }, .{ onOpened, onFailed, onRead, onWrite, onClosed }) |name, func| {
        @field(self.subs, name) = @field(vfs, name).subscribeUnscopedOpts(self, func, last) catch |err| blk: {
            log.warn("Can't record file activity: {t}", .{err});
            break :blk null;
        };
    }
}

/// Unhooks. Virtual files the game still has open stop working.
pub fn stop(self: *Files) void {
    inline for (@typeInfo(Subs).@"struct".field_names) |name| {
        if (@field(self.subs, name)) |s| s.unsubscribe();
        @field(self.subs, name) = null;
    }
    if (self.vfs) |v| v.deinit();
    self.vfs = null;
}

/// For our own threads that do file I/O, like the log writer.
pub const ignoreThread = Vfs.ignoreThread;

fn onOpened(self: *Files, f: *const Vfs.File) void {
    self.add(.{ .op = .open, .file = f.id, .thread = f.thread, .virtual = f.kind == .virtual, .redirected = f.requested != null }, f.path);
}

fn onFailed(self: *Files, req: *const Vfs.OpenRequest, status: u32) void {
    // Existence checks that miss are too common to be worth a line
    if (req.query) return;
    self.add(.{ .op = .fail, .file = 0, .thread = req.thread, .status = status, .redirected = req.path.ptr != req.requested.ptr }, req.requested);
}

fn onRead(self: *Files, r: *Vfs.Read) void {
    self.addIo(.read, r.file, r.data.len);
}

fn onWrite(self: *Files, w: *Vfs.Write) void {
    self.addIo(if (w.denied != null) .refused else .write, w.file, w.data.len);
}

fn onClosed(self: *Files, f: *const Vfs.File) void {
    self.add(.{ .op = .close, .file = f.id, .thread = f.thread, .virtual = f.kind == .virtual, .bytes = f.stats.bytes_read.load(.monotonic) + f.stats.bytes_written.load(.monotonic) }, f.path);
}

fn addIo(self: *Files, op: Op, f: *const Vfs.File, bytes: usize) void {
    if (!self.recording.load(.monotonic)) return;
    self.acquire();
    if (self.next_seq > 0) {
        const last = &self.entries[@intCast((self.next_seq - 1) % capacity)];
        if (last.op == op and last.file == f.id) {
            last.count +|= 1;
            last.bytes += bytes;
            last.time_ns = core.timing.now() -| self.start_ns;
            self.release();
            return;
        }
    }
    self.release();
    self.add(.{ .op = op, .file = f.id, .thread = Vfs.native.threadId(), .bytes = bytes, .virtual = f.kind == .virtual }, f.path);
}

fn add(self: *Files, entry: Entry, path: []const u8) void {
    if (!self.recording.load(.monotonic)) return;
    const time = core.timing.now();
    self.acquire();
    defer self.release();
    if (self.next_seq == 0) self.start_ns = time;
    const e = &self.entries[@intCast(self.next_seq % capacity)];
    e.* = entry;
    e.seq = self.next_seq;
    e.time_ns = time -| self.start_ns;
    e.path = .{};
    e.path.set(path);
    self.next_seq += 1;
}

/// Next time, read from the last `seq + 1`. Coalesced entries repeat as they grow; take the newest.
pub fn readSince(self: *Files, seq: u64, out: []Entry) []Entry {
    self.acquire();
    defer self.release();
    const oldest = self.next_seq -| capacity;
    const start_at = @max(seq, oldest);
    const n: usize = @intCast(@min(self.next_seq -| start_at, out.len));
    for (out[0..n], 0..) |*dest, i| dest.* = self.entries[@intCast((start_at + i) % capacity)];
    return out[0..n];
}

/// The newest entry, which can still grow.
pub fn latest(self: *Files) ?Entry {
    self.acquire();
    defer self.release();
    if (self.next_seq == 0) return null;
    return self.entries[@intCast((self.next_seq - 1) % capacity)];
}

fn acquire(self: *Files) void {
    while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn release(self: *Files) void {
    self.lock.store(false, .release);
}

const tests = struct {
    const testing = std.testing;

    test "back to back reads add up" {
        const files = try testing.allocator.create(Files);
        defer testing.allocator.destroy(files);
        files.* = .{};
        var f: Vfs.File = undefined;
        f.id = 7;
        f.path = "C:/a.pak";
        f.kind = .real;
        files.addIo(.read, &f, 10);
        files.addIo(.read, &f, 5);
        files.addIo(.write, &f, 1);
        var out: [4]Entry = undefined;
        const got = files.readSince(0, &out);
        try testing.expectEqual(2, got.len);
        try testing.expectEqual(2, got[0].count);
        try testing.expectEqual(15, got[0].bytes);
        try testing.expectEqualStrings("C:/a.pak", got[0].path.message());
        try testing.expectEqual(.write, got[1].op);
    }
};

test {
    _ = tests;
}
