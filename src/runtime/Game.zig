//! Hooks the game's rendering and window, and runs the overlay and the runtime's UI.

const Game = @This();

const std = @import("std");

const core = @import("wraith_core");

const Settings = @import("Settings.zig");
const GameSettings = @import("GameSettings.zig");
const Graphics = @import("graphics/Graphics.zig");
const Window = @import("tuft_input").Window;
const Blocker = @import("tuft_input").Blocker;
const Keybinds = @import("tuft_input").Keybinds;
const Gamepads = @import("tuft_input").Gamepads;
const XInput = @import("tuft_input").XInput;
const Ime = @import("tuft_input").Ime;
const input_wiring = @import("input_wiring.zig");
const Overlay = @import("ui/Overlay.zig");
const Themes = @import("ui/Themes.zig");
const fonts = @import("ui/fonts.zig");
const Shell = @import("ui/shell/Shell.zig");
const Registry = @import("settings/Registry.zig");
const host = @import("host/root.zig");

const log = core.log.scoped(.wraith_input);

allocator: std.mem.Allocator,
graphics: *Graphics,
window: *Window,
blocker: *Blocker,
keybinds: *Keybinds,
/// Outlives the keybinds and overlay, which listen to it.
gamepads: *Gamepads,
/// Null without XInput on the system.
xinput: ?*XInput,
/// Outlives the overlay. Null when the setting's off.
ime: ?*Ime,
wiring: core.Scope,
/// On the overlay's `update`.
frames: core.Scope,
themes: Themes,
overlay: *Overlay,
shell: *Shell,
registry: ?*Registry,
/// Read once, since the overlay only takes them at the start.
overlay_scale: ?*Registry.Setting = null,
overlay_viewports: ?*Registry.Setting = null,
allow_gamepad_capture: ?*Registry.Setting = null,

/// `game_settings` must outlive the game, since what it does is saved to it.
pub const Options = struct {
    /// The game hasn't started rendering yet, so hook device creation instead of probing.
    before_rendering: bool = false,
    handover: ?*core.runtime_abi.GraphicsHandover = null,
    /// Its key settings bind to the game's keys while the game's here. Must outlive it.
    registry: ?*Registry = null,
    /// Switch the game's IME on for our text boxes and place it. Off leaves it as the game set it.
    ime: bool = true,
};

pub fn create(allocator: std.mem.Allocator, io: std.Io, game_settings: *core.Config(GameSettings), config_root: []const u8, options: Options) !*Game {
    const self = try allocator.create(Game);
    errdefer allocator.destroy(self);
    self.allocator = allocator;
    self.registry = options.registry;
    self.overlay_scale = null;
    self.overlay_viewports = null;
    self.allow_gamepad_capture = null;
    errdefer self.removeSettings();
    var scale: f32 = 1.25;
    var viewports = true;
    if (self.registry) |r| {
        self.overlay_scale = try r.add(.{
            .id = "wraith.overlay_scale",
            .name = "Overlay scale",
            .help = "How big the overlay's text and widgets are, on top of the screen's own scaling.",
            .group = Settings.group,
            .section = "Look & Feel",
            .restart = true,
            .kind = .{ .number = .{ .default = scale, .min = 0.75, .max = 2.5 } },
        }, .{});
        self.overlay_viewports = try r.add(.{
            .id = "wraith.overlay_viewports",
            .name = "Windows outside the game",
            .help = "Lets overlay windows be dragged out of the game's window, onto another monitor say.",
            .group = Settings.group,
            .section = "Look & Feel",
            .restart = true,
            .kind = .{ .toggle = viewports },
        }, .{});
        scale = @floatCast(r.get(self.overlay_scale.?).number);
        viewports = r.get(self.overlay_viewports.?).toggle;
    }

    self.graphics = try Graphics.create(allocator, .{ .early = options.before_rendering, .handover = options.handover });
    errdefer self.graphics.destroy();
    self.window = try Window.create(allocator, io);
    errdefer self.window.destroy();
    self.blocker = try Blocker.create(allocator, self.window);
    errdefer {
        self.window.closeTasks();
        self.blocker.destroy();
    }
    self.gamepads = try Gamepads.create(allocator, io, .{});
    errdefer self.gamepads.destroy();
    self.xinput = XInput.create(allocator) catch |err| blk: {
        log.warn("No controllers, XInput didn't load: {t}", .{err});
        break :blk null;
    };
    errdefer if (self.xinput) |x| x.destroy(allocator);
    if (self.xinput) |x| try self.gamepads.addSource(x.source());
    self.keybinds = try Keybinds.create(allocator, self.window, self.blocker);
    errdefer self.keybinds.destroy();
    try self.keybinds.attachGamepads(self.gamepads);
    self.ime = if (options.ime) try Ime.create(allocator, self.window) else null;
    errdefer if (self.ime) |ime| ime.destroy();
    if (self.registry) |r| r.setKeybinds(self.keybinds);
    errdefer if (self.registry) |r| r.setKeybinds(null);
    self.wiring = .init(allocator);
    errdefer self.wiring.deinit();
    try input_wiring.wire(&self.wiring, self.graphics, self.window, self.keybinds);
    const ini_path = try std.fs.path.join(allocator, &.{ config_root, "imgui.ini" });
    defer allocator.free(ini_path);
    const themes_dir = try std.fs.path.join(allocator, &.{ config_root, "themes" });
    defer allocator.free(themes_dir);
    self.themes = try Themes.load(allocator, io, themes_dir);
    errdefer self.themes.deinit();
    fonts.loadSystem(allocator, io);
    errdefer fonts.freeSystem();
    // The shell sets the theme before the first frame
    self.overlay = try Overlay.create(allocator, io, self.graphics, self.window, self.blocker, self.keybinds, .{
        .scale = scale,
        .ini_path = ini_path,
        .viewports = viewports,
        .ime = self.ime,
    });
    errdefer self.overlay.destroy();
    try self.overlay.attachGamepads(self.gamepads);
    if (self.registry) |r| {
        self.allow_gamepad_capture = try r.add(.{
            .id = "wraith.allow_gamepad_capture",
            .name = "Allow gamepad capture",
            .help = "Lets the overlay and plugins take controllers from the game. Off, the game always keeps them.",
            .group = Settings.group,
            .section = "Controls",
            .kind = .{ .toggle = true },
        }, .{ .changed = .{ .ctx = self, .call = allowGamepadChanged } });
        self.overlay.setEnabled(.gamepad, r.get(self.allow_gamepad_capture.?).toggle);
    }

    self.shell = try Shell.create(allocator, self.overlay, self.keybinds, .{
        .registry = options.registry,
        .themes = &self.themes,
        .game = game_settings,
        .io = io,
    });
    errdefer self.shell.destroy();

    host.ui.setOverlay(self.overlay);
    errdefer host.ui.setOverlay(null);
    host.keybinds.setKeybinds(self.keybinds);
    errdefer host.keybinds.setKeybinds(null);
    host.keybinds.setWindow(self.window);
    errdefer host.keybinds.setWindow(null);
    // Right after keybinds, before the overlay's frame
    try self.graphics.frame.subscribeOpts(&self.wiring, self, startFrame, .{ .priority = 99 });
    // Plugins' frames run inside the overlay's ImGui frame, or a headless one
    self.frames = .init(allocator);
    errdefer self.frames.deinit();
    try self.overlay.update.subscribe(&self.frames, self, runFrame);
    self.overlay.captures = .{ .wants = host.capture.overlayWants, .event = host.capture.fromOverlay };
    host.messages.setFrames(true);
    errdefer host.messages.setFrames(false);
    host.frame.setFrames(true);
    errdefer host.frame.setFrames(false);
    try self.graphics.enable();
    return self;
}

fn startFrame(_: *Game, _: *const Graphics.Frame) void {
    host.messages.deliver();
    host.watches.deliver();
}

fn runFrame(_: *Game) void {
    host.frame.run();
}

fn allowGamepadChanged(ctx: *anyopaque, setting: *Registry.Setting) void {
    const self: *Game = @ptrCast(@alignCast(ctx));
    const r = self.registry orelse return;
    self.overlay.setEnabled(.gamepad, r.get(setting).toggle);
}

/// Call after plugins are gone.
pub fn destroy(self: *Game) void {
    self.shell.destroy();
    // Its change hook uses the overlay
    if (self.registry) |r| if (self.allow_gamepad_capture) |s| r.remove(s);
    self.allow_gamepad_capture = null;
    // Anything still registered stops using the game's keys
    if (self.registry) |r| r.setKeybinds(null);
    host.keybinds.setKeybinds(null);
    host.keybinds.setWindow(null);
    host.watches.shutdown();
    host.ui.setOverlay(null);
    // Off the overlay's event before it goes
    self.frames.deinit();
    self.overlay.destroy();
    // The workbench went with the shell, so nothing's using them
    fonts.freeSystem();
    self.themes.deinit();
    self.wiring.deinit();
    host.messages.setFrames(false);
    host.frame.setFrames(false);
    self.keybinds.destroy();
    // After the overlay, which stops using it
    if (self.ime) |ime| ime.destroy();
    // Nobody's listening now, and its thread stops before the source goes
    self.gamepads.destroy();
    if (self.xinput) |x| x.destroy(self.allocator);
    // A queued release task points at the blocker
    self.window.closeTasks();
    self.blocker.destroy();
    self.window.destroy();
    self.graphics.destroy();
    self.removeSettings();
    self.allocator.destroy(self);
}

fn removeSettings(self: *Game) void {
    const r = self.registry orelse return;
    if (self.overlay_scale) |s| r.remove(s);
    if (self.overlay_viewports) |s| r.remove(s);
    if (self.allow_gamepad_capture) |s| r.remove(s);
    self.overlay_scale = null;
    self.overlay_viewports = null;
    self.allow_gamepad_capture = null;
}
