//! The free camera and posing for plugins, `Camera` and `Posing`, which game and engine plugins hand
//! the game's camera and skeletons to. Any thread.

const std = @import("std");

const api = @import("wraith_api");
const math = @import("tuft_math");
const sync = @import("tuft_sys").sync;

const Photo = @import("../photo/Photo.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;
const OnGone = @import("Owned.zig").OnGone;
const leases = @import("leases.zig");
const wraith = @import("wraith.zig");
const Owner = @import("tuft_event").Owner;

const W = api.wraith;
pub const FreeCamera = W.FreeCamera;
pub const Posing = W.Posing;

var photo: ?*Photo = null;
/// Held shared while calling in, so `set(null)` waits for calls in flight.
var lock: sync.RwLock = .{};

/// Set null before it goes.
pub fn set(p: ?*Photo) void {
    lock.lock();
    defer lock.unlock();
    photo = p;
}

/// As the camera changes hands: the free camera uses the new one's world. Under the camera's lease lock.
pub fn cameraHandedOver(after: ?*leases.Lease) void {
    const a = after orelse return;
    const w = a.world orelse return;
    lock.lockShared();
    defer lock.unlockShared();
    if (photo) |p| p.camera.world(w);
}

/// As posing changes hands: forgets the old one's characters. Edits are kept by bone name for if it's back.
pub fn posingHandedOver(before: ?*leases.Lease) void {
    const b = before orelse return;
    lock.lockShared();
    defer lock.unlockShared();
    if (photo) |p| p.posing.forget(@intFromPtr(&b.loaded.owner));
}

fn keepWorld(w: W.FreeCamera.World, lease: *leases.Lease) void {
    lease.world = w;
    if (!lease.held()) return;
    lock.lockShared();
    defer lock.unlockShared();
    if (photo) |p| p.camera.world(w);
}

/// A lease on `part` as the plugin's `Lease`, for `claim`s.
fn claimFor(loaded: *Loaded, comptime part: leases.Part, changed: ?W.Lease.Changed) api.salamander.Plain(if (part == .camera) W.FreeCamera else W.Posing, "claim") {
    const t = wraith.tablesOf(loaded) orelse {
        if (changed) |c| c.release();
        return error.Failed;
    };
    const l = leases.claim(loaded, part, changed, null) catch return error.Failed;
    if (part == .camera) takePendingWorld(loaded);
    return .init(l, t.lease);
}

/// A world set before claiming goes on its lease now it has one, as if it had come after.
fn takePendingWorld(loaded: *Loaded) void {
    const w = loaded.pending_world orelse return;
    loaded.pending_world = null;
    _ = leases.withLease(loaded, .camera, w, keepWorld);
}

pub const CameraImpl = struct {
    pub fn claim(loaded: *Loaded, changed: ?W.Lease.Changed) api.salamander.Plain(W.FreeCamera, "claim") {
        return claimFor(loaded, .camera, changed);
    }

    pub fn setWorld(loaded: *Loaded, w: W.FreeCamera.World) void {
        // Without a lease yet, it's kept for when it claims one
        if (!leases.withLease(loaded, .camera, w, keepWorld)) loaded.pending_world = w;
    }

    pub fn camera(loaded: *Loaded, id: u64, state: *W.FreeCamera.State) void {
        if (!leases.holds(loaded, .camera)) return;
        lock.lockShared();
        defer lock.unlockShared();
        if (photo) |p| p.camera.camera(id, state);
    }

    pub fn focus(_: *Loaded, point: math.Vec3) void {
        lock.lockShared();
        defer lock.unlockShared();
        if (photo) |p| p.camera.focus(point);
    }

    pub fn active(_: *Loaded) bool {
        lock.lockShared();
        defer lock.unlockShared();
        const p = photo orelse return false;
        return p.camera.active();
    }

    pub fn wantedCamera(loaded: *Loaded) u64 {
        lock.lockShared();
        defer lock.unlockShared();
        const p = photo orelse return 0;
        return p.cameras.wantedCamera(loaded);
    }

    pub fn cameras(loaded: *Loaded, add: ?W.ItemList.Add, rename: ?W.ItemList.Rename) api.salamander.Object(W.ItemList) {
        return @import("wraith.zig").cameraList(loaded, add, rename);
    }
};

pub const PosingImpl = struct {
    pub fn claim(loaded: *Loaded, changed: ?W.Lease.Changed) api.salamander.Plain(W.Posing, "claim") {
        return claimFor(loaded, .posing, changed);
    }

    /// False for a plugin that doesn't hold posing, so it can skip building skeletons.
    pub fn active(loaded: *Loaded) bool {
        if (!leases.holds(loaded, .posing)) return false;
        lock.lockShared();
        defer lock.unlockShared();
        const p = photo orelse return false;
        return p.posing.active();
    }

    pub fn pose(loaded: *Loaded, skeleton: W.Posing.Skeleton, matrices: *math.Mat4) void {
        if (!leases.holds(loaded, .posing)) return;
        const lease = posing_cleanup.lease(&loaded.owner) orelse return;
        defer lease.end();
        lock.lockShared();
        defer lock.unlockShared();
        if (photo) |p| p.posing.pose(@intFromPtr(&loaded.owner), skeleton, matrices);
    }

    pub fn shapes(loaded: *Loaded, actor: u64, list: []const W.Posing.Shape, weights: *f32) void {
        if (!leases.holds(loaded, .posing)) return;
        const lease = posing_cleanup.lease(&loaded.owner) orelse return;
        defer lease.end();
        lock.lockShared();
        defer lock.unlockShared();
        if (photo) |p| p.posing.shapes(actor, list, weights);
    }

    pub fn wanted(loaded: *Loaded, actor: u64) bool {
        if (!leases.holds(loaded, .posing)) return false;
        lock.lockShared();
        defer lock.unlockShared();
        const p = photo orelse return false;
        return p.posing.wants(actor);
    }
};

var posing_cleanup: OnGone(.closing, posingOwnerGone) = .{};

/// Its ids mean nothing once it's gone, and a new one could hand over the same ones.
fn posingOwnerGone(owner: *Owner) void {
    lock.lockShared();
    defer lock.unlockShared();
    if (photo) |p| p.posing.forget(@intFromPtr(owner));
}

test "a camera world set before claiming is kept for the lease" {
    const testing = std.testing;
    var game: Loaded = undefined;
    game.initForTest(testing.allocator, "kai");
    game.manifest.value.game = .{ .ids = &.{"kai"} };
    defer {
        game.deinitForTest();
        wraith.forget(&game);
    }
    const before: W.FreeCamera.World = .{ .up = .pos_y, .look = .pos_z, .left_handed = false, .metre = 1 };
    CameraImpl.setWorld(&game, before);
    try testing.expectEqual(before, game.pending_world.?);

    const lease = try leases.claim(&game, .camera, null, null);
    takePendingWorld(&game);
    try testing.expectEqual(before, lease.world.?);
    try testing.expectEqual(null, game.pending_world);

    // Once it has one, it goes straight on it
    const after: W.FreeCamera.World = .{ .up = .pos_z, .look = .pos_x, .left_handed = true, .metre = 100 };
    CameraImpl.setWorld(&game, after);
    try testing.expectEqual(after, lease.world.?);
    try testing.expectEqual(null, game.pending_world);
}
