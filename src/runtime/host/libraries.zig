//! Named script libraries for providers' `require`, see `Libraries`.

const std = @import("std");

const Owner = @import("tuft_event").Owner;
const api = @import("wraith_api");

const Loaded = @import("../PluginLoader.zig").Loaded;
const Libraries = @import("../Libraries.zig");

pub fn get(_: *Loaded, name: []const u8, language: []const u8, out: []u8) api.LibraryError!usize {
    return Libraries.global.get(name, language, out);
}

pub fn add(loaded: *Loaded, name: []const u8, language: []const u8, source: []const u8) api.LibraryError!void {
    const lease = watch.lease(&listener, &loaded.owner, .data) orelse return error.OutOfMemory;
    defer lease.end();
    try Libraries.global.add(.{ .owner = &loaded.owner, .name = name, .language = language, .source = source });
}

var watch: Owner.Watch(*u8, .{ .released = released }) = .{};
var listener: u8 = 0;

fn released(_: *u8, owner: *Owner) void {
    Libraries.global.removeOwner(owner);
}

test "the runtime's own are there" {
    const testing = std.testing;
    Libraries.global = try .initBuiltin(testing.allocator);
    defer Libraries.global.deinit();
    var loaded: Loaded = undefined;
    var buf: [16]u8 = undefined;
    try testing.expect(try get(&loaded, "ce", "lua", &buf) > buf.len);
    try testing.expectError(error.NoSource, get(&loaded, "ce", "js", &buf));
    try testing.expectError(error.NotFound, get(&loaded, "nope", "lua", &buf));
}

test "a plugin's go with it" {
    const testing = std.testing;
    Libraries.global = try .initBuiltin(testing.allocator);
    defer Libraries.global.deinit();
    var loaded: Loaded = undefined;
    loaded.initForTest(testing.allocator, "cam");
    try add(&loaded, "freecam", "js", "module.exports = 1;");
    try testing.expectError(error.Taken, add(&loaded, "ce", "lua", "x"));
    var buf: [32]u8 = undefined;
    try testing.expectEqual(19, try get(&loaded, "freecam", "js", &buf));
    loaded.deinitForTest();
    try testing.expectError(error.NotFound, get(&loaded, "freecam", "js", &buf));
}
