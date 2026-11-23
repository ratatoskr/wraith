//! The free camera's pose and turning it into the game's camera and back, in the game's own axes.

const std = @import("std");
const math = @import("tuft_math");

const Vec3 = math.Vec3;
const Quat = math.Quat;
const Mat4 = math.Mat4;

pub const V3 = @Vector(3, f32);

/// Like the schema's `CamAxis`.
pub const Axis = enum(u8) { pos_y, neg_y, pos_z, neg_z, pos_x, neg_x, _ };

pub const Aim = enum(u8) { target, rotation, _ };

/// Like the schema's `CamState`, which the plugin copies in and out of.
pub const Camera = struct {
    position: Vec3,
    aim: Aim,
    target: Vec3,
    /// For `target`. Zero means the world's
    up: Vec3 = .zero,
    rotation: Quat,
    roll: f32,
    fov: f32,
};

/// The world's axes, worked out once from how the game says it's laid out.
pub const Basis = struct {
    up: V3,
    /// Where a camera with no rotation looks, and where yaw 0 faces
    look: V3,
    right: V3,
    left_handed: bool,

    pub fn init(up: Axis, look: Axis, left_handed: bool) Basis {
        const u = axis(up);
        // Look can't be along up, so fall back to the next axis round
        var l = axis(look);
        if (@abs(dot(u, l)) > 0.5) l = .{ u[2], u[0], u[1] };
        return .{ .up = u, .look = l, .right = rightOf(l, u, left_handed), .left_handed = left_handed };
    }

    /// Y up, looking down +Z, left-handed, like D3D.
    pub const default: Basis = init(.pos_y, .pos_z, true);
};

fn axis(a: Axis) V3 {
    return switch (a) {
        .pos_x => .{ 1, 0, 0 },
        .neg_x => .{ -1, 0, 0 },
        .neg_y => .{ 0, -1, 0 },
        .pos_z => .{ 0, 0, 1 },
        .neg_z => .{ 0, 0, -1 },
        else => .{ 0, 1, 0 },
    };
}

/// Where the free camera is. Yaw turns right from `look`, pitch tips up.
pub const Pose = struct {
    position: V3,
    yaw: f32,
    pitch: f32,
    roll: f32,
    /// 0 when the game didn't give one
    fov: f32,
    /// How far ahead a target goes, the game's own distance when it took over
    reach: f32,

    pub const max_pitch = std.math.pi / 2.0 - 0.01;

    /// Where it's facing.
    pub fn forward(p: Pose, b: Basis) V3 {
        const cp = @cos(p.pitch);
        return splat(cp * @cos(p.yaw)) * b.look + splat(cp * @sin(p.yaw)) * b.right + splat(@sin(p.pitch)) * b.up;
    }

    /// Right and up as the camera sees them, before roll.
    pub fn sides(p: Pose, b: Basis) struct { right: V3, up: V3 } {
        const f = p.forward(b);
        const r = normalize(rightOf(f, b.up, b.left_handed));
        return .{ .right = r, .up = upOf(r, f, b.left_handed) };
    }

    /// Where it sits to look at `pivot` from `distance` away, facing the way it does.
    pub fn orbiting(p: Pose, b: Basis, pivot: V3, distance: f32) V3 {
        return pivot - p.forward(b) * splat(distance);
    }

    /// The point `distance` ahead of it, to orbit round when there's nothing better.
    pub fn ahead(p: Pose, b: Basis, distance: f32) V3 {
        return p.position + p.forward(b) * splat(distance);
    }

    /// Picks up where the game's camera is.
    pub fn fromCamera(b: Basis, cam: Camera) Pose {
        var f: V3 = undefined;
        var reach: f32 = 1;
        var roll = cam.roll;
        switch (cam.aim) {
            .rotation => {
                f = rotate(cam.rotation, b.look);
                const level = sidesFor(b, f);
                const u = rotate(cam.rotation, b.up);
                roll = std.math.atan2(-dot(u, level.right), dot(u, level.up));
            },
            else => {
                const d = cam.target.vec() - cam.position.vec();
                reach = length(d);
                f = if (reach > 1e-6) d / splat(reach) else b.look;
                if (reach < 1e-3) reach = 1;
                // A tipped up is roll too, so it's level once that goes back to 0
                const u = cam.up.vec();
                if (dot(u, u) > 1e-8) {
                    const level = sidesFor(b, normalize(f));
                    roll += std.math.atan2(-dot(u, level.right), dot(u, level.up));
                }
            },
        }
        f = normalize(f);
        return .{
            .position = cam.position.vec(),
            .yaw = std.math.atan2(dot(f, b.right), dot(f, b.look)),
            .pitch = std.math.clamp(std.math.asin(std.math.clamp(dot(f, b.up), -1, 1)), -max_pitch, max_pitch),
            .roll = roll,
            .fov = cam.fov,
            .reach = reach,
        };
    }

    /// Writes it into the game's camera, in the form the game gave it.
    pub fn toCamera(p: Pose, b: Basis, cam: *Camera) void {
        cam.position = .from(p.position);
        if (p.fov > 0 and cam.fov > 0) cam.fov = p.fov;
        const f = p.forward(b);
        switch (cam.aim) {
            .rotation => {
                const s = p.sides(b);
                const c = @cos(p.roll);
                const n = @sin(p.roll);
                const r = splat(c) * s.right + splat(n) * s.up;
                const u = splat(c) * s.up - splat(n) * s.right;
                cam.rotation = fromBases(.{ b.right, b.up, b.look }, .{ r, u, f });
            },
            else => {
                cam.target = .from(p.position + f * splat(p.reach));
                // The world's up, so turning never rolls it and only `roll` tips it
                cam.up = .from(b.up);
                cam.roll = p.roll;
            },
        }
    }
};

fn sidesFor(b: Basis, f: V3) struct { right: V3, up: V3 } {
    const r = normalize(rightOf(f, b.up, b.left_handed));
    return .{ .right = r, .up = upOf(r, f, b.left_handed) };
}

/// Right of `look` with `up` above it. If they line up, any right will do.
fn rightOf(look: V3, up: V3, left_handed: bool) V3 {
    const r = if (left_handed) cross(up, look) else cross(look, up);
    if (dot(r, r) > 1e-8) return r;
    return if (@abs(look[0]) < 0.9) cross(look, .{ 1, 0, 0 }) else cross(look, .{ 0, 0, 1 });
}

fn upOf(right: V3, look: V3, left_handed: bool) V3 {
    return if (left_handed) cross(look, right) else cross(right, look);
}

/// The rotation taking `from`'s right, up and look onto `to`'s.
fn fromBases(from: [3]V3, to: [3]V3) Quat {
    // Row vectors, so from[i] * m = to[i] gives m = transpose(from) * to
    return rows(from).transpose().mul(rows(to)).rotation();
}

fn rows(b: [3]V3) Mat4 {
    return .fromRows(Vec3.from(b[0]).withW(0), Vec3.from(b[1]).withW(0), Vec3.from(b[2]).withW(0), .{ .w = 1 });
}

/// `v` turned by `q`.
pub fn rotate(q: Quat, v: V3) V3 {
    return q.rotate(.from(v)).vec();
}

pub fn splat(x: f32) V3 {
    return @splat(x);
}

pub fn dot(a: V3, b: V3) f32 {
    return @reduce(.Add, a * b);
}

pub fn cross(a: V3, b: V3) V3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

pub fn length(a: V3) f32 {
    return @sqrt(dot(a, a));
}

pub fn normalize(a: V3) V3 {
    const l = length(a);
    return if (l > 1e-8) a / splat(l) else a;
}

/// Eases `from` toward `to`, the same whatever the frame rate. 0 smoothing snaps.
pub fn ease(from: anytype, to: @TypeOf(from), smoothing: f32, dt: f32) @TypeOf(from) {
    if (smoothing <= 0) return to;
    // Gets 99% of the way in `smoothing` seconds
    const k = 1 - @exp(-dt * 4.6 / smoothing);
    return switch (@TypeOf(from)) {
        f32 => from + (to - from) * k,
        else => from + (to - from) * splat(k),
    };
}

const testing = std.testing;

fn expectNear(a: V3, b: V3) !void {
    inline for (0..3) |i| try testing.expectApproxEqAbs(a[i], b[i], 1e-4);
}

test "yaw 0 faces look, positive yaw turns right" {
    const kai: Basis = .init(.pos_y, .neg_z, false);
    try expectNear(kai.right, .{ 1, 0, 0 });
    var p: Pose = .{ .position = @splat(0), .yaw = 0, .pitch = 0, .roll = 0, .fov = 0, .reach = 1 };
    try expectNear(p.forward(kai), .{ 0, 0, -1 });
    p.yaw = std.math.pi / 2.0;
    try expectNear(p.forward(kai), .{ 1, 0, 0 });

    const d3d = Basis.default;
    try expectNear(d3d.right, .{ 1, 0, 0 });
    p.pitch = 0.3;
    try testing.expect(dot(p.forward(d3d), d3d.up) > 0);
}

test "a look-at camera goes in and back out unchanged" {
    const b: Basis = .init(.pos_y, .neg_z, false);
    const cam: Camera = .{ .position = .init(1, 2, 3), .aim = .target, .target = .init(4, 3, -1), .rotation = .identity, .roll = 0.2, .fov = 0.8 };
    const p: Pose = .fromCamera(b, cam);
    var out = cam;
    out.target = .zero;
    p.toCamera(b, &out);
    try expectNear(out.target.vec(), cam.target.vec());
    try testing.expectApproxEqAbs(cam.roll, out.roll, 1e-5);
}

test "a look-at camera's tipped up becomes roll, so it levels with the world" {
    const b: Basis = .init(.pos_y, .neg_z, false);
    // Looking down -z, with up tipped 0.3 towards +x, which is right
    const cam: Camera = .{ .position = .zero, .aim = .target, .target = .init(0, 0, -5), .up = .init(@sin(@as(f32, 0.3)), @cos(@as(f32, 0.3)), 0), .rotation = .identity, .roll = 0.1, .fov = 1 };
    var p: Pose = .fromCamera(b, cam);
    try testing.expectApproxEqAbs(0.1 - 0.3, p.roll, 1e-4);
    var out = cam;
    p.toCamera(b, &out);
    try expectNear(out.up.vec(), b.up);
    try testing.expectApproxEqAbs(p.roll, out.roll, 1e-5);
    // Levelling
    p.roll = 0;
    p.yaw += 1;
    p.toCamera(b, &out);
    try expectNear(out.up.vec(), b.up);
    try testing.expectEqual(0, out.roll);
}

test "a rotation camera goes in and back out unchanged" {
    for ([_]Basis{ .default, .init(.pos_y, .neg_z, false), .init(.pos_z, .pos_x, true) }) |b| {
        const p: Pose = .{ .position = .{ 5, 6, 7 }, .yaw = 0.7, .pitch = -0.4, .roll = 0.3, .fov = 1, .reach = 1 };
        var cam: Camera = .{ .position = .zero, .aim = .rotation, .target = .zero, .rotation = .identity, .roll = 0, .fov = 1 };
        p.toCamera(b, &cam);
        try expectNear(rotate(cam.rotation, b.look), p.forward(b));
        const back: Pose = .fromCamera(b, cam);
        try testing.expectApproxEqAbs(p.yaw, back.yaw, 1e-4);
        try testing.expectApproxEqAbs(p.pitch, back.pitch, 1e-4);
        try testing.expectApproxEqAbs(p.roll, back.roll, 1e-4);
    }
}

test "orbiting keeps the pivot in front, the same distance away" {
    const b: Basis = .init(.pos_y, .neg_z, false);
    var p: Pose = .{ .position = .{ 1, 2, 3 }, .yaw = 0.4, .pitch = -0.3, .roll = 0, .fov = 1, .reach = 1 };
    const pivot = p.ahead(b, 3);
    try testing.expectApproxEqAbs(3, length(pivot - p.position), 1e-4);
    // Turning swings it round the pivot, still facing it
    p.yaw += 1.2;
    p.position = p.orbiting(b, pivot, 3);
    try testing.expectApproxEqAbs(3, length(pivot - p.position), 1e-4);
    try expectNear(p.ahead(b, 3), pivot);
}

test "easing doesn't depend on the frame rate" {
    var fast: f32 = 0;
    for (0..10) |_| fast = ease(fast, 1, 0.5, 0.01);
    const slow = ease(@as(f32, 0), 1, 0.5, 0.1);
    try testing.expectApproxEqAbs(fast, slow, 1e-4);
}
