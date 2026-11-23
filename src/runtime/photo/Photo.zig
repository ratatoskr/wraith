//! Photo mode: the free camera, posing, pausing and screenshots, together. Camera and Posing are
//! always there for game and engine plugins to hand things to, and their keys always work. The Photo
//! mode window puts them in one place.

const Photo = @This();

const std = @import("std");
const tuft_input = @import("tuft_input");
const Keybinds = tuft_input.Keybinds;

const core = @import("wraith_core");
const ui = @import("wraith_ui");

const Registry = @import("../settings/Registry.zig");
const Overlay = @import("../ui/Overlay.zig");
const Screenshot = @import("../Screenshot.zig");
const game_area = @import("../host/game_area.zig");
pub const Camera = @import("Camera.zig");
pub const Posing = @import("Posing.zig");

const log = core.log.scoped(.wraith_runtime);

allocator: std.mem.Allocator,
overlay: *Overlay,
camera: Camera = undefined,
posing: Posing = undefined,
scope: core.Scope,
/// The speed the game was at before Photo mode paused it. Render thread.
paused_from: ?f64 = null,

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
    self.resume_();
    self.posing.deinit();
    self.camera.deinit();
    self.allocator.destroy(self);
}

/// Every frame, even when the overlay can't draw.
fn update(self: *Photo) void {
    self.camera.tick();
    self.posing.tick();
}

pub fn paused(self: *const Photo) bool {
    return self.paused_from != null;
}

pub fn setPaused(self: *Photo, on: bool) void {
    if (on == self.paused()) return;
    if (on) {
        const before = game_area.currentSpeed();
        game_area.setSpeedForPlayer(0) catch |err| return log.warn("Couldn't pause the game: {t}", .{err});
        self.paused_from = if (before == 0) 1 else before;
    } else self.resume_();
}

fn resume_(self: *Photo) void {
    const before = self.paused_from orelse return;
    self.paused_from = null;
    // Only if it's still the pause we made
    if (game_area.currentSpeed() == 0) game_area.setSpeedForPlayer(before) catch |err| log.warn("Couldn't unpause the game: {t}", .{err});
}

/// The Photo mode window, in the shell's windows.
pub const Window = struct {
    window: ui.Window = .{ .title = "Photo mode##wraith.photo", .size = .{ 360, 0 } },
    photo: ?*Photo = null,
    screenshot: ?*Screenshot = null,

    pub fn draw(self: *Window) void {
        const photo = self.photo orelse {
            ui.textDisabled("Photo mode needs the game's files.", .{});
            return;
        };
        const cam = &photo.camera;
        var buf: [96]u8 = undefined;

        ui.separatorText("Camera");
        if (!cam.hasCamera()) {
            ui.textWrapped("No camera yet. The free camera needs a plugin for this game, or its engine, that hands it the camera.", .{});
        } else {
            var on = cam.isOn();
            if (ui.checkbox("Free camera", &on)) cam.flip();
            ui.sameLine();
            ui.textDisabled("{s}", .{cam.toggleKeyName(&buf)});
            if (cam.isOn()) {
                var orbiting = cam.isOrbiting();
                if (ui.checkbox("Orbit", &orbiting)) cam.setOrbiting(orbiting, null);
            }
        }

        ui.separatorText("Game");
        var pause = photo.paused();
        if (ui.checkbox("Pause", &pause)) photo.setPaused(pause);
        ui.tooltip("Stops the world, through the game's engine when there's a plugin for it. The camera still moves.", .{});

        ui.separatorText("Posing");
        var posing_open = photo.posing.isOpen();
        if (ui.checkbox("Posing window", &posing_open)) photo.posing.setOpen(posing_open);

        ui.separatorText("Screenshot");
        if (self.screenshot) |shot| {
            if (ui.button("Take a screenshot")) shot.take();
            ui.tooltip("Of the game without Wraith's windows, unless Settings says to keep them.", .{});
        } else ui.textDisabled("Screenshots need the game's files.", .{});
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
