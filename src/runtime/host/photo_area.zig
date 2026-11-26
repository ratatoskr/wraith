//! The free camera and posing for plugins: `Camera` and `Posing` from the API, which game and engine
//! plugins hand the game's camera and skeletons to. They go to the runtime's Photo mode while there
//! is one. Any thread.

const std = @import("std");

const api = @import("wraith_api");
const math = @import("tuft_math");
const sync = @import("tuft_sys").sync;

const Photo = @import("../photo/Photo.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;
const OnGone = @import("Owned.zig").OnGone;
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

pub const CameraImpl = struct {
    pub fn setWorld(_: *Loaded, w: W.FreeCamera.World) void {
        lock.lockShared();
        defer lock.unlockShared();
        if (photo) |p| p.camera.world(w);
    }

    pub fn camera(_: *Loaded, id: u64, state: *W.FreeCamera.State) void {
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
        return p.camera.wantedCamera(loaded);
    }

    pub fn cameras(loaded: *Loaded, add: ?W.ItemList.Add, rename: ?W.ItemList.Rename) api.salamander.Object(W.ItemList) {
        return @import("wraith.zig").cameraList(loaded, add, rename);
    }
};

pub const PosingImpl = struct {
    pub fn active(_: *Loaded) bool {
        lock.lockShared();
        defer lock.unlockShared();
        const p = photo orelse return false;
        return p.posing.active();
    }

    pub fn pose(loaded: *Loaded, skeleton: W.Posing.Skeleton, matrices: *math.Mat4) void {
        const lease = posing_cleanup.lease(&loaded.owner) orelse return;
        defer lease.end();
        lock.lockShared();
        defer lock.unlockShared();
        if (photo) |p| p.posing.pose(@intFromPtr(&loaded.owner), skeleton, matrices);
    }

    pub fn shapes(loaded: *Loaded, actor: u64, list: []const W.Posing.Shape, weights: *f32) void {
        const lease = posing_cleanup.lease(&loaded.owner) orelse return;
        defer lease.end();
        lock.lockShared();
        defer lock.unlockShared();
        if (photo) |p| p.posing.shapes(actor, list, weights);
    }

    pub fn wanted(_: *Loaded, actor: u64) bool {
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
