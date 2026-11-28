//! Posing characters from the skeletons plugins hand over each frame. Actors and bones are the scene's
//! `actor` and `bone` kinds, so picking, the gizmo and resetting are the scene's.

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
const Scene = @import("Scene.zig");
const View = @import("View.zig");
const slots = @import("../host/slots.zig");
const Target = slots.Target;
const icons = @import("../ui/icons.zig");
const poses = @import("pose.zig");

const W = api.wraith;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;

/// Listed under it in Settings.
const Show = enum { posed, everyone, nobody };
const show_options = [_][]const u8{ "The one being posed", "Everyone", "No one" };

pub const Press = enum { freeze, focus };

const DragBase = struct { actor: u64, bone: poses.Name, base: Mat4 };

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

/// For the store and what the window keeps between frames.
const gpa = core.heap.named("posing", std.heap.smp_allocator);

registry: *Registry,
overlay: *Overlay,
scene: *Scene,
/// What the game's threads and the render thread share.
lock: Atomic(u32) = .init(0),
/// The thread holding `lock`, so drawing that calls back into posing, like its tools, doesn't wait on
/// itself. 0 for none
lock_owner: Atomic(u64) = .init(0),
/// How many times `lock_owner` has it. Only it touches this
lock_depth: u32 = 0,
/// Whether to bother the game for skeletons
wanted: Atomic(bool) = .init(false),
store: poses.Store = undefined,
/// Actors picked, or with a bone picked, from the scene each frame, for the game's threads
posed: std.ArrayList(u64) = .empty,
show: *Registry.Setting = undefined,
thickness: *Registry.Setting = undefined,
keys: std.EnumArray(Press, Key) = .init(.{
    .freeze = .{ .which = .freeze },
    .focus = .{ .which = .focus },
}),
/// Keys wait for the frame, since the store's the render thread's.
want_freeze: Atomic(bool) = .init(false),
want_focus: Atomic(bool) = .init(false),

// Render thread only from here down

/// Showing the cursor and keeping the keyboard and mouse from the game, like Wraith's own windows
grabbed: bool = false,
/// Where each dragged bone would be without its own edit, as the drag started
drag_bases: std.ArrayList(DragBase) = .empty,
/// The Shapes tab's
link_shapes: bool = true,
changed_only: bool = false,
/// Kept between frames so drawing doesn't allocate each time, as big as the biggest so far
screen: std.ArrayList(?ui.Vec2) = .empty,
rows: std.ArrayList(Row) = .empty,
depths: std.ArrayList(u8) = .empty,
shown_bones: std.ArrayList(u32) = .empty,

/// Keep it where it is, since its keys point at it.
pub fn init(self: *Posing, registry: *Registry, overlay: *Overlay, scene: *Scene) !void {
    self.* = .{ .registry = registry, .overlay = overlay, .scene = scene };
    self.store = .init(gpa);
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
            .freeze => .{ "wraith.posing.freeze", "Freeze or unfreeze the actor being posed", .f8 },
            .focus => .{ "wraith.posing.focus", "Orbit the camera round the picked bone", .keypad_decimal },
        };
        // Focus only does anything while the window's open, so the game keeps the key otherwise
        slot.setting = try registry.add(.{ .id = id, .name = name, .group = Settings.group, .section = Photo.section, .heading = "Posing keys", .kind = .{ .key = .{ .default = .one(.{ .key = key }), .consume = p != .focus } } }, .{ .key = .{ .ctx = slot, .call = Key.fired } });
        bound += 1;
    }
    try scene.add(.{ .slot = .photo_scene, .id = "actors", .parent = "world", .kind = "actors", .title = "Actors", .icon = icons.users, .open = true, .order = 200, .children = .of(self, actorRows) }, .none);
    try scene.add(.{ .slot = .photo_inspector, .id = "actors", .kind = "actors", .presentation = .@"inline", .order = 100 }, .{ .native = .of(self, drawActors) });
    try scene.add(.{ .slot = .photo_inspector, .id = "actor", .kind = "actor", .presentation = .@"inline", .order = 100 }, .{ .native = .of(self, drawActor) });
    try scene.add(.{ .slot = .photo_row, .id = "freeze", .kind = "actor", .order = 100 }, .{ .native = .of(self, actorIcons) });
    try scene.add(.{ .slot = .photo_menu, .id = "actor", .kind = "actor", .order = 100 }, .{ .native = .of(self, actorMenu) });
    try scene.add(.{ .slot = .photo_tools, .id = "actor", .kind = "actor", .order = 200 }, .{ .native = .of(self, actorTools) });
    try scene.addKind(.of("actor", self, ActorKind, .{}));
    try scene.addState(.of(self, PoseState));
    try scene.addKind(.of("bone", self, BoneKind, .{ .inspect_as = "actor", .edit_note = "The change from its animation, in the bone's own axes." }));
}

/// Every bone and shape edit, for undo.
const PoseState = struct {
    pub fn version(self: *Posing) u64 {
        self.acquire();
        defer self.release();
        return self.store.changes;
    }

    pub fn save(self: *Posing, a: std.mem.Allocator) ?[]u8 {
        self.acquire();
        defer self.release();
        return self.store.saveEdits(a) catch null;
    }

    pub fn load(self: *Posing, bytes: []const u8) void {
        self.acquire();
        defer self.release();
        self.store.loadEdits(bytes) catch {};
    }
};

/// What an actor can do in the scene.
const ActorKind = struct {
    pub fn label(self: *Posing, t: Target, buf: []u8) ?[]const u8 {
        self.acquire();
        defer self.release();
        const a = self.store.byId(t.id) orelse return null;
        return std.fmt.bufPrint(buf, "{s}", .{a.name.get()}) catch null;
    }

    pub fn position(self: *Posing, t: Target) ?Vec3 {
        self.acquire();
        defer self.release();
        const a = self.store.byId(t.id) orelse return null;
        return if (a.count > 0) a.position(0) else null;
    }

    pub fn can_reset(self: *Posing, t: Target) bool {
        self.acquire();
        defer self.release();
        return self.store.hasEdits(t.id);
    }

    pub fn reset(self: *Posing, t: Target) void {
        self.acquire();
        defer self.release();
        self.store.resetActor(t.id);
    }
};

/// What a bone can do in the scene: a `boneTarget`, found by its actor and name.
const BoneKind = struct {
    pub fn label(_: *Posing, t: Target, buf: []u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{s}", .{t.name}) catch null;
    }

    pub fn position(self: *Posing, t: Target) ?Vec3 {
        self.acquire();
        defer self.release();
        const a, const b = self.boneOf(t) orelse return null;
        return a.position(b);
    }

    pub fn get_transform(self: *Posing, t: Target) ?Mat4 {
        self.acquire();
        defer self.release();
        const a, const b = self.boneOf(t) orelse return null;
        return a.world[b].mul(a.to_world);
    }

    pub fn set_transform(self: *Posing, t: Target, m: Mat4) void {
        self.acquire();
        defer self.release();
        const a, const b = self.boneOf(t) orelse return;
        const base = self.dragBase(a.id, t.name) orelse self.baseOf(a, b);
        // Back into the bones' space, then less where it'd be anyway, leaves its own edit
        const from_world = a.to_world.inverse() orelse return;
        const undo_base = base.inverse() orelse return;
        if (self.store.edit(a.id, t.name)) |e| e.setMatrix(m.mul(from_world).mul(undo_base));
    }

    pub fn begin_drag(self: *Posing, t: Target) void {
        self.acquire();
        defer self.release();
        const a, const b = self.boneOf(t) orelse return;
        self.drag_bases.append(gpa, .{ .actor = a.id, .bone = a.names[b], .base = self.baseOf(a, b) }) catch {};
    }

    pub fn end_drag(self: *Posing) void {
        self.acquire();
        defer self.release();
        self.drag_bases.clearRetainingCapacity();
    }

    /// Whether `child` is somewhere under `parent` on the same actor.
    pub fn is_under(self: *Posing, child: Target, parent: Target) bool {
        if (child.parent != parent.parent) return false;
        self.acquire();
        defer self.release();
        const a, const c = self.boneOf(child) orelse return false;
        const p = a.find(parent.name) orelse return false;
        var at: i32 = a.parents[c];
        // Parents come first, so this ends
        while (at >= 0 and at < c) : (at = a.parents[@intCast(at)]) {
            if (at == p) return true;
        }
        return false;
    }

    pub fn handles(self: *Posing, sink: *View.Sink) void {
        self.drawSkeletons(sink);
    }

    /// Its change from its animation, which is what the boxes show.
    pub fn edit(self: *Posing, t: Target) ?Scene.Local {
        self.acquire();
        defer self.release();
        _ = self.boneOf(t) orelse return null;
        return if (self.store.findEdit(t.parent, t.name)) |e| e.local() else .{};
    }

    pub fn set_edit(self: *Posing, t: Target, l: Scene.Local) void {
        self.acquire();
        defer self.release();
        var e: poses.Edit = .{ .actor = t.parent, .bone = .init(t.name) };
        e.setLocal(l);
        setEdit(&self.store, e);
    }

    pub fn can_reset(self: *Posing, t: Target) bool {
        self.acquire();
        defer self.release();
        return self.store.findEdit(t.parent, t.name) != null;
    }

    pub fn reset(self: *Posing, t: Target) void {
        self.acquire();
        defer self.release();
        self.store.resetBone(t.parent, t.name);
    }
};

/// Where bone `b` would be without its own edit, in the bones' space. Under the lock.
fn baseOf(self: *Posing, a: *const poses.Actor, b: u32) Mat4 {
    const own = if (self.store.findEdit(a.id, a.names[b].get())) |e| e.matrix() else Mat4.identity;
    return (own.inverse() orelse Mat4.identity).mul(a.world[b]);
}

fn dragBase(self: *const Posing, actor: u64, bone: []const u8) ?Mat4 {
    for (self.drag_bases.items) |*d| if (d.actor == actor and d.bone.eql(bone)) return d.base;
    return null;
}

/// Waits for keys in flight. Game plugins may still call in, so the store stays till the end.
pub fn deinit(self: *Posing) void {
    for (std.enums.values(Press)) |p| self.registry.remove(self.keys.getPtr(p).setting);
    self.registry.remove(self.show);
    self.registry.remove(self.thickness);
    self.grab(false);
    self.wanted.store(false, .monotonic);
    // `posed` stays with the store, since game plugins may still ask
    self.drag_bases.deinit(gpa);
    self.screen.deinit(gpa);
    self.rows.deinit(gpa);
    self.depths.deinit(gpa);
    self.shown_bones.deinit(gpa);
}

fn acquire(self: *Posing) void {
    const me: u64 = @intCast(std.Thread.getCurrentId());
    if (self.lock_owner.load(.monotonic) == me) {
        self.lock_depth += 1;
        return;
    }
    while (self.lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    self.lock_owner.store(me, .monotonic);
    self.lock_depth = 1;
}

fn release(self: *Posing) void {
    self.lock_depth -= 1;
    if (self.lock_depth > 0) return;
    self.lock_owner.store(0, .monotonic);
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
    return self.isPosed(actor) or self.store.hasEdits(actor);
}

/// Picked, or one of its bones is. Under the lock.
fn isPosed(self: *const Posing, actor: u64) bool {
    return std.mem.indexOfScalar(u64, self.posed.items, actor) != null;
}

/// Drops what `owner` handed over, when it's going.
pub fn forget(self: *Posing, owner: usize) void {
    self.acquire();
    defer self.release();
    self.store.forgetOwner(owner);
}

// Render thread from here

fn pressed(self: *Posing, which: Press) void {
    switch (which) {
        .freeze => self.want_freeze.store(true, .release),
        .focus => self.want_focus.store(true, .release),
    }
}

/// The active actor's frozen or not, by its key.
fn toggleFrozen(self: *Posing) void {
    self.acquire();
    defer self.release();
    const a = self.current(&self.store) orelse return;
    setFrozen(a, !a.frozen);
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

/// Once a frame, with whether Photo mode's open.
pub fn tick(self: *Posing, open: bool) void {
    if (self.want_freeze.swap(false, .acq_rel)) self.toggleFrozen();
    // Focus only does anything while it's open
    if (self.want_focus.swap(false, .acq_rel) and open) self.scene.focusActive();
    self.grab(open);
    self.draw(open);
}

fn draw(self: *Posing, open: bool) void {
    const waited = core.timing.scope("posing lock");
    self.acquire();
    waited.end();
    defer self.release();
    self.syncPicked();
    const store = &self.store;
    store.frame +%= 1;
    self.wanted.store(open or store.anyEdits() or store.anyFrozen(), .monotonic);
    if (!open) return;
    // The game's plugin sets it each frame
    const v = frame.view();
    if (v.known) store.setCamera(v.viewMatrix, v.projection) else store.view_proj = null;
}

/// The active actor, or the active bone's, if it's still around. Under the lock.
fn current(self: *Posing, store: *poses.Store) ?*poses.Actor {
    const t = self.scene.active() orelse return null;
    const id = actorOf(t) orelse return null;
    const a = store.byId(id) orelse return null;
    return if (store.isLive(a)) a else null;
}

/// The actor an actor or bone target is on.
fn actorOf(t: Target) ?u64 {
    if (std.mem.eql(u8, t.kind, "actor")) return t.id;
    if (std.mem.eql(u8, t.kind, "bone")) return t.parent;
    return null;
}

/// The active bone, if it's on `a`.
fn currentBone(self: *Posing, a: *const poses.Actor) ?u32 {
    const t = self.scene.active() orelse return null;
    if (!std.mem.eql(u8, t.kind, "bone") or t.parent != a.id) return null;
    return a.find(t.name);
}

/// Picks `a` in the scene, or `bone` on it. Under the lock.
pub fn select(self: *Posing, a: *const poses.Actor, bone: ?u32) void {
    self.scene.selectTarget(if (bone) |b| boneTarget(a, b) else .{ .kind = "actor", .id = a.id });
    self.syncPicked();
}

/// Which actors the scene's picks are on, so the game's threads see them. Under the lock.
fn syncPicked(self: *Posing) void {
    self.posed.clearRetainingCapacity();
    for (self.scene.picked.items) |*k| {
        const id = actorOf(k.target()) orelse continue;
        if (!self.isPosed(id)) self.posed.append(gpa, id) catch break;
    }
}

/// Every live actor's bones over the game, clickable, dimmed when others are being posed.
fn drawSkeletons(self: *Posing, sink: *View.Sink) void {
    const t = core.timing.scope("posing skeletons");
    defer t.end();
    self.acquire();
    defer self.release();
    const store = &self.store;
    const show = choice(Show, self.registry.get(self.show).choice, &show_options);
    const thickness: f32 = @floatCast(self.registry.get(self.thickness).number);
    const anyone = self.posed.items.len > 0;
    for (store.actors.items) |a| {
        if (!store.isLive(a)) continue;
        const is_posed = self.isPosed(a.id);
        if (show == .nobody or (show == .posed and !is_posed)) continue;
        // Each bone once, since it's a parent to its children's lines too
        self.screen.resize(gpa, a.count) catch continue;
        const screen = self.screen.items;
        for (0..a.count) |i| {
            screen[i] = sink.project(a.position(i));
            const at = screen[i] orelse continue;
            const p = a.parents[i];
            if (p >= 0 and p < i) {
                if (screen[@intCast(p)]) |from| sink.draw_list.addLine(from, at, if (is_posed or !anyone) bone_colour else dim_colour, thickness);
            }
            if (is_posed) sink.draw_list.addCircleFilled(at, thickness + 1.5, joint_colour);
            sink.point(boneTarget(a, @intCast(i)), at);
        }
    }
}

// Photo mode's window, on the render thread. Each takes the lock itself.

/// An actor's row, copied out so rows draw unlocked, since their buttons lock.
const Row = struct { id: u64, name: poses.Name, edited: bool };

/// The actors under the Actors node.
fn actorRows(self: *Posing, _: Target) void {
    const scene = self.scene;
    self.rows.clearRetainingCapacity();
    var live: usize = 0;
    {
        self.acquire();
        defer self.release();
        const store = &self.store;
        const text = scene.searchText();
        for (store.actors.items) |a| {
            if (!store.isLive(a)) continue;
            live += 1;
            // The one being posed stays, so searching never hides it
            if (!self.isPosed(a.id) and !matchesActor(a, text)) continue;
            self.rows.append(gpa, .{ .id = a.id, .name = a.name, .edited = store.hasEdits(a.id) }) catch break;
        }
    }
    const rows = self.rows.items;
    const n = rows.len;
    for (rows[0..n]) |*r| _ = scene.row("actor", r.id, icons.user, "{s}{s}", .{ r.name.get(), if (r.edited) " *" else "" });
    if (live == 0) {
        ui.textDisabled("None yet", .{});
        ui.tooltip("Posing needs a plugin for this game, or its engine, that hands it skeletons.", .{});
    } else if (n == 0) ui.textDisabled("Nothing's called that", .{});
}

/// Freezing, on each actor's row.
fn actorIcons(self: *Posing, key: Target) void {
    self.acquire();
    defer self.release();
    const a = self.store.byId(key.id) orelse return Scene.skipIcon();
    if (Scene.rowIcon(icons.snowflake ++ "##freeze", a.frozen, "{s} the actor", .{if (a.frozen) "Unfreeze" else "Freeze"})) setFrozen(a, !a.frozen);
}

/// Freezing, in an actor's right-click menu. The scene adds focusing, resetting and copying.
fn actorMenu(self: *Posing, key: Target) void {
    self.acquire();
    defer self.release();
    const a = self.store.byId(key.id) orelse return;
    if (ui.menuItem(if (a.frozen) "Unfreeze" else "Freeze", .{})) setFrozen(a, !a.frozen);
}

/// What Actors itself shows: how to pick one.
fn drawActors(self: *Posing, _: Target) void {
    self.acquire();
    defer self.release();
    var live: usize = 0;
    for (self.store.actors.items) |a| live += @intFromBool(self.store.isLive(a));
    if (live == 0) return ui.textWrapped("Nothing to pose yet. Posing needs a plugin for this game, or its engine, that hands it skeletons.", .{});
    ui.textDisabled("{d} in the scene. Pick one from the list, or click on a bone in the game.", .{live});
}

/// The picked actor's tools, bones and shapes.
fn drawActor(self: *Posing, key: Target) void {
    self.acquire();
    defer self.release();
    self.syncPicked();
    const store = &self.store;
    const a = store.byId(key.id) orelse return ui.textDisabled("That actor's gone.", .{});
    if (!store.isLive(a)) return ui.textDisabled("That actor's gone.", .{});
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

/// A bone as `photo.tools` and `photo.menu` see it: by its place, its actor and its name.
fn boneTarget(a: *const poses.Actor, bone: u32) Target {
    return .{ .kind = "bone", .id = bone, .parent = a.id, .name = a.names[bone].get() };
}

/// The bone a `boneTarget` names, if it's still there. Under the lock.
fn boneOf(self: *Posing, key: Target) ?struct { *poses.Actor, u32 } {
    const a = self.store.byId(key.parent) orelse return null;
    return .{ a, a.find(key.name) orelse return null };
}

/// Freezing the whole actor. The scene adds focusing and resetting.
fn actorTools(self: *Posing, key: Target) void {
    self.acquire();
    defer self.release();
    const a = self.store.byId(key.id) orelse return;
    if (Photo.toolButton(icons.snowflake ++ "##posing_freeze", a.frozen, "{s} the actor. {s}", .{ if (a.frozen) "Unfreeze" else "Freeze", self.keyName(.freeze) })) setFrozen(a, !a.frozen);
}

fn bonesTab(self: *Posing, store: *poses.Store, a: *poses.Actor) void {
    // Above the list, so it takes what's left
    if (self.currentBone(a) == null) ui.textDisabled("Pick a bone, here or by clicking on it", .{});
    if (ui.child("bones", .{ 0, 0 }, .{ .border = true })) |c| {
        defer c.end();
        self.boneList(store, a);
    }
}

/// Stores `edit`, or drops it if it does nothing.
fn setEdit(store: *poses.Store, edit: poses.Edit) void {
    const bone = edit.bone.get();
    if (edit.isNothing()) return store.resetBone(edit.actor, bone);
    const e = store.edit(edit.actor, bone) orelse return ui.textDisabled("Too many posed bones", .{});
    e.* = edit;
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
    ui.textDisabled("Ctrl-click a slider to type, even past 0 or 1. Right-click to reset. Some games' shapes are only on or off.", .{});

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
        const asked = if (a.shape_toggles[i]) blk: {
            // On or off only, like FFXIV's
            var on = weight >= 0.5;
            const clicked = ui.checkbox(label, &on);
            weight = if (on) 1 else 0;
            break :blk clicked;
        } else ui.sliderWith(label, &weight, 0, 1, .{ .format = "%.2f" });
        if (asked) {
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

/// The bones as an indented tree, filtered while searching.
fn boneList(self: *Posing, store: *poses.Store, a: *const poses.Actor) void {
    self.depths.resize(gpa, a.count) catch return;
    const depth = self.depths.items;
    // What's shown, which is every bone unless searching
    self.shown_bones.resize(gpa, a.count) catch return;
    const rows = self.shown_bones.items;
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
        const t = boneTarget(a, i);
        if (ui.selectable(label, self.scene.isPicked(t))) self.clickBone(a, i, picked, rows[0..n]);
        // Picked by a right-click too, so what the menu's for is what's shown, keeping the rest if it's one of them
        if (ui.isItemClicked(.right) and !self.scene.isPicked(t)) self.select(a, i);
        const scope = ui.id(@as(i32, @intCast(i)));
        defer scope.end();
        // What bones can do, and the `photo.menu` items for them, Wraith's and plugins'
        if (self.scene.hasMenu("bone")) if (ui.contextMenu("##bone")) |m| {
            defer m.end();
            self.scene.drawMenu(t);
        };
    }
}

/// Shift picks every bone shown from the active one to `i`; otherwise as the scene picks.
fn clickBone(self: *Posing, a: *const poses.Actor, i: u32, from: ?u32, rows: []const u32) void {
    if (self.scene.mods().shift) if (from) |f| {
        const x = std.mem.indexOfScalar(u32, rows, f) orelse return self.scene.pick(boneTarget(a, i));
        const y = std.mem.indexOfScalar(u32, rows, i) orelse return;
        // Toward `i`, so it ends up active
        var r = x;
        while (true) {
            self.scene.addPick(boneTarget(a, rows[r]));
            if (r == y) break;
            if (y > x) r += 1 else r -= 1;
        }
        return;
    };
    self.scene.pick(boneTarget(a, i));
}

fn searchText(self: *const Posing) []const u8 {
    return self.scene.searchText();
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

/// Which of `options` it's on, as `E`'s values in the same order.
fn choice(comptime E: type, value: []const u8, options: []const []const u8) E {
    for (options, 0..) |o, i| if (std.mem.eql(u8, o, value)) return @fromBackingInt(@intCast(i));
    return @fromBackingInt(0);
}

test {
    _ = poses;
}
