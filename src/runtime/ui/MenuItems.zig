//! Menu items owners add to the Wraith UI. The hub's menu bar shows them, a menu per owner.

const std = @import("std");

const tuft_sys = @import("tuft_sys");
const Owner = @import("tuft_event").Owner;

/// Must not move until it's removed or its owner closes.
pub const Item = struct {
    label: []const u8,
    /// The menu it's under, its owner's name for people.
    menu: []const u8 = "",
    open: *bool,
    dev: bool = false,
};

pub const Entry = struct {
    item: *const Item,
    owner: *Owner,
};

const allocator = std.heap.page_allocator;

var lock: tuft_sys.sync.RwLock = .{};
var entries: std.ArrayList(Entry) = .empty;

var watch: Owner.Watch(*u8, .{ .closing = closing }) = .{};
var listener: u8 = 0;

/// Ignored once `owner` has closed.
pub fn add(owner: *Owner, item: *const Item) error{OutOfMemory}!void {
    const lease = watch.lease(&listener, owner, .calls) orelse return;
    defer lease.end();
    lock.lock();
    defer lock.unlock();
    try entries.append(allocator, .{ .item = item, .owner = owner });
}

pub fn remove(item: *const Item) void {
    lock.lock();
    defer lock.unlock();
    for (entries.items, 0..) |e, i| {
        if (e.item == item) {
            _ = entries.orderedRemove(i);
            return;
        }
    }
}

/// Owners can't remove theirs until `end`, so keep it short. Render thread only.
pub fn read() Reading {
    lock.lockShared();
    return .{ .entries = entries.items };
}

pub const Reading = struct {
    entries: []const Entry,

    pub fn end(_: Reading) void {
        lock.unlockShared();
    }
};

fn closing(_: *u8, owner: *Owner) void {
    lock.lock();
    defer lock.unlock();
    var i: usize = 0;
    while (i < entries.items.len) {
        if (entries.items[i].owner == owner) _ = entries.orderedRemove(i) else i += 1;
    }
}

test "items listed until removed" {
    var a: Owner = .init("a");
    var b: Owner = .init("b");
    var open = false;
    const first: Item = .{ .label = "First", .open = &open };
    const second: Item = .{ .label = "Second", .open = &open, .dev = true };
    const third: Item = .{ .label = "Third", .open = &open };
    try add(&a, &first);
    try add(&b, &second);
    try add(&a, &third);
    {
        const r = read();
        defer r.end();
        try std.testing.expectEqual(3, r.entries.len);
        try std.testing.expectEqual(&second, r.entries[1].item);
        try std.testing.expectEqualStrings("Second", r.entries[1].item.label);
        try std.testing.expect(r.entries[1].item.dev);
    }

    remove(&second);
    remove(&second);
    a.close();
    try add(&a, &first); // too late
    {
        const r = read();
        defer r.end();
        try std.testing.expectEqual(0, r.entries.len);
    }
    b.close();
}
