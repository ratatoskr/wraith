//! The free camera and posing for plugins: `Camera` and `Posing` from the API, which game and engine
//! plugins hand the game's camera and skeletons to. They go to the runtime's Photo mode while there
//! is one. Any thread.

const std = @import("std");

const api = @import("wraith_api");
const math = @import("tuft_math");
const sync = @import("tuft_sys").sync;

const Photo = @import("../photo/Photo.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;

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

    pub fn pose(_: *Loaded, skeleton: W.PosingSkeleton, matrices: *math.Mat4) void {
        lock.lockShared();
        defer lock.unlockShared();
        if (photo) |p| p.posing.pose(skeleton, matrices);
    }
};
