//! Local wall clock time.

const std = @import("std");
const builtin = @import("builtin");

pub const native = switch (builtin.os.tag) {
    .windows => @import("win/time.zig"),
    else => @compileError("Unsupported operating system"),
};

pub const LocalTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    millisecond: u16,
};

/// Cheap and uses almost no stack.
pub const localNow = native.localNow;

test localNow {
    const t = localNow();
    try std.testing.expect(t.year >= 2024);
    try std.testing.expect(t.month >= 1 and t.month <= 12);
    try std.testing.expect(t.hour < 24 and t.millisecond < 1000);
}
