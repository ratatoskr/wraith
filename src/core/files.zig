//! File writes on an `Io` worker: std's Windows file calls need more stack than game threads have.

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

pub const Options = struct {
    /// Makes its folder first.
    make_dir: bool = false,
    /// Writes a temp file and renames it over, so a crash can't leave half a file.
    replace: bool = false,
};

/// Writes `data` to `path` on a worker and waits for it. Not for the render thread.
pub fn write(io: std.Io, path: []const u8, data: []const u8, options: Options) !void {
    var writing = try io.concurrent(writeHere, .{ io, path, data, options });
    return writing.await(io);
}

/// Needs a worker's stack, see `write`.
pub fn writeHere(io: std.Io, path: []const u8, data: []const u8, options: Options) !void {
    const cwd = std.Io.Dir.cwd();
    if (options.make_dir) if (std.fs.path.dirname(path)) |dir| try cwd.createDirPath(io, dir);
    if (!options.replace) return cwd.writeFile(io, .{ .sub_path = path, .data = data });
    var buf: [std.fs.max_path_bytes + 4]u8 = undefined;
    const tmp = std.fmt.bufPrint(&buf, "{s}.tmp", .{path}) catch return error.NameTooLong;
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = data });
    try cwd.rename(tmp, cwd, path, io);
}

/// Background saves for files like settings; the latest wins. Call `wait` before freeing.
pub const Saver = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options = .{},
    /// On the worker, when a save fails.
    failed: ?*const fn (path: []const u8, err: anyerror) void = null,

    group: std.Io.Group = .init,
    next: Atomic(u32) = .init(0),
    /// Only taken on workers, so callers never wait on a file.
    lock: std.Io.Mutex = .init,
    /// Under `lock`.
    written: u32 = 0,
    /// Under `lock`. From the latest save that ran.
    last_error: ?anyerror = null,

    /// Copies `path` and `data`. Any thread.
    pub fn save(self: *Saver, path: []const u8, data: []const u8) error{ OutOfMemory, ConcurrencyUnavailable }!void {
        const copy = try self.allocator.alloc(u8, path.len + data.len);
        @memcpy(copy[0..path.len], path);
        @memcpy(copy[path.len..], data);
        const number = self.next.fetchAdd(1, .monotonic) +% 1;
        self.group.concurrent(self.io, run, .{ self, copy, path.len, number }) catch |err| {
            self.allocator.free(copy);
            return err;
        };
    }

    /// Waits for saves still going. Returns how the latest one went. One thread at a time.
    pub fn wait(self: *Saver) anyerror!void {
        self.group.await(self.io) catch {};
        // Nothing's running now, so no lock
        defer self.last_error = null;
        if (self.last_error) |err| return err;
    }

    fn run(self: *Saver, copy: []u8, path_len: usize, number: u32) void {
        defer self.allocator.free(copy);
        const path = copy[0..path_len];
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        // A newer one already went out
        if (number -% self.written > std.math.maxInt(u32) / 2) return;
        writeHere(self.io, path, copy[path_len..], self.options) catch |err| {
            self.last_error = err;
            if (self.failed) |f| f(path, err);
            return;
        };
        self.written = number;
        self.last_error = null;
    }
};

const tests = struct {
    const testing = std.testing;
    const io = testing.io;

    fn readBack(dir: std.Io.Dir, name: []const u8) ![]u8 {
        return dir.readFileAlloc(io, name, testing.allocator, .limited(1024));
    }

    fn join(tmp: *testing.TmpDir, name: []const u8) ![]u8 {
        const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
        defer testing.allocator.free(root);
        return std.fs.path.join(testing.allocator, &.{ root, name });
    }

    test "write makes the folder and replaces" {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try join(&tmp, "sub" ++ std.fs.path.sep_str ++ "a.txt");
        defer testing.allocator.free(path);

        try testing.expectError(error.FileNotFound, write(io, path, "x", .{}));
        try write(io, path, "one", .{ .make_dir = true });
        try write(io, path, "two", .{ .replace = true });
        const text = try readBack(tmp.dir, "sub/a.txt");
        defer testing.allocator.free(text);
        try testing.expectEqualStrings("two", text);
        try testing.expectError(error.FileNotFound, tmp.dir.access(io, "sub/a.txt.tmp", .{}));
    }

    test "saver keeps the latest and reports failures" {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try join(&tmp, "b.txt");
        defer testing.allocator.free(path);

        var saver: Saver = .{ .allocator = testing.allocator, .io = io };
        for (0..20) |i| {
            var buf: [8]u8 = undefined;
            try saver.save(path, try std.fmt.bufPrint(&buf, "{d}", .{i}));
        }
        try saver.wait();
        const text = try readBack(tmp.dir, "b.txt");
        defer testing.allocator.free(text);
        try testing.expectEqualStrings("19", text);

        const missing = try join(&tmp, "gone" ++ std.fs.path.sep_str ++ "c.txt");
        defer testing.allocator.free(missing);
        try saver.save(missing, "x");
        try testing.expectError(error.FileNotFound, saver.wait());
        // Reported once
        try saver.wait();
    }
};

test {
    _ = tests;
}
