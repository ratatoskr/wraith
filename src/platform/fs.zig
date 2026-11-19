const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;
const builtin = @import("builtin");

pub const native = switch (builtin.os.tag) {
    .windows => @import("win/fs.zig"),
    else => @compileError("Unsupported operating system"),
};

pub const tempDirAlloc = native.tempDirAlloc;
pub const appDataDirAlloc = native.appDataDirAlloc;
pub const localAppDataDirAlloc = native.localAppDataDirAlloc;
pub const picturesDirAlloc = native.picturesDirAlloc;

pub const fixedDriveRoots = native.fixedDriveRoots;

/// Unbuffered so a crash loses nothing. `write` needs almost no stack.
pub const AppendFile = native.AppendFile;

/// Set `cancel` to bail early with `error.Canceled`.
pub fn sha512File(io: std.Io, path: []const u8, cancel: ?*const Atomic(bool)) ![64]u8 {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var buffer: [64 << 10]u8 = undefined;
    var reader = file.reader(io, &.{});
    var hash: std.crypto.hash.sha2.Sha512 = .init(.{});
    while (true) {
        if (cancel) |c| if (c.load(.monotonic)) return error.Canceled;
        const n = try reader.interface.readSliceShort(&buffer);
        if (n == 0) break;
        hash.update(buffer[0..n]);
    }
    var digest: [64]u8 = undefined;
    hash.final(&digest);
    return digest;
}

pub fn ensureDirectory(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, path);
}

pub fn deleteDirectory(io: std.Io, path: []const u8) !void {
    const dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    try std.Io.Dir.deleteTree(dir, io, ".");
}

pub fn copyDirectory(alloc: std.mem.Allocator, io: std.Io, src_path: []const u8, dst_path: []const u8) !void {
    const src_dir = try std.Io.Dir.openDirAbsolute(io, src_path, .{ .iterate = true });
    defer src_dir.close(io);

    std.Io.Dir.createDirAbsolute(io, dst_path, .default_file) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    var target_dir = try std.Io.Dir.openDirAbsolute(io, dst_path, .{});
    defer target_dir.close(io);

    var walker = try src_dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .file => {
                try std.Io.Dir.copyFile(src_dir, entry.path, target_dir, entry.path, io, .{ .make_path = true });
            },
            else => {
                continue;
            },
        }
    }
}

const tests = struct {
    test "sha512File" {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(io, .{ .sub_path = "abc.txt", .data = "abc" });
        const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
        defer std.testing.allocator.free(root);
        const path = try std.fs.path.join(std.testing.allocator, &.{ root, "abc.txt" });
        defer std.testing.allocator.free(path);

        var expected: [64]u8 = undefined;
        std.crypto.hash.sha2.Sha512.hash("abc", &expected, .{});
        try std.testing.expectEqualSlices(u8, &expected, &(try sha512File(io, path, null)));

        const cancelled: Atomic(bool) = .init(true);
        try std.testing.expectError(error.Canceled, sha512File(io, path, &cancelled));
    }

    test "deleteDirectory" {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try tmp.dir.createDirPath(io, "victim/nested");
        try tmp.dir.writeFile(io, .{ .sub_path = "victim/nested/file.txt", .data = "x" });

        const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
        defer std.testing.allocator.free(root);
        const victim = try std.fs.path.join(std.testing.allocator, &.{ root, "victim" });
        defer std.testing.allocator.free(victim);

        try deleteDirectory(io, victim);
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "victim/nested/file.txt", .{}));

        const missing = try std.fs.path.join(std.testing.allocator, &.{ root, "missing" });
        defer std.testing.allocator.free(missing);
        try deleteDirectory(io, missing);
    }

    test "ensureDirectory" {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
        defer std.testing.allocator.free(root);
        const dir = try std.fs.path.join(std.testing.allocator, &.{ root, "made" });
        defer std.testing.allocator.free(dir);

        try ensureDirectory(io, dir);
        try ensureDirectory(io, dir); // second call is a no-op
        try tmp.dir.access(io, "made", .{});

        const nested = try std.fs.path.join(std.testing.allocator, &.{ root, "a", "b", "c" });
        defer std.testing.allocator.free(nested);
        try ensureDirectory(io, nested);
        try tmp.dir.access(io, "a/b/c", .{});
    }

    test "copyDirectory" {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try tmp.dir.createDirPath(io, "src/nested");
        try tmp.dir.writeFile(io, .{ .sub_path = "src/top.txt", .data = "top" });
        try tmp.dir.writeFile(io, .{ .sub_path = "src/nested/deep.txt", .data = "deep" });

        const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
        defer std.testing.allocator.free(root);
        const src = try std.fs.path.join(std.testing.allocator, &.{ root, "src" });
        defer std.testing.allocator.free(src);
        const dst = try std.fs.path.join(std.testing.allocator, &.{ root, "dst" });
        defer std.testing.allocator.free(dst);

        try copyDirectory(std.testing.allocator, io, src, dst);

        var buf: [8]u8 = undefined;
        try std.testing.expectEqualStrings("top", try tmp.dir.readFile(io, "dst/top.txt", &buf));
        try std.testing.expectEqualStrings("deep", try tmp.dir.readFile(io, "dst/nested/deep.txt", &buf));
    }
};

test {
    std.testing.refAllDecls(@This());
    _ = tests;
}
