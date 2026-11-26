//! What the game shows: its camera's view and how its output's encoded, from `display.sal`.

const std = @import("std");

const api = @import("wraith_api");
const Owner = @import("Owner.zig");
const Lease = @import("lease.zig").Lease;

const W = api.wraith;
const Mat4 = @import("tuft_math").Mat4;
const Vec3 = @import("tuft_math").Vec3;

/// The game camera's view, for drawing over the world. Direct3D style: row vectors, +z forward, depth 0-1.
pub const View = struct {
    view: Mat4,
    projection: Mat4,

    pub fn viewProjection(self: View) Mat4 {
        return self.view.mul(self.projection);
    }

    /// `point` in window pixels from the top left, or null if behind the camera.
    pub fn project(self: View, point: Vec3, size: [2]f32) ?[2]f32 {
        const clip = self.viewProjection().transformVec4(point.withW(1));
        if (clip.w < 0.01) return null;
        return .{ (clip.x / clip.w * 0.5 + 0.5) * size[0], (0.5 - clip.y / clip.w * 0.5) * size[1] };
    }
};

/// Lease on the view and color space, for game or engine plugins. Only the holder's setters count.
pub fn claimView(changed: Lease.Changed) error{ OwnerGone, Failed }!Lease {
    const owner = Owner.current() orelse return error.OwnerGone;
    return .{ .object = owner.root.display().claimView(changed.callback) catch return error.Failed };
}

/// Sets the view each frame, after the free camera moved it. Holder only, any thread.
pub fn setView(view_: Mat4, projection: Mat4) void {
    const owner = Owner.current() orelse return;
    owner.root.display().setView(view_, projection);
}

/// Sets the output color space, like HDR10, where the swap chain can't say. Holder only, any thread.
pub fn setColorSpace(space: W.ColorSpace) void {
    const owner = Owner.current() orelse return;
    owner.root.display().setColorSpace(space);
}

/// The game's camera as its plugin last set it, or null if it hasn't lately. Any thread.
pub fn view() ?View {
    const owner = Owner.current() orelse return null;
    const v = owner.root.display().gameView();
    if (!v.known) return null;
    return .{ .view = v.viewMatrix, .projection = v.projection };
}

const tests = struct {
    test "a point in front lands on screen, one behind doesn't" {
        // Looking down +z, a quarter turn wide
        const near: f32 = 0.1;
        const far: f32 = 100;
        const projection: Mat4 = .{ .m = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, far / (far - near), 1, 0, 0, -near * far / (far - near), 0 } };
        const v: View = .{ .view = .identity, .projection = projection };
        const middle = v.project(.{ .z = 5 }, .{ 800, 600 }).?;
        try std.testing.expectApproxEqAbs(400, middle[0], 1e-3);
        try std.testing.expectApproxEqAbs(300, middle[1], 1e-3);
        // Up and right is up and right on screen
        const corner = v.project(.{ .x = 5, .y = 5, .z = 5 }, .{ 800, 600 }).?;
        try std.testing.expectApproxEqAbs(800, corner[0], 1e-3);
        try std.testing.expectApproxEqAbs(0, corner[1], 1e-3);
        try std.testing.expectEqual(null, v.project(.{ .z = -5 }, .{ 800, 600 }));
    }
};

test {
    _ = tests;
}
