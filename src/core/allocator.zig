//! Main allocator. SafeAllocator in debug, smp_allocator in release.

const std = @import("std");
const builtin = @import("builtin");

pub const checking = builtin.mode == .debug;

pub const Default = struct {
    safe: if (checking) std.heap.SafeAllocator else void,

    pub fn init() Default {
        // Deep enough to get past the tracked and main heaps' frames to who asked
        return .{ .safe = if (checking) .init(std.heap.page_allocator, .{ .stack_trace_frames = 16 }) else {} };
    }

    pub fn allocator(self: *Default) std.mem.Allocator {
        return if (checking) self.safe.allocator() else std.heap.smp_allocator;
    }

    /// Don't use the allocator after this.
    pub fn deinit(self: *Default) usize {
        return if (checking) self.safe.deinit() else 0;
    }
};

test Default {
    var gpa: Default = .init();
    const a = gpa.allocator();
    const bytes = try a.alloc(u8, 64);
    a.free(bytes);
    try std.testing.expectEqual(0, gpa.deinit());
}
