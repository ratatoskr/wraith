//! Tab-separated clipboard text, so it pastes into a spreadsheet.

const Clip = @This();

const std = @import("std");

const ui = @import("root.zig");

out: std.Io.Writer.Allocating = .init(std.heap.smp_allocator),
lines: usize = 0,

/// Fields go in `fmt`, split by `\t`.
pub fn line(self: *Clip, comptime fmt: []const u8, args: anytype) void {
    if (self.lines > 0) self.out.writer.writeByte('\n') catch return;
    self.out.writer.print(fmt, args) catch return;
    self.lines += 1;
}

pub fn copy(self: *Clip) void {
    defer self.out.deinit();
    if (self.lines == 0) return;
    self.out.writer.writeByte(0) catch return;
    const written = self.out.written();
    ui.setClipboard(written[0 .. written.len - 1 :0]);
}
