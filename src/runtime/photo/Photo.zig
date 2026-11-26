//! Photo mode: the free camera, posing, pausing and screenshots in one window, over one scene.

const Photo = @This();

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;
const tuft_input = @import("tuft_input");
const Keybinds = tuft_input.Keybinds;

const core = @import("wraith_core");
const ui = @import("wraith_ui");

const Registry = @import("../settings/Registry.zig");
const Settings = @import("../Settings.zig");
const Overlay = @import("../ui/Overlay.zig");
const Screenshot = @import("../Screenshot.zig");
const GameSpeed = @import("../ui/GameSpeed.zig");
const icons = @import("../ui/icons.zig");
pub const Scene = @import("Scene.zig");
pub const Camera = @import("Camera.zig");
pub const Cameras = @import("Cameras.zig");
pub const Posing = @import("Posing.zig");
const slots = @import("../host/slots.zig");
const Target = slots.Target;

/// Where the camera's and posing's settings and keys are, among Wraith's own.
pub const section = "Photo mode";

allocator: std.mem.Allocator,
registry: *Registry,
overlay: *Overlay,
scene: Scene,
camera: Camera = undefined,
cameras: Cameras = undefined,
posing: Posing = undefined,
speed: GameSpeed = .{},
/// The shell's, for the toolbar's button
screenshot: ?*Screenshot = null,
scope: core.Scope,
/// Opens and closes it. Posing's id still, so bindings carry over
window_key: *Registry.Setting = undefined,
/// Whether it's open, from any thread.
open: Atomic(bool) = .init(false),
/// The shell's, so the key opens it. Render thread.
window: ?*Window = null,
/// Whether it was open last frame, to tell which side opened or closed it.
was_open: bool = false,

pub fn create(allocator: std.mem.Allocator, registry: *Registry, overlay: *Overlay, keybinds: *Keybinds) !*Photo {
    const self = try allocator.create(Photo);
    errdefer allocator.destroy(self);
    self.* = .{ .allocator = allocator, .registry = registry, .overlay = overlay, .scene = .init(allocator), .scope = .init(allocator) };
    errdefer self.scope.deinit();
    errdefer self.scene.deinit();
    try self.scene.add(.{ .slot = .photo_scene, .id = "world", .kind = "world", .title = "World", .icon = icons.globe, .open = true, .order = 100 }, .none);
    try self.scene.add(.{ .slot = .photo_inspector, .id = "world", .kind = "world", .presentation = .@"inline", .order = 100 }, .{ .native = .of(self, drawWorld) });
    inline for (.{ .{ "camera", drawCameraTools }, .{ "speed", drawSpeedTool }, .{ "overlay", drawOverlayTool }, .{ "screenshot", drawScreenshotTool } }, 1..) |t, i| {
        try self.scene.add(.{ .slot = .photo_toolbar, .id = t[0], .order = i * 100 }, .{ .native = .of(self, t[1]) });
    }
    try self.camera.init(registry, overlay, keybinds);
    errdefer self.camera.deinit();
    try self.cameras.init(&self.scene, &self.camera);
    try self.posing.init(registry, overlay, &self.scene);
    errdefer self.posing.deinit();
    self.window_key = try registry.add(.{ .id = "wraith.posing.window", .name = "Open or close Photo mode", .group = Settings.group, .section = section, .heading = "Window", .kind = .{ .key = .{ .default = .one(.{ .key = .f7 }), .consume = true } } }, .{ .key = .{ .ctx = self, .call = windowKey } });
    errdefer registry.remove(self.window_key);
    try overlay.update.subscribe(&self.scope, self, update);
    return self;
}

pub fn destroy(self: *Photo) void {
    // Waits for a frame in flight
    self.scope.deinit();
    self.registry.remove(self.window_key);
    self.posing.deinit();
    self.camera.deinit();
    self.scene.deinit();
    self.allocator.destroy(self);
}

pub fn isOpen(self: *const Photo) bool {
    return self.open.load(.acquire);
}

pub fn setOpen(self: *Photo, on: bool) void {
    self.open.store(on, .release);
}

fn windowKey(ctx: *anyopaque, phase: Keybinds.Phase) void {
    const self: *Photo = @ptrCast(@alignCast(ctx));
    if (phase == .pressed) self.setOpen(!self.isOpen());
}

/// Every frame, even when the overlay can't draw.
fn update(self: *Photo) void {
    self.syncOpen();
    self.camera.tick();
    self.posing.tick(self.isOpen());
    if (self.scene.takeFocus()) |point| self.camera.focus(point);
}

/// The key and the window's own close button both open and close it.
fn syncOpen(self: *Photo) void {
    const w = self.window orelse return;
    const keyed = self.isOpen();
    if (keyed != self.was_open) {
        w.window.open = keyed;
        if (keyed) w.window.raise = true;
    } else if (w.window.open != self.was_open) self.setOpen(w.window.open);
    self.was_open = w.window.open;
}

/// The game's speed, when World's picked.
fn drawWorld(self: *Photo, _: Target) void {
    ui.separatorText("Game speed");
    self.speed.draw(.{ .width = 0, .label = false, .explain = true });
    ui.textDisabled("Right-click the slider for normal speed.", .{});
}

/// An icon button in the toolbar, flat till it's hovered, and lit while it's on.
pub fn toolButton(label: [:0]const u8, on: bool, comptime tip: []const u8, args: anytype) bool {
    const lit: ui.StyleColors = if (on) ui.withStyleColor(.button, .button_active) else ui.withColor(.button, @as(u32, 0));
    defer lit.end();
    const clicked = ui.iconButton(label, "");
    ui.tooltip(tip, args);
    return clicked;
}

/// Room between groups of tools.
pub fn gap() void {
    ui.sameLineWith(0, ui.scaled(8));
}

/// Tighter than the rest of the window, so the tools take one slim row.
pub fn compact() ui.StyleScope {
    return ui.styleVars(.{ .frame_padding = .{ ui.scaled(4), ui.scaled(2) }, .item_spacing = .{ ui.scaled(2), ui.scaled(4) } });
}

fn drawCameraTools(self: *Photo, _: Target) void {
    const tight = compact();
    defer tight.end();
    const cam = &self.camera;
    var buf: [96]u8 = undefined;
    const no_camera = ui.disabled(!cam.hasCamera());
    defer no_camera.end();
    // Fly or orbit, and the rest, are on the camera it's moving
    const on = cam.isOn();
    if (toolButton(if (on) icons.video ++ "##photo_free" else icons.video_off ++ "##photo_free", on, "Free camera. {s}", .{cam.toggleKeyName(&buf)})) cam.flip();
}

fn drawSpeedTool(self: *Photo, _: Target) void {
    const tight = compact();
    defer tight.end();
    self.speed.draw(.{ .width = 70, .label = false });
}

fn drawOverlayTool(self: *Photo, _: Target) void {
    const tight = compact();
    defer tight.end();
    self.posing.drawOverlayTool();
}

fn drawScreenshotTool(self: *Photo, _: Target) void {
    const tight = compact();
    defer tight.end();
    const shot = self.screenshot;
    const no_shot = ui.disabled(shot == null);
    defer no_shot.end();
    if (toolButton(icons.aperture ++ "##photo_shot", false, "Take a screenshot of the game without Wraith's windows, unless Settings says to keep them", .{})) {
        if (shot) |s| s.take();
    }
}

/// The Photo mode window, in the shell's windows: the toolbar, the scene, and what's picked in it.
pub const Window = struct {
    window: ui.Window = .{ .title = "Photo mode##wraith.photo", .size = .{ 540, 440 } },
    photo: ?*Photo = null,
    split: ui.Split = .{ .ratio = 0.34, .min = 120 },

    pub fn draw(self: *Window) void {
        const photo = self.photo orelse {
            ui.textDisabled("Photo mode needs the game's files.", .{});
            return;
        };
        photo.scene.drawToolbar();
        ui.separator();
        if (self.split.first("scene")) |c| {
            defer c.end();
            photo.scene.drawTree();
        }
        if (self.split.second("picked")) |c| {
            defer c.end();
            photo.scene.drawInspector();
        }
    }
};

const testing = std.testing;

test {
    _ = Scene;
}

test "the game's camera goes through untouched till the free camera's on, then it's ours" {
    const Rig = @import("../testing/Rig.zig");
    const W = @import("wraith_api").wraith;
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    const registry = try Registry.create(testing.allocator, .{ .keybinds = rig.keybinds });
    defer registry.destroy();
    const photo = try Photo.create(testing.allocator, registry, rig.overlay, rig.keybinds);
    defer photo.destroy();
    const cam = &photo.camera;
    cam.world(.{ .up = .pos_y, .look = .pos_z, .left_handed = true, .metre = 1 });

    var state: W.FreeCamera.State = .{ .position = .{ .x = 1 }, .aim = .rotation, .target = .{}, .up = .{ .y = 1 }, .rotation = .identity, .roll = 0, .fov = 1 };
    const before = state;
    cam.camera(0, &state);
    try testing.expectEqual(before, state);
    try testing.expect(!cam.active());

    // On, it stays where it was turned on, wherever the game puts its own
    cam.flip();
    try testing.expect(cam.active());
    state.position = .{ .x = 50 };
    cam.camera(0, &state);
    try testing.expectApproxEqAbs(1, state.position.x, 1e-4);

    // A cut to another of the game's cameras carries on from that one, which stays put
    state.position = .{ .x = 20 };
    cam.camera(1, &state);
    try testing.expectEqual(20, state.position.x);
    state.position = .{ .x = 50 };
    cam.camera(1, &state);
    try testing.expectApproxEqAbs(20, state.position.x, 1e-4);

    // Off, the game's is left alone again
    cam.flip();
    state.position = .{ .x = 50 };
    cam.camera(1, &state);
    try testing.expectEqual(50, state.position.x);
    try testing.expect(!photo.posing.active());
}

test "the free camera hides only its controls from the game, unless it's set to hide everything" {
    const Rig = @import("../testing/Rig.zig");
    const W = @import("wraith_api").wraith;
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    const registry = try Registry.create(testing.allocator, .{ .keybinds = rig.keybinds });
    defer registry.destroy();
    const photo = try Photo.create(testing.allocator, registry, rig.overlay, rig.keybinds);
    defer photo.destroy();
    const cam = &photo.camera;
    cam.world(.{ .up = .pos_y, .look = .pos_z, .left_handed = true, .metre = 1 });
    var state: W.FreeCamera.State = .{ .position = .{}, .aim = .rotation, .target = .{}, .up = .{ .y = 1 }, .rotation = .identity, .roll = 0, .fov = 1 };
    cam.camera(0, &state);
    rig.present(); // attaches

    const forward = cam.holds.getPtrConst(.forward).setting.binding.?;
    try testing.expect(!forward.consume.load(.acquire));
    cam.flip();
    // Its keys, the button it looks with and the wheel, and nothing else
    try testing.expect(forward.consume.load(.acquire));
    try testing.expectEqual(@import("tuft_input").Blocker.buttonBit(.right), rig.blocker.consume_buttons.load(.acquire));
    try testing.expect(rig.blocker.consume_wheel.load(.acquire));
    try testing.expect(!rig.overlay.taken(.keyboard));
    try testing.expect(!rig.overlay.taken(.mouse));

    try registry.set(cam.hide_from_game, .{ .choice = "Everything" });
    rig.present();
    try testing.expect(rig.overlay.taken(.keyboard));
    try testing.expect(rig.overlay.taken(.mouse));
    try testing.expect(!forward.consume.load(.acquire));
    try testing.expectEqual(0, rig.blocker.consume_buttons.load(.acquire));

    cam.flip();
    rig.present();
    try testing.expect(!rig.overlay.taken(.keyboard));
    try testing.expect(!rig.blocker.consume_wheel.load(.acquire));
}

test "one selection: picking a bone picks its actor, and picking World lets the actor go" {
    const Rig = @import("../testing/Rig.zig");
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    const registry = try Registry.create(testing.allocator, .{ .keybinds = rig.keybinds });
    defer registry.destroy();
    const photo = try Photo.create(testing.allocator, registry, rig.overlay, rig.keybinds);
    defer photo.destroy();
    const Bone = struct { name: []const u8, parent: i32 };
    const bones = [_]Bone{ .{ .name = "hips", .parent = -1 }, .{ .name = "head", .parent = 0 } };
    var matrices = [_]@import("tuft_math").Mat4{ .identity, .identity };
    photo.posing.store.pose(7, "Rean", &bones, &matrices, .identity);
    photo.setOpen(true);

    photo.posing.select(photo.posing.store.byId(7).?, 1);
    try testing.expectEqual(7, photo.scene.selectedOf("actor"));
    try testing.expect(photo.posing.wants(7));

    photo.scene.select("world", 0);
    rig.present();
    try testing.expectEqual(null, photo.posing.actor);
    try testing.expect(!photo.posing.wants(7));
}
