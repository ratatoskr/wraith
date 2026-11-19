//! Where Wraith keeps things, under `%LOCALAPPDATA%\Wraith` or `WRAITH_ROOT`.

const std = @import("std");

const Locations = @This();

root: []const u8,
/// Mods, plugins and projects alike.
mods: []const u8,

pub const Env = struct {
    /// Empty counts as unset.
    root_override: ?[]const u8 = null,
    local_app_data: ?[]const u8 = null,
};

pub fn init(allocator: std.mem.Allocator, env: Env) error{ OutOfMemory, NoRoot }!Locations {
    const root = if (env.root_override) |r| (if (r.len != 0) try allocator.dupe(u8, r) else null) else null;
    const owned_root = root orelse try std.fs.path.join(allocator, &.{ env.local_app_data orelse return error.NoRoot, "Wraith" });
    errdefer allocator.free(owned_root);
    return .{ .root = owned_root, .mods = try std.fs.path.join(allocator, &.{ owned_root, "mods" }) };
}

pub fn deinit(self: Locations, allocator: std.mem.Allocator) void {
    allocator.free(self.root);
    allocator.free(self.mods);
}

pub fn path(self: Locations, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ self.root, name });
}

const tests = struct {
    const testing = std.testing;

    test "root location" {
        const a = testing.allocator;
        const local = try init(a, .{ .local_app_data = "C:\\Users\\u\\AppData\\Local" });
        defer local.deinit(a);
        try testing.expectEqualStrings("C:\\Users\\u\\AppData\\Local\\Wraith", local.root);
        try testing.expectEqualStrings("C:\\Users\\u\\AppData\\Local\\Wraith\\mods", local.mods);

        const overridden = try init(a, .{ .root_override = "D:\\sandbox", .local_app_data = "C:\\x" });
        defer overridden.deinit(a);
        try testing.expectEqualStrings("D:\\sandbox\\mods", overridden.mods);

        const empty = try init(a, .{ .root_override = "", .local_app_data = "C:\\x" });
        defer empty.deinit(a);
        try testing.expectEqualStrings("C:\\x\\Wraith", empty.root);

        try testing.expectError(error.NoRoot, init(a, .{}));
    }
};

test {
    _ = tests;
}
