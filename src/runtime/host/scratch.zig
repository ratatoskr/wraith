//! Where text and slices the API gives back live, one per thread. They're good till that thread's
//! next call that gives some, which is longer than any script binder needs, since it copies them.

const std = @import("std");

/// Kept between calls up to this, so a thread that once read something big gives it back.
const keep_limit = 256 << 10;

threadlocal var arena: ?std.heap.ArenaAllocator = null;

/// Starts over, freeing what the last call gave. Call once per call that gives something back.
pub fn begin() std.mem.Allocator {
    if (arena) |*a| {
        _ = a.reset(.{ .retain_with_limit = keep_limit });
    } else arena = .init(std.heap.page_allocator);
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
