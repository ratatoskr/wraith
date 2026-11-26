//! Windows virtual key codes, as CE saves hotkeys, to our key names.

const std = @import("std");

/// Like `Ctrl+Shift+f8`, or null for unknown keys or more than one non-modifier.
pub fn chord(arena: std.mem.Allocator, codes: []const u16) !?[]const u8 {
    var ctrl = false;
    var shift = false;
    var alt = false;
    var super = false;
    var key: ?[]const u8 = null;
    for (codes) |c| switch (c) {
        0x10, 0xA0, 0xA1 => shift = true,
        0x11, 0xA2, 0xA3 => ctrl = true,
        0x12, 0xA4, 0xA5 => alt = true,
        0x5B, 0x5C => super = true,
        else => {
            if (key != null) return null;
            key = name(c) orelse return null;
        },
    };
    const k = key orelse return null;
    return try std.fmt.allocPrint(arena, "{s}{s}{s}{s}{s}", .{
        if (ctrl) "Ctrl+" else "",
        if (shift) "Shift+" else "",
        if (alt) "Alt+" else "",
        if (super) "Super+" else "",
        k,
    });
}

fn name(vk: u16) ?[]const u8 {
    const digits = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" };
    const letters = [_][]const u8{ "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z" };
    const fkeys = [_][]const u8{ "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12", "F13", "F14", "F15", "F16", "F17", "F18", "F19", "F20", "F21", "F22", "F23", "F24" };
    const keypad = [_][]const u8{ "keypad_0", "keypad_1", "keypad_2", "keypad_3", "keypad_4", "keypad_5", "keypad_6", "keypad_7", "keypad_8", "keypad_9" };
    return switch (vk) {
        0x30...0x39 => digits[vk - 0x30],
        0x41...0x5A => letters[vk - 0x41],
        0x70...0x87 => fkeys[vk - 0x70],
        0x60...0x69 => keypad[vk - 0x60],
        0x08 => "backspace",
        0x09 => "tab",
        0x0D => "enter",
        0x13 => "pause",
        0x14 => "caps_lock",
        0x1B => "escape",
        0x20 => "space",
        0x21 => "page_up",
        0x22 => "page_down",
        0x23 => "end",
        0x24 => "home",
        0x25 => "left",
        0x26 => "up",
        0x27 => "right",
        0x28 => "down",
        0x2C => "print_screen",
        0x2D => "insert",
        0x2E => "delete",
        0x5D => "menu",
        0x6A => "keypad_multiply",
        0x6B => "keypad_add",
        0x6D => "keypad_subtract",
        0x6E => "keypad_decimal",
        0x6F => "keypad_divide",
        0x90 => "num_lock",
        0x91 => "scroll_lock",
        0xBA => "semicolon",
        0xBB => "equal",
        0xBC => "comma",
        0xBD => "minus",
        0xBE => "period",
        0xBF => "slash",
        0xC0 => "grave",
        0xDB => "left_bracket",
        0xDC => "backslash",
        0xDD => "right_bracket",
        0xDE => "apostrophe",
        0xE2 => "oem_102",
        else => null,
    };
}

const testing = std.testing;

test "virtual keys to chords" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("Alt+X", (try chord(a, &.{ 18, 88 })).?);
    try testing.expectEqualStrings("Ctrl+Shift+F8", (try chord(a, &.{ 0x10, 0x11, 0x77 })).?);
    try testing.expectEqualStrings("keypad_5", (try chord(a, &.{0x65})).?);
    try testing.expectEqual(null, try chord(a, &.{ 0x41, 0x42 }));
    try testing.expectEqual(null, try chord(a, &.{0x11}));
}
