//! Per-thread storage for what the API gives back, good till that thread's next call that gives some.

const std = @import("std");
const core = @import("wraith_core");

/// Kept between calls up to this, so a thread that once read something big gives it back.
const keep_limit = 256 << 10;

threadlocal var arena: ?std.heap.ArenaAllocator = null;

/// Starts over, freeing what the last call gave. Call once per call that gives something back.
pub fn begin() std.mem.Allocator {
    if (arena) |*a| {
        _ = a.reset(.{ .retain_with_limit = keep_limit });
    } else arena = .init(core.heap.main);
    return arena.?.allocator();
}

/// `items` copied in, after a `begin`.
pub fn dupe(comptime T: type, items: []const T) error{OutOfMemory}![]T {
    return begin().dupe(T, items);
}

test "each begin frees the last" {
    const a = begin();
    const first = try a.dupe(u8, "hello");
    try std.testing.expectEqualStrings("hello", first);
    const again = try dupe(u8, "there");
    try std.testing.expectEqualStrings("there", again);
}
