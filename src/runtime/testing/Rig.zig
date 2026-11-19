//! The runtime's game-facing stack on a throwaway device and window, for tests.

const Rig = @This();

const std = @import("std");
const testing = std.testing;

const core = @import("wraith_core");
const wraith_platform = @import("wraith_platform");
const tuft_window = @import("tuft_window");
const gfx = @import("tuft_gfx");
const hook = @import("tuft_hook");

const Graphics = @import("../graphics/Graphics.zig");
const Window = @import("tuft_input").Window;
const Blocker = @import("tuft_input").Blocker;
const Keybinds = @import("tuft_input").Keybinds;
const input_wiring = @import("../input_wiring.zig");
const Overlay = @import("../ui/Overlay.zig");
const host_frame = @import("../host/frame.zig");
const host_capture = @import("../host/capture.zig");

const win = wraith_platform.win.api;

pub const Options = struct {
    overlay: bool = true,
    ini_path: ?[]const u8 = null,
    viewports: bool = false,
    /// Vulkan skips the test if there's no Vulkan.
    api: gfx.OwnedSurface.Kind = .d3d11,
};

surface: gfx.OwnedSurface,
hwnd: win.HWND,
graphics: *Graphics,
window: *Window,
blocker: *Blocker,
keybinds: *Keybinds,
wiring: core.Scope,
overlay: *Overlay = undefined,
has_overlay: bool,
scope: core.Scope,
/// From `runPluginFrames`.
plugin_frames: bool,
saved_log: core.log.Filter,
saved_std_log: std.log.Level,

/// The first `present` attaches and subclasses the game window.
pub fn init(self: *Rig, options: Options) !void {
    self.saved_log = core.log.mute(&.{ .graphics, .core });
    errdefer core.log.setFilter(self.saved_log);
    // tuft logs through std.log, which only reaches wraith's filter inside the runtime DLL
    self.saved_std_log = testing.log_level;
    testing.log_level = .err;
    errdefer testing.log_level = self.saved_std_log;

    // Like the runtime, every hook claims its bytes
    @import("tuft_mem").Claims.enable(testing.allocator);
    errdefer @import("tuft_mem").Claims.disable();
    try hook.init(testing.allocator);
    errdefer hook.deinit();
    self.surface = gfx.OwnedSurface.create(options.api, .{}) catch |err| return switch (err) {
        error.Unavailable => error.SkipZigTest,
        else => err,
    };
    errdefer self.surface.destroy();
    self.hwnd = @ptrCast(self.surface.window());
    game.install(self.hwnd);
    errdefer game.uninstall(self.hwnd);
    self.scope = .init(testing.allocator);
    errdefer self.scope.deinit();
    self.plugin_frames = false;
    try self.start(options);
}

/// Runs plugins' frame callbacks in the overlay's `update` and takes their captures, like the game does.
/// Until `deinit` or `reload`.
pub fn runPluginFrames(self: *Rig) !void {
    try self.overlay.update.subscribe(&self.scope, self, runFrame);
    self.overlay.captures = .{ .wants = host_capture.overlayWants, .event = host_capture.fromOverlay };
    host_frame.setFrames(true);
    self.plugin_frames = true;
}

fn runFrame(_: *Rig) void {
    host_frame.run();
}

fn stopPluginFrames(self: *Rig) void {
    if (!self.plugin_frames) return;
    host_frame.setFrames(false);
    self.plugin_frames = false;
}

fn start(self: *Rig, options: Options) !void {
    self.graphics = try Graphics.create(testing.allocator, .{});
    errdefer self.graphics.destroy();
    self.window = try Window.create(testing.allocator, testing.io);
    errdefer self.window.destroy();
    self.blocker = try Blocker.create(testing.allocator, self.window);
    errdefer self.blocker.destroy();
    self.keybinds = try Keybinds.create(testing.allocator, self.window, self.blocker);
    errdefer self.keybinds.destroy();
    self.wiring = .init(testing.allocator);
    errdefer self.wiring.deinit();
    try input_wiring.wire(&self.wiring, self.graphics, self.window, self.keybinds);
    self.has_overlay = options.overlay;
    if (options.overlay) self.overlay = try Overlay.create(testing.allocator, testing.io, self.graphics, self.window, self.blocker, self.keybinds, .{ .ini_path = options.ini_path, .viewports = options.viewports });
    errdefer if (options.overlay) self.overlay.destroy();
    try self.graphics.enable();
    // D3D12 and Vulkan only attach after a first present, so get that out of the way
    if (options.api == .d3d12 or options.api == .vulkan) self.present();
}

pub fn deinit(self: *Rig) void {
    self.scope.deinit();
    self.stopPluginFrames();
    self.stop();
    game.uninstall(self.hwnd);
    self.surface.destroy();
    hook.deinit();
    @import("tuft_mem").Claims.disable();
    core.log.setFilter(self.saved_log);
    testing.log_level = self.saved_std_log;
}

fn stop(self: *Rig) void {
    if (self.has_overlay) self.overlay.destroy();
    self.wiring.deinit();
    self.keybinds.destroy();
    self.window.closeTasks();
    self.blocker.destroy();
    self.window.destroy();
    self.graphics.destroy();
}

/// Like a reload while the game keeps going. The test's subscriptions go with it.
pub fn reload(self: *Rig, options: Options) !void {
    self.scope.deinit();
    self.stopPluginFrames();
    self.stop();
    self.scope = .init(testing.allocator);
    try self.start(options);
}

pub fn present(self: *Rig) void {
    self.surface.present();
}

pub fn resize(self: *Rig, width: u32, height: u32) bool {
    return self.surface.resize(width, height);
}

pub fn send(self: *Rig, msg: u32, wparam: usize, lparam: isize) isize {
    return tuft_window.send(self.hwnd, msg, wparam, lparam);
}

pub const game = struct {
    var prev: isize = 0;
    var counts: [0x400]u32 = @splat(0);
    var last_wparams: [0x400]usize = @splat(0);

    pub fn count(msg: u32) u32 {
        return counts[msg];
    }

    pub fn lastWparam(msg: u32) usize {
        return last_wparams[msg];
    }

    fn install(window: win.HWND) void {
        counts = @splat(0);
        last_wparams = @splat(0);
        prev = win.SetWindowLongPtrW(window, win.GWLP_WNDPROC, @bitCast(@intFromPtr(&proc)));
    }

    fn uninstall(window: win.HWND) void {
        _ = win.SetWindowLongPtrW(window, win.GWLP_WNDPROC, prev);
    }

    fn proc(window: win.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
        if (msg < counts.len) {
            counts[msg] += 1;
            last_wparams[msg] = wparam;
        }
        return win.CallWindowProcW(prev, window, msg, wparam, lparam);
    }
};
