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
    pub fn world(_: *Loaded, w: W.CamWorld) void {
        lock.lockShared();
        defer lock.unlockShared();
        if (photo) |p| p.camera.world(w);
    }

    pub fn camera(_: *Loaded, state: *W.CamState) void {
        lock.lockShared();
        defer lock.unlockShared();
        if (photo) |p| p.camera.camera(state);
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
};

pub const PosingImpl = struct {
    pub fn active(_: *Loaded) bool {
        lock.lockShared();
        defer lock.unlockShared();
        const p = photo orelse return false;
        return p.posing.active();
    }

    pub fn pose(loaded: *Loaded, skeleton: W.PosingSkeleton, matrices: *math.Mat4) void {
        const lease = posing_cleanup.lease(&loaded.owner) orelse return;
        defer lease.end();
        lock.lockShared();
        defer lock.unlockShared();
        if (photo) |p| p.posing.pose(@intFromPtr(&loaded.owner), skeleton, matrices);
    }

    pub fn shapes(loaded: *Loaded, actor: u64, list: []const W.PosingShape, weights: *f32) void {
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
