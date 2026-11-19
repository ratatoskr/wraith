//! Binaries for each arch share a folder, told apart by name.

const std = @import("std");
const builtin = @import("builtin");

pub const Arch = enum {
    x86,
    x64,

    pub fn dllName(arch: Arch, buf: []u8, name: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "wraith_{s}_{t}.dll", .{ name, arch });
    }

    pub fn dllNameAlloc(arch: Arch, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "wraith_{s}_{t}.dll", .{ name, arch });
    }
};

pub const native: Arch = switch (builtin.cpu.arch) {
    .x86 => .x86,
    .x86_64 => .x64,
    else => @compileError("x86 and x64 only"),
};

test "binary names" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("wraith_kai_x86.dll", try Arch.x86.dllName(&buf, "kai"));
    const name = try Arch.x64.dllNameAlloc(std.testing.allocator, "bootstrap");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("wraith_bootstrap_x64.dll", name);
}
