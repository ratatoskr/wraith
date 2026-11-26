//! The in-game overlay, one Dear ImGui instance shared by the runtime and plugins.

const Overlay = @This();

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;
const tuft_arch = @import("tuft_arch");

const core = @import("wraith_core");
const wraith_platform = @import("wraith_platform");
const tuft_window = @import("tuft_window");

const imgui = @import("imgui.zig");
const ui = @import("wraith_ui");
const c = imgui.c;
const tuft_imgui = @import("tuft_imgui");
const tuft_input = @import("tuft_input");
const imgui_input = tuft_imgui.input;
const Win32 = tuft_imgui.Win32;
const Host = tuft_imgui.Host;
const Themes = @import("Themes.zig");
const fonts = @import("fonts.zig");
const Graphics = @import("../graphics/Graphics.zig");
const FrameStats = @import("../FrameStats.zig");
const Gizmos = @import("Gizmos.zig");
const host_frame = @import("../host/frame.zig");
const Window = @import("tuft_input").Window;
const Blocker = @import("tuft_input").Blocker;
const Keybinds = @import("tuft_input").Keybinds;
const Gamepads = @import("tuft_input").Gamepads;

const input = wraith_platform.input;
const log = core.log.scoped(.wraith_ui);
const WM_ACTIVATE: u32 = 0x0006;

/// What the overlay can take from the game.
pub const Device = tuft_input.Device;

pub const Options = struct {
    scale: f32 = 1.25,
    ini_path: ?[]const u8 = null,
    /// Null means ImGui's dark style. Must outlive the overlay.
    theme: ?*const Themes.Theme = null,
    viewports: bool = false,
    /// Lets text boxes in the game's window use the IME. Must outlive the overlay.
    ime: ?*tuft_input.Ime = null,
};

pub const DrawEvent = core.Event(fn () void);

/// Who asks for frame captures and gets them. Render thread.
pub const Captures = struct {
    wants: *const fn (point: tuft_imgui.capture.Point) bool,
    event: *const fn (event: tuft_imgui.capture.Event, graphics: Graphics.Api) void,
};

/// ImGui only gets the mouse while it's visible, unless given it.
pub const CursorHint = enum(u8) {
    /// Games that draw their own cursor need `visible` or `hidden`.
    auto,
    visible,
    hidden,
};

const Queued = struct {
    event: input.Event,
    viewport: bool = false,

    fn supersedes(newer: Queued, older: Queued) bool {
        if (newer.event == .gamepad_axes and older.event == .gamepad_axes) return true;
        return newer.event == .mouse_move and older.event == .mouse_move and newer.viewport == older.viewport;
    }
};
const InputQueue = core.Mailbox(Queued, 256);

/// Only the render thread can close ImGui's windows.
const close_viewports_timeout_ms = 500;

allocator: std.mem.Allocator,
io: std.Io,
graphics: *Graphics,
blocker: *Blocker,
keybinds: *Keybinds,
options: Options,
/// ImGui keeps the pointer until the context is destroyed.
ini_path: ?[:0]u8,
/// Read at `create`, handed to ImGui with the context.
ini_text: ?[]u8 = null,
/// Writes imgui.ini off the render thread.
ini_saver: core.files.Saver,
/// Render thread, inside the overlay's ImGui frame.
draw: DrawEvent,
/// Render thread, once a frame after `draw`. In a headless frame when the overlay can't draw.
update: DrawEvent,
subscriptions: core.Scope,
window: *Window,
/// Set once, read from any thread.
focus: Atomic(?*tuft_input.Focus) = .init(null),

cursor_hint: Atomic(CursorHint) = .init(.auto),
/// Draws the cursor. Taking the mouse is separate.
cursor_requests: Atomic(u32) = .init(0),
/// Counted, so a device stays taken till every request is dropped.
takes: std.EnumArray(Device, Atomic(u32)) = .initFill(.init(0)),
/// Holds the cursor still and hidden, for looking around with the mouse. Counted like `takes`.
holds: Atomic(u32) = .init(0),
/// Whether it's held right now. Written each frame, read on the window thread.
holding: Atomic(bool) = .init(false),
/// Off leaves a device with the game, whoever takes it and whatever ImGui wants.
enabled: std.EnumArray(Device, Atomic(bool)) = .initFill(.init(true)),
/// The game leaves its cursor free while it shows (like FFXIV), so our windows don't take input from it.
mouse_free_hint: Atomic(bool) = .init(false),
mouse_free_choice: Atomic(MouseFree) = .init(.auto),
/// Mouse buttons whose presses are hidden from the game, counted per button. See `consumeButton`.
consumes: std.EnumArray(tuft_input.MouseButton, Atomic(u32)) = .initFill(.init(0)),
consumes_wheel: Atomic(u32) = .init(0),
/// What ImGui is using right now. Written after each frame, read on the window thread.
wants: std.EnumArray(Device, Atomic(bool)) = .initFill(.init(false)),
/// Whether the overlay's own UI takes controllers while it's open. From the shell's settings.
ui_takes_gamepad: Atomic(bool) = .init(false),
queue: InputQueue = .{},
queue_overflowed: Atomic(bool) = .init(false),
theme_request: Atomic(?*const Themes.Theme) = .init(null),
render_thread: Atomic(std.Thread.Id) = .init(0),
monitors_changed: Atomic(bool) = .init(false),
last_frame_ms: tuft_arch.atomic.Value(u64) = .init(0),
close_viewports: Atomic(bool) = .init(false),
viewports_closed: Atomic(bool) = .init(false),
api: Atomic(u32) = .init(0),
shown_theme: Atomic(?*const Themes.Theme) = .init(null),
/// Every present's time, recorded here. Read from any thread.
frames: FrameStats = .{},

// Render thread only
host: Host,
last_frame: ?std.Io.Timestamp = null,
/// Runs on their own thread.
viewport_translator: input.Translator = .{},
failed: bool = false,
/// For `update` when the overlay can't draw. Made on first use.
headless: ?*c.ImGuiContext = null,
headless_failed: bool = false,
/// Set before frames start.
captures: ?Captures = null,
/// While the cursor's held: where it's pulled back to each frame, and where it was before. Screen coords.
held: ?struct { anchor: input.Point, home: input.Point } = null,
/// How far it was pushed since last frame, while held.
mouse_motion: input.Point = .{ .x = 0, .y = 0 },
default_style: c.ImGuiStyle = undefined,
ui_scale: f32 = 1,
theme: ?*const Themes.Theme = null,

pub fn create(allocator: std.mem.Allocator, io: std.Io, graphics: *Graphics, window: *Window, blocker: *Blocker, keybinds: *Keybinds, options: Options) !*Overlay {
    const self = try allocator.create(Overlay);
    errdefer allocator.destroy(self);
    const ini_path = if (options.ini_path) |path| try allocator.dupeSentinel(u8, path, 0) else null;
    errdefer if (ini_path) |path| allocator.free(path);
    self.* = .{
        .allocator = allocator,
        .io = io,
        .graphics = graphics,
        .blocker = blocker,
        .keybinds = keybinds,
        .options = options,
        .ini_path = ini_path,
        .ini_saver = .{ .allocator = allocator, .io = io, .failed = iniFailed },
        .draw = .init(allocator),
        .update = .init(allocator),
        .subscriptions = .init(allocator),
        .window = window,
        .host = .init(allocator, .{
            .viewports = options.viewports,
            .viewport_input = .{ .ctx = self, .func = onViewportInput },
            .viewport_icon = "WRAITH_ICON",
            .setup = .{ .ctx = self, .func = setUpContext },
            .capture_sink = .of(Overlay, self, onCaptured),
            .ime = options.ime,
        }),
    };
    self.options.ini_path = null; // the caller's copy
    if (self.ini_path) |path| self.ini_text = readIni(allocator, io, path);
    errdefer {
        if (self.ini_text) |t| allocator.free(t);
        self.subscriptions.deinit();
        self.update.deinit();
        self.draw.deinit();
    }

    try graphics.frame.subscribe(&self.subscriptions, self, onFrame);
    try graphics.resize.subscribe(&self.subscriptions, self, onSurfaceChange);
    try graphics.detach.subscribe(&self.subscriptions, self, onSurfaceChange);
    try window.message.subscribeOpts(&self.subscriptions, self, onMessage, .{ .priority = Window.Priority.overlay });
    if (options.viewports) self.keepGameActive();
    imgui.bind();
    return self;
}

/// Keeps the game thinking it's active while one of our windows is, or many games pause.
pub fn keepGameActive(self: *Overlay) void {
    if (self.focus.load(.acquire) != null) return;
    const focus = tuft_input.Focus.create(self.allocator, self.window, .{ .ctx = null, .func = isOurs }) catch |err| {
        log.warn("Clicking our windows may pause the game: {t}", .{err});
        return;
    };
    self.focus.store(focus, .release);
}

fn isOurs(_: ?*anyopaque, window: tuft_window.Handle) bool {
    return tuft_imgui.isOurs(null, window);
}

/// On its thread. A game paused by losing focus renders again.
pub fn ourWindowActivated(self: *Overlay) void {
    if (self.focus.load(.acquire)) |f| f.ourWindowActivated();
}

/// Unsubscribe from `draw` and `update` first.
pub fn destroy(self: *Overlay) void {
    self.closeViewports();
    if (self.focus.load(.acquire)) |f| f.destroy();
    self.subscriptions.deinit();
    _ = self.queue.close();
    self.blocker.capture(.empty);
    self.blocker.consumeButtons(0);
    self.blocker.consumeWheel(false);

    // Saves imgui.ini, here since ImGui doesn't write it itself
    self.saveIniNow();
    self.ini_saver.wait() catch {};
    self.host.deinit();
    if (self.headless) |context| c.ImGui_DestroyContext(context);
    if (self.ini_text) |t| self.allocator.free(t);
    if (self.ini_path) |path| self.allocator.free(path);
    self.update.deinit();
    self.draw.deinit();
    self.allocator.destroy(self);
}

/// Only the render thread can destroy ImGui's windows, so ask it to on its next frame.
fn closeViewports(self: *Overlay) void {
    if (!self.options.viewports) return;
    const render_thread = self.render_thread.load(.acquire);
    if (render_thread == 0 or render_thread == std.Thread.getCurrentId()) return;
    self.close_viewports.store(true, .release);
    const deadline = std.Io.Clock.awake.now(self.io).addDuration(.fromMilliseconds(close_viewports_timeout_ms));
    while (!self.viewports_closed.load(.acquire)) {
        if (std.Io.Clock.awake.now(self.io).compare(.gte, deadline)) {
            log.warn("No frame to close the overlay's windows in; leaving them to their thread", .{});
            return;
        }
        self.io.sleep(.fromMilliseconds(1), .awake) catch return;
    }
}

/// Render thread.
fn stopViewports(self: *Overlay) void {
    self.host.stopViewports();
    self.viewports_closed.store(true, .release);
}

/// For games that draw their own cursor. Any thread.
pub fn setCursorHint(self: *Overlay, hint: CursorHint) void {
    self.cursor_hint.store(hint, .release);
}

/// Counted, so the cursor stays until every request is dropped. Doesn't take the mouse. Any thread.
pub fn requestCursor(self: *Overlay, on: bool) void {
    count(&self.cursor_requests, on);
}

/// Hides `device` from the game and lets the overlay navigate with it. Counted. Any thread.
pub fn take(self: *Overlay, device: Device, on: bool) void {
    count(self.takes.getPtr(device), on);
    self.updateCapture();
}

/// Asked for and allowed. Any thread.
pub fn taken(self: *const Overlay, device: Device) bool {
    return self.enabled.getPtrConst(device).load(.acquire) and self.takes.getPtrConst(device).load(.acquire) != 0;
}

/// Keeps the cursor still and hidden from the next frame, so the mouse can turn something forever. Counted. Any thread.
pub fn holdMouse(self: *Overlay, on: bool) void {
    count(&self.holds, on);
}

/// How far the mouse was pushed since last frame while it's held, in pixels. Render thread.
pub fn mouseMotion(self: *const Overlay) input.Point {
    return self.mouse_motion;
}

/// From the user's settings. Any thread.
pub fn setEnabled(self: *Overlay, device: Device, on: bool) void {
    self.enabled.getPtr(device).store(on, .release);
    self.updateCapture();
    if (device == .mouse) self.updateConsumed();
}

/// Whether the game leaves the mouse free, as the player's setting picks.
pub const MouseFree = enum(u8) {
    /// As the game's plugin says
    auto,
    free,
    taken,
};

/// What game plugins say. Any thread.
pub fn setMouseFreeHint(self: *Overlay, free: bool) void {
    self.mouse_free_hint.store(free, .release);
}

/// The player's setting, over the hint. Any thread.
pub fn setMouseFreeChoice(self: *Overlay, choice: MouseFree) void {
    self.mouse_free_choice.store(choice, .release);
}

/// Whether our windows leave the mouse and keyboard with the game, taking only what's over or typed into them. Any thread.
pub fn mouseFree(self: *const Overlay) bool {
    return switch (self.mouse_free_choice.load(.acquire)) {
        .auto => self.mouse_free_hint.load(.acquire),
        .free => true,
        .taken => false,
    };
}

/// Hides `button`'s presses from the game till let go; the rest of the mouse stays the game's. Counted. Any thread.
pub fn consumeButton(self: *Overlay, button: tuft_input.MouseButton, on: bool) void {
    count(self.consumes.getPtr(button), on);
    self.updateConsumed();
}

/// Hides the wheel from the game. Counted like `take`. Any thread.
pub fn consumeWheel(self: *Overlay, on: bool) void {
    count(&self.consumes_wheel, on);
    self.updateConsumed();
}

fn updateConsumed(self: *Overlay) void {
    var bits: u8 = 0;
    for (std.enums.values(tuft_input.MouseButton)) |b| {
        if (self.consumes.getPtrConst(b).load(.acquire) != 0) bits |= Blocker.buttonBit(b);
    }
    const on = self.enabled.getPtrConst(.mouse).load(.acquire);
    self.blocker.consumeButtons(if (on) bits else 0);
    self.blocker.consumeWheel(on and self.consumes_wheel.load(.acquire) != 0);
}

/// Controllers reach ImGui from now on. `gamepads` has to outlive the overlay.
pub fn attachGamepads(self: *Overlay, gamepads: *Gamepads) !void {
    try gamepads.changed.subscribe(&self.subscriptions, self, onGamepads);
}

pub fn cursorRequested(self: *const Overlay) bool {
    return self.cursor_requests.load(.acquire) != 0;
}

fn framesLive(self: *const Overlay) bool {
    return self.nowMs() -| self.last_frame_ms.load(.acquire) <= Win32.stale_frame_ms;
}

fn nowMs(self: *const Overlay) u64 {
    const ns = std.Io.Clock.awake.now(self.io).nanoseconds;
    return @intCast(@max(0, @divTrunc(ns, std.time.ns_per_ms)));
}

fn count(counter: *Atomic(u32), on: bool) void {
    if (on) {
        _ = counter.fetchAdd(1, .acq_rel);
    } else {
        const before = counter.fetchSub(1, .acq_rel);
        std.debug.assert(before != 0); // dropped more than was taken
    }
}

fn mouseIsOurs(self: *const Overlay) bool {
    if (self.cursorRequested() or self.taken(.mouse)) return true;
    return switch (self.cursor_hint.load(.acquire)) {
        .auto => input.cursorVisible(),
        .visible => true,
        .hidden => false,
    };
}

/// Per device: what's taken plus what ImGui wants. ImGui wanting the mouse only takes clicks, so the game still sees it move.
fn updateCapture(self: *Overlay) void {
    var channels: Blocker.Channels = .empty;
    if (self.taken(.keyboard) or self.wanted(.keyboard)) channels.insert(.keyboard);
    if (self.taken(.mouse)) {
        channels.insert(.mouse_buttons);
        channels.insert(.mouse_motion);
    } else if (self.wanted(.mouse)) {
        channels.insert(.mouse_buttons);
    }
    if (self.taken(.gamepad) or self.wanted(.gamepad)) channels.insert(.gamepad);
    self.blocker.capture(channels);
}

fn wanted(self: *const Overlay, device: Device) bool {
    return self.enabled.getPtrConst(device).load(.acquire) and self.wants.getPtrConst(device).load(.acquire);
}

// Render thread

fn onFrame(self: *Overlay, frame: *const Graphics.Frame) void {
    self.frames.record(core.timing.now());
    const timed = core.timing.scope("overlay");
    defer timed.end();
    // ImGui and anyone drawing must see real input
    const bypass = Blocker.Bypass.begin();
    defer bypass.end();

    self.render_thread.store(std.Thread.getCurrentId(), .release);
    self.api.store(@backingInt(frame.api), .release);
    self.last_frame_ms.store(self.nowMs(), .release);
    // Before plugins' frames, even headless ones, so they see this frame's motion
    self.moveHeldMouse(frame.window);
    if (self.close_viewports.load(.acquire) and !self.viewports_closed.load(.acquire)) self.stopViewports();
    // Runs our windows' messages too, so their input lands in the queue
    if (!self.prepare(frame)) {
        // For good, so nothing asked for can come
        self.failCaptures();
        return self.headlessUpdate();
    }
    if (self.theme_request.swap(null, .acq_rel)) |theme| self.applyTheme(theme);

    const io = c.ImGui_GetIO();
    // Over ImGui's own windows the mouse is ImGui's, but never while held, since it's recentred every frame
    const mouse_ours = self.held == null and (self.mouseIsOurs() or (if (self.host.platform) |p| p.hoveringViewport() else false));
    var pending: [InputQueue.capacity]Queued = undefined;
    if (self.queue_overflowed.swap(false, .monotonic)) log.warn("Overlay input queue full; dropped events", .{});
    var focus_changed = false;
    for (self.queue.drain(&pending)) |queued| {
        var event = queued.event;
        if (self.host.platform != null) switch (event) {
            // Focus messages come in any order, so work out who has it once they're all in
            .focus => {
                focus_changed = true;
                continue;
            },
            // ImGui wants screen coordinates with viewports
            .mouse_move => |pos| if (!queued.viewport) {
                event = .{ .mouse_move = toScreen(frame.window, pos) };
            },
            else => {},
        };
        if (!mouse_ours and !queued.viewport and event.device() == .mouse) continue;
        imgui_input.feed(io, event);
    }
    if (focus_changed) c.ImGuiIO_AddFocusEvent(io, self.host.platform.?.appFocused());
    if (!mouse_ours) releaseMouse(io);

    io.*.MouseDrawCursor = self.cursorRequested() and self.held == null;
    // Keyboard nav grabs the keyboard whenever an ImGui window has focus, so only while it's taken
    setFlag(io, c.ImGuiConfigFlags_NavEnableKeyboard, self.taken(.keyboard));
    setFlag(io, c.ImGuiConfigFlags_NavEnableGamepad, self.taken(.gamepad));
    if (mouse_ours) {
        if (self.host.platform) |p| {
            if (p.appFocused()) pollMouse(io, null);
        } else if (tuft_window.isForeground(frame.window)) {
            pollMouse(io, frame.window);
        }
    }

    if (!self.host.beginFrame(frame, self.deltaTime())) return self.headlessUpdate();
    self.draw.fire(.{});
    self.update.fire(.{});
    // After plugins' frames and posing, so whatever they placed this frame is where it's drawn
    drawGizmos(self);
    // After plugins' frames, so one asked for in there is this frame
    self.requestCaptures();
    self.host.endFrame(frame);
    self.saveIniLater();

    // Picking a key for a keybind swallows every device, so the press doesn't reach the game
    const listening = tuft_imgui.takeListening();
    self.wants.getPtr(.mouse).store(io.*.WantCaptureMouse or listening, .release);
    self.wants.getPtr(.keyboard).store(io.*.WantCaptureKeyboard or listening, .release);
    self.wants.getPtr(.gamepad).store(listening, .release);
    self.keybinds.setTyping(io.*.WantTextInput);
    self.keybinds.setPaused(listening);
    self.updateCapture();
}

fn setFlag(io: *c.ImGuiIO, flag: c.ImGuiConfigFlags, on: bool) void {
    if (on) {
        io.*.ConfigFlags |= flag;
    } else {
        io.*.ConfigFlags &= ~flag;
    }
}

/// Measures how far the held cursor went and recentres it. Call inside a `Blocker.Bypass`.
fn moveHeldMouse(self: *Overlay, window: tuft_window.Handle) void {
    const hold = self.holds.load(.acquire) != 0 and tuft_window.isForeground(window);
    if (!hold) {
        if (self.held) |h| input.moveCursor(h.home);
        self.held = null;
        self.holding.store(false, .release);
        self.mouse_motion = .{ .x = 0, .y = 0 };
        return;
    }
    const now = input.screenCursorPosition() orelse return;
    // The window can move, so it's worked out each time
    const middle = input.clientCenter(window) orelse return;
    if (self.held) |*h| {
        self.mouse_motion = .{ .x = now.x - h.anchor.x, .y = now.y - h.anchor.y };
        h.anchor = middle;
    } else {
        self.held = .{ .anchor = middle, .home = now };
        self.mouse_motion = .{ .x = 0, .y = 0 };
    }
    self.holding.store(true, .release);
    input.moveCursor(middle);
}

fn requestCaptures(self: *Overlay) void {
    const captures = self.captures orelse return;
    for ([_]tuft_imgui.capture.Point{ .before, .after }) |point| {
        if (captures.wants(point)) self.host.requestCapture(point);
    }
}

fn failCaptures(self: *Overlay) void {
    const captures = self.captures orelse return;
    for ([_]tuft_imgui.capture.Point{ .before, .after }) |point| {
        if (captures.wants(point)) captures.event(.{ .failed = point }, @fromBackingInt(@intCast(self.api.load(.acquire))));
    }
}

fn onCaptured(self: *Overlay, event: tuft_imgui.capture.Event) void {
    const captures = self.captures orelse return;
    captures.event(event, @fromBackingInt(@intCast(self.api.load(.acquire))));
}

/// The gizmo in front. Draggable only while the overlay has the mouse, so clicks go to the game otherwise.
fn drawGizmos(self: *Overlay) void {
    const v = host_frame.view();
    Gizmos.draw(if (v.known) .{ .view = v.viewMatrix, .projection = v.projection } else null, self.taken(.mouse));
}

fn onSurfaceChange(self: *Overlay, _: *const Graphics.Frame) void {
    self.host.releaseTarget();
}

/// Fires `update` in a headless ImGui frame, for when the overlay can't draw this one.
fn headlessUpdate(self: *Overlay) void {
    if (self.update.count() == 0) return;
    const previous = c.ImGui_GetCurrentContext();
    defer c.ImGui_SetCurrentContext(previous);
    const context = self.headless orelse made: {
        if (self.headless_failed) return;
        const made = c.ImGui_CreateContext(null) orelse {
            log.err("No headless ImGui context, so plugins' frames won't run", .{});
            self.headless_failed = true;
            return;
        };
        // Making it only switches to it if there wasn't one
        c.ImGui_SetCurrentContext(made);
        const io = c.ImGui_GetIO();
        io.*.IniFilename = null;
        io.*.DisplaySize = .{ .x = 1920, .y = 1080 };
        io.*.ConfigErrorRecoveryEnableAssert = false;
        tuft_imgui.headless.init();
        self.headless = made;
        break :made made;
    };
    c.ImGui_SetCurrentContext(context);
    c.ImGui_GetIO().*.DeltaTime = self.deltaTime();
    c.ImGui_NewFrame();
    tuft_imgui.headless.textures();
    self.update.fire(.{});
    c.ImGui_EndFrame();
}

fn prepare(self: *Overlay, frame: *const Graphics.Frame) bool {
    if (self.failed) return false;
    self.host.prepare(frame, self.monitors_changed.swap(false, .acq_rel)) catch |err| return self.fail(switch (err) {
        error.CreateContextFailed => "ImGui_CreateContext failed",
        error.UnsupportedApi => "this graphics API isn't supported by the overlay yet",
        error.BackendFailed => "ImGui's renderer backend failed to start",
    });
    return true;
}

fn setUpContext(ctx: *anyopaque, frame: *const Graphics.Frame) void {
    const self: *Overlay = @ptrCast(@alignCast(ctx));
    const io = c.ImGui_GetIO();
    // ImGui would read and write it on the render thread, so we do it elsewhere
    io.*.IniFilename = null;
    if (self.ini_text) |text| {
        c.ImGui_LoadIniSettingsFromMemory(@ptrCast(text.ptr), text.len);
        self.allocator.free(text);
        self.ini_text = null;
    }
    io.*.BackendPlatformName = ui.str("wraith");
    // Plugin usage errors get unwound after their draw, see host/ui.zig
    io.*.ConfigErrorRecoveryEnableAssert = false;

    self.default_style = c.ImGui_GetStyle().*;
    self.ui_scale = tuft_window.dpiScale(frame.window) * self.options.scale;
    fonts.load(font_size);
    self.applyTheme(self.options.theme);
}

/// Unscaled. ImGui's own font size, so windows stay the size they were.
const font_size = 13;

/// Null if there isn't one yet. Not on the render thread.
fn readIni(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    // std's file calls want more stack than the caller may have
    var reading = io.concurrent(readIniOnWorker, .{ allocator, io, path }) catch return null;
    return reading.await(io) catch null;
}

fn readIniOnWorker(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 << 20));
}

/// Render thread, after a frame. ImGui asks every few seconds once the layout changed.
fn saveIniLater(self: *Overlay) void {
    const io = c.ImGui_GetIO();
    if (!io.*.WantSaveIniSettings) return;
    io.*.WantSaveIniSettings = false;
    const path = self.ini_path orelse return;
    var len: usize = 0;
    const text = c.ImGui_SaveIniSettingsToMemory(&len);
    self.ini_saver.save(path, @as([*]const u8, @ptrCast(text))[0..len]) catch {};
}

/// Before the context goes, from whatever thread that is.
fn saveIniNow(self: *Overlay) void {
    const path = self.ini_path orelse return;
    const context = self.host.context orelse return;
    const previous = c.ImGui_GetCurrentContext();
    defer c.ImGui_SetCurrentContext(previous);
    c.ImGui_SetCurrentContext(context);
    var len: usize = 0;
    const text = c.ImGui_SaveIniSettingsToMemory(&len);
    self.ini_saver.save(path, @as([*]const u8, @ptrCast(text))[0..len]) catch {};
}

fn iniFailed(path: []const u8, err: anyerror) void {
    log.warn("Couldn't save {s}: {t}", .{ path, err });
}

fn fail(self: *Overlay, reason: []const u8) bool {
    log.err("Overlay disabled: {s}", .{reason});
    self.failed = true;
    return false;
}

/// Render thread, between frames.
fn applyTheme(self: *Overlay, theme: ?*const Themes.Theme) void {
    const style = c.ImGui_GetStyle();
    if (theme) |t| {
        t.apply(style, &self.default_style);
    } else {
        style.* = self.default_style;
    }
    c.ImGuiStyle_ScaleAllSizes(style, self.ui_scale);
    style.*.FontScaleDpi = self.ui_scale;
    style.*.FontSizeBase = font_size;
    self.theme = theme;
    self.shown_theme.store(theme, .release);
}

/// From the next frame. `theme` must outlive the overlay. Any thread.
pub fn setTheme(self: *Overlay, theme: *const Themes.Theme) void {
    self.theme_request.store(theme, .release);
}

/// Any thread.
pub fn currentTheme(self: *const Overlay) ?*const Themes.Theme {
    return self.shown_theme.load(.acquire);
}

/// Null before the first frame. Any thread.
pub fn graphicsApi(self: *const Overlay) ?Graphics.Api {
    const api = self.api.load(.acquire);
    return if (api == 0) null else @fromBackingInt(@intCast(api));
}

fn deltaTime(self: *Overlay) f32 {
    const now = std.Io.Clock.awake.now(self.io);
    defer self.last_frame = now;
    const last = self.last_frame orelse return 1.0 / 60.0;
    const seconds = @as(f32, @floatFromInt(last.durationTo(now).nanoseconds)) / std.time.ns_per_s;
    return @max(seconds, 1e-6); // ImGui asserts on zero
}

fn releaseMouse(io: *c.ImGuiIO) void {
    imgui_input.feed(io, .mouse_leave);
    for (std.enums.values(tuft_input.MouseButton)) |b| imgui_input.feed(io, .{ .mouse_button = .{ .button = b, .down = false } });
}

/// Feeds the mouse from hardware state, for games that suppress mouse messages.
fn pollMouse(io: *c.ImGuiIO, window: ?tuft_window.Handle) void {
    if (window) |w| {
        if (input.cursorPosition(w)) |p| imgui_input.feed(io, .{ .mouse_move = p });
    } else {
        if (input.screenCursorPosition()) |p| imgui_input.feed(io, .{ .mouse_move = p });
    }
    for ([_]tuft_input.MouseButton{ .left, .right, .middle }) |b| {
        imgui_input.feed(io, .{ .mouse_button = .{ .button = b, .down = input.isButtonDown(b) } });
    }
}

// Window thread

fn onMessage(self: *Overlay, m: *const Window.Message) ?isize {
    if (self.options.viewports and Win32.changesMonitors(m.raw)) self.monitors_changed.store(true, .release);
    const event = m.event orelse return null;
    if (event == .cursor) {
        // Held for looking around, so no cursor at all
        if (self.holding.load(.acquire) and self.framesLive()) {
            input.hideCursor();
            return input.handledResult(event);
        }
        // Only while frames are drawing ImGui's cursor instead
        if (!self.cursorRequested() or !self.framesLive()) return null;
        // ImGui draws the cursor, so stop the game setting its own
        input.hideCursor();
        return input.handledResult(event);
    }
    self.queue.pushCoalesced(.{ .event = event }, Queued.supersedes) catch self.queue_overflowed.store(true, .monotonic);
    return null;
}

/// Gamepad poll thread. ImGui always gets them so its state stays right, but only navigates while taken.
fn onGamepads(self: *Overlay, update: *const Gamepads.Update) void {
    for (update.changes) |change| {
        self.queue.push(.{ .event = .{ .key = .{ .key = change.key, .down = change.down } } }) catch self.queue_overflowed.store(true, .monotonic);
    }
    if (update.axes_changed) {
        self.queue.pushCoalesced(.{ .event = .{ .gamepad_axes = update.axes() } }, Queued.supersedes) catch self.queue_overflowed.store(true, .monotonic);
    }
}

fn toScreen(window: tuft_window.Handle, p: input.Point) input.Point {
    const s = tuft_window.clientToScreen(window, .{ .x = p.x, .y = p.y }) orelse return p;
    return .{ .x = s.x, .y = s.y };
}

/// Render thread, inside their window proc. Queued in screen coords.
fn onViewportInput(ctx: *anyopaque, viewport_input: Win32.Input) void {
    const self: *Overlay = @ptrCast(@alignCast(ctx));
    const event: input.Event = switch (viewport_input) {
        .mouse_left => .mouse_leave,
        .message => |m| blk: {
            // A game paused by losing focus renders again
            if (m.msg == WM_ACTIVATE and m.wparam & 0xFFFF != 0) self.ourWindowActivated();
            // Key messages read the modifier state, so it has to be the real one
            const bypass = Blocker.Bypass.begin();
            defer bypass.end();
            const event = self.viewport_translator.translate(m) orelse return;
            break :blk switch (event) {
                .cursor => return,
                .mouse_move => |p| .{ .mouse_move = toScreen(m.window, p) },
                else => event,
            };
        },
    };
    self.queue.pushCoalesced(.{ .event = event, .viewport = true }, Queued.supersedes) catch |err| switch (err) {
        error.QueueFull => self.queue_overflowed.store(true, .monotonic),
        error.Closed => {},
    };
}

const tests = struct {
    const testing = std.testing;
    const api = wraith_platform.win.api;
    const gfx = @import("tuft_gfx");
    const Rig = @import("../testing/Rig.zig");

    const Drawer = struct {
        draws: u32 = 0,

        fn draw(self: *Drawer) void {
            self.draws += 1;
            _ = c.ImGui_Begin(ui.str("test"), null, 0);
            c.ImGui_TextUnformatted(ui.str("frame"));
            c.ImGui_End();
        }
    };

    test "draw every frame" {
        var rig: Rig = undefined;
        try rig.init(.{});
        var destroyed = false;
        defer if (!destroyed) rig.deinit();
        var drawer: Drawer = .{};
        try rig.overlay.draw.subscribe(&rig.scope, &drawer, Drawer.draw);

        rig.present();
        rig.present();
        try testing.expectEqual(2, drawer.draws);

        // Fails if anything still holds the old buffers
        try testing.expect(rig.resize(128, 96));
        rig.present();
        try testing.expectEqual(3, drawer.draws);
        try testing.expect(c.ImGui_GetDrawData().*.CmdListsCount > 0);
        const textures = c.ImGui_GetPlatformIO().*.Textures;
        for (textures.Data[0..@intCast(textures.Size)]) |tex| try testing.expectEqual(c.ImTextureStatus_OK, @as(c_int, @intCast(tex.*.Status)));

        rig.deinit(); // presenting now would be unhooked
        destroyed = true;
        try testing.expectEqual(3, drawer.draws);
    }

    const Updater = struct {
        updates: u32 = 0,
        context: ?*c.ImGuiContext = null,
        drawer: Drawer = .{},

        fn update(self: *Updater) void {
            self.updates += 1;
            self.context = c.ImGui_GetCurrentContext();
            // UI goes somewhere either way
            self.drawer.draw();
        }
    };

    test "update runs headless when the overlay can't draw" {
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        var drawer: Drawer = .{};
        try rig.overlay.draw.subscribe(&rig.scope, &drawer, Drawer.draw);
        var updater: Updater = .{};
        try rig.overlay.update.subscribe(&rig.scope, &updater, Updater.update);

        rig.present();
        try testing.expectEqual(1, drawer.draws);
        try testing.expectEqual(1, updater.updates);
        const overlay_context = updater.context;

        // Like an API it can't draw with. No overlay frame, but updates go on
        rig.overlay.failed = true;
        rig.present();
        rig.present();
        try testing.expectEqual(1, drawer.draws);
        try testing.expectEqual(3, updater.updates);
        try testing.expect(updater.context != null and updater.context != overlay_context);
        try testing.expectEqual(rig.overlay.headless, updater.context);
    }

    test "theme applies next frame" {
        const saved = core.log.mute(&.{.ui});
        defer core.log.setFilter(saved);
        var themes = try Themes.load(testing.allocator, testing.io, null);
        defer themes.deinit();
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        rig.present();
        const scale = rig.overlay.ui_scale;
        try testing.expectEqual(null, rig.overlay.theme);
        try testing.expectEqual(3, c.ImGui_GetIO().*.Fonts.*.Fonts.Size);
        const mono = ui.monospace();
        try testing.expect(mono.pushed);
        mono.end();

        rig.overlay.setTheme(themes.find("Dark"));
        rig.present();
        const style = c.ImGui_GetStyle();
        try testing.expectEqualStrings("Dark", rig.overlay.theme.?.name);
        // ImGui rounds sizes to whole pixels
        try testing.expectEqual(@trunc(4 * scale), style.*.FrameRounding);
        try testing.expectEqual(@trunc(10 * scale), style.*.WindowPadding.x);
        try testing.expectApproxEqAbs(0.118, style.*.Colors[c.ImGuiCol_WindowBg].x, 0.001);
        try testing.expectEqual(scale, style.*.FontScaleDpi);

        // A theme that sets nothing gives ImGui's defaults again, not Dark's scaled twice
        const plain: Themes.Theme = .{ .name = "Plain", .file = .{}, .builtin = false };
        rig.overlay.setTheme(&plain);
        rig.present();
        try testing.expectEqual(@trunc(rig.overlay.default_style.WindowPadding.x * scale), style.*.WindowPadding.x);
    }

    test "layout saved to ini_path" {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        defer testing.allocator.free(root);
        const path = try std.fs.path.join(testing.allocator, &.{ root, "imgui.ini" });
        defer testing.allocator.free(path);

        var rig: Rig = undefined;
        try rig.init(.{ .ini_path = path });
        var drawer: Drawer = .{};
        try rig.overlay.draw.subscribe(&rig.scope, &drawer, Drawer.draw);
        rig.present();
        rig.deinit(); // saves

        const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(64 << 10));
        defer testing.allocator.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "[Window][test]") != null);

        // Read at start and handed to ImGui, which never touches the file itself
        try rig.init(.{ .ini_path = path });
        defer rig.deinit();
        rig.present();
        try testing.expect(c.ImGui_GetIO().*.IniFilename == null);
        const loaded = std.mem.span(@as([*:0]const u8, @ptrCast(c.ImGui_SaveIniSettingsToMemory(null))));
        try testing.expect(std.mem.indexOf(u8, loaded, "[Window][test]") != null);
    }

    test "devices taken on their own" {
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        rig.present(); // attaches

        rig.overlay.take(.keyboard, true);
        rig.overlay.take(.keyboard, true); // someone else too
        rig.present();
        try testing.expect(rig.overlay.taken(.keyboard) and !rig.overlay.taken(.mouse));
        try testing.expect(c.ImGui_GetIO().*.ConfigFlags & c.ImGuiConfigFlags_NavEnableKeyboard != 0);
        // Taking and the cursor are separate requests
        try testing.expect(!c.ImGui_GetIO().*.MouseDrawCursor);
        _ = rig.send(api.WM_LBUTTONDOWN, 1, 0x0020_0010);
        _ = rig.send(api.WM_KEYDOWN, 'W', 1);
        try testing.expectEqual(1, Rig.game.count(api.WM_LBUTTONDOWN));
        try testing.expectEqual(0, Rig.game.count(api.WM_KEYDOWN));

        rig.overlay.take(.mouse, true);
        rig.present();
        _ = rig.send(api.WM_LBUTTONDOWN, 1, 0x0020_0010);
        try testing.expectEqual(1, Rig.game.count(api.WM_LBUTTONDOWN));
        try testing.expect(rig.blocker.captured().contains(.mouse_motion));
        rig.overlay.take(.mouse, false);

        rig.overlay.take(.keyboard, false);
        rig.present();
        try testing.expect(rig.overlay.taken(.keyboard)); // one left
        _ = rig.send(api.WM_KEYDOWN, 'W', 1);
        try testing.expectEqual(0, Rig.game.count(api.WM_KEYDOWN));

        rig.overlay.take(.keyboard, false);
        rig.present();
        try testing.expect(!rig.overlay.taken(.keyboard));
        try testing.expect(c.ImGui_GetIO().*.ConfigFlags & c.ImGuiConfigFlags_NavEnableKeyboard == 0);
        _ = rig.send(api.WM_LBUTTONDOWN, 1, 0x0020_0010);
        _ = rig.send(api.WM_KEYDOWN, 'W', 1);
        try testing.expectEqual(2, Rig.game.count(api.WM_LBUTTONDOWN));
        try testing.expectEqual(1, Rig.game.count(api.WM_KEYDOWN));
    }

    test "picking a key swallows every device" {
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        const Picker = struct {
            listen: bool = true,
            chord: ?tuft_input.Chord = null,

            fn draw(self: *@This()) void {
                if (!self.listen) return;
                _ = c.ImGui_Begin(ui.str("keys"), null, 0);
                _ = ui.chordInput("##key", &self.chord, .{ .listen = true });
                c.ImGui_End();
            }
        };
        var picker: Picker = .{};
        try rig.overlay.draw.subscribe(&rig.scope, &picker, Picker.draw);
        rig.present();
        rig.present();
        const captured = rig.blocker.captured();
        try testing.expect(captured.contains(.keyboard) and captured.contains(.mouse_buttons) and captured.contains(.gamepad));

        // Controllers not allowed at all stay with the game
        rig.overlay.setEnabled(.gamepad, false);
        try testing.expect(!rig.blocker.captured().contains(.gamepad));
        try testing.expect(rig.blocker.captured().contains(.keyboard));
        rig.overlay.setEnabled(.gamepad, true);

        picker.listen = false;
        rig.present();
        rig.present();
        try testing.expect(!rig.blocker.captured().contains(.gamepad));
        try testing.expect(!rig.blocker.captured().contains(.keyboard));
    }

    test "controllers and turning a device off" {
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        rig.present();

        rig.overlay.take(.keyboard, true);
        rig.overlay.take(.mouse, true);
        rig.present();
        try testing.expect(!rig.blocker.captured().contains(.gamepad));
        try testing.expect(c.ImGui_GetIO().*.ConfigFlags & c.ImGuiConfigFlags_NavEnableGamepad == 0);

        rig.overlay.take(.gamepad, true);
        rig.present();
        try testing.expect(rig.blocker.captured().contains(.gamepad));
        try testing.expect(c.ImGui_GetIO().*.ConfigFlags & c.ImGuiConfigFlags_NavEnableGamepad != 0);

        // Turned off, the game keeps it even while taken
        rig.overlay.setEnabled(.gamepad, false);
        rig.present();
        try testing.expect(!rig.overlay.taken(.gamepad));
        try testing.expect(!rig.blocker.captured().contains(.gamepad));
        try testing.expect(c.ImGui_GetIO().*.ConfigFlags & c.ImGuiConfigFlags_NavEnableGamepad == 0);
        rig.overlay.setEnabled(.gamepad, true);

        rig.overlay.take(.keyboard, false);
        rig.overlay.take(.mouse, false);
        rig.present();
        try testing.expect(rig.blocker.captured().contains(.gamepad));
        rig.overlay.take(.gamepad, false);
        rig.present();
        try testing.expect(!rig.blocker.captured().contains(.gamepad));
    }

    test "messages reach ImGui" {
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        rig.overlay.setCursorHint(.visible); // don't depend on the real cursor
        rig.present();

        const Recorder = struct {
            chars: u32 = 0,
            last: c.ImWchar = 0,

            fn draw(self: *@This()) void {
                const queue = c.ImGui_GetIO().*.InputQueueCharacters;
                self.chars += @intCast(queue.Size);
                if (queue.Size > 0) self.last = queue.Data[0];
            }
        };
        var recorder: Recorder = .{};
        try rig.overlay.draw.subscribe(&rig.scope, &recorder, Recorder.draw);

        _ = rig.send(api.WM_MOUSEMOVE, 0, (20 << 16) | 10);
        _ = rig.send(api.WM_CHAR, 'x', 0);
        rig.present();
        rig.present(); // ImGui holds back text that follows a mouse move to the next frame
        const io = c.ImGui_GetIO();
        try testing.expectEqual(10, io.*.MousePos.x);
        try testing.expectEqual(20, io.*.MousePos.y);
        try testing.expectEqual(1, recorder.chars);
        try testing.expectEqual('x', recorder.last);
        try testing.expect(io.*.DisplaySize.x > 0 and io.*.DeltaTime > 0);
    }

    test "window under cursor takes clicks" {
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        const Panel = struct {
            fn draw(_: *@This()) void {
                c.ImGui_SetNextWindowPos(.{ .x = 0, .y = 0 }, c.ImGuiCond_Always);
                c.ImGui_SetNextWindowSize(.{ .x = 200, .y = 200 }, c.ImGuiCond_Always);
                _ = c.ImGui_Begin(ui.str("stats"), null, 0);
                c.ImGui_End();
            }
        };
        var panel: Panel = .{};
        try rig.overlay.draw.subscribe(&rig.scope, &panel, Panel.draw);
        rig.overlay.setCursorHint(.visible);
        rig.present(); // attaches

        // Inside the small test window's client area
        const over_panel: isize = (5 << 16) | 5;
        _ = rig.send(api.WM_MOUSEMOVE, 0, over_panel);
        rig.present();
        rig.present();
        try testing.expect(!rig.overlay.taken(.mouse));
        try testing.expect(c.ImGui_GetIO().*.WantCaptureMouse);

        const moves = Rig.game.count(api.WM_MOUSEMOVE);
        _ = rig.send(api.WM_LBUTTONDOWN, 1, over_panel);
        _ = rig.send(api.WM_LBUTTONUP, 0, over_panel);
        _ = rig.send(api.WM_MOUSEMOVE, 0, over_panel + 1);
        try testing.expectEqual(0, Rig.game.count(api.WM_LBUTTONDOWN)); // the panel's
        try testing.expectEqual(moves + 1, Rig.game.count(api.WM_MOUSEMOVE)); // still the game's
        try testing.expect(!c.ImGui_GetIO().*.MouseDrawCursor);

        // Mouse-look, so the panel takes nothing
        rig.overlay.setCursorHint(.hidden);
        rig.present();
        rig.present();
        try testing.expect(!c.ImGui_GetIO().*.WantCaptureMouse);
        _ = rig.send(api.WM_LBUTTONDOWN, 1, over_panel);
        try testing.expectEqual(1, Rig.game.count(api.WM_LBUTTONDOWN));
    }

    test "viewport window takes input" {
        var rig: Rig = undefined;
        try rig.init(.{ .viewports = true });
        var destroyed = false;
        defer if (!destroyed) rig.deinit();
        var outside: Outside = .{};
        try rig.overlay.draw.subscribe(&rig.scope, &outside, Outside.draw);
        rig.overlay.setCursorHint(.visible);
        rig.present(); // attaches
        rig.present();
        rig.present();

        const pio = c.ImGui_GetPlatformIO();
        try testing.expectEqual(2, pio.*.Viewports.Size);
        try testing.expectEqual(@as(?*anyopaque, rig.hwnd), pio.*.Viewports.Data[0].*.PlatformHandle);
        const hwnd: api.HWND = @ptrCast(pio.*.Viewports.Data[1].*.PlatformHandle.?);
        try testing.expect(api.IsWindow(hwnd).toBool());
        try testing.expect(c.ImGui_GetIO().*.ConfigFlags & c.ImGuiConfigFlags_ViewportsEnable != 0);

        _ = rig.send(api.WM_MOUSEMOVE, 0, (7 << 16) | 9);
        rig.present();
        var expected: api.POINT = .{ .x = 9, .y = 7 };
        _ = api.ClientToScreen(rig.hwnd, &expected);
        const io = c.ImGui_GetIO();
        try testing.expectEqual(@as(f32, @floatFromInt(expected.x)), io.*.MousePos.x);
        try testing.expectEqual(@as(f32, @floatFromInt(expected.y)), io.*.MousePos.y);

        // A wheel, not a click, since a click would steal focus while tests run
        rig.overlay.setCursorHint(.hidden);
        _ = tuft_window.send(hwnd, api.WM_MOUSEWHEEL, 120 << 16, 0);
        rig.present();
        try testing.expectEqual(1, outside.wheel);
        try testing.expectEqual(0, Rig.game.count(api.WM_MOUSEWHEEL));

        rig.deinit();
        destroyed = true;
        try testing.expect(!api.IsWindow(hwnd).toBool());
    }

    const Outside = struct {
        draws: u32 = 0,
        wheel: f32 = 0,

        fn draw(self: *@This()) void {
            self.draws += 1;
            self.wheel += c.ImGui_GetIO().*.MouseWheel;
            const main = c.ImGui_GetMainViewport();
            c.ImGui_SetNextWindowPos(.{ .x = main.*.Pos.x + main.*.Size.x + 100, .y = main.*.Pos.y }, c.ImGuiCond_Always);
            c.ImGui_SetNextWindowSize(.{ .x = 200, .y = 120 }, c.ImGuiCond_Always);
            _ = c.ImGui_Begin(ui.str("outside"), null, c.ImGuiWindowFlags_NoFocusOnAppearing);
            c.ImGui_End();
        }
    };

    test "reload draws again" {
        inline for (.{ .d3d11, .d3d10, .d3d12, .d3d9, .opengl, .vulkan }) |graphics_api| {
            const options: Rig.Options = .{ .viewports = true, .api = graphics_api };
            var rig: Rig = undefined;
            try rig.init(options);
            defer rig.deinit();
            for (0..3) |_| rig.present();

            try rig.reload(options);
            var drawer: Drawer = .{};
            try rig.overlay.draw.subscribe(&rig.scope, &drawer, Drawer.draw);
            for (0..5) |_| rig.present();
            try testing.expect(drawer.draws >= 3);
        }
    }

    test "closing viewports mid-session" {
        var rig: Rig = undefined;
        try rig.init(.{ .viewports = true });
        defer rig.deinit();
        var outside: Outside = .{};
        try rig.overlay.draw.subscribe(&rig.scope, &outside, Outside.draw);
        rig.present();
        rig.present();
        const pio = c.ImGui_GetPlatformIO();
        try testing.expectEqual(2, pio.*.Viewports.Size);
        const hwnd: api.HWND = @ptrCast(pio.*.Viewports.Data[1].*.PlatformHandle.?);

        // Like on unload. DX12's backend has state on the main viewport we mustn't touch then
        rig.overlay.close_viewports.store(true, .release);
        rig.present();
        try testing.expect(rig.overlay.viewports_closed.load(.acquire));
        try testing.expect(!api.IsWindow(hwnd).toBool());
        try testing.expectEqual(null, rig.overlay.host.platform);

        const draws = outside.draws;
        rig.present();
        try testing.expectEqual(draws + 1, outside.draws);
    }

    test "cursor and taking the mouse are separate" {
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        rig.overlay.setCursorHint(.hidden); // mouse-look
        rig.present(); // attaches

        rig.overlay.requestCursor(true);
        rig.overlay.requestCursor(true); // a second plugin
        rig.present();
        try testing.expect(c.ImGui_GetIO().*.MouseDrawCursor);
        try testing.expect(!rig.overlay.taken(.mouse));
        try testing.expect(!rig.blocker.captured().contains(.mouse_motion));

        rig.overlay.take(.mouse, true);
        rig.present();
        const moves = Rig.game.count(api.WM_MOUSEMOVE);
        _ = rig.send(api.WM_MOUSEMOVE, 0, (6 << 16) | 6);
        _ = rig.send(api.WM_LBUTTONDOWN, 1, (6 << 16) | 6);
        try testing.expectEqual(moves, Rig.game.count(api.WM_MOUSEMOVE)); // no spinning camera
        try testing.expectEqual(0, Rig.game.count(api.WM_LBUTTONDOWN));

        rig.overlay.requestCursor(false);
        rig.present();
        try testing.expect(c.ImGui_GetIO().*.MouseDrawCursor); // one request left

        rig.overlay.requestCursor(false);
        rig.overlay.take(.mouse, false);
        rig.present();
        try testing.expect(!c.ImGui_GetIO().*.MouseDrawCursor);
        try testing.expect(!rig.blocker.captured().contains(.mouse_motion));
        _ = rig.send(api.WM_MOUSEMOVE, 0, (7 << 16) | 7);
        try testing.expectEqual(moves + 1, Rig.game.count(api.WM_MOUSEMOVE));
    }
};

test {
    _ = tests;
}
