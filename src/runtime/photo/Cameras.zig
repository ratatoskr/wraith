//! Cameras in Photo mode's scene, under World: the free camera, the game's cameras from its plugin's
//! list, and which of them is on screen.

const Cameras = @This();

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;
const ui = @import("wraith_ui");

const lists = @import("../host/lists.zig");
const icons = @import("../ui/icons.zig");
const Camera = @import("Camera.zig");
const Scene = @import("Scene.zig");
const slots = @import("../host/slots.zig");
const Target = slots.Target;

scene: *Scene,
camera: *Camera,
/// The list's pick goes on screen. Off, the game decides. Off each time the game starts. Any thread.
follow: Atomic(bool) = .init(false),

pub fn init(self: *Cameras, scene: *Scene, camera: *Camera) !void {
    self.* = .{ .scene = scene, .camera = camera };
    try scene.add(.{ .slot = .photo_scene, .id = "cameras", .parent = "world", .kind = "cameras", .title = "Cameras", .icon = icons.video, .open = true, .order = 100, .children = .of(self, rows) }, .none);
    try scene.add(.{ .slot = .photo_inspector, .id = "free_camera", .kind = "cameras", .presentation = .@"inline", .order = 100 }, .{ .native = .of(self, drawFree) });
    try scene.add(.{ .slot = .photo_inspector, .id = "camera", .kind = "camera", .presentation = .@"inline", .order = 100 }, .{ .native = .of(self, drawGame) });
    try scene.add(.{ .slot = .photo_row, .id = "add_camera", .kind = "cameras", .order = 100 }, .{ .native = .of(self, addIcon) });
    try scene.add(.{ .slot = .photo_row, .id = "view_camera", .kind = "camera", .order = 100 }, .{ .native = .of(self, viewIcon) });
}

/// The camera `loaded` should put on screen, or 0 for the game's own. Any thread.
pub fn wantedCamera(self: *Cameras, loaded: *const anyopaque) u64 {
    const held = lists.cameras() orelse return 0;
    defer held.end();
    if (@as(*const anyopaque, held.record.loaded) != loaded) return 0;
    return self.viewed(held.record);
}

/// The one put on screen, or 0 when the game decides.
fn viewed(self: *Cameras, record: *lists.Record) u64 {
    if (!self.follow.load(.acquire)) return 0;
    return record.firstSelected();
}

/// Puts `id` on screen, or hands the choice back to the game if it's there already.
fn toggleView(self: *Cameras, record: *lists.Record, id: u64) void {
    if (self.viewed(record) == id) return self.follow.store(false, .release);
    record.select(id);
    self.follow.store(true, .release);
}

fn rows(self: *Cameras, _: Target) void {
    const scene = self.scene;
    const held = lists.cameras() orelse return;
    defer held.end();
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const snap = held.record.snapshot(arena.allocator()) orelse return;
    for (snap.items) |it| {
        if (!scene.matches(it.name)) continue;
        const note = if (it.current) "  (On screen)" else "";
        _ = scene.row("camera", it.id, icons.camera, "{s}{s}", .{ it.name, note });
        if (it.detail.len > 0) ui.tooltip("{s}", .{it.detail});
    }
}

/// Add, on the Cameras row, when the plugin makes cameras.
fn addIcon(_: *Cameras, _: Target) void {
    const held = lists.cameras() orelse return Scene.skipIcon();
    defer held.end();
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const snap = held.record.snapshot(arena.allocator()) orelse return Scene.skipIcon();
    if (!snap.has.add) return Scene.skipIcon();
    if (Scene.rowIcon(icons.plus ++ "##add", false, "Add a camera where the view is", .{})) held.record.callAdd();
}

/// On screen or not, on each camera's row.
fn viewIcon(self: *Cameras, key: Target) void {
    const held = lists.cameras() orelse return Scene.skipIcon();
    defer held.end();
    const on = self.viewed(held.record) == key.id;
    if (Scene.rowIcon(if (on) icons.eye ++ "##view" else icons.eye_off ++ "##view", on, "{s}", .{if (on) "Showing this one. Click to let the game pick" else "Show this one"})) self.toggleView(held.record, key.id);
}

/// The free camera, when Cameras itself is picked.
fn drawFree(self: *Cameras, _: Target) void {
    const cam = self.camera;
    if (!cam.hasCamera()) {
        ui.textWrapped("No camera yet. The free camera needs a plugin for this game, or its engine, that hands it the camera.", .{});
        return;
    }
    var buf: [96]u8 = undefined;
    ui.separatorText("Free camera");
    var on = cam.isOn();
    if (ui.checkbox("On", &on)) cam.flip();
    ui.sameLine();
    ui.textDisabled("{s}", .{cam.toggleKeyName(&buf)});
    {
        const not_on = ui.disabled(!cam.isOn());
        defer not_on.end();
        var orbiting = cam.isOrbiting();
        if (ui.checkbox("Orbit", &orbiting)) cam.setOrbiting(orbiting, null);
        ui.sameLine();
        ui.textDisabled("{s}", .{cam.orbitKeyName(&buf)});
        if (ui.button("Level")) cam.level();
        ui.sameLine();
        ui.textDisabled("{s}", .{cam.levelKeyName(&buf)});
    }
    ui.textDisabled("It moves whichever camera's on screen.", .{});
    if (lists.cameras()) |held| {
        defer held.end();
        const following = self.viewed(held.record) != 0;
        ui.separatorText("On screen");
        ui.textDisabled("{s}", .{if (following) "The one you picked with its eye." else "Whichever the game picks."});
        if (following and ui.button("Let the game pick")) self.follow.store(false, .release);
    }
    ui.separatorText("Keys");
    cam.drawKeyList();
    ui.textDisabled("Its speed, smoothing and keys are in Settings, under Photo mode.", .{});
}

/// One of the game's cameras.
fn drawGame(self: *Cameras, key: Target) void {
    const held = lists.cameras() orelse return ui.textDisabled("The game's cameras are gone.", .{});
    defer held.end();
    const record = held.record;
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const snap = record.snapshot(arena.allocator()) orelse return;
    const it = for (snap.items) |it| {
        if (it.id == key.id) break it;
    } else return ui.textDisabled("That camera's gone.", .{});

    // The rename popup's opened and drawn under the list's id
    const scope = ui.id(@as(*const lists.Record, record));
    defer scope.end();
    var title: [80:0]u8 = undefined;
    ui.separatorText(std.fmt.bufPrintSentinel(&title, "{s}", .{it.name}, 0) catch "Camera");
    if (it.detail.len > 0) ui.textWrapped("{s}", .{it.detail});
    if (it.current) ui.textDisabled("The game has it on screen.", .{});
    var on = self.viewed(record) == it.id;
    if (ui.checkbox("Show this one", &on)) self.toggleView(record, it.id);
    ui.tooltip("Off, the game picks which camera's on screen.", .{});
    if (snap.has.rename) {
        if (ui.button("Rename")) record.startRename(it);
        if (snap.has.remove) ui.sameLine();
    }
    if (snap.has.remove and ui.button("Remove")) record.callRemove(it.id);
    record.drawRename();
}
