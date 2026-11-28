//! Skeletons as last handed over, and the player's edits, reapplied every frame.

const std = @import("std");
const math = @import("tuft_math");
const transform = @import("transform.zig");

const Vec3 = math.Vec3;
const Quat = math.Quat;
const Mat4 = math.Mat4;

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
    rotation: Quat = .identity,
    position: Vec3 = .zero,
    scale: Vec3 = .one,

    pub fn local(e: *const Edit) transform.Local {
        return .{ .rotation = e.rotation, .position = e.position, .scale = e.scale };
    }

    pub fn setLocal(e: *Edit, l: transform.Local) void {
        e.rotation = l.rotation;
        e.position = l.position;
        e.scale = l.scale;
    }

    pub fn matrix(e: *const Edit) Mat4 {
        return e.local().matrix();
    }

    /// Takes on `m`'s position, turn and scale, which has to be scaled, then turned, then moved.
    pub fn setMatrix(e: *Edit, m: Mat4) void {
        e.setLocal(.of(m));
    }

    pub fn isNothing(e: *const Edit) bool {
        const r = e.rotation;
        return r.x == 0 and r.y == 0 and r.z == 0 and std.meta.eql(e.position, Vec3.zero) and std.meta.eql(e.scale, Vec3.one);
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

/// A shape's name after the last dot, so `Face.blink` and `Lashes.blink` match.
pub fn shapeKey(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return if (dot + 1 < name.len) name[dot + 1 ..] else name;
}

pub const euler = transform.euler;
pub const eulerOf = transform.eulerOf;

/// A bone's edit, found in this frame's skeleton.
pub const Placed = struct {
    bone: u32,
    matrix: Mat4,

    fn lessThan(_: void, a: Placed, b: Placed) bool {
        return a.bone < b.bone;
    }
};

/// Puts each edit on its bone and everything under it. `parents` must come before their children.
/// `inside` is room for a flag a bone.
pub fn apply(parents: []const i32, world: []Mat4, edits: []Placed, inside: []bool) void {
    std.mem.sort(Placed, edits, {}, Placed.lessThan);
    const n = @min(parents.len, world.len, inside.len);
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
    /// Each as long as the most bones it's had, so posing doesn't allocate every frame
    names: []Name = &.{},
    parents: []i32 = &.{},
    /// As posed, in the bones' space
    world: []Mat4 = &.{},
    to_world: Mat4 = .identity,
    frozen: bool = false,
    /// What it's held at while frozen, from before the edits. 0 means take the next frame's
    base_count: u32 = 0,
    base: []Mat4 = &.{},
    shape_count: u32 = 0,
    /// Each as long as the most shapes it's had, likewise
    shape_names: []Name = &.{},
    shape_meshes: []Name = &.{},
    /// Only ever on or off, so a checkbox, and 0 or 1
    shape_toggles: []bool = &.{},
    /// As posed
    weights: []f32 = &.{},
    /// Like `base`, for the weights
    shape_base_count: u32 = 0,
    shape_base: []f32 = &.{},

    /// Room for `n` bones, or what it had when out of memory. How many it has room for.
    fn bones(a: *Actor, gpa: std.mem.Allocator, n: usize) usize {
        if (n <= a.names.len) return n;
        const names = gpa.alloc(Name, n) catch return a.names.len;
        const parents = gpa.alloc(i32, n) catch {
            gpa.free(names);
            return a.names.len;
        };
        const world = gpa.alloc(Mat4, n) catch {
            gpa.free(names);
            gpa.free(parents);
            return a.names.len;
        };
        const base = gpa.alloc(Mat4, n) catch {
            gpa.free(names);
            gpa.free(parents);
            gpa.free(world);
            return a.names.len;
        };
        // A frozen pose of the old size is taken again next frame anyway
        a.freeBones(gpa);
        a.names = names;
        a.parents = parents;
        a.world = world;
        a.base = base;
        a.base_count = 0;
        return n;
    }

    /// Room for `n` shapes, likewise.
    fn shapes(a: *Actor, gpa: std.mem.Allocator, n: usize) usize {
        if (n <= a.shape_names.len) return n;
        const names = gpa.alloc(Name, n) catch return a.shape_names.len;
        const meshes = gpa.alloc(Name, n) catch {
            gpa.free(names);
            return a.shape_names.len;
        };
        const toggles = gpa.alloc(bool, n) catch {
            gpa.free(names);
            gpa.free(meshes);
            return a.shape_names.len;
        };
        const weights = gpa.alloc(f32, n) catch {
            gpa.free(names);
            gpa.free(meshes);
            gpa.free(toggles);
            return a.shape_names.len;
        };
        const base = gpa.alloc(f32, n) catch {
            gpa.free(names);
            gpa.free(meshes);
            gpa.free(toggles);
            gpa.free(weights);
            return a.shape_names.len;
        };
        a.freeShapes(gpa);
        a.shape_names = names;
        a.shape_meshes = meshes;
        a.shape_toggles = toggles;
        a.weights = weights;
        a.shape_base = base;
        a.shape_base_count = 0;
        return n;
    }

    fn freeBones(a: *Actor, gpa: std.mem.Allocator) void {
        gpa.free(a.names);
        gpa.free(a.parents);
        gpa.free(a.world);
        gpa.free(a.base);
    }

    fn freeShapes(a: *Actor, gpa: std.mem.Allocator) void {
        gpa.free(a.shape_names);
        gpa.free(a.shape_meshes);
        gpa.free(a.shape_toggles);
        gpa.free(a.weights);
        gpa.free(a.shape_base);
    }

    /// Unused again, keeping its room for whoever's next.
    fn clear(a: *Actor) void {
        a.* = .{
            .names = a.names,
            .parents = a.parents,
            .world = a.world,
            .base = a.base,
            .shape_names = a.shape_names,
            .shape_meshes = a.shape_meshes,
            .shape_toggles = a.shape_toggles,
            .weights = a.weights,
            .shape_base = a.shape_base,
        };
    }

    /// Where a bone is in the world.
    pub fn position(a: *const Actor, bone: usize) Vec3 {
        return a.to_world.transformPoint(a.world[bone].getTranslation());
    }

    pub fn find(a: *const Actor, name: []const u8) ?u32 {
        for (a.names[0..a.count], 0..) |*n, i| if (n.eql(name)) return @intCast(i);
        return null;
    }
};

/// Shared between the game's threads, which pose, and the render thread, which edits. Callers hold the lock.
pub const Store = struct {
    gpa: std.mem.Allocator,
    /// Each stays where it is, since the window holds them while it draws. Unused ones are reused
    actors: std.ArrayList(*Actor) = .empty,
    edits: std.ArrayList(Edit) = .empty,
    shape_edits: std.ArrayList(ShapeEdit) = .empty,
    /// `pose`'s, kept so it doesn't allocate every frame
    placed: std.ArrayList(Placed) = .empty,
    inside: std.ArrayList(bool) = .empty,
    scratch_parents: std.ArrayList(i32) = .empty,
    /// Counts render frames
    frame: u64 = 0,
    /// Bumped whenever the edits change, for undo
    changes: u64 = 0,
    view: Mat4 = .identity,
    projection: Mat4 = .identity,
    view_proj: ?Mat4 = null,

    pub fn setCamera(s: *Store, view: Mat4, projection: Mat4) void {
        s.view = view;
        s.projection = projection;
        s.view_proj = view.mul(projection);
    }

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *Store) void {
        for (s.actors.items) |a| {
            a.freeBones(s.gpa);
            a.freeShapes(s.gpa);
            s.gpa.destroy(a);
        }
        s.actors.deinit(s.gpa);
        s.edits.deinit(s.gpa);
        s.shape_edits.deinit(s.gpa);
        s.placed.deinit(s.gpa);
        s.inside.deinit(s.gpa);
        s.scratch_parents.deinit(s.gpa);
    }

    /// `bones` are anything with a `name` and a `parent`, and `matrices` one for each.
    pub fn pose(s: *Store, id: u64, name: []const u8, bones: anytype, matrices: []Mat4, to_world: Mat4) void {
        const given: usize = @min(bones.len, matrices.len);
        const slot = s.slotFor(id);
        // All of them, unless memory's run out
        const count: u32 = @intCast(if (slot) |a| a.bones(s.gpa, given) else given);
        const world = matrices[0..count];
        if (slot) |a| {
            if (!a.used or a.id != id) {
                a.clear();
                a.used = true;
                a.id = id;
            }
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

        s.placed.clearRetainingCapacity();
        for (s.edits.items) |*e| {
            if (e.actor != id) continue;
            const bone = for (bones[0..count], 0..) |b, i| {
                if (e.bone.eql(textOf(b.name))) break i;
            } else continue;
            s.placed.append(s.gpa, .{ .bone = @intCast(bone), .matrix = e.matrix() }) catch break;
        }
        if (s.placed.items.len > 0) placed: {
            const parents = if (slot) |a| a.parents[0..count] else blk: {
                s.scratch_parents.resize(s.gpa, count) catch break :placed;
                for (bones[0..count], s.scratch_parents.items) |b, *p| p.* = b.parent;
                break :blk s.scratch_parents.items;
            };
            s.inside.resize(s.gpa, count) catch break :placed;
            apply(parents, world, s.placed.items, s.inside.items);
        }
        if (slot) |a| @memcpy(a.world[0..count], world);
    }

    /// `shapes` have a `name` and `mesh`, one weight each. Call after `pose` for the same actor.
    pub fn shape(s: *Store, id: u64, shapes: anytype, weights: []f32) void {
        const given: usize = @min(shapes.len, weights.len);
        const slot = s.byId(id);
        const count: u32 = @intCast(if (slot) |a| a.shapes(s.gpa, given) else given);
        const w = weights[0..count];
        if (slot) |a| {
            if (a.shape_count != count) a.shape_base_count = 0;
            a.shape_count = count;
            for (shapes[0..count], 0..) |sh, i| {
                a.shape_names[i] = .init(textOf(sh.name));
                a.shape_meshes[i] = .init(textOf(sh.mesh));
                a.shape_toggles[i] = toggleOf(sh);
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
            if (s.shapeEditFor(id, mesh.get(), name.get())) |e| {
                // An on or off one is either, whatever was asked
                weight.* = if (toggleOf(sh)) (if (e.weight >= 0.5) 1 else 0) else e.weight;
            }
        };
        if (slot) |a| @memcpy(a.weights[0..count], w);
    }

    fn toggleOf(sh: anytype) bool {
        return if (@hasField(@TypeOf(sh), "toggle")) sh.toggle else false;
    }

    /// What goes on a shape: its mesh's own edit, else one for every mesh.
    pub fn shapeEditFor(s: *Store, actor: u64, mesh: []const u8, shape_name: []const u8) ?*ShapeEdit {
        var every: ?*ShapeEdit = null;
        for (s.shape_edits.items) |*e| {
            if (e.actor != actor or !e.fits(mesh, shape_name)) continue;
            if (e.mesh.len > 0) return e;
            every = e;
        }
        return every;
    }

    /// Exactly this one, by mesh, empty for every mesh, and shape.
    pub fn findShapeEdit(s: *Store, actor: u64, mesh: []const u8, shape_name: []const u8) ?*ShapeEdit {
        for (s.shape_edits.items) |*e| {
            if (e.actor == actor and e.mesh.eql(mesh) and e.shape.eql(shape_name)) return e;
        }
        return null;
    }

    /// Made if it isn't there. Null when out of memory. Good till the next one's made.
    pub fn shapeEdit(s: *Store, actor: u64, mesh: []const u8, shape_name: []const u8) ?*ShapeEdit {
        // Asked for to be changed
        s.changes +%= 1;
        if (s.findShapeEdit(actor, mesh, shape_name)) |e| return e;
        const e = s.shape_edits.addOne(s.gpa) catch return null;
        e.* = .{ .actor = actor, .mesh = .init(mesh), .shape = .init(shape_name) };
        return e;
    }

    pub fn resetShape(s: *Store, actor: u64, mesh: []const u8, shape_name: []const u8) void {
        const e = s.findShapeEdit(actor, mesh, shape_name) orelse return;
        _ = s.shape_edits.swapRemove(e - s.shape_edits.items.ptr);
        s.changes +%= 1;
    }

    /// Every mesh's own edit of a shape by its key, so one for every mesh isn't hidden by them.
    pub fn resetShapeOnMeshes(s: *Store, actor: u64, key: []const u8) void {
        s.changes +%= 1;
        var i: usize = 0;
        while (i < s.shape_edits.items.len) {
            const e = &s.shape_edits.items[i];
            if (e.actor == actor and e.mesh.len > 0 and std.mem.eql(u8, shapeKey(e.shape.get()), key)) {
                _ = s.shape_edits.swapRemove(i);
            } else i += 1;
        }
    }

    pub fn resetShapes(s: *Store, actor: u64) void {
        s.changes +%= 1;
        var i: usize = 0;
        while (i < s.shape_edits.items.len) {
            if (s.shape_edits.items[i].actor == actor) _ = s.shape_edits.swapRemove(i) else i += 1;
        }
    }

    pub fn hasShapeEdits(s: *const Store, actor: u64) bool {
        for (s.shape_edits.items) |e| if (e.actor == actor) return true;
        return false;
    }

    /// Its own slot, a free one, the longest gone that has nothing to lose, or a new one. Null when
    /// out of memory.
    fn slotFor(s: *Store, id: u64) ?*Actor {
        for (s.actors.items) |a| if (a.used and a.id == id) return a;
        for (s.actors.items) |a| if (!a.used) return a;
        var oldest: ?*Actor = null;
        for (s.actors.items) |a| {
            if (a.frozen or s.hasEdits(a.id) or s.isLive(a)) continue;
            if (oldest == null or a.seen < oldest.?.seen) oldest = a;
        }
        if (oldest) |a| return a;
        s.actors.ensureUnusedCapacity(s.gpa, 1) catch return null;
        const a = s.gpa.create(Actor) catch return null;
        a.* = .{};
        s.actors.appendAssumeCapacity(a);
        return a;
    }

    pub fn isLive(s: *const Store, a: *const Actor) bool {
        return a.used and s.frame -% a.seen < stale_frames;
    }

    pub fn byId(s: *Store, id: u64) ?*Actor {
        for (s.actors.items) |a| if (a.used and a.id == id) return a;
        return null;
    }

    pub fn findEdit(s: *Store, actor: u64, bone: []const u8) ?*Edit {
        for (s.edits.items) |*e| if (e.actor == actor and e.bone.eql(bone)) return e;
        return null;
    }

    /// The bone's edit, made if it hasn't one. Null when out of memory. Good till the next one's made.
    pub fn edit(s: *Store, actor: u64, bone: []const u8) ?*Edit {
        // Asked for to be changed
        s.changes +%= 1;
        if (s.findEdit(actor, bone)) |e| return e;
        const e = s.edits.addOne(s.gpa) catch return null;
        e.* = .{ .actor = actor, .bone = .init(bone) };
        return e;
    }

    pub fn resetBone(s: *Store, actor: u64, bone: []const u8) void {
        const e = s.findEdit(actor, bone) orelse return;
        _ = s.edits.swapRemove(e - s.edits.items.ptr);
        s.changes +%= 1;
    }

    pub fn resetActor(s: *Store, actor: u64) void {
        s.changes +%= 1;
        var i: usize = 0;
        while (i < s.edits.items.len) {
            if (s.edits.items[i].actor == actor) _ = s.edits.swapRemove(i) else i += 1;
        }
        s.resetShapes(actor);
    }

    /// Bones or shapes.
    pub fn hasEdits(s: *const Store, actor: u64) bool {
        for (s.edits.items) |e| if (e.actor == actor) return true;
        return s.hasShapeEdits(actor);
    }

    pub fn anyEdits(s: *const Store) bool {
        return s.edits.items.len > 0 or s.shape_edits.items.len > 0;
    }

    pub fn anyFrozen(s: *const Store) bool {
        for (s.actors.items) |a| if (a.used and a.frozen) return true;
        return false;
    }

    /// Everything `owner` handed over, edits and all, since the ids it gave mean nothing once it's gone.
    pub fn forgetOwner(s: *Store, owner: usize) void {
        for (s.actors.items) |a| {
            if (!a.used or a.owner != owner) continue;
            s.resetActor(a.id);
            a.clear();
        }
    }

    /// Every bone and shape edit, for undo. Edits are plain data, so they're kept as they are.
    pub fn saveEdits(s: *const Store, a: std.mem.Allocator) ![]u8 {
        const head = [2]u32{ @intCast(s.edits.items.len), @intCast(s.shape_edits.items.len) };
        const parts = [_][]const u8{ std.mem.asBytes(&head), std.mem.sliceAsBytes(s.edits.items), std.mem.sliceAsBytes(s.shape_edits.items) };
        return std.mem.concat(a, u8, &parts);
    }

    /// Back to what `saveEdits` gave.
    pub fn loadEdits(s: *Store, bytes: []const u8) !void {
        var head: [2]u32 = undefined;
        @memcpy(std.mem.asBytes(&head), bytes[0..@sizeOf([2]u32)]);
        try s.edits.resize(s.gpa, head[0]);
        try s.shape_edits.resize(s.gpa, head[1]);
        var from: usize = @sizeOf([2]u32);
        const edits = std.mem.sliceAsBytes(s.edits.items);
        @memcpy(edits, bytes[from..][0..edits.len]);
        from += edits.len;
        const shapes = std.mem.sliceAsBytes(s.shape_edits.items);
        @memcpy(shapes, bytes[from..][0..shapes.len]);
        s.changes +%= 1;
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
    var inside: [parents.len]bool = undefined;
    apply(&parents, &world, &edits, &inside);
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
    var inside: [parents.len]bool = undefined;
    apply(&parents, &world, &edits, &inside);
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
        const e: Edit = .{ .actor = 1, .bone = .init("b"), .rotation = euler(c[0]), .position = c[1], .scale = c[2] };
        var back: Edit = .{ .actor = 1, .bone = .init("b") };
        back.setMatrix(e.matrix());
        try testing.expect(sameTurn(back.rotation, e.rotation));
        try testing.expect(back.position.approxEql(e.position, 1e-4));
        try testing.expect(back.scale.approxEql(e.scale, 1e-4));
    }
    // Straight up, where degrees lose one, the turn's kept whole
    const up: Edit = .{ .actor = 1, .bone = .init("b"), .rotation = euler(.init(20, 90, 30)) };
    var back: Edit = .{ .actor = 1, .bone = .init("b") };
    back.setMatrix(up.matrix());
    try testing.expect(sameTurn(back.rotation, up.rotation));
}

test "no turn, move or scale is nothing" {
    var e: Edit = .{ .actor = 1, .bone = .init("b") };
    try testing.expect(e.isNothing());
    e.rotation = euler(.zero);
    try testing.expect(e.isNothing());
    e.rotation = euler(.init(0, 0, 1));
    try testing.expect(!e.isNothing());
}

const sameTurn = transform.sameTurn;

test "edits stick by name every frame, and freezing holds the pose from before them" {
    var store: Store = .init(testing.allocator);
    defer store.deinit();
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
    var store: Store = .init(testing.allocator);
    defer store.deinit();
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
    var store: Store = .init(testing.allocator);
    defer store.deinit();
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

test "an on or off shape's edit is either, whatever weight was asked" {
    var store: Store = .init(testing.allocator);
    defer store.deinit();
    const bones = [_]TestBone{.{ .name = "root", .parent = -1 }};
    var frame = [_]Mat4{at(0, 0, 0)};
    store.pose(7, "B'tah", &bones, &frame, .identity);
    const Toggled = struct { name: []const u8, mesh: []const u8, toggle: bool };
    const shapes = [_]Toggled{
        .{ .name = "shp_brw_a", .mesh = "face.mdl", .toggle = true },
        .{ .name = "smile", .mesh = "face.mdl", .toggle = false },
    };
    store.shapeEdit(7, "face.mdl", "shp_brw_a").?.weight = 0.3;
    store.shapeEdit(7, "face.mdl", "smile").?.weight = 0.3;
    var weights = [_]f32{ 1, 0 };
    store.shape(7, &shapes, &weights);
    try testing.expectEqualSlices(f32, &.{ 0, 0.3 }, &weights);
    try testing.expectEqualSlices(bool, &.{ true, false }, store.byId(7).?.shape_toggles[0..2]);

    store.shapeEdit(7, "face.mdl", "shp_brw_a").?.weight = 0.6;
    weights = .{ 0, 0 };
    store.shape(7, &shapes, &weights);
    try testing.expectEqual(1, weights[0]);
}

test "freezing holds the weights from before the edits" {
    var store: Store = .init(testing.allocator);
    defer store.deinit();
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

test "big skeletons, crowds and many edits all fit" {
    var store: Store = .init(testing.allocator);
    defer store.deinit();
    // More of each than the old fixed lists held: 32 actors, 512 bones, 256 edits
    const count = 2048;
    var names: [count][8]u8 = undefined;
    var bones: [count]TestBone = undefined;
    for (&bones, &names, 0..) |*b, *n, i| b.* = .{ .name = std.fmt.bufPrint(n, "b{d}", .{i}) catch unreachable, .parent = @as(i32, @intCast(i)) - 1 };
    const frame = try testing.allocator.alloc(Mat4, count);
    defer testing.allocator.free(frame);
    for (0..100) |actor| {
        @memset(frame, at(0, 1, 0));
        store.pose(actor, "extra", &bones, frame, .identity);
    }
    try testing.expectEqual(100, store.actors.items.len);
    try testing.expectEqual(count, store.byId(99).?.count);
    for (0..1000) |i| store.edit(i % 100, bones[i].name).?.scale = .init(1, 1, 1);
    try testing.expectEqual(1000, store.edits.items.len);
    // The last bone, past where a fixed skeleton stopped, still takes an edit
    store.edit(5, bones[count - 1].name).?.position = .init(0, 0, 1);
    @memset(frame, at(0, 0, 0));
    store.pose(5, "extra", &bones, frame, .identity);
    try testing.expect(frame[count - 1].getTranslation().z > 0.5);
}

test "edits saved and loaded come back as they were, and each change is counted" {
    var store: Store = .init(testing.allocator);
    defer store.deinit();
    const before = store.changes;
    store.edit(7, "head").?.position = .init(0, 2, 0);
    store.shapeEdit(7, "Face", "smile").?.weight = 0.5;
    try testing.expect(store.changes > before);
    const saved = try store.saveEdits(testing.allocator);
    defer testing.allocator.free(saved);

    store.resetActor(7);
    store.edit(8, "hand").?.scale = .init(2, 2, 2);
    const changed = store.changes;
    try store.loadEdits(saved);
    try testing.expect(store.changes != changed);
    try testing.expectEqual(1, store.edits.items.len);
    try testing.expect(store.findEdit(7, "head").?.position.approxEql(.init(0, 2, 0), 1e-6));
    try testing.expectEqual(null, store.findEdit(8, "hand"));
    try testing.expectEqual(0.5, store.findShapeEdit(7, "Face", "smile").?.weight);
}

test "a shape's key is what's after its last dot" {
    try testing.expectEqualStrings("blink", shapeKey("Face_BS.blink"));
    try testing.expectEqualStrings("blink", shapeKey("blink"));
    try testing.expectEqualStrings("odd.", shapeKey("odd."));
}
