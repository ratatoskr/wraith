//! Posing characters. Game and engine plugins hand over their skeletons each frame through the API's
//! `Posing`, and this does picking, freezing, keys and settings, and draws the skeletons and the
//! gizmo over the game. Photo mode's window draws its actors, panel and tools with what's here.

const Posing = @This();

const std = @import("std");
const core = @import("wraith_core");
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
const Gizmos = @import("../ui/Gizmos.zig");
const Camera = @import("Camera.zig");
const icons = @import("../ui/icons.zig");
const poses = @import("pose.zig");

const W = api.wraith;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;

/// Listed under it in Settings.
const Show = enum { posed, everyone, nobody };
const show_options = [_][]const u8{ "The one being posed", "Everyone", "No one" };

pub const Press = enum { window, freeze, focus };

pub const Tool = enum { rotate, move, scale };

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
/// Photo mode's window is open, from any thread.
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
/// What the gizmo does, and whether it goes along the world's axes or the bone's
tool: Tool = .rotate,
world_axes: bool = false,
/// The skeletons and gizmo over the game, off for a clear look at the pose
overlay_on: bool = true,
/// Posing's handles, drawn by Wraith's gizmos like a plugin's, and whether it's said to show
gizmo: *Gizmos.Gizmo = undefined,
gizmo_shown: bool = false,
/// Where the bone would be without its own edit, as the drag started
drag_base: Mat4 = .identity,
/// Narrows the actors, bones and shapes down by name
search: [64:0]u8 = @splat(0),
/// The Shapes tab's
link_shapes: bool = true,
changed_only: bool = false,

/// Keep it where it is, since its keys point at it.
pub fn init(self: *Posing, registry: *Registry, overlay: *Overlay, camera: *Camera) !void {
    self.* = .{ .registry = registry, .overlay = overlay, .camera = camera };
    self.store = try .init(std.heap.page_allocator);
    self.gizmo = try Gizmos.create();
    errdefer Gizmos.destroy(self.gizmo);
    self.show = try registry.add(.{ .id = "wraith.posing.show", .name = "Draw skeletons of", .help = "While Photo mode's open.", .group = Settings.group, .section = Photo.section, .heading = "Posing", .kind = .{ .choice = .{ .default = show_options[0], .options = &show_options } } }, .{});
    errdefer registry.remove(self.show);
    self.thickness = try registry.add(.{ .id = "wraith.posing.thickness", .name = "Line thickness", .group = Settings.group, .section = Photo.section, .heading = "Posing", .kind = .{ .number = .{ .default = 1.5, .min = 0.5, .max = 5, .step = 0 } } }, .{});
    errdefer registry.remove(self.thickness);
    var bound: usize = 0;
    errdefer for (std.enums.values(Press)[0..bound]) |p| registry.remove(self.keys.getPtr(p).setting);
    for (std.enums.values(Press)) |p| {
        const slot = self.keys.getPtr(p);
        slot.posing = self;
        const id, const name, const key: tuft_input.Key = switch (p) {
            .window => .{ "wraith.posing.window", "Open or close Photo mode", .f7 },
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
    Gizmos.destroy(self.gizmo);
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

pub fn pose(self: *Posing, owner: usize, skeleton: W.Posing.Skeleton, matrices: *Mat4) void {
    const bones = skeleton.bones;
    const many: [*]Mat4 = @ptrCast(matrices);
    const t = core.timing.scope("posing a skeleton");
    defer t.end();
    self.acquire();
    defer self.release();
    self.store.pose(skeleton.id, skeleton.name, bones, many[0..bones.len], skeleton.to_world);
    if (self.store.byId(skeleton.id)) |a| a.owner = owner;
}

pub fn shapes(self: *Posing, actor: u64, list: []const W.Posing.Shape, weights: *f32) void {
    const many: [*]f32 = @ptrCast(weights);
    self.acquire();
    defer self.release();
    self.store.shape(actor, list, many[0..list.len]);
}

/// Picked or edited, while the window's open.
pub fn wants(self: *Posing, actor: u64) bool {
    self.acquire();
    defer self.release();
    return self.actor == actor or self.store.hasEdits(actor);
}

/// Drops what `owner` handed over, when it's going.
pub fn forget(self: *Posing, owner: usize) void {
    self.acquire();
    defer self.release();
    self.store.forgetOwner(owner);
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
    a.shape_base_count = 0;
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
    const waited = core.timing.scope("posing lock");
    self.acquire();
    waited.end();
    defer self.release();
    const store = &self.store;
    store.frame +%= 1;
    self.wanted.store(open or store.anyEdits() or store.anyFrozen(), .monotonic);
    if (!open) {
        _ = self.hideGizmo();
        return;
    }
    // The game's plugin sets it each frame
    const v = frame.view();
    if (v.known) store.setCamera(v.viewMatrix, v.projection) else store.view_proj = null;
    if (!self.overlay_on) {
        _ = self.hideGizmo();
        return;
    }
    {
        const t = core.timing.scope("posing skeletons");
        defer t.end();
        self.drawSkeletons(store);
    }
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

pub fn select(self: *Posing, a: *const poses.Actor, bone: ?u32) void {
    self.actor = a.id;
    if (bone) |b| {
        self.bone = a.names[b];
        self.has_bone = true;
    } else self.has_bone = false;
    // In front again, even over a Scene panel's
    self.gizmo_shown = false;
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
        // Each bone once, since it's a parent to its children's lines too
        var screen: [poses.max_bones]?ui.Vec2 = undefined;
        for (0..a.count) |i| {
            screen[i] = project(vp, a.position(i));
            const at = screen[i] orelse continue;
            const p = a.parents[i];
            if (p >= 0 and p < i) {
                if (screen[@intCast(p)]) |from| dl.addLine(from, at, if (is_posed or posed == null) bone_colour else dim_colour, thickness);
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
    const on_gizmo = self.updateGizmo(store, posed);
    if (hover) |h| if (!on_gizmo) {
        dl.addCircle(h.at, 6, hover_colour, 1.5);
        ui.mouseTooltip("{s}", .{h.actor.names[h.bone].get()});
        if (ui.isMouseClicked(.left)) self.select(h.actor, h.bone);
    };
}

/// Handles on the picked bone, which edit it like the boxes do. Wraith's gizmos draw them after
/// this frame's done, so what's dragged comes back here next frame. True while the mouse is on them.
fn updateGizmo(self: *Posing, store: *poses.Store, posed: ?*poses.Actor) bool {
    const a = posed orelse return self.hideGizmo();
    const b = self.currentBone(a) orelse return self.hideGizmo();
    const g = self.gizmo;
    if (!self.gizmo_shown) {
        g.show();
        self.gizmo_shown = true;
    }
    const name = a.names[b].get();
    g.setTool(switch (self.tool) {
        .rotate => .rotate,
        .move => .move,
        .scale => .scale,
    });
    g.setWorldAxes(self.world_axes);
    if (g.takeMoved()) |m| {
        // Back into the bones' space, then less where it'd be anyway, leaves its own edit
        const from_world = a.to_world.inverse() orelse return true;
        const undo_base = self.drag_base.inverse() orelse return true;
        if (store.edit(a.id, name)) |e| e.setMatrix(m.mul(from_world).mul(undo_base));
    }
    // Where it'd be without its own edit, as a drag starts
    if (!g.isDragging()) {
        const own = if (store.findEdit(a.id, name)) |e| e.matrix() else Mat4.identity;
        self.drag_base = (own.inverse() orelse Mat4.identity).mul(a.world[b]);
    }
    g.place(a.world[b].mul(a.to_world));
    return g.isHovered();
}

fn hideGizmo(self: *Posing) bool {
    // Even when it's not said to show: picking another actor or bone clears `gizmo_shown` so it
    // comes back in front, and with nothing picked after, it'd be left where it was
    self.gizmo.hide();
    self.gizmo_shown = false;
    return false;
}

// Photo mode's window, on the render thread. Each takes the lock itself.

/// The search box over the actors, which narrows the bones and shapes too.
pub fn drawSearch(self: *Posing) void {
    ui.setNextItemWidth(ui.fill);
    _ = ui.inputTextHint("##search", "Search actors, bones and shapes", &self.search);
}

/// A row for each actor in the scene list, frozen ones with a snowflake and edited ones marked.
/// True when one's clicked.
pub fn drawActorRows(self: *Posing, selected: bool) bool {
    self.acquire();
    defer self.release();
    const store = &self.store;
    const text = self.searchText();
    var buf: [80:0]u8 = undefined;
    var live: usize = 0;
    var shown: usize = 0;
    var clicked = false;
    for (store.actors) |*a| {
        if (!store.isLive(a)) continue;
        live += 1;
        // The one being posed stays, so searching never hides it
        if (self.actor != a.id and !matchesActor(a, text)) continue;
        shown += 1;
        const icon = if (a.frozen) icons.snowflake else icons.user;
        const mark = if (store.hasEdits(a.id)) " *" else "";
        const label = std.fmt.bufPrintSentinel(&buf, "{s}  {s}{s}##actor{d}", .{ icon, a.name.get(), mark, a.id }, 0) catch continue;
        if (ui.selectable(label, selected and self.actor == a.id)) {
            if (self.actor != a.id) self.select(a, null) else self.gizmo_shown = false;
            clicked = true;
        }
    }
    if (live == 0) {
        ui.textDisabled("None yet", .{});
        ui.tooltip("Posing needs a plugin for this game, or its engine, that hands it skeletons.", .{});
    } else if (shown == 0) ui.textDisabled("Nothing's called that", .{});
    return clicked;
}

/// The posed actor's bones and shapes.
pub fn drawActorPanel(self: *Posing) void {
    self.acquire();
    defer self.release();
    const store = &self.store;
    const a = self.current(store) orelse {
        var any = false;
        for (store.actors) |*one| any = any or store.isLive(one);
        if (any) {
            ui.textDisabled("Pick an actor from the list, or click on a bone in the game.", .{});
        } else ui.textWrapped("Nothing to pose yet. Posing needs a plugin for this game, or its engine, that hands it skeletons.", .{});
        return;
    };
    var title: [64:0]u8 = undefined;
    ui.separatorText(std.fmt.bufPrintSentinel(&title, "{s}{s}", .{ a.name.get(), if (a.frozen) " (frozen)" else "" }, 0) catch "Actor");

    // Tabs only when there's more than bones
    if (a.shape_count == 0) return self.bonesTab(store, a);
    const tabs = ui.tabBar("parts") orelse return;
    defer tabs.end();
    if (ui.tabItem("Bones", .{})) |t| {
        defer t.end();
        self.bonesTab(store, a);
    }
    if (ui.tabItem("Shapes", .{})) |t| {
        defer t.end();
        self.shapesTab(store, a);
    }
}

/// The toolbar's posing buttons: the skeletons and gizmo, freezing, focusing and resetting.
pub fn drawTools(self: *Posing) void {
    self.acquire();
    defer self.release();
    const store = &self.store;
    const posed = self.current(store);
    const shown = self.overlay_on;
    if (Photo.toolButton(if (shown) icons.eye ++ "##posing_overlay" else icons.eye_off ++ "##posing_overlay", shown, "{s} the skeletons and gizmo", .{if (shown) "Hide" else "Show"})) self.overlay_on = !shown;
    ui.sameLine();
    const off = ui.disabled(posed == null);
    defer off.end();
    {
        const hidden = ui.disabled(!shown);
        defer hidden.end();
        inline for (.{ .{ Tool.rotate, icons.rotate_3d, "Rotate" }, .{ Tool.move, icons.move_3d, "Move" }, .{ Tool.scale, icons.scale_3d, "Scale" } }) |t| {
            if (Photo.toolButton(t[1] ++ "##posing_" ++ t[2], self.tool == t[0], t[2] ++ " with the gizmo", .{})) self.tool = t[0];
            ui.sameLine();
        }
        if (Photo.toolButton(icons.globe ++ "##posing_world", self.world_axes, "Line the gizmo up with the world, not the bone", .{})) self.world_axes = !self.world_axes;
    }
    Photo.gap();
    const frozen = if (posed) |a| a.frozen else false;
    if (Photo.toolButton(icons.snowflake ++ "##posing_freeze", frozen, "{s} the actor. {s}", .{ if (frozen) "Unfreeze" else "Freeze", self.keyName(.freeze) })) {
        if (posed) |a| setFrozen(a, !a.frozen);
    }
    ui.sameLine();
    const bone = if (posed) |a| self.currentBone(a) else null;
    {
        const no_bone = ui.disabled(bone == null);
        defer no_bone.end();
        if (Photo.toolButton(icons.crosshair ++ "##posing_focus", false, "Orbit the camera round the picked bone. {s}", .{self.keyName(.focus)})) {
            if (posed) |a| if (bone) |b| {
                self.focus_at = a.position(b);
            };
        }
    }
    ui.sameLine();
    const edited = if (posed) |a| store.hasEdits(a.id) else false;
    {
        const nothing = ui.disabled(!edited);
        defer nothing.end();
        if (Photo.toolButton(icons.rotate_ccw ++ "##posing_reset", false, "Put the actor back, bones and shapes", .{})) {
            if (posed) |a| store.resetActor(a.id);
        }
    }
}

fn bonesTab(self: *Posing, store: *poses.Store, a: *poses.Actor) void {
    // The list takes what the picked bone's boxes leave
    const boxes: f32 = if (self.currentBone(a) != null) 7 else 2;
    const room = ui.getContentRegionAvailPixels()[1] - boxes * (ui.frameHeight() + ui.scaled(ui.getStyle().item_spacing[1]));
    if (ui.child("bones", .{ 0, @max(room, ui.scaled(120)) }, .{ .border = true })) |c| {
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
    if (store.findEdit(a.id, name) != null and ui.button("Reset bone")) store.resetBone(a.id, name);
    ui.textDisabled("In the bone's own axes. Double-click a box to type.", .{});
}

/// A slider for each blend shape. Linked, one stands for every mesh's shape of the same name.
fn shapesTab(self: *Posing, store: *poses.Store, a: *const poses.Actor) void {
    _ = ui.checkbox("Same name on every mesh", &self.link_shapes);
    ui.tooltip("One slider for each name, so the lashes blink along with the face.", .{});
    ui.sameLine();
    _ = ui.checkbox("Changed only", &self.changed_only);
    if (store.hasShapeEdits(a.id)) {
        ui.sameLine();
        if (ui.smallButton("Reset shapes")) store.resetShapes(a.id);
    }
    ui.textDisabled("Ctrl-click a slider to type, even past 0 or 1. Right-click to reset.", .{});

    const c = ui.child("shapes", .{ 0, 0 }, .{ .border = true }) orelse return;
    defer c.end();
    const text = self.searchText();
    var buf: [112:0]u8 = undefined;
    var shown: usize = 0;
    for (0..a.shape_count) |i| {
        const name = a.shape_names[i].get();
        const mesh = a.shape_meshes[i].get();
        const key = poses.shapeKey(name);
        if (self.link_shapes) {
            const seen = for (a.shape_names[0..i]) |*n| {
                if (std.mem.eql(u8, poses.shapeKey(n.get()), key)) break true;
            } else false;
            if (seen) continue;
        }
        if (text.len > 0 and std.ascii.findIgnoreCase(name, text) == null) continue;
        const changed = store.shapeEditFor(a.id, mesh, name) != null;
        if (self.changed_only and !changed) continue;
        shown += 1;

        const edit_mesh = if (self.link_shapes) "" else mesh;
        const edit_name = if (self.link_shapes) key else name;
        const mark = if (changed) " *" else "";
        const label = if (self.link_shapes)
            std.fmt.bufPrintSentinel(&buf, "{s}{s}##{d}", .{ key, mark, i }, 0) catch continue
        else
            std.fmt.bufPrintSentinel(&buf, "{s} ({s}){s}##{d}", .{ name, mesh, mark, i }, 0) catch continue;
        const row = ui.id(@as(i32, @intCast(i)));
        defer row.end();
        var weight = a.weights[i];
        if (ui.sliderWith(label, &weight, 0, 1, .{ .format = "%.2f" })) {
            // Linked, it has to win over each mesh's own
            if (self.link_shapes) store.resetShapeOnMeshes(a.id, key);
            if (store.shapeEdit(a.id, edit_mesh, edit_name)) |e| e.weight = weight else ui.textDisabled("Too many changed shapes", .{});
        }
        if (ui.contextMenu("reset")) |m| {
            defer m.end();
            if (ui.menuItem("Reset", .{ .enabled = changed })) {
                if (self.link_shapes) store.resetShapeOnMeshes(a.id, key);
                store.resetShape(a.id, edit_mesh, edit_name);
            }
        }
    }
    if (shown == 0) {
        if (self.changed_only) ui.textDisabled("No changed shapes.", .{}) else ui.textDisabled("No shapes called that.", .{});
    }
}

/// The bones as an indented tree, with posed ones marked. Only the ones that match while
/// searching, still indented.
fn boneList(self: *Posing, store: *poses.Store, a: *const poses.Actor) void {
    var depth: [poses.max_bones]u8 = undefined;
    // What's shown, which is every bone unless searching
    var rows: [poses.max_bones]u16 = undefined;
    var n: usize = 0;
    const picked = self.currentBone(a);
    const text = self.searchText();
    const pad: [32]u8 = @splat(' ');
    var picked_row: ?usize = null;
    for (0..a.count) |i| {
        const p = a.parents[i];
        depth[i] = if (p >= 0 and p < i) @min(depth[@intCast(p)] + 1, pad.len / 2) else 0;
        if (text.len > 0 and std.ascii.findIgnoreCase(a.names[i].get(), text) == null) continue;
        if (picked == @as(u32, @intCast(i))) picked_row = n;
        rows[n] = @intCast(i);
        n += 1;
    }
    if (n == 0) return ui.textDisabled("No bones called that.", .{});
    // Only the rows on screen, since skeletons run to hundreds of bones
    var buf: [96:0]u8 = undefined;
    var clip = ui.clip(n);
    clip.include(picked_row);
    while (clip.next()) |r| {
        const i = rows[r];
        const name = a.names[i].get();
        const mark = if (store.findEdit(a.id, name) != null) " *" else "";
        const label = std.fmt.bufPrintSentinel(&buf, "{s}{s}{s}##{d}", .{ pad[0 .. depth[i] * 2], name, mark, i }, 0) catch continue;
        if (ui.selectable(label, picked == @as(u32, i))) self.select(a, i);
    }
}

fn searchText(self: *const Posing) []const u8 {
    return std.mem.trim(u8, std.mem.sliceTo(&self.search, 0), " \t");
}

/// By its name, or one of its bones' or shapes'.
fn matchesActor(a: *const poses.Actor, text: []const u8) bool {
    if (text.len == 0 or std.ascii.findIgnoreCase(a.name.get(), text) != null) return true;
    for (a.names[0..a.count]) |*n| if (std.ascii.findIgnoreCase(n.get(), text) != null) return true;
    for (a.shape_names[0..a.shape_count]) |*n| if (std.ascii.findIgnoreCase(n.get(), text) != null) return true;
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
