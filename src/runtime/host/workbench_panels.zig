//! Showing a C# class in the Workbench's Classes, asked for from any thread. Plugins' Workbench panels
//! are contributions to its slots, in `slots.zig`.

const std = @import("std");
const core = @import("wraith_core");
const sync = @import("tuft_sys").sync;

const gpa = core.heap.main;

var class_lock: sync.RwLock = .{};
/// Under `class_lock`. Empty for none.
var class_wanted: std.ArrayList(u8) = .empty;

pub fn showClass(name: []const u8) void {
    class_lock.lock();
    defer class_lock.unlock();
    class_wanted.clearRetainingCapacity();
    class_wanted.appendSlice(gpa, name) catch class_wanted.clearRetainingCapacity();
}

/// The class asked for since last time, copied into `buf`, or null. Workbench thread.
pub fn takeClass(buf: []u8) ?[]const u8 {
    class_lock.lock();
    defer class_lock.unlock();
    if (class_wanted.items.len == 0) return null;
    const n = @min(buf.len, class_wanted.items.len);
    @memcpy(buf[0..n], class_wanted.items[0..n]);
    class_wanted.clearRetainingCapacity();
    return buf[0..n];
}

const tests = struct {
    const testing = std.testing;

    test "showClass is picked up once" {
        showClass("UnityEngine.Transform");
        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings("UnityEngine.Transform", takeClass(&buf).?);
        try testing.expectEqual(null, takeClass(&buf));
    }
};

test {
    _ = tests;
}
