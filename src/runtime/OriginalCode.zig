//! The game's code as it was before any plugin hooked it.

const OriginalCode = @This();

const std = @import("std");

const core = @import("wraith_core");
const memory = @import("tuft_mem");

const log = core.log.scoped(.wraith_runtime);

pub const heap_name = "game code copy";

tracked: core.heap.TrackedAllocator = undefined,
snapshot: ?memory.CodeSnapshot = null,

pub var global: OriginalCode = .{};

/// Must not move until `release`.
pub fn take(self: *OriginalCode, child: std.mem.Allocator) void {
    self.* = .{};
    self.tracked.init(child, heap_name);
    core.heap.registry.add(&self.tracked.usage);
    self.snapshot = memory.CodeSnapshot.take(self.tracked.allocator(), memory.Module.main().base) catch |err| {
        log.warn("Couldn't copy the game's code: {t}", .{err});
        return;
    };
    const snapshot = &self.snapshot.?;
    snapshot.install();
    log.info("Copied {d} code section(s) of the game ({Bi:.1}) for scans of its original code", .{ snapshot.sections.items.len, snapshot.size() });
}

pub fn release(self: *OriginalCode) void {
    if (self.snapshot) |*s| s.deinit();
    core.heap.registry.remove(&self.tracked.usage);
    self.* = .{};
}

pub fn find(self: *const OriginalCode, start: usize, len: usize) ?[*]const u8 {
    const snapshot = &(self.snapshot orelse return null);
    return snapshot.find(start, len);
}

test "scans read the copy" {
    const saved = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved;
    global.take(std.testing.allocator);
    defer global.release();
    const snapshot = &global.snapshot.?;
    try std.testing.expect(snapshot.sections.items.len > 0);

    var heaps: [64]core.heap.Stats = undefined;
    var listed = false;
    for (heaps[0..core.heap.registry.snapshot(&heaps)]) |h| {
        if (std.mem.eql(u8, h.name(), heap_name)) {
            listed = true;
            try std.testing.expect(h.live_bytes >= snapshot.size());
        }
    }
    try std.testing.expect(listed);

    const text = try memory.Module.main().text();
    try std.testing.expect(global.find(text.start, text.len) != null);
    try std.testing.expectEqual(null, global.find(text.start, text.len + 1));

    // The code is read-only, so "hook" it by changing the copy instead
    const copy = snapshot.sections.items[0];
    const offset = copy.copy.len / 2;
    const marker = [_]u8{ 0xF1, 0xE2, 0xD3, 0xC4, 0xB5, 0xA6, 0x97, 0x88, 0x79, 0x6A, 0x5B, 0x4C };
    @memcpy(copy.copy[offset..][0..marker.len], &marker);
    const range: memory.Range = .{ .start = copy.start, .len = copy.copy.len };
    const signature = "F1 E2 D3 C4 B5 A6 97 88 79 6A 5B 4C";
    try std.testing.expectEqual(copy.start + offset, try range.original().scan("marker", signature).unwrap());
    try std.testing.expectError(error.PatternNotFound, range.scan("marker", signature).unwrap());
}
