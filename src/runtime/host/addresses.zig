//! The game's named addresses for plugins, see `Names`. Ids find entries.

const std = @import("std");

const mem = @import("tuft_mem");
const Owner = @import("tuft_event").Owner;
const api = @import("wraith_api");

const Loaded = @import("../PluginLoader.zig").Loaded;
const Names = @import("../Names.zig");

pub fn get(_: *Loaded, id: []const u8) api.AddressError!usize {
    return Names.global.get(id);
}

pub fn add(loaded: *Loaded, entry: api.AddressEntry) api.AddressAddError!void {
    if (entry.id.len == 0 or std.mem.indexOfAny(u8, entry.id, " \t") != null) return error.InvalidId;
    if (entry.address.len == 0) return error.InvalidAddress;
    const lease = keeping(loaded) orelse return error.OutOfMemory;
    defer lease.end();
    var buf: [192]u8 = undefined;
    const full = std.fmt.bufPrint(&buf, "{s}.{s}", .{ loaded.name, entry.id }) catch return error.InvalidId;
    if (Names.global.has(.plugin, full)) return error.AlreadyAdded;
    var offsets: [16]isize = undefined;
    if (entry.offsets.len > offsets.len) return error.InvalidAddress;
    for (entry.offsets, 0..) |o, i| offsets[i] = @intCast(o);
    try Names.global.put(.{
        .source = .plugin,
        .owner = &loaded.owner,
        .group = loaded.name,
        .name = full,
        .label = entry.name,
        .where = .{ .text = .{ .text = entry.address, .offsets = offsets[0..entry.offsets.len] } },
        .type = entry.type,
        .size = entry.size,
    });
}

pub fn remove(loaded: *Loaded, id: []const u8) void {
    var buf: [192]u8 = undefined;
    const full = std.fmt.bufPrint(&buf, "{s}.{s}", .{ loaded.name, id }) catch return;
    Names.global.remove(.plugin, &loaded.owner, full);
}

pub fn resolve(_: *Loaded, text: []const u8, names: []const api.Name, problem: *api.LocationProblem) api.AddressError!usize {
    var found: mem.Location.Problem = .{};
    return Names.global.eval(text, scopeOf(&names), &found) catch |err| {
        problem.set(found.message());
        return switch (err) {
            error.Unreadable => error.Unreadable,
            error.NotFound => error.NotFound,
            else => error.InvalidAddress,
        };
    };
}

/// `names` as symbols, looked up before everything else. Only good while `names` is.
pub fn scopeOf(names: *const []const api.Name) mem.Symbols {
    return .{ .context = @ptrCast(@constCast(names)), .vtable = &.{ .resolve = struct {
        fn resolve(context: ?*anyopaque, name: []const u8) ?usize {
            const list: *const []const api.Name = @ptrCast(@alignCast(context.?));
            return api.Name.find(list.*, name);
        }
    }.resolve } };
}

fn keeping(loaded: *Loaded) ?Owner.Lease {
    return watch.lease(&listener, &loaded.owner, .data);
}

var watch: Owner.Watch(*u8, .{ .released = released }) = .{};
var listener: u8 = 0;

fn released(_: *u8, owner: *Owner) void {
    Names.global.removeOwner(owner);
}

const tests = struct {
    const testing = std.testing;

    test "ids find plugin entries until the plugin goes" {
        Names.global = .init(testing.allocator);
        defer Names.global.deinit();
        var value: u32 = 5;
        var pointer: *u32 = &value;
        var loaded: Loaded = undefined;
        loaded.initForTest(testing.allocator, "kai");

        var buf: [32]u8 = undefined;
        const before = Names.global.generation();
        try add(&loaded, .{ .id = "hp", .address = try std.fmt.bufPrint(&buf, "0x{x}", .{@intFromPtr(&pointer)}), .offsets = &.{0}, .type = "u32" });
        try testing.expect(Names.global.generation() != before);
        try testing.expectError(error.AlreadyAdded, add(&loaded, .{ .id = "hp", .address = "0x1" }));
        try testing.expectEqual(@intFromPtr(&value), try get(&loaded, "kai.hp"));

        var shown: [2]Names.Info = undefined;
        try testing.expectEqual(1, Names.global.list(&shown));
        try testing.expectEqual(.plugin, shown[0].source);
        try testing.expectEqualStrings("kai", shown[0].group.get());

        var problem: api.LocationProblem = .{};
        const names = [_]api.Name{.of("mine", 0x40)};
        try testing.expectEqual(0x48, try resolve(&loaded, "mine + 8", &names, &problem));
        try testing.expectEqual(@intFromPtr(&value) + 2, try resolve(&loaded, "(kai.hp)+2", &.{}, &problem));
        try testing.expectError(error.InvalidAddress, resolve(&loaded, "nobody", &.{}, &problem));
        try testing.expectEqualStrings("there's no nobody", problem.message());

        remove(&loaded, "hp");
        try testing.expectError(error.NotFound, get(&loaded, "kai.hp"));
        try add(&loaded, .{ .id = "hp", .address = "0x1" });
        loaded.deinitForTest();
        try testing.expectError(error.NotFound, get(&loaded, "kai.hp"));
    }
};

test {
    _ = tests;
}
