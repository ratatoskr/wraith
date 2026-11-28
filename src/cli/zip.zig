//! Writing zips, for `wraith pack`. Each file's deflated, or stored if that's no smaller.

const std = @import("std");
const flate = std.compress.flate;

pub const Entry = struct {
    /// With forward slashes, like `kai/wraith.json`.
    name: []const u8,
    data: []const u8,
};

/// The whole zip.
pub fn write(gpa: std.mem.Allocator, entries: []const Entry) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    const Central = struct { name: []const u8, method: u16, crc: u32, size: u32, packed_size: u32, offset: u32 };
    var centrals: std.ArrayList(Central) = .empty;
    defer centrals.deinit(gpa);

    for (entries) |e| {
        const deflated = try deflate(gpa, e.data);
        defer gpa.free(deflated);
        const stored = deflated.len >= e.data.len;
        const body = if (stored) e.data else deflated;
        const c: Central = .{
            .name = e.name,
            .method = if (stored) 0 else 8,
            .crc = std.hash.Crc32.hash(e.data),
            .size = try fit(e.data.len),
            .packed_size = try fit(body.len),
            .offset = try fit(out.written().len),
        };
        try centrals.append(gpa, c);
        try w.writeInt(u32, 0x04034b50, .little);
        try header(w, c.method, c.crc, c.packed_size, c.size, e.name.len);
        try w.writeAll(e.name);
        try w.writeAll(body);
    }

    const start = try fit(out.written().len);
    for (centrals.items) |c| {
        try w.writeInt(u32, 0x02014b50, .little);
        // Made by 2.0
        try w.writeInt(u16, 20, .little);
        try header(w, c.method, c.crc, c.packed_size, c.size, c.name.len);
        // No comment, disk 0, no attributes
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u32, 0, .little);
        try w.writeInt(u32, c.offset, .little);
        try w.writeAll(c.name);
    }
    const size = try fit(out.written().len - start);
    const count = std.math.cast(u16, centrals.items.len) orelse return error.TooManyFiles;
    try w.writeInt(u32, 0x06054b50, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, count, .little);
    try w.writeInt(u16, count, .little);
    try w.writeInt(u32, size, .little);
    try w.writeInt(u32, start, .little);
    try w.writeInt(u16, 0, .little);
    return out.toOwnedSlice();
}

/// What local and central headers share, from the version needed on.
fn header(w: *std.Io.Writer, method: u16, crc: u32, packed_size: u32, size: u32, name_len: usize) !void {
    try w.writeInt(u16, 20, .little);
    // UTF-8 names
    try w.writeInt(u16, 0x0800, .little);
    try w.writeInt(u16, method, .little);
    // 1980-01-01, so the same files make the same zip
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0x0021, .little);
    try w.writeInt(u32, crc, .little);
    try w.writeInt(u32, packed_size, .little);
    try w.writeInt(u32, size, .little);
    try w.writeInt(u16, std.math.cast(u16, name_len) orelse return error.NameTooLong, .little);
    try w.writeInt(u16, 0, .little);
}

fn fit(n: usize) !u32 {
    return std.math.cast(u32, n) orelse error.TooBig;
}

fn deflate(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    // It needs room to start with
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, data.len / 2 + 64);
    errdefer out.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var c = try flate.Compress.init(&out.writer, window, .raw, .best);
    try c.writer.writeAll(data);
    try c.finish();
    return out.toOwnedSlice();
}

test "what it writes, std's zip reads back" {
    const t = std.testing;
    const repeated: [1200]u8 = @splat('h');
    const text: []const u8 = &repeated;
    const bytes = try write(t.allocator, &.{
        .{ .name = "kai/wraith.json", .data = "{}" },
        .{ .name = "kai/notes/a.txt", .data = text },
    });
    defer t.allocator.free(bytes);

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.zip", .data = bytes });
    const file = try tmp.dir.openFile(t.io, "a.zip", .{});
    defer file.close(t.io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(t.io, &buf);
    try tmp.dir.createDirPath(t.io, "out");
    var out = try tmp.dir.openDir(t.io, "out", .{});
    defer out.close(t.io);
    try std.zip.extract(out, &reader, .{});
    const got = try out.readFileAlloc(t.io, "kai/notes/a.txt", t.allocator, .limited(1 << 16));
    defer t.allocator.free(got);
    try t.expectEqualStrings(text, got);
}
