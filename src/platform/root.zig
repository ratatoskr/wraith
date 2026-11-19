//! OS stuff that tuft doesn't cover.

const std = @import("std");
const builtin = @import("builtin");

pub const fs = @import("fs.zig");
pub const fonts = @import("fonts.zig");
pub const process = @import("process.zig");
pub const time = @import("time.zig");
pub const input = @import("tuft_input");
pub const clipboard = @import("tuft_sys").clipboard;

pub const win = if (builtin.os.tag == .windows) struct {
    pub const api = @import("tuft_sys").win;
} else struct {};

test {
    std.testing.refAllDecls(@This());
    if (builtin.os.tag == .windows) std.testing.refAllDecls(win);
}
