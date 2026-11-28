//! Cameras in Photo mode's scene, under World: the game's main camera, any its plugin lists, which
//! one's on screen, and the free camera, which moves whichever that is.

const Cameras = @This();

const std = @import("std");
const math = @import("tuft_math");
const core = @import("wraith_core");
const Atomic = @import("tuft_arch").atomic.Value;
const ui = @import("wraith_ui");

const lists = @import("../host/lists.zig");
const icons = @import("../ui/icons.zig");
const Camera = @import("Camera.zig");
const Scene = @import("Scene.zig");
const slots = @import("../host/slots.zig");
const Target = slots.Target;

/// The game's own view, or the plugin's pick of its cameras. Listed ones are never 0.
const main_id = 0;

scene: *Scene,
camera: *Camera,
/// A listed camera's on screen rather than the main one. Off each time the game starts. Any thread.
follow: Atomic(bool) = .init(false),

pub fn init(self: *Cameras, scene: *Scene, camera: *Camera) !void {
    self.* = .{ .scene = scene, .camera = camera };
    try scene.add(.{ .slot = .photo_scene, .id = "cameras", .parent = "world", .kind = "cameras", .title = "Cameras", .icon = icons.video, .open = true, .order = 100, .children = .of(self, rows) }, .none);
    try scene.add(.{ .slot = .photo_inspector, .id = "cameras", .kind = "cameras", .presentation = .@"inline", .order = 100 }, .{ .native = .of(self, drawFolder) });
    try scene.add(.{ .slot = .photo_inspector, .id = "camera", .kind = "camera", .presentation = .@"inline", .order = 100 }, .{ .native = .of(self, drawCamera) });
    // Till a plugin for the game adds its own
    try scene.add(.{ .slot = .photo_inspector, .id = "look", .kind = "camera", .title = "Look", .presentation = .foldout, .open = true, .order = 400, .fallback = true }, .{ .native = .of(self, drawNoLook) });
    try scene.add(.{ .slot = .photo_row, .id = "add_camera", .kind = "cameras", .order = 100 }, .{ .native = .of(self, addIcon) });
    try scene.add(.{ .slot = .photo_row, .id = "free_camera", .kind = "camera", .order = 100 }, .{ .native = .of(self, freeIcon) });
    try scene.add(.{ .slot = .photo_row, .id = "view_camera", .kind = "camera", .order = 200 }, .{ .native = .of(self, viewIcon) });
    try scene.add(.{ .slot = .photo_menu, .id = "camera", .kind = "camera", .order = 100 }, .{ .native = .of(self, cameraMenu) });
    // Boxes but no gizmo, which would sit on the eye of the one being looked through
    try scene.addKind(.of("camera", self, CameraKind, .{ .parts = .{ .scale = false }, .gizmo = false }));
}

/// What a camera can do in the scene. Only listed ones have names or can go.
const CameraKind = struct {
    pub fn label(_: *Cameras, t: Target, buf: []u8) ?[]const u8 {
        if (t.id == main_id) return null;
        const held = lists.cameras() orelse return null;
        defer held.end();
        var arena: std.heap.ArenaAllocator = .init(core.heap.main);
        defer arena.deinit();
        const snap = held.record.snapshot(arena.allocator()) orelse return null;
        for (snap.items) |it| if (it.id == t.id) return std.fmt.bufPrint(buf, "{s}", .{it.name}) catch null;
        return null;
    }

    pub fn can_remove(_: *Cameras, t: Target) bool {
        if (t.id == main_id) return false;
        const held = lists.cameras() orelse return false;
        defer held.end();
        var arena: std.heap.ArenaAllocator = .init(core.heap.main);
        defer arena.deinit();
        const snap = held.record.snapshot(arena.allocator()) orelse return false;
        return snap.has.remove;
    }

    pub fn remove(_: *Cameras, t: Target) void {
        const held = lists.cameras() orelse return;
        defer held.end();
        held.record.callRemove(t.id);
    }

    /// The one on screen, since that's what the free camera moves.
    pub fn get_transform(self: *Cameras, t: Target) ?math.Mat4 {
        if (t.id != self.onScreen()) return null;
        return self.camera.transform();
    }

    pub fn set_transform(self: *Cameras, t: Target, m: math.Mat4) void {
        if (t.id != self.onScreen()) return;
        self.camera.setTransform(m);
    }
};

/// The listed camera `loaded` should put on screen, or 0 for its main one. Any thread.
pub fn wantedCamera(self: *Cameras, loaded: *const anyopaque) u64 {
    const held = lists.cameras() orelse return 0;
    defer held.end();
    if (@as(*const anyopaque, held.record.loaded) != loaded) return 0;
    return self.viewed(held.record);
}

/// The listed one on screen, or 0 for the main one.
fn viewed(self: *Cameras, record: *lists.Record) u64 {
    if (!self.follow.load(.acquire)) return 0;
    return record.firstSelected();
}

/// Which row's on screen, by id: the main one unless a listed one's been put there.
fn onScreen(self: *Cameras) u64 {
    const held = lists.cameras() orelse return main_id;
    defer held.end();
    return self.viewed(held.record);
}

/// Puts `id` on screen, the main one for 0. Like radio buttons, one's always there.
fn show(self: *Cameras, id: u64) void {
    if (id == main_id) return self.follow.store(false, .release);
    const held = lists.cameras() orelse return;
    defer held.end();
    held.record.select(id);
    self.follow.store(true, .release);
}

/// Whether the plugin lists cameras to pick from.
fn listed() bool {
    const held = lists.cameras() orelse return false;
    held.end();
    return true;
}

/// The main camera, then any the plugin lists.
fn rows(self: *Cameras, _: Target) void {
    const scene = self.scene;
    const on = self.onScreen();
    // Which is on screen only says something when there's more than one
    const several = listed();
    if (scene.matches("Main camera")) {
        _ = scene.row("camera", main_id, icons.camera, "Main camera{s}", .{note(several and on == main_id)});
        ui.tooltip("The game's own view{s}", .{if (listed()) ", or whichever of its cameras it picks" else ""});
    }
    const held = lists.cameras() orelse return;
    defer held.end();
    var arena: std.heap.ArenaAllocator = .init(core.heap.main);
    defer arena.deinit();
    const snap = held.record.snapshot(arena.allocator()) orelse return;
    for (snap.items) |it| {
        if (!scene.matches(it.name)) continue;
        _ = scene.row("camera", it.id, icons.camera, "{s}{s}", .{ it.name, note(several and on == it.id) });
        if (it.detail.len > 0) ui.tooltip("{s}", .{it.detail});
    }
}

fn note(on_screen: bool) []const u8 {
    return if (on_screen) "  (On screen)" else "";
}

/// Add, on the Cameras row, when the plugin makes cameras.
fn addIcon(_: *Cameras, _: Target) void {
    const held = lists.cameras() orelse return Scene.skipIcon();
    defer held.end();
    var arena: std.heap.ArenaAllocator = .init(core.heap.main);
    defer arena.deinit();
    const snap = held.record.snapshot(arena.allocator()) orelse return Scene.skipIcon();
    if (!snap.has.add) return Scene.skipIcon();
    if (Scene.rowIcon(icons.plus ++ "##add", false, "Add a camera where the view is", .{})) held.record.callAdd();
}

/// The free camera's switch, on whichever camera's on screen, since that's what it moves.
fn freeIcon(self: *Cameras, key: Target) void {
    const cam = self.camera;
    if (key.id != self.onScreen() or !cam.hasCamera()) return Scene.skipIcon();
    var buf: [96]u8 = undefined;
    const on = cam.isOn();
    if (Scene.rowIcon(if (on) icons.video ++ "##free" else icons.video_off ++ "##free", on, "{s} the free camera. {s}", .{ if (on) "Stop" else "Start", cam.toggleKeyName(&buf) })) cam.flip();
}

/// Which camera's on screen, one at a time. Only when the plugin lists some to pick from.
fn viewIcon(self: *Cameras, key: Target) void {
    if (!listed()) return Scene.skipIcon();
    const on = self.onScreen() == key.id;
    const tip = if (on) "On screen" else if (key.id == main_id) "Let the game pick" else "Show this one";
    if (Scene.rowIcon(if (on) icons.eye ++ "##view" else icons.eye_off ++ "##view", on, "{s}", .{tip}) and !on) self.show(key.id);
}

/// Showing a camera and the free camera, in its right-click menu. The scene adds copying and removing.
fn cameraMenu(self: *Cameras, key: Target) void {
    const on_screen = self.onScreen() == key.id;
    if (listed() and ui.menuItem(if (key.id == main_id) "Let the game pick" else "Show this one", .{ .enabled = !on_screen })) self.show(key.id);
    const cam = self.camera;
    var on = cam.isOn();
    if (ui.menuItem("Free camera", .{ .checked = &on, .enabled = on_screen and cam.hasCamera() })) cam.flip();
}

/// Wraith's own Look, till a plugin for the game has one.
fn drawNoLook(_: *Cameras, _: Target) void {
    ui.textWrapped("This game doesn't support camera look settings.", .{});
    ui.textDisabled("No plugin for it changes exposure, colour or effects.", .{});
}

/// Cameras itself has nothing of its own.
fn drawFolder(_: *Cameras, _: Target) void {
    ui.textDisabled("Pick a camera to move it freely, or to put it on screen.", .{});
}

/// A camera: what it is, putting it on screen, and the free camera while it's there.
fn drawCamera(self: *Cameras, key: Target) void {
    const on_screen = self.onScreen() == key.id;
    if (key.id == main_id) {
        ui.separatorText("Main camera");
        ui.textWrapped("The game's own view{s}.", .{if (listed()) ", or whichever of its cameras it picks" else ""});
        self.showButton(key.id, on_screen);
    } else if (!self.drawListed(key.id, on_screen)) return;
    self.drawFree(on_screen);
}

fn showButton(self: *Cameras, id: u64, on_screen: bool) void {
    if (on_screen) return ui.textDisabled("On screen.", .{});
    if (ui.button(if (id == main_id) "Let the game pick" else "Show this one")) self.show(id);
}

/// One of the cameras the plugin lists. False if it's gone.
fn drawListed(self: *Cameras, id: u64, on_screen: bool) bool {
    const held = lists.cameras() orelse {
        ui.textDisabled("The game's cameras are gone.", .{});
        return false;
    };
    defer held.end();
    const record = held.record;
    var arena: std.heap.ArenaAllocator = .init(core.heap.main);
    defer arena.deinit();
    const snap = record.snapshot(arena.allocator()) orelse return false;
    const it = for (snap.items) |it| {
        if (it.id == id) break it;
    } else {
        ui.textDisabled("That camera's gone.", .{});
        return false;
    };
    // The rename popup's opened and drawn under the list's id
    const scope = ui.id(@as(*const lists.Record, record));
    defer scope.end();
    ui.separatorText(arena.allocator().dupeSentinel(u8, it.name, 0) catch "Camera");
    if (it.detail.len > 0) ui.textWrapped("{s}", .{it.detail});
    self.showButton(id, on_screen);
    if (snap.has.rename) {
        ui.sameLine();
        if (ui.button("Rename")) record.startRename(it);
    }
    if (snap.has.remove) {
        ui.sameLine();
        if (ui.button("Remove")) record.callRemove(it.id);
    }
    record.drawRename();
    return true;
}

/// The free camera, which only moves the camera that's on screen.
fn drawFree(self: *Cameras, on_screen: bool) void {
    const cam = self.camera;
    ui.separatorText("Free camera");
    if (!cam.hasCamera()) {
        ui.textWrapped("No camera yet. The free camera needs a plugin for this game, or its engine, that hands it the camera.", .{});
        return;
    }
    if (!on_screen) ui.textDisabled("Show this one to move it freely.", .{});
    const away = ui.disabled(!on_screen);
    defer away.end();
    var buf: [96]u8 = undefined;
    var on = cam.isOn();
    if (ui.checkbox("On", &on)) cam.flip();
    ui.sameLine();
    ui.textDisabled("{s}", .{cam.toggleKeyName(&buf)});
    {
        const off = ui.disabled(!cam.isOn());
        defer off.end();
        const orbiting = cam.isOrbiting();
        if (ui.raw("ImGui_RadioButton")("Fly", !orbiting) and orbiting) cam.setOrbiting(false, null);
        ui.sameLine();
        if (ui.raw("ImGui_RadioButton")("Orbit", orbiting) and !orbiting) cam.setOrbiting(true, null);
        ui.sameLine();
        ui.textDisabled("{s}", .{cam.orbitKeyName(&buf)});
        ui.tooltip("Orbit circles round where you're looking, or the bone you focus on.", .{});
        if (ui.button("Level")) cam.level();
        ui.sameLine();
        ui.textDisabled("{s}", .{cam.levelKeyName(&buf)});
        if (cam.fovDegrees()) |degrees| {
            var fov = degrees;
            ui.setNextItemWidth(160);
            if (ui.sliderWith("Field of view", &fov, 5, 150, .{ .format = "%.0f°" })) cam.setFov(fov);
            var keys: [200]u8 = undefined;
            ui.tooltip("Zoom in and out with {s}. Ctrl-click to type.", .{cam.zoomKeyNames(&keys)});
            ui.sameLine();
            if (ui.smallButton("Game's")) cam.resetFov();
            ui.tooltip("Back to the field of view the game had.", .{});
        }
    }
    ui.textDisabled("Its speed, smoothing and keys are in Settings, under Photo mode.", .{});
}
