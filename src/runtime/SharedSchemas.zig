//! `.sal` text plugins and scripts load, so the Addresses panel can use their types too. Only text
//! is kept, each view parses its own copy. Any thread.

const SharedSchemas = @This();

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const tuft_sys = @import("tuft_sys");
const Owner = @import("tuft_event").Owner;

pub var global: SharedSchemas = .{};

/// Bigger than any schema should be.
pub const max_text = 16 << 20;

pub const Entry = struct {
    /// Gone with it. Null for the runtime's.
    owner: ?*const Owner = null,
    /// What it's shown under, like its plugin.
    group: []const u8 = "",
    /// What it's from, like its file.
    name: []const u8,
    text: []const u8,
};

allocator: std.mem.Allocator = std.heap.page_allocator,
lock: tuft_sys.sync.RwLock = .{},
entries: std.ArrayList(*Held) = .empty,
/// Bumped on every change, so views can catch up.
changes: Atomic(u32) = .init(1),

const Held = struct {
    arena: std.heap.ArenaAllocator,
    entry: Entry,
};

pub fn init(allocator: std.mem.Allocator) SharedSchemas {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *SharedSchemas) void {
    for (self.entries.items) |h| destroy(h);
    self.entries.deinit(self.allocator);
    self.* = .{};
}

/// Kept once if the same owner adds the same name and text again.
pub fn add(self: *SharedSchemas, entry: Entry) error{ OutOfMemory, TooBig }!void {
    if (entry.text.len > max_text) return error.TooBig;
    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const held = try a.create(Held);
    held.* = .{ .arena = undefined, .entry = .{
        .owner = entry.owner,
        .group = try a.dupe(u8, entry.group),
        .name = try a.dupe(u8, entry.name),
        .text = try a.dupe(u8, entry.text),
    } };
    self.lock.lock();
    defer self.lock.unlock();
    for (self.entries.items) |h| {
        const e = &h.entry;
        if (e.owner == entry.owner and std.mem.eql(u8, e.name, entry.name) and std.mem.eql(u8, e.text, entry.text)) {
            arena.deinit();
            return;
        }
    }
    try self.entries.append(self.allocator, held);
    held.arena = arena;
    _ = self.changes.fetchAdd(1, .release);
}

/// Everything it added.
pub fn removeOwner(self: *SharedSchemas, owner: *const Owner) void {
    self.lock.lock();
    defer self.lock.unlock();
    var i: usize = 0;
    var removed = false;
    while (i < self.entries.items.len) {
        const h = self.entries.items[i];
        if (h.entry.owner == owner) {
            destroy(h);
            _ = self.entries.orderedRemove(i);
            removed = true;
        } else i += 1;
    }
    if (removed) _ = self.changes.fetchAdd(1, .release);
}

pub fn generation(self: *SharedSchemas) u32 {
    return self.changes.load(.acquire);
}

/// Copies of them all, in the order they came, in `arena`.
pub fn copy(self: *SharedSchemas, arena: std.mem.Allocator) ![]Entry {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    const out = try arena.alloc(Entry, self.entries.items.len);
    for (out, self.entries.items) |*o, h| {
        const e = &h.entry;
        o.* = .{
            .owner = e.owner,
            .group = try arena.dupe(u8, e.group),
            .name = try arena.dupe(u8, e.name),
            .text = try arena.dupe(u8, e.text),
        };
    }
    return out;
}

fn destroy(h: *Held) void {
    var arena = h.arena;
    arena.deinit();
}
