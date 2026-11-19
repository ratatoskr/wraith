//! The files a CE table carries in its `<Files>`, like sounds for `playSound`. CE deflates each
//! one and writes it in its own base85, with its size first, or as hex in old tables.

const std = @import("std");

pub const File = struct {
    name: []const u8,
    data: []const u8,
};

/// One as the table has it.
pub const Raw = struct {
    name: []const u8,
    ascii85: bool,
    text: []const u8,
};

/// Bigger ones stay behind, since they'd bloat the tweak file. They're DLLs and such, not sounds.
pub const max_size = 4 << 20;

pub const Error = error{ InvalidFile, TooBig, OutOfMemory };

pub fn decode(arena: std.mem.Allocator, raw: Raw) Error!File {
    const compressed = if (raw.ascii85) try base85(arena, raw.text) else try hex(arena, raw.text);
    const inflated = try inflate(arena, compressed);
    if (!raw.ascii85) return .{ .name = raw.name, .data = inflated };
    // CE writes the size first in these
    if (inflated.len < 4) return error.InvalidFile;
    const size = std.mem.readInt(u32, inflated[0..4], .little);
    if (size > inflated.len - 4) return error.InvalidFile;
    return .{ .name = raw.name, .data = inflated[4..][0..size] };
}

/// CE's own, `custombase85.pas`: big-endian groups of 5, short tails padded with its last digit.
const alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%()*+,-./:;=?@[]^_{}";

const digits: [256]u8 = blk: {
    var t: [256]u8 = @splat(0xFF);
    for (alphabet, 0..) |ch, i| t[ch] = i;
    break :blk t;
};

pub fn base85(arena: std.mem.Allocator, text: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var group: [5]u8 = undefined;
    var n: usize = 0;
    for (text) |ch| {
        if (std.ascii.isWhitespace(ch)) continue;
        const d = digits[ch];
        if (d == 0xFF) return error.InvalidFile;
        group[n] = d;
        n += 1;
        if (n == 5) {
            try appendGroup(arena, &out, group, 4);
            n = 0;
        }
    }
    if (n == 1) return error.InvalidFile;
    if (n > 1) {
        for (group[n..]) |*d| d.* = 84;
        try appendGroup(arena, &out, group, n - 1);
    }
    return out.items;
}

fn appendGroup(arena: std.mem.Allocator, out: *std.ArrayList(u8), group: [5]u8, keep: usize) Error!void {
    var value: u64 = 0;
    for (group) |d| value = value * 85 + d;
    if (value > std.math.maxInt(u32)) return error.InvalidFile;
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, @intCast(value), .big);
    try out.appendSlice(arena, bytes[0..keep]);
}

fn hex(arena: std.mem.Allocator, text: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var high: ?u8 = null;
    for (text) |ch| {
        if (std.ascii.isWhitespace(ch)) continue;
        const v = std.fmt.charToDigit(ch, 16) catch return error.InvalidFile;
        if (high) |h| {
            try out.append(arena, (h << 4) | v);
            high = null;
        } else high = v;
    }
    return out.items;
}

/// Raw deflate, no zlib header, like CE's `Tdecompressionstream`.
fn inflate(arena: std.mem.Allocator, compressed: []const u8) Error![]u8 {
    var in: std.Io.Reader = .fixed(compressed);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var d: std.compress.flate.Decompress = .init(&in, .raw, &window);
    var out: std.Io.Writer.Allocating = .init(arena);
    _ = d.reader.streamRemaining(&out.writer) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => error.InvalidFile,
    };
    if (out.written().len > max_size) return error.TooBig;
    return out.written();
}

const tests = struct {
    const testing = std.testing;

    /// The other way, like `BinToBase85`, for making test data.
    fn encode(arena: std.mem.Allocator, bytes: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < bytes.len) : (i += 4) {
            var chunk: [4]u8 = @splat(0);
            const n = @min(4, bytes.len - i);
            @memcpy(chunk[0..n], bytes[i..][0..n]);
            var value: u32 = std.mem.readInt(u32, &chunk, .big);
            var five: [5]u8 = undefined;
            var j: usize = 5;
            while (j > 0) {
                j -= 1;
                five[j] = alphabet[value % 85];
                value /= 85;
            }
            try out.appendSlice(arena, five[0 .. n + 1]);
        }
        return out.items;
    }

    /// Deflate's stored block, which any inflater reads.
    fn stored(arena: std.mem.Allocator, bytes: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.append(arena, 1);
        var len: [2]u8 = undefined;
        std.mem.writeInt(u16, &len, @intCast(bytes.len), .little);
        try out.appendSlice(arena, &len);
        std.mem.writeInt(u16, &len, ~@as(u16, @intCast(bytes.len)), .little);
        try out.appendSlice(arena, &len);
        try out.appendSlice(arena, bytes);
        return out.items;
    }

    test "base85 like CE's" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        for ([_][]const u8{ "", "a", "ab", "abc", "abcd", "abcde", "hello, table files!" }) |s| {
            try testing.expectEqualStrings(s, try base85(a, try encode(a, s)));
        }
        try testing.expectEqualStrings("00000", try encode(a, "\x00\x00\x00\x00"));
        try testing.expectError(error.InvalidFile, base85(a, "0<"));
    }

    test "a sound as new and old tables have it" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const wav = "RIFF\x04\x00\x00\x00WAVE";

        var sized: [4 + wav.len]u8 = undefined;
        std.mem.writeInt(u32, sized[0..4], wav.len, .little);
        @memcpy(sized[4..], wav);
        const new = try decode(a, .{ .name = "ding.wav", .ascii85 = true, .text = try encode(a, try stored(a, &sized)) });
        try testing.expectEqualStrings("ding.wav", new.name);
        try testing.expectEqualStrings(wav, new.data);

        var hex_text: std.ArrayList(u8) = .empty;
        for (try stored(a, wav)) |b| try hex_text.print(a, "{X:0>2}", .{b});
        const old = try decode(a, .{ .name = "old.wav", .ascii85 = false, .text = hex_text.items });
        try testing.expectEqualStrings(wav, old.data);

        try testing.expectError(error.InvalidFile, decode(a, .{ .name = "x", .ascii85 = true, .text = "zzzzz" }));
    }
};

test {
    _ = tests;
}
