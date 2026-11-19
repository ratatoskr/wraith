//! Who SDK stuff belongs to: a plugin's `Wraith` root, from `wraith.sal`. SDK calls are made for the
//! thread's current owner, which is the plugin's own unless something entered another.

const Owner = @This();

const std = @import("std");

const api = @import("wraith_api");

pub const Wraith = api.wraith.Wraith;

/// Stops working once the plugin's unloading.
root: Wraith,

var own_root: ?Wraith = null;
threadlocal var entered: ?Wraith = null;

/// `root` is a `Wraith` object, from anywhere `wraith.sal` was loaded.
pub fn attach(root: anytype) void {
    own_root = of(root).root;
}

pub fn of(root: anytype) Owner {
    return .{ .root = .{ .data = root.data, .table = root.table } };
}

pub fn detach() void {
    own_root = null;
}

pub fn own() ?Owner {
    return .{ .root = own_root orelse return null };
}

/// Not inlined, since a task can move threads and a cached thread-local address would be the old thread's.
pub noinline fn current() ?Owner {
    if (entered) |root| return .{ .root = root };
    return own();
}

/// Nests, so `end` goes back to the previous one.
pub fn enter(self: Owner) Entered {
    const previous = entered;
    entered = self.root;
    return .{ .previous = previous };
}

pub const Entered = struct {
    previous: ?Wraith,

    pub fn end(self: Entered) void {
        entered = self.previous;
    }
};

/// Absolute. Might not exist yet.
pub fn configDirectory(self: Owner) []const u8 {
    return self.root.config().directory();
}

/// Might not exist yet.
pub fn gameConfigDirectory(self: Owner) []const u8 {
    return self.root.config().gameDirectory();
}

test "current owner nesting" {
    const a: Wraith = .{ .data = 1 };
    const b: Wraith = .{ .data = 2 };
    const saved = own_root;
    defer own_root = saved;

    detach();
    try std.testing.expectEqual(null, current());
    attach(a);
    try std.testing.expectEqual(1, current().?.root.data);

    const outer = (Owner{ .root = b }).enter();
    try std.testing.expectEqual(2, current().?.root.data);
    const inner = (Owner{ .root = a }).enter();
    try std.testing.expectEqual(1, current().?.root.data);
    inner.end();
    try std.testing.expectEqual(2, current().?.root.data);
    outer.end();
    try std.testing.expectEqual(1, current().?.root.data);
}
