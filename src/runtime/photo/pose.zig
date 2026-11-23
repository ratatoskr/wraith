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
pub const max_shapes = 512;
pub const max_shape_edits = 256;
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

/// One blend shape's weight, set outright. With no mesh it's every mesh's shape of that name.
pub const ShapeEdit = struct {
    actor: u64,
    /// Empty for every mesh
    mesh: Name = .{},
    /// The whole name for one mesh, or `shapeKey` of it for every mesh
    shape: Name,
    weight: f32 = 0,

    fn fits(e: *const ShapeEdit, mesh: []const u8, shape: []const u8) bool {
        if (e.mesh.len == 0) return e.shape.eql(shapeKey(shape));
        return e.mesh.eql(mesh) and e.shape.eql(shape);
    }
};

/// What a shape's called once what's before the last dot is gone, so `Face.blink` and `Lashes.blink`
/// count as the same, the way exporters often name them.
pub fn shapeKey(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return if (dot + 1 < name.len) name[dot + 1 ..] else name;
}

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
    /// Who hands it over, so it's forgotten with them. 0 for nobody in particular.
    owner: usize = 0,
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
    shape_count: u32 = 0,
    shape_names: [max_shapes]Name = undefined,
    shape_meshes: [max_shapes]Name = undefined,
    /// As posed
    weights: [max_shapes]f32 = undefined,
    /// Like `base`, for the weights
    shape_base_count: u32 = 0,
    shape_base: [max_shapes]f32 = undefined,

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
    shape_edits: [max_shape_edits]ShapeEdit = undefined,
    shape_edit_count: usize = 0,
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

    /// `shapes` are anything with a `name` and a `mesh`, and `weights` one for each. After `pose`
    /// for the same actor, which gives it its slot.
    pub fn shape(s: *Store, id: u64, shapes: anytype, weights: []f32) void {
        const count: u32 = @intCast(@min(shapes.len, weights.len, max_shapes));
        const w = weights[0..count];
        const slot = s.byId(id);
        if (slot) |a| {
            if (a.shape_count != count) a.shape_base_count = 0;
            a.shape_count = count;
            for (shapes[0..count], 0..) |sh, i| {
                a.shape_names[i] = .init(textOf(sh.name));
                a.shape_meshes[i] = .init(textOf(sh.mesh));
            }
            if (a.frozen) {
                if (a.shape_base_count == count) @memcpy(w, a.shape_base[0..count]) else {
                    @memcpy(a.shape_base[0..count], w);
                    a.shape_base_count = count;
                }
            }
        }
        if (s.hasShapeEdits(id)) for (shapes[0..count], w) |sh, *weight| {
            // Cut short like the names the window has, so long ones still match
            const mesh: Name = .init(textOf(sh.mesh));
            const name: Name = .init(textOf(sh.name));
            if (s.shapeEditFor(id, mesh.get(), name.get())) |e| weight.* = e.weight;
        };
        if (slot) |a| @memcpy(a.weights[0..count], w);
    }

    /// What goes on a shape: its mesh's own edit, else one for every mesh.
    pub fn shapeEditFor(s: *Store, actor: u64, mesh: []const u8, shape_name: []const u8) ?*ShapeEdit {
        var every: ?*ShapeEdit = null;
        for (s.shape_edits[0..s.shape_edit_count]) |*e| {
            if (e.actor != actor or !e.fits(mesh, shape_name)) continue;
            if (e.mesh.len > 0) return e;
            every = e;
        }
        return every;
    }

    /// Exactly this one, by mesh, empty for every mesh, and shape.
    pub fn findShapeEdit(s: *Store, actor: u64, mesh: []const u8, shape_name: []const u8) ?*ShapeEdit {
        for (s.shape_edits[0..s.shape_edit_count]) |*e| {
            if (e.actor == actor and e.mesh.eql(mesh) and e.shape.eql(shape_name)) return e;
        }
        return null;
    }

    /// Made if it isn't there. Null when there are too many.
    pub fn shapeEdit(s: *Store, actor: u64, mesh: []const u8, shape_name: []const u8) ?*ShapeEdit {
        if (s.findShapeEdit(actor, mesh, shape_name)) |e| return e;
        if (s.shape_edit_count == max_shape_edits) return null;
        const e = &s.shape_edits[s.shape_edit_count];
        e.* = .{ .actor = actor, .mesh = .init(mesh), .shape = .init(shape_name) };
        s.shape_edit_count += 1;
        return e;
    }

    pub fn resetShape(s: *Store, actor: u64, mesh: []const u8, shape_name: []const u8) void {
        const e = s.findShapeEdit(actor, mesh, shape_name) orelse return;
        s.shape_edit_count -= 1;
        e.* = s.shape_edits[s.shape_edit_count];
    }

    /// Every mesh's own edit of a shape by its key, so one for every mesh isn't hidden by them.
    pub fn resetShapeOnMeshes(s: *Store, actor: u64, key: []const u8) void {
        var i: usize = 0;
        while (i < s.shape_edit_count) {
            const e = &s.shape_edits[i];
            if (e.actor == actor and e.mesh.len > 0 and std.mem.eql(u8, shapeKey(e.shape.get()), key)) {
                s.shape_edit_count -= 1;
                e.* = s.shape_edits[s.shape_edit_count];
            } else i += 1;
        }
    }

    pub fn resetShapes(s: *Store, actor: u64) void {
        var i: usize = 0;
        while (i < s.shape_edit_count) {
            if (s.shape_edits[i].actor == actor) {
                s.shape_edit_count -= 1;
                s.shape_edits[i] = s.shape_edits[s.shape_edit_count];
            } else i += 1;
        }
    }

    pub fn hasShapeEdits(s: *const Store, actor: u64) bool {
        for (s.shape_edits[0..s.shape_edit_count]) |e| if (e.actor == actor) return true;
        return false;
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
        s.resetShapes(actor);
    }

    /// Bones or shapes.
    pub fn hasEdits(s: *const Store, actor: u64) bool {
        for (s.edits[0..s.edit_count]) |e| if (e.actor == actor) return true;
        return s.hasShapeEdits(actor);
    }

    pub fn anyEdits(s: *const Store) bool {
        return s.edit_count > 0 or s.shape_edit_count > 0;
    }

    pub fn anyFrozen(s: *const Store) bool {
        for (s.actors) |*a| if (a.used and a.frozen) return true;
        return false;
    }

    /// Everything `owner` handed over, edits and all, since the ids it gave mean nothing once it's gone.
    pub fn forgetOwner(s: *Store, owner: usize) void {
        for (s.actors) |*a| {
            if (!a.used or a.owner != owner) continue;
            s.resetActor(a.id);
            a.* = .{};
        }
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

test "an owner going takes its actors' edits with it, and no one else's" {
    var store: Store = try .init(testing.allocator);
    defer store.deinit(testing.allocator);
    const bones = [_]TestBone{ .{ .name = "root", .parent = -1 }, .{ .name = "head", .parent = 0 } };
    var frame = [_]Mat4{ at(0, 0, 0), at(0, 1, 0) };
    store.pose(7, "Rean", &bones, &frame, .identity);
    store.byId(7).?.owner = 1;
    store.pose(8, "Agnes", &bones, &frame, .identity);
    store.byId(8).?.owner = 2;
    store.edit(7, "head").?.position = .init(0, 2, 0);
    store.edit(8, "head").?.position = .init(0, 2, 0);

    store.forgetOwner(1);
    try testing.expectEqual(null, store.byId(7));
    try testing.expect(!store.hasEdits(7));
    try testing.expect(store.hasEdits(8));
    // A new plugin handing over the same id starts afresh
    frame = .{ at(0, 0, 0), at(0, 1, 0) };
    store.pose(7, "Rean", &bones, &frame, .identity);
    try testing.expect(frame[1].getTranslation().approxEql(.init(0, 1, 0), 1e-5));
}

const TestShape = struct { name: []const u8, mesh: []const u8 };

test "a shape edit for every mesh goes on each that has it, and a mesh's own wins" {
    var store: Store = try .init(testing.allocator);
    defer store.deinit(testing.allocator);
    const bones = [_]TestBone{.{ .name = "root", .parent = -1 }};
    var frame = [_]Mat4{at(0, 0, 0)};
    store.pose(7, "Rean", &bones, &frame, .identity);
    const shapes = [_]TestShape{
        .{ .name = "Face.blink", .mesh = "Face" },
        .{ .name = "Lashes.blink", .mesh = "Lashes" },
        .{ .name = "smile", .mesh = "Face" },
    };

    store.shapeEdit(7, "", "blink").?.weight = 1;
    var weights = [_]f32{ 0.2, 0.3, 0.4 };
    store.shape(7, &shapes, &weights);
    try testing.expectEqualSlices(f32, &.{ 1, 1, 0.4 }, &weights);
    try testing.expectEqualSlices(f32, &.{ 1, 1, 0.4 }, store.byId(7).?.weights[0..3]);

    store.shapeEdit(7, "Lashes", "Lashes.blink").?.weight = 0.5;
    weights = .{ 0.2, 0.3, 0.4 };
    store.shape(7, &shapes, &weights);
    try testing.expectEqualSlices(f32, &.{ 1, 0.5, 0.4 }, &weights);

    // Another actor's the same names aren't touched
    store.pose(8, "Agnes", &bones, &frame, .identity);
    var other = [_]f32{ 0.2, 0.3, 0.4 };
    store.shape(8, &shapes, &other);
    try testing.expectEqualSlices(f32, &.{ 0.2, 0.3, 0.4 }, &other);

    store.resetShapeOnMeshes(7, "blink");
    weights = .{ 0.2, 0.3, 0.4 };
    store.shape(7, &shapes, &weights);
    try testing.expectEqualSlices(f32, &.{ 1, 1, 0.4 }, &weights);

    store.resetActor(7);
    weights = .{ 0.2, 0.3, 0.4 };
    store.shape(7, &shapes, &weights);
    try testing.expectEqualSlices(f32, &.{ 0.2, 0.3, 0.4 }, &weights);
}

test "freezing holds the weights from before the edits" {
    var store: Store = try .init(testing.allocator);
    defer store.deinit(testing.allocator);
    const bones = [_]TestBone{.{ .name = "root", .parent = -1 }};
    var frame = [_]Mat4{at(0, 0, 0)};
    const shapes = [_]TestShape{ .{ .name = "blink", .mesh = "Face" }, .{ .name = "smile", .mesh = "Face" } };
    store.pose(7, "Rean", &bones, &frame, .identity);
    store.byId(7).?.frozen = true;
    store.shapeEdit(7, "Face", "smile").?.weight = 0.9;

    var weights = [_]f32{ 0.1, 0.1 };
    store.shape(7, &shapes, &weights);
    // The game blinks on, but it's held, edit and all
    weights = .{ 1, 0 };
    store.shape(7, &shapes, &weights);
    try testing.expectEqualSlices(f32, &.{ 0.1, 0.9 }, &weights);
}

test "a shape's key is what's after its last dot" {
    try testing.expectEqualStrings("blink", shapeKey("Face_BS.blink"));
    try testing.expectEqualStrings("blink", shapeKey("blink"));
    try testing.expectEqualStrings("odd.", shapeKey("odd."));
}
