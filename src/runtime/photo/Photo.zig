//! Photo mode: the free camera, posing, pausing and screenshots, together. Camera and Posing are
//! always there for game and engine plugins to hand things to, and their keys always work. The Photo
//! mode window puts them in one place: tools along the top, the scene down the left, which is the
//! world, the camera and the actors, and whatever's picked in it on the right.

const Photo = @This();

const std = @import("std");
const tuft_input = @import("tuft_input");
const Keybinds = tuft_input.Keybinds;

const core = @import("wraith_core");
const ui = @import("wraith_ui");

const Registry = @import("../settings/Registry.zig");
const Overlay = @import("../ui/Overlay.zig");
const Screenshot = @import("../Screenshot.zig");
const GameSpeed = @import("../ui/GameSpeed.zig");
const icons = @import("../ui/icons.zig");
pub const Camera = @import("Camera.zig");
pub const Posing = @import("Posing.zig");

const log = core.log.scoped(.wraith_runtime);

/// Where the camera's and posing's settings and keys are, among Wraith's own.
pub const section = "Photo mode";

allocator: std.mem.Allocator,
overlay: *Overlay,
camera: Camera = undefined,
posing: Posing = undefined,
scope: core.Scope,
/// The shell's, so Posing's key opens it. Render thread.
window: ?*Window = null,
/// Whether it was open last frame, to tell which side opened or closed it.
was_open: bool = false,

pub fn create(allocator: std.mem.Allocator, registry: *Registry, overlay: *Overlay, keybinds: *Keybinds) !*Photo {
    const self = try allocator.create(Photo);
    errdefer allocator.destroy(self);
    self.* = .{ .allocator = allocator, .overlay = overlay, .scope = .init(allocator) };
    errdefer self.scope.deinit();
    try self.camera.init(registry, overlay, keybinds);
    errdefer self.camera.deinit();
    try self.posing.init(registry, overlay, &self.camera);
    errdefer self.posing.deinit();
    try overlay.update.subscribe(&self.scope, self, update);
    return self;
}

pub fn destroy(self: *Photo) void {
    // Waits for a frame in flight
    self.scope.deinit();
    self.posing.deinit();
    self.camera.deinit();
    self.allocator.destroy(self);
}

/// Every frame, even when the overlay can't draw.
fn update(self: *Photo) void {
    self.syncOpen();
    self.camera.tick();
    self.posing.tick();
}

/// Posing's key and the window's own close button both open and close it.
fn syncOpen(self: *Photo) void {
    const w = self.window orelse return;
    const keyed = self.posing.isOpen();
    if (keyed != self.was_open) {
        w.window.open = keyed;
        if (keyed) w.window.raise = true;
    } else if (w.window.open != self.was_open) self.posing.setOpen(w.window.open);
    self.was_open = w.window.open;
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
fn compact() ui.StyleScope {
    return ui.styleVars(.{ .frame_padding = .{ ui.scaled(4), ui.scaled(2) }, .item_spacing = .{ ui.scaled(2), ui.scaled(4) } });
}

/// The Photo mode window, in the shell's windows.
pub const Window = struct {
    window: ui.Window = .{ .title = "Photo mode##wraith.photo", .size = .{ 540, 440 } },
    photo: ?*Photo = null,
    screenshot: ?*Screenshot = null,
    speed: GameSpeed = .{},
    split: ui.Split = .{ .ratio = 0.34, .min = 120 },
    picked: Picked = .actor,
    /// The posed actor last frame, so picking one in the game shows it here
    seen_actor: ?u64 = null,

    const Picked = enum { world, camera, actor };

    pub fn draw(self: *Window) void {
        const photo = self.photo orelse {
            ui.textDisabled("Photo mode needs the game's files.", .{});
            return;
        };
        if (photo.posing.actor != self.seen_actor) {
            self.seen_actor = photo.posing.actor;
            if (self.seen_actor != null) self.picked = .actor;
        }
        self.toolbar(photo);
        ui.separator();
        if (self.split.first("scene")) |c| {
            defer c.end();
            self.scene(photo);
        }
        if (self.split.second("picked")) |c| {
            defer c.end();
            switch (self.picked) {
                .world => self.worldPanel(),
                .camera => cameraPanel(&photo.camera),
                .actor => photo.posing.drawActorPanel(),
            }
        }
    }

    fn toolbar(self: *Window, photo: *Photo) void {
        const tight = compact();
        defer tight.end();
        const cam = &photo.camera;
        var buf: [96]u8 = undefined;
        {
            const no_camera = ui.disabled(!cam.hasCamera());
            defer no_camera.end();
            const on = cam.isOn();
            if (toolButton(if (on) icons.video ++ "##photo_free" else icons.video_off ++ "##photo_free", on, "Free camera. {s}", .{cam.toggleKeyName(&buf)})) cam.flip();
            ui.sameLine();
            const not_on = ui.disabled(!on);
            defer not_on.end();
            if (toolButton(icons.orbit ++ "##photo_orbit", cam.isOrbiting(), "Orbit. {s}", .{cam.orbitKeyName(&buf)})) cam.setOrbiting(!cam.isOrbiting(), null);
        }
        gap();
        self.speed.draw(.{ .width = 70, .label = false });
        gap();
        photo.posing.drawTools();
        gap();
        const shot = self.screenshot;
        const no_shot = ui.disabled(shot == null);
        defer no_shot.end();
        if (toolButton(icons.aperture ++ "##photo_shot", false, "Take a screenshot of the game without Wraith's windows, unless Settings says to keep them", .{})) {
            if (shot) |s| s.take();
        }
    }

    fn scene(self: *Window, photo: *Photo) void {
        if (ui.selectable(icons.globe ++ "  World", self.picked == .world)) self.picked = .world;
        if (ui.selectable(icons.video ++ "  Camera", self.picked == .camera)) self.picked = .camera;
        ui.separatorText("Actors");
        photo.posing.drawSearch();
        if (photo.posing.drawActorRows(self.picked == .actor)) self.picked = .actor;
    }

    fn worldPanel(self: *Window) void {
        ui.separatorText("Game speed");
        self.speed.draw(.{ .width = 0, .label = false, .explain = true });
        ui.textDisabled("Right-click the slider for normal speed.", .{});
        ui.separatorText("Screenshot");
        if (self.screenshot) |shot| {
            if (ui.button("Take a screenshot")) shot.take();
            ui.tooltip("Of the game without Wraith's windows, unless Settings says to keep them.", .{});
        } else ui.textDisabled("Screenshots need the game's files.", .{});
    }

    fn cameraPanel(cam: *Camera) void {
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
        ui.separatorText("Keys");
        cam.drawKeyList();
        ui.textDisabled("Its speed, smoothing and keys are in Settings, under Photo mode.", .{});
    }
};

const testing = std.testing;

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

    var state: W.CamState = .{ .position = .{ .x = 1 }, .aim = .rotation, .target = .{}, .up = .{ .y = 1 }, .rotation = .identity, .roll = 0, .fov = 1 };
    const before = state;
    cam.camera(&state);
    try testing.expectEqual(before, state);
    try testing.expect(!cam.active());

    // On, it stays where it was turned on, wherever the game puts its own
    cam.flip();
    try testing.expect(cam.active());
    state.position = .{ .x = 50 };
    cam.camera(&state);
    try testing.expectApproxEqAbs(1, state.position.x, 1e-4);

    // Off, the game's is left alone again
    cam.flip();
    state.position = .{ .x = 50 };
    cam.camera(&state);
    try testing.expectEqual(50, state.position.x);
    try testing.expect(!photo.posing.active());
}
