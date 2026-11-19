//! CE records to the Addresses list, saved as `addresses.rwa.zon`.

const std = @import("std");

const table = @import("table.zig");
const numbers = @import("numbers.zig");
const tweak_format = @import("wraith_api").tweak;

pub const Chord = @typeInfo(@typeInfo(@TypeOf(tweak_format.parseChord)).@"fn".return_type.?).optional.child;

/// Like tuft's `mem.values.Kind`, which the Addresses list saves by name.
pub const Kind = enum { byte, two_bytes, four_bytes, eight_bytes, float, double, text, text_utf16, bytes };

pub const Bits = struct { shift: u8 = 0, width: u8 = 1 };
pub const Choice = struct { value: i64 = 0, label: []const u8 = "" };
pub const Freeze = enum { always, only_increase, only_decrease };
pub const Action = enum { toggle_hold, hold, release, set, increase, decrease };
pub const Hotkey = struct {
    chord: ?Chord = null,
    action: Action = .toggle_hold,
    value: []const u8 = "",
};

/// Like the Addresses list's saved entry, so it reads ours as its own.
pub const Item = struct {
    name: []const u8 = "",
    id: []const u8 = "",
    address: []const u8 = "",
    offsets: []const []const u8 = &.{},
    kind: Kind = .four_bytes,
    length: u16 = 16,
    type: []const u8 = "",
    count: []const u8 = "",
    depth: u8 = 0,
    group: bool = false,
    expanded: bool = true,
    bits: ?Bits = null,
    choices: []const Choice = &.{},
    labels_only: bool = false,
    choices_from: []const u8 = "",
    freeze: Freeze = .always,
    hotkeys: []const Hotkey = &.{},
};

pub const Saved = struct {
    items: []const Item = &.{},
};

/// What the list holds, past which it cuts things off.
pub const max_name = 63;
pub const max_id = 63;
pub const max_address = 127;
pub const max_offsets = 8;
pub const max_offset = 15;

pub fn zon(arena: std.mem.Allocator, items: []const Item) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.zon.stringify.serialize(Saved{ .items = items }, .{}, &out.writer);
    try out.writer.writeByte('\n');
    return out.written();
}

/// The kind for CE's `<VariableType>`, or null if there's none of ours.
pub fn kindOf(e: table.Entry) ?Kind {
    const t = e.type;
    const pairs = [_]struct { []const u8, Kind }{
        .{ "Byte", .byte },           .{ "2 Bytes", .two_bytes }, .{ "4 Bytes", .four_bytes },
        .{ "8 Bytes", .eight_bytes }, .{ "Float", .float },       .{ "Double", .double },
        .{ "Array of byte", .bytes },
    };
    for (pairs) |p| if (std.ascii.eqlIgnoreCase(t, p[0])) return p[1];
    if (std.ascii.eqlIgnoreCase(t, "String")) return if (e.unicode) .text_utf16 else .text;
    return null;
}

/// How long a text or byte entry is.
pub fn lengthOf(e: table.Entry, kind: Kind) u16 {
    const n: u32 = switch (kind) {
        .text, .text_utf16 => e.length orelse 16,
        .bytes => e.byte_length orelse e.length orelse 16,
        else => return 16,
    };
    return @intCast(std.math.clamp(n, 1, 4096));
}

/// Cut to fit, between UTF-8 characters.
pub fn fit(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

const testing = std.testing;

test "it saves the way the Addresses list reads" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = [_]Item{
        .{ .name = "Party", .address = "[kai.exe+0xD600A8]+0x38", .group = true },
        .{ .name = "HP \"max\"", .address = "+0x10", .offsets = &.{ "0x8", "0x10" }, .kind = .two_bytes, .depth = 1 },
    };
    const text = try zon(a, &items);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const back = try std.zon.parse.fromSlice(Saved, .{ .gpa = a, .arena = a, .source = try a.dupeSentinel(u8, text, 0), .diagnostics = &diagnostics, .ignore_unknown_fields = true });
    try testing.expectEqual(2, back.items.len);
    try testing.expectEqualStrings("HP \"max\"", back.items[1].name);
    try testing.expectEqualStrings("0x10", back.items[1].offsets[1]);
    try testing.expectEqual(.two_bytes, back.items[1].kind);
    try testing.expectEqualStrings("ab", fit("ab\xC3\xA9", 3));
}
