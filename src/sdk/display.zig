//! What the game shows: its camera's view and how its output's encoded, from `display.sal`.

const std = @import("std");

const api = @import("wraith_api");
const Owner = @import("Owner.zig");

const W = api.wraith;
const Mat4 = @import("tuft_math").Mat4;
const Vec3 = @import("tuft_math").Vec3;

/// What the game's camera shows, for drawing over the world, like a gizmo or a label over a
/// character. Row-vector style, the way Direct3D has it: the camera looks down +z and depth goes
/// from 0 to 1.
pub const View = struct {
    view: Mat4,
    projection: Mat4,

    pub fn viewProjection(self: View) Mat4 {
        return self.view.mul(self.projection);
    }

    /// Where `point` in the world is on a window `size` pixels big, from its top left. Null if it's
    /// behind the camera.
    pub fn project(self: View, point: Vec3, size: [2]f32) ?[2]f32 {
        const clip = self.viewProjection().transformVec4(point.withW(1));
        if (clip.w < 0.01) return null;
        return .{ (clip.x / clip.w * 0.5 + 0.5) * size[0], (0.5 - clip.y / clip.w * 0.5) * size[1] };
    }
};

/// For a game or game engine plugin, each frame once the camera's where it'll be drawn from, after
/// the free camera has moved it. Any thread.
pub fn setView(view_: Mat4, projection: Mat4) void {
    const owner = Owner.current() orelse return;
    owner.root.display().setView(view_, projection);
}

/// For a game or game engine plugin that knows how the game's output is encoded, like HDR10 when
/// the game's HDR is on. Wraith goes by it where the swap chain can't say, like a 10-bit one Wraith
/// joined late. What the game sets on its swap chain itself still wins. Any thread.
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
