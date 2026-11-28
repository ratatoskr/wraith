//! Named script libraries for `require(name)` and `@use`, one entry per language. Any thread.

const Libraries = @This();

const std = @import("std");
const core = @import("wraith_core");

const api = @import("wraith_api");
const tuft_sys = @import("tuft_sys");
const Owner = @import("tuft_event").Owner;
const ce = @import("wraith_importer").ce;

pub var global: Libraries = .{};

/// Bigger than any library should be.
pub const max_source = 16 << 20;

pub const Entry = struct {
    /// Gone with it. Null for the runtime's.
    owner: ?*const Owner = null,
    name: []const u8,
    /// Like `lua` or `js`.
    language: []const u8,
    source: []const u8,
};

allocator: std.mem.Allocator = core.heap.main,
lock: tuft_sys.sync.RwLock = .{},
entries: std.ArrayList(*Held) = .empty,

const Held = struct {
    arena: std.heap.ArenaAllocator,
    entry: Entry,
};

pub fn init(allocator: std.mem.Allocator) Libraries {
    return .{ .allocator = allocator };
}

/// With the runtime's own, like the Cheat Engine layer for imported tables.
pub fn initBuiltin(allocator: std.mem.Allocator) !Libraries {
    var self: Libraries = .init(allocator);
    errdefer self.deinit();
    try self.add(.{ .name = ce.lua.library_name, .language = "lua", .source = ce.lua.compat_source });
    return self;
}

pub fn deinit(self: *Libraries) void {
    for (self.entries.items) |h| destroy(h);
    self.entries.deinit(self.allocator);
    self.* = .{};
}

/// The same owner again replaces its own. Someone else's by that name and language is taken.
pub fn add(self: *Libraries, entry: Entry) api.LibraryError!void {
    if (!api.validLibraryName(entry.name) or entry.language.len == 0 or entry.language.len > 16) return error.InvalidName;
    if (entry.source.len > max_source) return error.TooBig;
    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const held = try a.create(Held);
    held.* = .{ .arena = undefined, .entry = .{
        .owner = entry.owner,
        .name = try a.dupe(u8, entry.name),
        .language = try a.dupe(u8, entry.language),
        .source = try a.dupe(u8, entry.source),
    } };
    self.lock.lock();
    defer self.lock.unlock();
    for (self.entries.items, 0..) |h, i| {
        const e = &h.entry;
        if (!std.mem.eql(u8, e.name, entry.name) or !std.mem.eql(u8, e.language, entry.language)) continue;
        if (e.owner != entry.owner) return error.Taken;
        held.arena = arena;
        self.entries.items[i] = held;
        destroy(h);
        return;
    }
    try self.entries.append(self.allocator, held);
    held.arena = arena;
}

/// Everything it added.
pub fn removeOwner(self: *Libraries, owner: *const Owner) void {
    self.lock.lock();
    defer self.lock.unlock();
    var i: usize = 0;
    while (i < self.entries.items.len) {
        const h = self.entries.items[i];
        if (h.entry.owner == owner) {
            destroy(h);
            _ = self.entries.orderedRemove(i);
        } else i += 1;
    }
}

/// The source's length, copied into `out` if it fits.
pub fn get(self: *Libraries, name: []const u8, language: []const u8, out: []u8) api.LibraryError!usize {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    var named = false;
    for (self.entries.items) |h| {
        const e = &h.entry;
        if (!std.mem.eql(u8, e.name, name)) continue;
        named = true;
        if (!std.mem.eql(u8, e.language, language)) continue;
        if (out.len >= e.source.len) @memcpy(out[0..e.source.len], e.source);
        return e.source.len;
    }
    return if (named) error.NoSource else error.NotFound;
}

fn destroy(h: *Held) void {
    var arena = h.arena;
    arena.deinit();
}

test "builtin, replaced, taken and gone with the owner" {
    const testing = std.testing;
    var libs: Libraries = try .initBuiltin(testing.allocator);
    defer libs.deinit();
    var buf: [8]u8 = undefined;
    try testing.expect(try libs.get("ce", "lua", &buf) > buf.len);
    try testing.expectError(error.NoSource, libs.get("ce", "js", &buf));
    try testing.expectError(error.NotFound, libs.get("nope", "lua", &buf));

    var owner: Owner = .init("kai");
    try testing.expectError(error.Taken, libs.add(.{ .owner = &owner, .name = "ce", .language = "lua", .source = "x" }));
    try testing.expectError(error.InvalidName, libs.add(.{ .owner = &owner, .name = "no spaces", .language = "lua", .source = "x" }));
    try libs.add(.{ .owner = &owner, .name = "util", .language = "lua", .source = "one" });
    try libs.add(.{ .owner = &owner, .name = "util", .language = "lua", .source = "two" });
    try libs.add(.{ .owner = &owner, .name = "ce", .language = "js", .source = "three" });
    try testing.expectEqual(3, try libs.get("util", "lua", &buf));
    try testing.expectEqualStrings("two", buf[0..3]);
    libs.removeOwner(&owner);
    try testing.expectError(error.NotFound, libs.get("util", "lua", &buf));
    try testing.expectError(error.NoSource, libs.get("ce", "js", &buf));
}
