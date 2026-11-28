//! Turn, position and scale, as the scene's Transform boxes show them, and degrees for turns.

const std = @import("std");
const math = @import("tuft_math");

const Vec3 = math.Vec3;
const Quat = math.Quat;
const Mat4 = math.Mat4;

/// Scaled, then turned, then moved, like a world transform or a bone's change from its animation.
pub const Local = struct {
    rotation: Quat = .identity,
    position: Vec3 = .zero,
    scale: Vec3 = .one,

    pub fn matrix(l: *const Local) Mat4 {
        return .transform(l.position, l.rotation, l.scale);
    }

    /// `m`'s, which has to be scaled, then turned, then moved.
    pub fn of(m: Mat4) Local {
        return .{
            .scale = .init(m.row(0).xyz().length(), m.row(1).xyz().length(), m.row(2).xyz().length()),
            .rotation = m.rotation(),
            .position = m.getTranslation(),
        };
    }
};

/// How one changed, put on another as it is: the same turn in its own axes, the same move, and the
/// same scale, as a ratio.
pub const Change = struct {
    turn: Quat = .identity,
    /// Untouched turns stay exact, since putting even no turn on loses a little
    turned: bool = false,
    move: Vec3 = .zero,
    scale_from: Vec3 = .one,
    scale_to: Vec3 = .one,

    pub fn between(before: Local, after: Local) Change {
        return .{
            .turn = after.rotation.mul(before.rotation.inverse()),
            .turned = !std.meta.eql(before.rotation, after.rotation),
            .move = after.position.sub(before.position),
            .scale_from = before.scale,
            .scale_to = after.scale,
        };
    }

    /// One `carried` by another that changed with it doesn't move itself, or it'd move twice.
    pub fn apply(c: *const Change, l: *Local, carried: bool) void {
        // The turn first, in its own axes, then what it had
        if (c.turned) l.rotation = c.turn.mul(l.rotation).normalize();
        if (!carried) l.position = l.position.add(c.move);
        l.scale = .init(grown(l.scale.x, c.scale_from.x, c.scale_to.x), grown(l.scale.y, c.scale_from.y, c.scale_to.y), grown(l.scale.z, c.scale_from.z, c.scale_to.z));
    }
};

/// By the same ratio, or the same amount from nothing.
fn grown(now: f32, from: f32, to: f32) f32 {
    if (from == to) return now;
    if (from == 0) return now + to;
    return now * (to / from);
}

/// Degrees round x, then y, then z.
pub fn euler(degrees: Vec3) Quat {
    const x = Quat.fromAxisAngle(Vec3.unit_x, math.degToRad(degrees.x));
    const y = Quat.fromAxisAngle(Vec3.unit_y, math.degToRad(degrees.y));
    const z = Quat.fromAxisAngle(Vec3.unit_z, math.degToRad(degrees.z));
    return x.mul(y).mul(z);
}

/// Degrees `euler` gives `q` from. Only for showing: one turn has many.
pub fn eulerOf(q: Quat) Vec3 {
    // Euler x then y then z is Rz Ry Rx for column vectors; rows here are where the axes go
    const r = [3]Vec3{ q.rotate(Vec3.unit_x), q.rotate(Vec3.unit_y), q.rotate(Vec3.unit_z) };
    const sy = std.math.clamp(-r[0].z, -1, 1);
    const y = std.math.asin(sy);
    if (@abs(sy) < 1 - 1e-6) {
        return .init(math.radToDeg(std.math.atan2(r[1].z, r[2].z)), math.radToDeg(y), math.radToDeg(std.math.atan2(r[0].y, r[0].x)));
    }
    // Straight up or down, so x and z turn round the same axis. Put it all in x
    return .init(math.radToDeg(std.math.atan2(-r[2].y, r[1].y)), math.radToDeg(y), 0);
}

/// q and -q are the same turn.
pub fn sameTurn(a: Quat, b: Quat) bool {
    return @abs(a.dot(b)) > 1 - 1e-5;
}

const testing = std.testing;

test "a transform's matrix comes back as the same transform, straight up too" {
    const cases = [_][3]Vec3{
        .{ .init(30, -20, 75), .init(0.1, 0.2, -0.3), .init(1, 1, 1) },
        .{ .init(-120, 45, 10), .zero, .init(2, 0.5, 1.5) },
        .{ .init(20, 90, 30), .init(5, 0, 0), .init(1, 1, 1) },
    };
    for (cases) |c| {
        const l: Local = .{ .rotation = euler(c[0]), .position = c[1], .scale = c[2] };
        const back: Local = .of(l.matrix());
        try testing.expect(sameTurn(back.rotation, l.rotation));
        try testing.expect(back.position.approxEql(l.position, 1e-4));
        try testing.expect(back.scale.approxEql(l.scale, 1e-4));
    }
}

test "degrees shown for a turn give that turn back" {
    for ([_]Vec3{ .init(30, -20, 75), .init(-120, 45, 10), .init(20, 90, 30), .init(0, -90, 45), .zero }) |d| {
        const q = euler(d);
        try testing.expect(sameTurn(euler(eulerOf(q)), q));
    }
}

test "a change puts the same move, scale and turn on another, and its turn's left alone if it didn't turn" {
    const turned = euler(.init(10, 20, 30));
    var l: Local = .{ .rotation = turned, .position = .init(1, 0, 0), .scale = .init(2, 2, 2) };
    const moved: Change = .between(.{ .scale = .init(1, 1, 1) }, .{ .position = .init(0, 1, 0), .scale = .init(1.5, 1, 1) });
    moved.apply(&l, false);
    try testing.expect(std.meta.eql(l.rotation, turned));
    try testing.expect(l.position.approxEql(.init(1, 1, 0), 1e-6));
    try testing.expect(l.scale.approxEql(.init(3, 2, 2), 1e-6));

    // What changed gets to where it went
    const before: Local = .{ .rotation = euler(.init(0, 0, 40)), .position = .init(1, 2, 3) };
    const after: Local = .{ .rotation = euler(.init(0, 0, 55)), .position = .init(1, 2, 4) };
    var same = before;
    Change.between(before, after).apply(&same, false);
    try testing.expect(sameTurn(same.rotation, after.rotation));
    try testing.expect(same.position.approxEql(after.position, 1e-6));

    // One that's carried turns, but doesn't move
    var child: Local = .{ .position = .init(0, 5, 0) };
    Change.between(before, after).apply(&child, true);
    try testing.expect(sameTurn(child.rotation, euler(.init(0, 0, 15))));
    try testing.expect(child.position.approxEql(.init(0, 5, 0), 1e-6));
}
