//! Per-process temp folders, each marked live by a held lock file.

const std = @import("std");

const platform = @import("wraith_platform");

const log = @import("wraith_core").log.scoped(.wraith_bootstrap);

const subdir = "wraith";
const lock_ext = ".lock";

pub const Session = struct {
    path: []const u8,
    lock: std.Io.File,
    lock_path: []const u8,

    pub fn start(allocator: std.mem.Allocator, io: std.Io) !Session {
        const base = try baseAlloc(allocator, io);
        defer allocator.free(base);
        cleanStale(allocator, io, base);
        return startIn(allocator, io, base);
    }

    fn startIn(allocator: std.mem.Allocator, io: std.Io, base: []const u8) !Session {
        var random: [4]u8 = undefined;
        io.random(&random);
        const name = try std.fmt.allocPrint(allocator, "{d}-{s}", .{ platform.process.currentId(), &std.fmt.bytesToHex(random, .lower) });
        defer allocator.free(name);

        // Lock first, so cleanup never thinks this folder is stale
        const lock_path = try std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{ base, std.fs.path.sep_str, name, lock_ext });
        errdefer allocator.free(lock_path);
        const lock = try std.Io.Dir.createFileAbsolute(io, lock_path, .{ .lock = .exclusive, .lock_nonblocking = true });
        errdefer lock.close(io);

        const path = try std.fs.path.join(allocator, &.{ base, name });
        errdefer allocator.free(path);
        try platform.fs.ensureDirectory(io, path);

        return .{ .path = path, .lock = lock, .lock_path = lock_path };
    }

    /// In practice the next `start` somewhere does the cleanup instead.
    pub fn end(self: *Session, allocator: std.mem.Allocator, io: std.Io) void {
        platform.fs.deleteDirectory(io, self.path) catch |err| log.warn("Couldn't delete {s}: {t}", .{ self.path, err });
        self.lock.close(io);
        std.Io.Dir.deleteFileAbsolute(io, self.lock_path) catch {};
        allocator.free(self.path);
        allocator.free(self.lock_path);
        self.* = undefined;
    }

    pub fn subdirAlloc(self: *const Session, allocator: std.mem.Allocator, io: std.Io, sub: []const u8) ![]const u8 {
        const path = try std.fs.path.join(allocator, &.{ self.path, sub });
        errdefer allocator.free(path);
        try platform.fs.ensureDirectory(io, path);
        return path;
    }
};

fn baseAlloc(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const temp = try platform.fs.tempDirAlloc(allocator);
    defer allocator.free(temp);
    const base = try std.fs.path.join(allocator, &.{ temp, subdir });
    errdefer allocator.free(base);
    try platform.fs.ensureDirectory(io, base);
    return base;
}

/// Deletes sessions whose process is gone. Best effort.
pub fn cleanStale(allocator: std.mem.Allocator, io: std.Io, base: []const u8) void {
    var dir = std.Io.Dir.openDirAbsolute(io, base, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        switch (entry.kind) {
            .directory => {
                const lock_name = std.fmt.allocPrint(allocator, "{s}{s}", .{ entry.name, lock_ext }) catch continue;
                defer allocator.free(lock_name);
                const lock = dir.openFile(io, lock_name, .{ .mode = .read_write, .lock = .exclusive, .lock_nonblocking = true }) catch |err| switch (err) {
                    error.WouldBlock => continue, // a running game's
                    error.FileNotFound => {
                        deleteEntry(io, dir, entry.name, .directory);
                        continue;
                    },
                    else => continue,
                };
                // Keep holding it while the folder goes so nobody else grabs it
                deleteEntry(io, dir, entry.name, .directory);
                lock.close(io);
                deleteEntry(io, dir, lock_name, .file);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, lock_ext)) continue;
                const folder = entry.name[0 .. entry.name.len - lock_ext.len];
                if (dir.access(io, folder, .{})) |_| continue else |_| {} // handled with its folder
                const lock = dir.openFile(io, entry.name, .{ .mode = .read_write, .lock = .exclusive, .lock_nonblocking = true }) catch continue;
                lock.close(io);
                deleteEntry(io, dir, entry.name, .file);
            },
            else => {},
        }
    }
}

fn deleteEntry(io: std.Io, dir: std.Io.Dir, name: []const u8, kind: enum { file, directory }) void {
    const result = switch (kind) {
        .directory => dir.deleteTree(io, name),
        .file => dir.deleteFile(io, name),
    };
    result catch |err| log.debug("Couldn't clean up {s} (will retry next time): {t}", .{ name, err });
}

const tests = struct {
    const testing = std.testing;

    fn scratchBase(io: std.Io, tmp: *std.testing.TmpDir) ![:0]u8 {
        return tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    }

    test "stale sessions cleaned" {
        const io = testing.io;
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const base = try scratchBase(io, &tmp);
        defer testing.allocator.free(base);

        // One live session from another game and one whose game exited
        var live = try Session.startIn(testing.allocator, io, base);
        defer live.end(testing.allocator, io);
        var gone = try Session.startIn(testing.allocator, io, base);
        const gone_name = try testing.allocator.dupe(u8, std.fs.path.basename(gone.path));
        defer testing.allocator.free(gone_name);
        gone.lock.close(io); // like the OS does when the process exits
        testing.allocator.free(gone.path);
        testing.allocator.free(gone.lock_path);

        // Old layout leftovers, and a startup that died between its lock and folder
        try tmp.dir.createDirPath(io, "runtime/r__0123");
        try tmp.dir.writeFile(io, .{ .sub_path = "runtime/r__0123/wraith_runtime.dll", .data = "x" });
        try tmp.dir.writeFile(io, .{ .sub_path = "1-deadbeef.lock", .data = "" });

        cleanStale(testing.allocator, io, base);

        try tmp.dir.access(io, std.fs.path.basename(live.path), .{});
        try testing.expectError(error.FileNotFound, tmp.dir.access(io, gone_name, .{}));
        try testing.expectError(error.FileNotFound, tmp.dir.access(io, "runtime", .{}));
        try testing.expectError(error.FileNotFound, tmp.dir.access(io, "1-deadbeef.lock", .{}));
    }

    test "lock is exclusive" {
        const io = testing.io;
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const base = try scratchBase(io, &tmp);
        defer testing.allocator.free(base);

        var session = try Session.startIn(testing.allocator, io, base);
        const name = try testing.allocator.dupe(u8, std.fs.path.basename(session.path));
        defer testing.allocator.free(name);
        const runtime = try session.subdirAlloc(testing.allocator, io, "runtime");
        testing.allocator.free(runtime);

        // Nobody else can take it
        const lock_name = try std.fmt.allocPrint(testing.allocator, "{s}{s}", .{ name, lock_ext });
        defer testing.allocator.free(lock_name);
        try testing.expectError(error.WouldBlock, tmp.dir.openFile(io, lock_name, .{ .mode = .read_write, .lock = .exclusive, .lock_nonblocking = true }));

        session.end(testing.allocator, io);
        try testing.expectError(error.FileNotFound, tmp.dir.access(io, name, .{}));
        try testing.expectError(error.FileNotFound, tmp.dir.access(io, lock_name, .{}));
    }
};

test {
    _ = tests;
}
