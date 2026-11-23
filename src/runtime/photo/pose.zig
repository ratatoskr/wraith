//! Skeletons as the game last handed them over, and the player's edits, which go back on every frame.
//! Bones are matrices in one space, so an edit to a bone turns, moves or scales it in its own axes and
//! takes everything under it along.

const std = @import("std");
const math = @import("tuft_math");

const Vec3 = math.Vec3;
const Quat = math.Quat;
const Mat4 = math.Mat4;

pub const max_bones = 512;
pub const max_actors = 32;
pub const max_edits = 256;
/// Render frames an actor stays listed after the game last posed it.
pub const stale_frames = 120;

/// A short name, copied so it outlives the call it came in.
pub const Name = struct {
    buf: [47]u8 = undefined,
    len: u8 = 0,

    pub fn init(s: []const u8) Name {
        var n: Name = .{};
        const len = @min(s.len, n.buf.len);
        @memcpy(n.buf[0..len], s[0..len]);
        n.len = @intCast(len);
        return n;
    }

    pub fn get(n: *const Name) []const u8 {
        return n.buf[0..n.len];
    }

    pub fn eql(n: *const Name, s: []const u8) bool {
        return std.mem.eql(u8, n.get(), s[0..@min(s.len, n.buf.len)]);
    }
};

/// One bone's change, in its own axes.
pub const Edit = struct {
    actor: u64,
    bone: Name,
    /// Degrees around x, then y, then z
    rotation: Vec3 = .zero,
    position: Vec3 = .zero,
    scale: Vec3 = .one,

    pub fn matrix(e: *const Edit) Mat4 {
        return .transform(e.position, euler(e.rotation), e.scale);
    }

    /// Takes on `m`'s position, turn and scale, which has to be scaled, then turned, then moved.
    pub fn setMatrix(e: *Edit, m: Mat4) void {
        var rows: [3]Vec3 = undefined;
        for (&rows, 0..) |*r, i| r.* = m.row(i).xyz();
        e.scale = .init(rows[0].length(), rows[1].length(), rows[2].length());
        for (&rows, [3]f32{ e.scale.x, e.scale.y, e.scale.z }) |*r, len| {
            if (len > math.epsilon) r.* = r.scale(1 / len);
        }
        e.rotation = eulerOf(rows);
        e.position = m.getTranslation();
    }

    pub fn isNothing(e: *const Edit) bool {
        return std.meta.eql(e.rotation, Vec3.zero) and std.meta.eql(e.position, Vec3.zero) and std.meta.eql(e.scale, Vec3.one);
    }
};

pub fn euler(degrees: Vec3) Quat {
    const x = Quat.fromAxisAngle(Vec3.unit_x, math.degToRad(degrees.x));
    const y = Quat.fromAxisAngle(Vec3.unit_y, math.degToRad(degrees.y));
    const z = Quat.fromAxisAngle(Vec3.unit_z, math.degToRad(degrees.z));
    return x.mul(y).mul(z);
}

/// The degrees `euler` takes for a turn, given as where it takes x, y and z.
fn eulerOf(r: [3]Vec3) Vec3 {
    // euler turns round x, then y, then z, which as a matrix for column vectors is Rz Ry Rx. Its
    // element [i][j] is r[j]'s i-th part, as rows here are where the axes go
    const sy = std.math.clamp(-r[0].z, -1, 1);
    const y = std.math.asin(sy);
    if (@abs(sy) < 1 - 1e-6) {
        return .init(math.radToDeg(std.math.atan2(r[1].z, r[2].z)), math.radToDeg(y), math.radToDeg(std.math.atan2(r[0].y, r[0].x)));
    }
    // Straight up or down, so x and z turn round the same axis. Put it all in x
    return .init(math.radToDeg(std.math.atan2(-r[2].y, r[1].y)), math.radToDeg(y), 0);
}

/// A bone's edit, found in this frame's skeleton.
pub const Placed = struct {
    bone: u32,
    matrix: Mat4,

    fn lessThan(_: void, a: Placed, b: Placed) bool {
        return a.bone < b.bone;
    }
};

/// Puts each edit on its bone and everything under it, parents first so a child's edit goes on in
/// its already moved axes. `parents` must come before their children.
pub fn apply(parents: []const i32, world: []Mat4, edits: []Placed) void {
    std.mem.sort(Placed, edits, {}, Placed.lessThan);
    var inside: [max_bones]bool = undefined;
    const n = @min(parents.len, world.len, max_bones);
    for (edits) |e| {
        const b = e.bone;
        if (b >= n) continue;
        const undo = world[b].inverse() orelse continue;
        // Into the bone's space, changed there, then back out
        const change = undo.mul(e.matrix).mul(world[b]);
        for (b..n) |j| {
            const p = parents[j];
            inside[j] = j == b or (p >= b and p < j and inside[@intCast(p)]);
            if (inside[j]) world[j] = world[j].mul(change);
        }
    }
}

pub const Actor = struct {
    used: bool = false,
    id: u64 = 0,
    name: Name = .{},
    /// `Store.frame` when the game last posed it
    seen: u64 = 0,
    count: u32 = 0,
    names: [max_bones]Name = undefined,
    parents: [max_bones]i32 = undefined,
    /// As posed, in the bones' space
    world: [max_bones]Mat4 = undefined,
    to_world: Mat4 = .identity,
    frozen: bool = false,
    /// What it's held at while frozen, from before the edits. 0 means take the next frame's
    base_count: u32 = 0,
    base: [max_bones]Mat4 = undefined,

    /// Where a bone is in the world.
    pub fn position(a: *const Actor, bone: usize) Vec3 {
        return a.world[bone].mul(a.to_world).getTranslation();
    }

    pub fn find(a: *const Actor, name: []const u8) ?u32 {
        for (a.names[0..a.count], 0..) |*n, i| if (n.eql(name)) return @intCast(i);
        return null;
    }
};

/// Everything shared between the game's threads, which pose, and the render thread, which edits.
/// Callers hold the lock.
pub const Store = struct {
    actors: []Actor,
    edits: [max_edits]Edit = undefined,
    edit_count: usize = 0,
    /// Counts render frames
    frame: u64 = 0,
    view: Mat4 = .identity,
    projection: Mat4 = .identity,
    view_proj: ?Mat4 = null,

    pub fn setCamera(s: *Store, view: Mat4, projection: Mat4) void {
        s.view = view;
        s.projection = projection;
        s.view_proj = view.mul(projection);
    }

    pub fn init(gpa: std.mem.Allocator) !Store {
        const actors = try gpa.alloc(Actor, max_actors);
        for (actors) |*a| a.* = .{};
        return .{ .actors = actors };
    }

    pub fn deinit(s: *Store, gpa: std.mem.Allocator) void {
        gpa.free(s.actors);
    }

    /// `bones` are anything with a `name` and a `parent`, and `matrices` one for each.
    pub fn pose(s: *Store, id: u64, name: []const u8, bones: anytype, matrices: []Mat4, to_world: Mat4) void {
        const count: u32 = @intCast(@min(bones.len, matrices.len, max_bones));
        const world = matrices[0..count];
        const slot = s.slotFor(id);
        if (slot) |a| {
            if (!a.used or a.id != id) a.* = .{ .used = true, .id = id };
            a.name = .init(name);
            a.seen = s.frame;
            a.to_world = to_world;
            if (a.count != count) a.base_count = 0;
            a.count = count;
            for (bones[0..count], 0..) |b, i| {
                a.names[i] = .init(textOf(b.name));
                a.parents[i] = b.parent;
            }
            if (a.frozen) {
                if (a.base_count == count) @memcpy(world, a.base[0..count]) else {
                    @memcpy(a.base[0..count], world);
                    a.base_count = count;
                }
            }
        }

        var placed: [max_edits]Placed = undefined;
        var n: usize = 0;
        for (s.edits[0..s.edit_count]) |*e| {
            if (e.actor != id) continue;
            const bone = for (bones[0..count], 0..) |b, i| {
                if (e.bone.eql(textOf(b.name))) break i;
            } else continue;
            placed[n] = .{ .bone = @intCast(bone), .matrix = e.matrix() };
            n += 1;
        }
        if (n > 0) {
            var parents: [max_bones]i32 = undefined;
            for (bones[0..count], parents[0..count]) |b, *p| p.* = b.parent;
            apply(parents[0..count], world, placed[0..n]);
        }
        if (slot) |a| @memcpy(a.world[0..count], world);
    }

    /// Its own slot, a free one, or the longest gone that has nothing to lose. Null when they're all in use.
    fn slotFor(s: *Store, id: u64) ?*Actor {
        for (s.actors) |*a| if (a.used and a.id == id) return a;
        for (s.actors) |*a| if (!a.used) return a;
        var oldest: ?*Actor = null;
        for (s.actors) |*a| {
            if (a.frozen or s.hasEdits(a.id) or s.isLive(a)) continue;
            if (oldest == null or a.seen < oldest.?.seen) oldest = a;
        }
        return oldest;
    }

    pub fn isLive(s: *const Store, a: *const Actor) bool {
        return a.used and s.frame -% a.seen < stale_frames;
    }

    pub fn byId(s: *Store, id: u64) ?*Actor {
        for (s.actors) |*a| if (a.used and a.id == id) return a;
        return null;
    }

    pub fn findEdit(s: *Store, actor: u64, bone: []const u8) ?*Edit {
        for (s.edits[0..s.edit_count]) |*e| if (e.actor == actor and e.bone.eql(bone)) return e;
        return null;
    }

    /// The bone's edit, made if it hasn't one. Null when there are too many.
    pub fn edit(s: *Store, actor: u64, bone: []const u8) ?*Edit {
        if (s.findEdit(actor, bone)) |e| return e;
        if (s.edit_count == max_edits) return null;
        const e = &s.edits[s.edit_count];
        e.* = .{ .actor = actor, .bone = .init(bone) };
        s.edit_count += 1;
        return e;
    }

    pub fn resetBone(s: *Store, actor: u64, bone: []const u8) void {
        const e = s.findEdit(actor, bone) orelse return;
        s.edit_count -= 1;
        e.* = s.edits[s.edit_count];
    }

    pub fn resetActor(s: *Store, actor: u64) void {
        var i: usize = 0;
        while (i < s.edit_count) {
            if (s.edits[i].actor == actor) {
                s.edit_count -= 1;
                s.edits[i] = s.edits[s.edit_count];
            } else i += 1;
        }
    }

    pub fn hasEdits(s: *const Store, actor: u64) bool {
        for (s.edits[0..s.edit_count]) |e| if (e.actor == actor) return true;
        return false;
    }

    pub fn anyFrozen(s: *const Store) bool {
        for (s.actors) |*a| if (a.used and a.frozen) return true;
        return false;
    }
};

/// A plain slice, or a salamander `String` from an async call.
fn textOf(name: anytype) []const u8 {
    return if (@TypeOf(name) == []const u8) name else name.get();
}

const testing = std.testing;

const TestBone = struct { name: []const u8, parent: i32 };

fn at(x: f32, y: f32, z: f32) Mat4 {
    return .translation(.init(x, y, z));
}

test "turning a bone swings its children round it" {
    // An arm along x: shoulder at 0, elbow at 1, hand at 2
    const parents = [_]i32{ -1, 0, 1 };
    var world = [_]Mat4{ at(0, 0, 0), at(1, 0, 0), at(2, 0, 0) };
    var edits = [_]Placed{.{ .bone = 1, .matrix = .transform(.zero, euler(.init(0, 0, 90)), .one) }};
    apply(&parents, &world, &edits);
    try testing.expect(world[0].getTranslation().approxEql(.init(0, 0, 0), 1e-5));
    try testing.expect(world[1].getTranslation().approxEql(.init(1, 0, 0), 1e-5));
    // 90 degrees round z takes x onto y
    try testing.expect(world[2].getTranslation().approxEql(.init(1, 1, 0), 1e-5));
}

test "a parent's edit goes on before its child's" {
    const parents = [_]i32{ -1, 0, 1, 0 };
    var world = [_]Mat4{ at(0, 0, 0), at(1, 0, 0), at(2, 0, 0), at(0, 5, 0) };
    // Given child first, it still turns the shoulder first, then bends the elbow in its turned axes
    var edits = [_]Placed{
        .{ .bone = 1, .matrix = .transform(.zero, euler(.init(0, 0, 90)), .one) },
        .{ .bone = 0, .matrix = .transform(.zero, euler(.init(0, 0, 90)), .one) },
    };
    apply(&parents, &world, &edits);
    try testing.expect(world[1].getTranslation().approxEql(.init(0, 1, 0), 1e-5));
    try testing.expect(world[2].getTranslation().approxEql(.init(-1, 1, 0), 1e-5));
    // Not under the elbow, so only the shoulder's turn moves it
    try testing.expect(world[3].getTranslation().approxEql(.init(-5, 0, 0), 1e-5));
}

test "an edit's matrix comes back as the same edit" {
    const cases = [_][3]Vec3{
        .{ .init(30, -20, 75), .init(0.1, 0.2, -0.3), .init(1, 1, 1) },
        .{ .init(-120, 45, 10), .zero, .init(2, 0.5, 1.5) },
        .{ .zero, .init(5, 0, 0), .init(1, 1, 1) },
    };
    for (cases) |c| {
        const e: Edit = .{ .actor = 1, .bone = .init("b"), .rotation = c[0], .position = c[1], .scale = c[2] };
        var back: Edit = .{ .actor = 1, .bone = .init("b") };
        back.setMatrix(e.matrix());
        try testing.expect(back.rotation.approxEql(e.rotation, 1e-3));
        try testing.expect(back.position.approxEql(e.position, 1e-4));
        try testing.expect(back.scale.approxEql(e.scale, 1e-4));
    }
    // Straight up still gives the same turn, if not the same numbers
    const up: Edit = .{ .actor = 1, .bone = .init("b"), .rotation = .init(20, 90, 30) };
    var back: Edit = .{ .actor = 1, .bone = .init("b") };
    back.setMatrix(up.matrix());
    try testing.expect(back.matrix().approxEql(up.matrix(), 1e-4));
}

test "edits stick by name every frame, and freezing holds the pose from before them" {
    var store: Store = try .init(testing.allocator);
    defer store.deinit(testing.allocator);
    const bones = [_]TestBone{ .{ .name = "root", .parent = -1 }, .{ .name = "head", .parent = 0 } };

    store.edit(7, "head").?.position = .init(0, 2, 0);
    var frame = [_]Mat4{ at(0, 0, 0), at(0, 1, 0) };
    store.pose(7, "Rean", &bones, &frame, .identity);
    try testing.expect(frame[1].getTranslation().approxEql(.init(0, 3, 0), 1e-5));
    // Another actor isn't touched
    var other = [_]Mat4{ at(0, 0, 0), at(0, 1, 0) };
    store.pose(8, "Agnes", &bones, &other, .identity);
    try testing.expect(other[1].getTranslation().approxEql(.init(0, 1, 0), 1e-5));

    store.byId(7).?.frozen = true;
    frame = .{ at(0, 0, 0), at(0, 1, 0) };
    store.pose(7, "Rean", &bones, &frame, .identity);
    // The game animates it on, but it's held where it was, edit and all
    frame = .{ at(4, 0, 0), at(4, 1, 0) };
    store.pose(7, "Rean", &bones, &frame, .identity);
    try testing.expect(frame[1].getTranslation().approxEql(.init(0, 3, 0), 1e-5));

    store.resetActor(7);
    frame = .{ at(4, 0, 0), at(4, 1, 0) };
    store.pose(7, "Rean", &bones, &frame, .identity);
    try testing.expect(frame[1].getTranslation().approxEql(.init(0, 1, 0), 1e-5));
}
