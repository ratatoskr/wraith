//! Store helpers for files and Windows paths.

const std = @import("std");

/// Manifests and info files are small.
pub const max_file = 4 << 20;

pub fn read(arena: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

pub fn list(arena: std.mem.Allocator, io: std.Io, dir_path: []const u8, prefix: []const u8, suffix: []const u8) ![]const []const u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return &.{},
        else => return err,
    };
    defer dir.close(io);
    var found: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name.len < prefix.len + suffix.len) continue;
        if (!std.ascii.startsWithIgnoreCase(entry.name, prefix) or !std.ascii.endsWithIgnoreCase(entry.name, suffix)) continue;
        try found.append(arena, try std.fs.path.join(arena, &.{ dir_path, entry.name }));
    }
    std.mem.sort([]const u8, found.items, {}, lessThan);
    return found.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

pub fn subdirs(arena: std.mem.Allocator, io: std.Io, dir_path: []const u8) ![]const []const u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return &.{},
        else => return err,
    };
    defer dir.close(io);
    var found: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) try found.append(arena, try arena.dupe(u8, entry.name));
    }
    return found.items;
}

pub fn ancestors(path: []const u8, max: usize) Ancestors {
    return .{ .next_dir = std.fs.path.dirname(path), .left = max };
}

pub const Ancestors = struct {
    next_dir: ?[]const u8,
    left: usize,

    pub fn next(self: *Ancestors) ?[]const u8 {
        if (self.left == 0) return null;
        const dir = self.next_dir orelse return null;
        self.left -= 1;
        self.next_dir = std.fs.path.dirname(dir);
        return dir;
    }
};

pub const max_depth = 6;

/// Ignores case and slash direction like Windows.
pub fn isWithin(dir: []const u8, path: []const u8) bool {
    const d = std.mem.trimEnd(u8, withoutPrefix(dir), "\\/");
    const p = withoutPrefix(path);
    if (p.len <= d.len) return false;
    for (d, p[0..d.len]) |a, b| if (fold(a) != fold(b)) return false;
    return p[d.len] == '\\' or p[d.len] == '/';
}

pub fn isSame(a: []const u8, b: []const u8) bool {
    const x = withoutPrefix(a);
    const y = withoutPrefix(b);
    if (x.len != y.len) return false;
    for (x, y) |c, d| if (fold(c) != fold(d)) return false;
    return true;
}

pub fn fold(c: u8) u8 {
    return if (c == '/') '\\' else std.ascii.toLower(c);
}

/// Strips the `\\?\` long path prefix. Some APIs add it, some don't.
pub fn withoutPrefix(path: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, path, "\\\\?\\") and !std.ascii.startsWithIgnoreCase(path[4..], "UNC\\")) path[4..] else path;
}

test isWithin {
    try std.testing.expect(isWithin("C:\\Games\\Kai", "c:/games/KAI/bin/kai.exe"));
    try std.testing.expect(isWithin("C:\\Games\\Kai\\", "C:\\Games\\Kai\\kai.exe"));
    try std.testing.expect(!isWithin("C:\\Games\\Kai", "C:\\Games\\Kai2\\kai.exe"));
    try std.testing.expect(!isWithin("C:\\Games\\Kai", "C:\\Games\\Kai"));
}
