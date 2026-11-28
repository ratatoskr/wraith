//! Photo mode over the game: each kind's handles to click on, and one gizmo for what's picked, moving
//! everything picked that can move. Render thread.

const View = @This();

const std = @import("std");
const math = @import("tuft_math");
const ui = @import("wraith_ui");

const Gizmos = @import("../ui/Gizmos.zig");
const frame = @import("../host/frame.zig");
const Scene = @import("Scene.zig");

const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
const Target = Scene.Target;
pub const Tool = Gizmos.Tool;

const picked_colour = ui.rgba(255, 190, 60, 255);
const hover_colour = ui.rgba(255, 255, 255, 255);
/// How near, in pixels, a click has to be
const pick_radius = 10;

/// Where a kind draws and what it's clicked on with. Projects for it, and keeps the nearest to the mouse.
pub const Sink = struct {
    scene: *const Scene,
    view_proj: Mat4,
    draw_list: ui.DrawList,
    mouse: ui.Vec2,
    /// The mouse is over the game, not a window
    free: bool,
    best: ?struct { key: Scene.Key, at: ui.Vec2 } = null,
    best_dist: f32 = pick_radius * pick_radius,

    /// World to screen through the camera, or null behind it.
    pub fn project(s: *const Sink, p: Vec3) ?ui.Vec2 {
        const clip = s.view_proj.transformVec4(p.withW(1));
        if (clip.w < 0.01) return null;
        const view = ui.mainViewport();
        return .{
            view.pos[0] + (clip.x / clip.w * 0.5 + 0.5) * view.size[0],
            view.pos[1] + (0.5 - clip.y / clip.w * 0.5) * view.size[1],
        };
    }

    /// `t` can be clicked on at `at`, which is ringed while it's picked.
    pub fn point(s: *Sink, t: Target, at: ui.Vec2) void {
        if (s.scene.isPicked(t)) s.draw_list.addCircle(at, 7, picked_colour, 2);
        if (!s.free) return;
        const dx = at[0] - s.mouse[0];
        const dy = at[1] - s.mouse[1];
        const d = dx * dx + dy * dy;
        if (d < s.best_dist) {
            s.best_dist = d;
            s.best = .{ .key = .of(t), .at = at };
        }
    }
};

/// One picked thing being dragged, and where it started.
const Dragged = struct { key: Scene.Key, start: Mat4 };

scene: *Scene,
gizmo: *Gizmos.Gizmo,
/// `Scene.picked_version` it was last shown for, so it comes in front again when the picks change
shown_for: ?u64 = null,
/// Where it was put last frame, which is where a drag starts from
placed: Mat4 = .identity,
/// Where the gizmo was as this drag started
drag_from: Mat4 = .identity,
/// While dragging: round the middle, everything that moves; each on its own, the active one, whose change the scene puts on the rest
dragged: std.ArrayList(Dragged) = .empty,
/// Each on its own, the active one's value as the drag started
active_start: ?Scene.Local = null,
dragging: bool = false,

pub fn init(scene: *Scene) !View {
    return .{ .scene = scene, .gizmo = try Gizmos.create() };
}

pub fn deinit(self: *View) void {
    Gizmos.destroy(self.gizmo);
    self.dragged.deinit(self.scene.allocator);
}

/// Once a frame, after the game's posed: handles, hovering, clicks and the gizmo.
pub fn update(self: *View, open: bool) void {
    const s = self.scene;
    if (!open or !s.handles_shown) {
        _ = self.hide();
        return;
    }
    const v = frame.view();
    if (!v.known) {
        _ = self.hide();
        return;
    }
    var sink: Sink = .{
        .scene = s,
        .view_proj = v.viewMatrix.mul(v.projection),
        .draw_list = ui.getBackgroundDrawList(),
        .mouse = ui.getMousePos(),
        .free = !ui.getIO().WantCaptureMouse,
    };
    for (s.kinds.items) |*k| if (k.handles) |f| f(k.ctx, &sink);
    // On the gizmo, a click's for it, not for picking something else
    const on_gizmo = self.updateGizmo();
    const best = &(sink.best orelse return);
    if (on_gizmo) return;
    sink.draw_list.addCircle(best.at, 6, hover_colour, 1.5);
    var buf: [96]u8 = undefined;
    if (s.labelOf(best.key.target(), &buf)) |name| ui.mouseTooltip("{s}", .{name});
    if (ui.isMouseClicked(.left)) s.pick(best.key.target());
}

/// On the active one, if it can move. True while the mouse is on it.
fn updateGizmo(self: *View) bool {
    const s = self.scene;
    const t = s.active() orelse return self.hide();
    const k = s.kindOf(t.kind) orelse return self.hide();
    if (!k.hasGizmo()) return self.hide();
    const g = self.gizmo;
    if (self.shown_for != s.picked_version) {
        g.show();
        self.shown_for = s.picked_version;
    }
    // What it offers, so a camera picked while scaling gets another tool, not nothing
    g.setTool(k.toolFor(s.tool));
    g.setWorldAxes(s.world_axes);
    if (g.takeMoved()) |m| {
        if (!self.dragging) self.startDrag();
        self.moveTo(m);
    }
    if (self.dragging and !g.isDragging()) self.endDrag();
    const own = k.get_transform.?(k.ctx, t) orelse return self.hide();
    // The active one's axes, at the middle of everything picked when they turn round it
    const at = if (s.pivot == .middle) if (self.middle()) |c| Mat4.fromRows(own.row(0), own.row(1), own.row(2), c.withW(1)) else own else own;
    self.placed = at;
    g.place(at);
    return g.isHovered();
}

/// Where everything picked that moves is, on average, leaving out what follows another. Null for none.
fn middle(self: *View) ?Vec3 {
    const s = self.scene;
    var sum: Vec3 = .zero;
    var n: f32 = 0;
    for (s.picked.items) |*key| {
        const t = key.target();
        const k = s.kindOf(t.kind) orelse continue;
        if (!k.canMove() or s.followsPicked(t)) continue;
        const m = k.get_transform.?(k.ctx, t) orelse continue;
        sum = sum.add(m.getTranslation());
        n += 1;
    }
    return if (n > 0) sum.scale(1 / n) else null;
}

/// Takes where what moves starts. Round the middle, that's everything picked but what follows
/// another; each on its own, just the active one.
fn startDrag(self: *View) void {
    const s = self.scene;
    self.dragged.clearRetainingCapacity();
    self.dragging = true;
    self.drag_from = self.placed;
    self.active_start = null;
    if (s.pivot == .each) {
        const t = s.active() orelse return;
        const k = s.kindOf(t.kind) orelse return;
        self.active_start = k.local(t);
        self.begin(s.picked.items[s.picked.items.len - 1], k);
        return;
    }
    for (s.picked.items) |*key| {
        const t = key.target();
        const k = s.kindOf(t.kind) orelse continue;
        if (!k.canMove() or s.followsPicked(t)) continue;
        self.begin(key.*, k);
    }
}

fn begin(self: *View, key: Scene.Key, k: *const Scene.Kind) void {
    const t = key.target();
    const start = k.get_transform.?(k.ctx, t) orelse return;
    if (k.begin_drag) |f| f(k.ctx, t);
    self.dragged.append(self.scene.allocator, .{ .key = key, .start = start }) catch {};
}

fn moveTo(self: *View, to: Mat4) void {
    const s = self.scene;
    if (s.pivot == .each) return self.moveEach(to);
    for (self.dragged.items) |*d| {
        const t = d.key.target();
        const k = s.kindOf(t.kind) orelse continue;
        k.set_transform.?(k.ctx, t, held(d.start, self.drag_from, to));
    }
}

/// The active one where it's dragged, and the scene puts the same change on the rest, as the boxes do.
fn moveEach(self: *View, to: Mat4) void {
    const s = self.scene;
    const t = s.active() orelse return;
    const k = s.kindOf(t.kind) orelse return;
    const start = self.active_start orelse return;
    const before = k.local(t) orelse return;
    // Through its own value if it has one, like a bone's change from its animation, else where it is
    const after: Scene.Local = if (k.edit != null) .of(changedOwn(start.matrix(), self.drag_from, to)) else .of(to);
    k.setLocal(t, after);
    s.changePicked(t, before, after);
}

fn endDrag(self: *View) void {
    const s = self.scene;
    self.dragging = false;
    // Each kind once
    for (self.dragged.items, 0..) |*d, i| {
        const k = s.kindOf(d.key.kind()) orelse continue;
        const seen = for (self.dragged.items[0..i]) |*e| {
            if (std.mem.eql(u8, e.key.kind(), d.key.kind())) break true;
        } else false;
        if (!seen) if (k.end_drag) |f| f(k.ctx);
    }
    self.dragged.clearRetainingCapacity();
}

fn hide(self: *View) bool {
    if (self.dragging) self.endDrag();
    // Even when not shown, or it'd be left where it was after picking nothing
    self.gizmo.hide();
    self.shown_for = null;
    return false;
}

/// Where something that started at `start` goes, held by the gizmo as it's dragged from `from` to `to`.
pub fn held(start: Mat4, from: Mat4, to: Mat4) Mat4 {
    const undo = from.inverse() orelse return start;
    // Row vectors: a point held by the gizmo goes from `x * from` to `x * to`
    return start.mul(undo.mul(to));
}

/// Something's own value, like a bone's change from its animation, as the gizmo on it is dragged from
/// `from` to `to`: the same change, in its own axes.
pub fn changedOwn(own: Mat4, from: Mat4, to: Mat4) Mat4 {
    const undo = from.inverse() orelse return own;
    // Row vectors: what the gizmo's on goes from `from` to `change * from`
    return to.mul(undo).mul(own);
}

const testing = std.testing;

fn turnZ(degrees: f32) Mat4 {
    return Quat.fromAxisAngle(Vec3.unit_z, math.degToRad(degrees)).toMat4();
}

const Quat = math.Quat;

test "held by the gizmo, others swing round it" {
    const from = Mat4.translation(.init(1, 0, 0));
    const to = turnZ(90).mul(Mat4.translation(.init(1, 0, 0)));
    // One along x from it ends up along y from it
    const other = held(Mat4.translation(.init(2, 0, 0)), from, to);
    try testing.expect(other.getTranslation().approxEql(.init(1, 1, 0), 1e-5));
    try testing.expect(held(from, from, to).approxEql(to, 1e-4));
}

test "its own value changed by the gizmo puts it where the gizmo went" {
    // A bone's own value and where it is, from its animation as `base`
    const base = Mat4.translation(.init(0, 1, 0));
    const own = turnZ(30);
    const from = own.mul(base);
    const to = turnZ(90).mul(Mat4.translation(.init(0, 0, 2))).mul(from);
    try testing.expect(changedOwn(own, from, to).mul(base).approxEql(to, 1e-4));
}
