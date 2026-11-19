//! Page protection for owners, put back when they go.

const std = @import("std");

const api = @import("wraith_api");
const mem = @import("tuft_mem");
const sync = @import("tuft_sys").sync;

const host = @import("root.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;

const Change = struct {
    address: usize,
    len: usize,
    old: mem.Protection,
};

/// One per owner, so its changes go back newest first.
const Changes = struct {
    loaded: *Loaded,
    lock: sync.RwLock = .{},
    list: std.ArrayList(Change) = .empty,

    pub fn stop(_: *Changes) void {}

    pub fn free(self: *Changes) void {
        while (self.list.pop()) |c| _ = mem.protect(c.address, c.len, c.old) catch {};
        self.list.deinit(self.loaded.allocator);
        self.loaded.allocator.destroy(self);
    }
};

var changes: host.Owned(Changes) = .{};
/// So two first calls from one owner don't both make a `Changes`.
var making: sync.RwLock = .{};

pub fn protect(loaded: *Loaded, address: usize, len: usize, protection: api.Protection) api.ProtectError!api.Protection {
    const record = try changesOf(loaded);
    record.lock.lock();
    defer record.lock.unlock();
    try record.list.ensureUnusedCapacity(loaded.allocator, 1);
    const old = mem.protect(address, len, convert(mem.Protection, protection)) catch return error.ProtectFailed;
    record.list.appendAssumeCapacity(.{ .address = address, .len = len, .old = old });
    return convert(api.Protection, old);
}

fn convert(comptime To: type, from: anytype) To {
    return switch (from) {
        inline else => |p| @field(To, @tagName(p)),
    };
}

fn changesOf(loaded: *Loaded) api.ProtectError!*Changes {
    if (changes.first(&loaded.owner)) |c| return c;
    making.lock();
    defer making.unlock();
    if (changes.first(&loaded.owner)) |c| return c;
    const record = try loaded.allocator.create(Changes);
    record.* = .{ .loaded = loaded };
    changes.add(record) catch {
        loaded.allocator.destroy(record);
        return error.ProtectFailed;
    };
    return record;
}

const tests = struct {
    const testing = std.testing;
    const sdk = @import("wraith_sdk");

    test "protection goes back when the owner does" {
        var loaded: Loaded = undefined;
        loaded.initForTest(testing.allocator, "test");
        sdk.Owner.attach(loaded.root());
        defer sdk.Owner.detach();
        const page = try mem.pages.allocAny(4096);
        defer mem.pages.free(page);
        const at = @intFromPtr(page.ptr);

        const m = sdk.wraith.root().?.memory();
        try testing.expectEqual(.read_write_execute, try m.protect(at, 16, .read));
        try testing.expectEqual(.read, try m.protect(at, 16, .read_write));
        try testing.expect(!mem.Memory.local.regionFrom(at).?.executable);
        loaded.deinitForTest();
        const back = mem.Memory.local.regionFrom(at).?;
        try testing.expect(back.writable and back.executable);
    }
};

test {
    _ = tests;
}
