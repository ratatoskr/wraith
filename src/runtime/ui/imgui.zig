//! Dear ImGui as the runtime hosts it.

const std = @import("std");

const core = @import("wraith_core");
const ui = @import("wraith_ui");

const tuft_imgui = @import("tuft_imgui");
pub const c = tuft_imgui.c;

const log = core.log.scoped(.wraith_ui);

/// Also sends ImGui's failed asserts to the log.
pub fn bind() void {
    ui.bind(lookup);
    tuft_imgui.setAssertHandler(onAssert);
}

pub const lookup = tuft_imgui.lookup;

/// False if anything had to be unwound.
pub const guarded = tuft_imgui.guarded;

/// Call between windows.
pub const resetLayout = tuft_imgui.resetLayout;

fn onAssert(expr: [*:0]const u8, file: [*:0]const u8, line: c_int) callconv(.c) void {
    log.err("ImGui assertion failed: {s} ({s}:{d})", .{ expr, std.fs.path.basename(std.mem.span(file)), line });
}
