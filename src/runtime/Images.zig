//! Images owners made to draw. Handles are ids, so a stale one finds nothing. Any thread.

const Images = @This();

const std = @import("std");
const core = @import("wraith_core");

const tuft_sys = @import("tuft_sys");
const Owner = @import("tuft_event").Owner;
const Texture = @import("tuft_imgui").Texture;
const c = @import("tuft_imgui").c;

pub var global: Images = .{};

/// Pixels too, since textures can outlive their owner by a frame or so.
allocator: std.mem.Allocator = core.heap.main,
lock: tuft_sys.sync.RwLock = .{},
entries: std.AutoHashMapUnmanaged(u32, Entry) = .empty,
next: u32 = 0,

pub const Entry = struct {
    /// Gone with it. Null for the runtime's.
    owner: ?*const Owner,
    texture: *Texture,
};

pub fn init(allocator: std.mem.Allocator) Images {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Images) void {
    var it = self.entries.valueIterator();
    while (it.next()) |e| e.texture.destroy();
    self.entries.deinit(self.allocator);
    self.* = .{};
}

/// Takes `texture`, even on error. Never 0.
pub fn add(self: *Images, owner: ?*const Owner, made: *Texture) error{OutOfMemory}!u32 {
    self.lock.lock();
    defer self.lock.unlock();
    self.entries.ensureUnusedCapacity(self.allocator, 1) catch {
        made.destroy();
        return error.OutOfMemory;
    };
    while (true) {
        self.next +%= 1;
        if (self.next != 0 and !self.entries.contains(self.next)) break;
    }
    self.entries.putAssumeCapacity(self.next, .{ .owner = owner, .texture = made });
    return self.next;
}

/// Only the owner's own. Nothing if it's gone already.
pub fn remove(self: *Images, owner: ?*const Owner, id: u32) void {
    const gone = blk: {
        self.lock.lock();
        defer self.lock.unlock();
        const e = self.entries.get(id) orelse return;
        if (e.owner != owner) return;
        _ = self.entries.remove(id);
        break :blk e.texture;
    };
    gone.destroy();
}

/// Everything it made.
pub fn removeOwner(self: *Images, owner: *const Owner) void {
    self.lock.lock();
    defer self.lock.unlock();
    var it = self.entries.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.owner != owner) continue;
        kv.value_ptr.texture.destroy();
        self.entries.removeByPtr(kv.key_ptr);
        // Removing can move what's left
        it = self.entries.iterator();
    }
}

pub fn size(self: *Images, owner: ?*const Owner, id: u32) ?[2]u32 {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    const e = self.entries.get(id) orelse return null;
    if (e.owner != owner) return null;
    return .{ e.texture.width, e.texture.height };
}

/// For the current ImGui context, this frame. Render thread.
pub fn textureRef(self: *Images, owner: ?*const Owner, id: u32) ?c.ImTextureRef {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    const e = self.entries.get(id) orelse return null;
    if (e.owner != owner) return null;
    return e.texture.ref();
}

pub fn count(self: *Images) usize {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    return self.entries.count();
}
