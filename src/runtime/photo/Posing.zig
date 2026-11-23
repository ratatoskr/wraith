//! Posing characters. Game and engine plugins hand over their skeletons each frame through the API's
//! `Posing`, and this does the window, picking, freezing, keys and settings.

const Posing = @This();

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;
const math = @import("tuft_math");
const tuft_input = @import("tuft_input");
const Keybinds = tuft_input.Keybinds;

const api = @import("wraith_api");
const ui = @import("wraith_ui");

const Registry = @import("../settings/Registry.zig");
const Settings = @import("../Settings.zig");
const Photo = @import("Photo.zig");
const Overlay = @import("../ui/Overlay.zig");
const frame = @import("../host/frame.zig");
const Camera = @import("Camera.zig");
const poses = @import("pose.zig");

const W = api.wraith;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;

/// Listed under it in Settings.
const Show = enum { posed, everyone, nobody };
const show_options = [_][]const u8{ "The one being posed", "Everyone", "No one" };

pub const Press = enum { window, freeze, focus };

const tools = [_][:0]const u8{ "Rotate", "Move", "Scale" };

const Key = struct {
    setting: *Registry.Setting = undefined,
    which: Press,
    posing: *Posing = undefined,

    fn fired(ctx: *anyopaque, phase: Keybinds.Phase) void {
        const self: *Key = @ptrCast(@alignCast(ctx));
        if (phase == .pressed) self.posing.pressed(self.which);
    }
};

const bone_colour = ui.rgba(90, 220, 120, 200);
const dim_colour = ui.rgba(160, 160, 160, 120);
const joint_colour = ui.rgba(90, 220, 120, 255);
const picked_colour = ui.rgba(255, 190, 60, 255);
const hover_colour = ui.rgba(255, 255, 255, 255);
const pick_radius = 10;

registry: *Registry,
overlay: *Overlay,
camera: *Camera,
/// What the game's threads and the render thread share.
lock: Atomic(u32) = .init(0),
/// Whether to bother the game for skeletons
wanted: Atomic(bool) = .init(false),
store: poses.Store = undefined,
show: *Registry.Setting = undefined,
thickness: *Registry.Setting = undefined,
keys: std.EnumArray(Press, Key) = .init(.{
    .window = .{ .which = .window },
    .freeze = .{ .which = .freeze },
    .focus = .{ .which = .focus },
}),
/// The window's open, from any thread.
open: Atomic(bool) = .init(false),
/// Keys wait for the frame, since the store's the render thread's.
want_freeze: Atomic(bool) = .init(false),
want_focus: Atomic(bool) = .init(false),

// Render thread only from here down

/// The actor and bone being posed, by id and name so they survive the game reloading them
actor: ?u64 = null,
bone: poses.Name = .{},
has_bone: bool = false,
/// Where to point the camera, once the lock's let go
focus_at: ?Vec3 = null,
/// Showing the cursor and keeping the keyboard and mouse from the game, like Wraith's own windows
grabbed: bool = false,
/// Which of `tools` the gizmo is, and whether it goes along the world's axes or the bone's
tool: usize = 0,
world_axes: bool = false,
/// While the gizmo's dragged, the bone where it's dragged to, in the world. It's ours, since the
/// bones only catch up when the game poses them next
dragging: bool = false,
gizmo_matrix: Mat4 = .identity,
/// Where the bone would be without its own edit, as the drag started
drag_base: Mat4 = .identity,
/// Labels for the actor list, which ImGui wants null terminated
labels: [poses.max_actors][56:0]u8 = undefined,
/// Narrows the actors and bones down by name
search: [64:0]u8 = @splat(0),

/// Keep it where it is, since its keys point at it.
pub fn init(self: *Posing, registry: *Registry, overlay: *Overlay, camera: *Camera) !void {
    self.* = .{ .registry = registry, .overlay = overlay, .camera = camera };
    self.store = try .init(std.heap.page_allocator);
    self.show = try registry.add(.{ .id = "wraith.posing.show", .name = "Draw skeletons of", .help = "While the Posing window's open.", .group = Settings.group, .section = Photo.section, .heading = "Posing", .kind = .{ .choice = .{ .default = show_options[0], .options = &show_options } } }, .{});
    errdefer registry.remove(self.show);
    self.thickness = try registry.add(.{ .id = "wraith.posing.thickness", .name = "Line thickness", .group = Settings.group, .section = Photo.section, .heading = "Posing", .kind = .{ .number = .{ .default = 1.5, .min = 0.5, .max = 5, .step = 0 } } }, .{});
    errdefer registry.remove(self.thickness);
    var bound: usize = 0;
    errdefer for (std.enums.values(Press)[0..bound]) |p| registry.remove(self.keys.getPtr(p).setting);
    for (std.enums.values(Press)) |p| {
        const slot = self.keys.getPtr(p);
        slot.posing = self;
        const id, const name, const key: tuft_input.Key = switch (p) {
            .window => .{ "wraith.posing.window", "Open or close Posing", .f7 },
            .freeze => .{ "wraith.posing.freeze", "Freeze or unfreeze the actor being posed", .f8 },
            .focus => .{ "wraith.posing.focus", "Orbit the camera round the picked bone", .keypad_decimal },
        };
        // Focus only does anything while the window's open, so the game keeps the key otherwise
        slot.setting = try registry.add(.{ .id = id, .name = name, .group = Settings.group, .section = Photo.section, .heading = "Posing keys", .kind = .{ .key = .{ .default = .one(.{ .key = key }), .consume = p != .focus } } }, .{ .key = .{ .ctx = slot, .call = Key.fired } });
        bound += 1;
    }
}

/// Waits for keys in flight. Game plugins may still call in, so the store stays till the end.
pub fn deinit(self: *Posing) void {
    for (std.enums.values(Press)) |p| self.registry.remove(self.keys.getPtr(p).setting);
    self.registry.remove(self.show);
    self.registry.remove(self.thickness);
    self.grab(false);
    self.wanted.store(false, .monotonic);
}

fn acquire(self: *Posing) void {
    while (self.lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn release(self: *Posing) void {
    self.lock.store(0, .release);
}

// The API, from game and engine plugins, on any thread

pub fn active(self: *const Posing) bool {
    return self.wanted.load(.monotonic);
}

pub fn pose(self: *Posing, skeleton: W.PosingSkeleton, matrices: *Mat4) void {
    const bones = skeleton.bones;
    const many: [*]Mat4 = @ptrCast(matrices);
    self.acquire();
    defer self.release();
    self.store.pose(skeleton.id, skeleton.name, bones, many[0..bones.len], skeleton.to_world);
}

// Render thread from here

pub fn isOpen(self: *const Posing) bool {
    return self.open.load(.acquire);
}

pub fn setOpen(self: *Posing, on: bool) void {
    self.open.store(on, .release);
}

fn pressed(self: *Posing, which: Press) void {
    switch (which) {
        .window => self.setOpen(!self.isOpen()),
        .freeze => self.want_freeze.store(true, .release),
        .focus => if (self.isOpen()) self.want_focus.store(true, .release),
    }
}

/// The posed actor's frozen or not, by its key.
fn toggleFrozen(self: *Posing) void {
    const id = self.actor orelse return;
    self.acquire();
    defer self.release();
    const a = self.store.byId(id) orelse return;
    setFrozen(a, !a.frozen);
}

fn focusPicked(self: *Posing) void {
    self.acquire();
    defer self.release();
    const a = self.current(&self.store) orelse return;
    const b = self.currentBone(a) orelse return;
    self.focus_at = a.position(b);
}

fn grab(self: *Posing, on: bool) void {
    if (self.grabbed == on) return;
    self.grabbed = on;
    self.overlay.requestCursor(on);
    self.overlay.take(.keyboard, on);
    self.overlay.take(.mouse, on);
}

fn setFrozen(a: *poses.Actor, on: bool) void {
    a.frozen = on;
    a.base_count = 0;
}

/// Once a frame.
pub fn tick(self: *Posing) void {
    if (self.want_freeze.swap(false, .acq_rel)) self.toggleFrozen();
    if (self.want_focus.swap(false, .acq_rel)) self.focusPicked();
    self.grab(self.isOpen());
    self.draw();
    const point = self.focus_at orelse return;
    self.focus_at = null;
    self.camera.focus(point);
}

fn draw(self: *Posing) void {
    const open = self.isOpen();
    self.acquire();
    defer self.release();
    const store = &self.store;
    store.frame +%= 1;
    self.wanted.store(open or store.edit_count > 0 or store.anyFrozen(), .monotonic);
    if (!open) return;
    // The game's plugin sets it each frame
    const v = frame.view();
    if (v.known) store.setCamera(v.view, v.projection) else store.view_proj = null;
    self.drawSkeletons(store);
    self.drawWindow(store);
}

/// The posed actor, if it's still around.
fn current(self: *Posing, store: *poses.Store) ?*poses.Actor {
    const a = store.byId(self.actor orelse return null) orelse return null;
    return if (store.isLive(a)) a else null;
}

fn currentBone(self: *Posing, a: *const poses.Actor) ?u32 {
    if (!self.has_bone) return null;
    return a.find(self.bone.get());
}

fn select(self: *Posing, a: *const poses.Actor, bone: ?u32) void {
    self.actor = a.id;
    if (bone) |b| {
        self.bone = a.names[b];
        self.has_bone = true;
    } else self.has_bone = false;
}
fn drawSkeletons(self: *Posing, store: *poses.Store) void {
    const show = choice(Show, self.registry.get(self.show).choice, &show_options);
    const vp = store.view_proj orelse return;
    const dl = ui.getBackgroundDrawList();
    const thickness: f32 = @floatCast(self.registry.get(self.thickness).number);
    const posed = self.current(store);
    const mouse = ui.getMousePos();
    const free_mouse = !ui.getIO().WantCaptureMouse;
    var hover: ?struct { actor: *poses.Actor, bone: u32, at: ui.Vec2 } = null;
    var hover_dist: f32 = pick_radius * pick_radius;

    for (store.actors) |*a| {
        if (!store.isLive(a)) continue;
        const is_posed = posed == a;
        if (show == .nobody or (show == .posed and !is_posed)) continue;
        for (0..a.count) |i| {
            const at = project(vp, a.position(i)) orelse continue;
            const p = a.parents[i];
            if (p >= 0 and p < i) {
                if (project(vp, a.position(@intCast(p)))) |from| dl.addLine(from, at, if (is_posed or posed == null) bone_colour else dim_colour, thickness);
            }
            if (is_posed) dl.addCircleFilled(at, thickness + 1.5, joint_colour);
            if (free_mouse) {
                const dx = at[0] - mouse[0];
                const dy = at[1] - mouse[1];
                const d = dx * dx + dy * dy;
                if (d < hover_dist) {
                    hover_dist = d;
                    hover = .{ .actor = a, .bone = @intCast(i), .at = at };
                }
            }
        }
    }

    if (posed) |a| if (self.currentBone(a)) |b| if (project(vp, a.position(b))) |at| dl.addCircle(at, 7, picked_colour, 2);
    // On the gizmo, a click's for it, not for picking another bone
    const on_gizmo = self.drawGizmo(store, posed, dl);
    if (hover) |h| if (!on_gizmo) {
        dl.addCircle(h.at, 6, hover_colour, 1.5);
        ui.mouseTooltip("{s}", .{h.actor.names[h.bone].get()});
        if (ui.isMouseClicked(.left)) self.select(h.actor, h.bone);
    };
}

/// Handles on the picked bone, which edit it like the boxes do. True while the mouse is on them.
fn drawGizmo(self: *Posing, store: *poses.Store, posed: ?*poses.Actor, dl: ui.DrawList) bool {
    const gizmo = ui.gizmo;
    gizmo.beginFrame();
    const a = posed orelse return self.stopDragging();
    const b = self.currentBone(a) orelse return self.stopDragging();
    const name = a.names[b].get();
    const view = ui.mainViewport();
    // Its own, apart from other plugins' gizmos
    const id = gizmo.id("posing");
    defer id.end();
    gizmo.setDrawList(dl);
    gizmo.setRect(view.pos, view.size);
    gizmo.setOrthographic(false);

    if (!self.dragging) {
        const own = if (store.findEdit(a.id, name)) |e| e.matrix() else Mat4.identity;
        self.gizmo_matrix = a.world[b].mul(a.to_world);
        self.drag_base = (own.inverse() orelse Mat4.identity).mul(a.world[b]);
    }
    const operation: gizmo.Operation = switch (self.tool) {
        0 => .rotate,
        1 => .translate,
        else => .scale,
    };
    _ = gizmo.manipulate(&store.view, &store.projection, operation, if (self.world_axes) .world else .local, &self.gizmo_matrix, .{});
    if (!gizmo.isUsing()) {
        self.dragging = false;
        return gizmo.isOver();
    }
    self.dragging = true;
    // Back into the bones' space, then less where it'd be anyway, leaves its own edit
    const from_world = a.to_world.inverse() orelse return true;
    const undo_base = self.drag_base.inverse() orelse return true;
    if (store.edit(a.id, name)) |e| e.setMatrix(self.gizmo_matrix.mul(from_world).mul(undo_base));
    return true;
}

fn stopDragging(self: *Posing) bool {
    self.dragging = false;
    return false;
}

fn drawWindow(self: *Posing, store: *poses.Store) void {
    var open = true;
    defer if (!open) self.open.store(false, .release);
    const window = ui.window("Posing", .{ .open = &open, .size = .{ 380, 560 } }) orelse return;
    defer window.end();

    var ids: [poses.max_actors]*poses.Actor = undefined;
    var items: [poses.max_actors][:0]const u8 = undefined;
    var n: usize = 0;
    var live: usize = 0;
    var selected: usize = 0;
    ui.setNextItemWidth(ui.fill);
    _ = ui.inputTextHint("##search", "Search actors and bones", &self.search);
    const text = self.searchText();
    for (store.actors) |*a| {
        if (!store.isLive(a)) continue;
        live += 1;
        // The one being posed stays, so searching never switches away from it
        if (self.actor != a.id and !matchesActor(a, text)) continue;
        items[n] = std.fmt.bufPrintSentinel(&self.labels[n], "{s}{s}", .{ a.name.get(), if (a.frozen) " (frozen)" else "" }, 0) catch continue;
        ids[n] = a;
        if (self.actor == a.id) selected = n;
        n += 1;
    }
    if (live == 0) {
        ui.textWrapped("Nothing to pose yet. Posing needs a plugin for this game, or its engine, that hands it skeletons.", .{});
        return;
    }
    if (n == 0) {
        ui.textDisabled("Nothing's called that.", .{});
        return;
    }
    if (text.len > 0) ui.textDisabled("{d} of {d} actors", .{ n, live });
    if (ui.combo("Actor", &selected, items[0..n])) self.select(ids[selected], null);
    const a = ids[selected];
    if (self.actor != a.id) self.select(a, null);

    var frozen = a.frozen;
    if (ui.checkbox("Frozen", &frozen)) setFrozen(a, frozen);
    ui.sameLine();
    ui.textDisabled("{s} to switch", .{self.keyName(.freeze)});
    if (store.hasEdits(a.id)) {
        ui.sameLine();
        if (ui.smallButton("Reset actor")) store.resetActor(a.id);
    }

    if (ui.child("bones", .{ 0, ui.scaled(220) }, .{ .border = true })) |c| {
        defer c.end();
        self.boneList(store, a);
    }

    const bone = self.currentBone(a) orelse {
        ui.textDisabled("Pick a bone, here or by clicking on it", .{});
        return;
    };
    const name = a.names[bone].get();
    var title: [64:0]u8 = undefined;
    ui.separatorText(std.fmt.bufPrintSentinel(&title, "{s}", .{name}, 0) catch "Bone");
    ui.setNextItemWidth(ui.scaled(110));
    _ = ui.combo("Gizmo", &self.tool, &tools);
    ui.sameLine();
    _ = ui.checkbox("World axes", &self.world_axes);
    var edit: poses.Edit = if (store.findEdit(a.id, name)) |e| e.* else .{ .actor = a.id, .bone = .init(name) };
    var changed = false;
    changed = ui.drag("Rotation", &edit.rotation, 0.25) or changed;
    changed = ui.drag("Position", &edit.position, 0.002) or changed;
    changed = ui.drag("Scale", &edit.scale, 0.002) or changed;
    if (changed) {
        if (edit.isNothing()) store.resetBone(a.id, name) else if (store.edit(a.id, name)) |e| {
            e.* = edit;
        } else ui.textDisabled("Too many posed bones", .{});
    }
    if (ui.button("Focus camera")) self.focus_at = a.position(bone);
    ui.tooltip("Orbits the camera round this bone. {s} does it too.", .{self.keyName(.focus)});
    ui.sameLine();
    if (store.findEdit(a.id, name) != null and ui.button("Reset bone")) store.resetBone(a.id, name);
    ui.textDisabled("In the bone's own axes. Double-click a box to type.", .{});
}

/// The bones as an indented tree, with posed ones marked. Only the ones that match while
/// searching, still indented.
fn boneList(self: *Posing, store: *poses.Store, a: *const poses.Actor) void {
    var depth: [poses.max_bones]u8 = undefined;
    const picked = self.currentBone(a);
    const text = self.searchText();
    var buf: [96:0]u8 = undefined;
    const pad: [32]u8 = @splat(' ');
    var shown: usize = 0;
    for (0..a.count) |i| {
        const p = a.parents[i];
        depth[i] = if (p >= 0 and p < i) @min(depth[@intCast(p)] + 1, pad.len / 2) else 0;
        const name = a.names[i].get();
        if (text.len > 0 and std.ascii.findIgnoreCase(name, text) == null) continue;
        shown += 1;
        const mark = if (store.findEdit(a.id, name) != null) " *" else "";
        const label = std.fmt.bufPrintSentinel(&buf, "{s}{s}{s}##{d}", .{ pad[0 .. depth[i] * 2], name, mark, i }, 0) catch continue;
        if (ui.selectable(label, picked == @as(u32, @intCast(i)))) self.select(a, @intCast(i));
    }
    if (shown == 0) ui.textDisabled("No bones called that.", .{});
}

fn searchText(self: *const Posing) []const u8 {
    return std.mem.trim(u8, std.mem.sliceTo(&self.search, 0), " \t");
}

/// By its name, or one of its bones'.
fn matchesActor(a: *const poses.Actor, text: []const u8) bool {
    if (text.len == 0 or std.ascii.findIgnoreCase(a.name.get(), text) != null) return true;
    for (a.names[0..a.count]) |*n| if (std.ascii.findIgnoreCase(n.get(), text) != null) return true;
    return false;
}

fn keyName(self: *Posing, which: Press) []const u8 {
    const keys = self.registry.get(self.keys.getPtrConst(which).setting).key orelse return "no key";
    return ui.chordName(&key_name_buf, keys.first());
}

var key_name_buf: [48]u8 = undefined;

/// World to screen through the camera, row-vector style.
fn project(vp: Mat4, p: Vec3) ?ui.Vec2 {
    const clip = vp.transformVec4(p.withW(1));
    if (clip.w < 0.01) return null;
    const view = ui.mainViewport();
    return .{
        view.pos[0] + (clip.x / clip.w * 0.5 + 0.5) * view.size[0],
        view.pos[1] + (0.5 - clip.y / clip.w * 0.5) * view.size[1],
    };
}

/// Which of `options` it's on, as `E`'s values in the same order.
fn choice(comptime E: type, value: []const u8, options: []const []const u8) E {
    for (options, 0..) |o, i| if (std.mem.eql(u8, o, value)) return @fromBackingInt(@intCast(i));
    return @fromBackingInt(0);
}

test {
    _ = poses;
}
