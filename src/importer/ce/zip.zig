//! Writing an import out, as a `.rwp` or into a folder.

const std = @import("std");

pub const File = struct {
    path: []const u8,
    text: []const u8,
};

/// A `.rwp` if `path` ends in it, else a folder of the project's files.
pub fn save(io: std.Io, gpa: std.mem.Allocator, path: []const u8, files: anytype) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.ascii.endsWithIgnoreCase(path, ".rwp")) {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try write(gpa, &out.writer, files);
        if (std.fs.path.dirname(path)) |dir| try cwd.createDirPath(io, dir);
        try cwd.writeFile(io, .{ .sub_path = path, .data = out.written() });
        return;
    }
    for (files) |f| {
        const full = try std.fs.path.join(gpa, &.{ path, f.path });
        defer gpa.free(full);
        if (std.fs.path.dirname(full)) |dir| try cwd.createDirPath(io, dir);
        try cwd.writeFile(io, .{ .sub_path = full, .data = f.text });
    }
}

/// A zip like a project's, stored and not compressed. `files` have `path` and `text`.
pub fn write(gpa: std.mem.Allocator, w: *std.Io.Writer, files: anytype) !void {
    const Entry = struct { crc: u32, offset: u32 };
    const entries = try gpa.alloc(Entry, files.len);
    defer gpa.free(entries);
    var offset: u32 = 0;
    for (files, entries) |f, *e| {
        e.* = .{ .crc = std.hash.Crc32.hash(f.text), .offset = offset };
        const size: u32 = @intCast(f.text.len);
        try w.writeInt(u32, 0x04034b50, .little);
        try w.writeInt(u16, 20, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0x21, .little);
        try w.writeInt(u32, e.crc, .little);
        try w.writeInt(u32, size, .little);
        try w.writeInt(u32, size, .little);
        try w.writeInt(u16, @intCast(f.path.len), .little);
        try w.writeInt(u16, 0, .little);
        try w.writeAll(f.path);
        try w.writeAll(f.text);
        offset += 30 + @as(u32, @intCast(f.path.len)) + size;
    }
    const central_start = offset;
    for (files, entries) |f, e| {
        const size: u32 = @intCast(f.text.len);
        try w.writeInt(u32, 0x02014b50, .little);
        try w.writeInt(u16, 20, .little);
        try w.writeInt(u16, 20, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0x21, .little);
        try w.writeInt(u32, e.crc, .little);
        try w.writeInt(u32, size, .little);
        try w.writeInt(u32, size, .little);
        try w.writeInt(u16, @intCast(f.path.len), .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u32, 0, .little);
        try w.writeInt(u32, e.offset, .little);
        try w.writeAll(f.path);
        offset += 46 + @as(u32, @intCast(f.path.len));
    }
    try w.writeInt(u32, 0x06054b50, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, @intCast(files.len), .little);
    try w.writeInt(u16, @intCast(files.len), .little);
    try w.writeInt(u32, offset - central_start, .little);
    try w.writeInt(u32, central_start, .little);
    try w.writeInt(u16, 0, .little);
}

test "a zip std can read back" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const files = [_]File{ .{ .path = "tweaks/god.rwt", .text = "@tweak \"God\"\n" }, .{ .path = "addresses.rwa.zon", .text = ".{}" } };
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(testing.allocator, &out.writer, &files);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "x.rwp", .data = out.written() });
    var file = try tmp.dir.openFile(testing.io, "x.rwp", .{});
    defer file.close(testing.io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(testing.io, &buf);
    try tmp.dir.createDirPath(testing.io, "out");
    var dest = try tmp.dir.openDir(testing.io, "out", .{});
    defer dest.close(testing.io);
    try std.zip.extract(dest, &reader, .{});
    const text = try dest.readFileAlloc(testing.io, "tweaks/god.rwt", testing.allocator, .limited(1024));
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("@tweak \"God\"\n", text);
}
