const std = @import("std");
const builtin = @import("builtin");

pub const native = switch (builtin.os.tag) {
    .windows => @import("win/process.zig"),
    else => @compileError("Unsupported operating system"),
};

pub const MemoryInfo = native.MemoryInfo;
/// Null if the OS won't tell us.
pub const memoryInfo = native.memoryInfo;
pub const currentId = native.currentId;

pub const envAlloc = native.envAlloc;
pub const setEnv = native.setEnv;
pub const openUri = native.openUri;

test {
    std.testing.refAllDecls(@This());
}
