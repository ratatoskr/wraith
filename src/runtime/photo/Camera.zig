//! The free camera: fly or orbit the camera plugins hand over each frame.
//! The game's thread only copies in and out, the render thread moves it.

const Camera = @This();

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;
const math = @import("tuft_math");
const tuft_input = @import("tuft_input");
const Keybinds = tuft_input.Keybinds;
const Keys = tuft_input.Keys;

const core = @import("wraith_core");
const api = @import("wraith_api");
const ui = @import("wraith_ui");

const Registry = @import("../settings/Registry.zig");
const Settings = @import("../Settings.zig");
const Photo = @import("Photo.zig");
const Overlay = @import("../ui/Overlay.zig");
const host_keys = @import("../host/keybinds.zig");
const rig = @import("rig.zig");

const W = api.wraith;
const V3 = rig.V3;

/// Listed under it in Settings.
const title = "Camera";

/// What the game's thread and the render thread share. The game's thread only copies in and out.
const Shared = struct {
    lock: Atomic(u32) = .init(0),
    basis: rig.Basis = .default,
    metre: f32 = 1,
    /// The game's camera, as of the last frame the free camera was off
    game: rig.Camera = undefined,
    seen: bool = false,
    on: bool = false,
    pose: rig.Pose = undefined,
    /// A point something wants to orbit, till the render thread picks it up
    focus_at: ?V3 = null,
    /// Which of the game's cameras was handed over last, so a cut restarts the pose
    id: u64 = 0,
    /// It did, till the render thread picks it up
    restarted: bool = false,

    fn acquire(s: *Shared) void {
        while (s.lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn release(s: *Shared) void {
        s.lock.store(0, .release);
    }
};

/// Kept down to move, look and so on.
pub const Hold = enum {
    forward,
    back,
    left,
    right,
    up,
    down,
    faster,
    slower,
    turn_left,
    turn_right,
    turn_up,
    turn_down,
    roll_left,
    roll_right,
    zoom_in,
    zoom_out,

    fn def(h: Hold) Def {
        return switch (h) {
            .forward => .{ "Forward", &.{.w} },
            .back => .{ "Back", &.{.s} },
            .left => .{ "Left", &.{.a} },
            .right => .{ "Right", &.{.d} },
            .up => .{ "Up", &.{.e} },
            .down => .{ "Down", &.{.q} },
            .faster => .{ "Faster", &.{ .left_shift, .gamepad_right_shoulder } },
            .slower => .{ "Slower", &.{ .left_ctrl, .gamepad_left_shoulder } },
            .turn_left => .{ "Turn left", &.{.left} },
            .turn_right => .{ "Turn right", &.{.right} },
            .turn_up => .{ "Look up", &.{.up} },
            .turn_down => .{ "Look down", &.{.down} },
            .roll_left => .{ "Roll left", &.{ .z, .gamepad_dpad_left } },
            .roll_right => .{ "Roll right", &.{ .c, .gamepad_dpad_right } },
            .zoom_in => .{ "Zoom in", &.{ .equal, .gamepad_dpad_up } },
            .zoom_out => .{ "Zoom out", &.{ .minus, .gamepad_dpad_down } },
        };
    }
};

/// Pressed once.
pub const Press = enum {
    toggle,
    orbit,
    level,
    controls,

    fn def(p: Press) Def {
        return switch (p) {
            // No controller button by default, so it can't clash with the game's
            .toggle => .{ "Turn the free camera on or off", &.{.f6} },
            .orbit => .{ "Switch between flying and orbiting", &.{ .o, .gamepad_x } },
            .level => .{ "Level the camera", &.{ .x, .gamepad_y } },
            .controls => .{ "Show or hide the camera's controls", &.{.h} },
        };
    }
};

/// Its name and its keys by default.
const Def = struct { []const u8, []const tuft_input.Key };

const HoldKey = struct {
    setting: *Registry.Setting = undefined,
    down: Atomic(bool) = .init(false),

    fn fired(ctx: *anyopaque, phase: Keybinds.Phase) void {
        const self: *HoldKey = @ptrCast(@alignCast(ctx));
        self.down.store(phase == .pressed, .release);
    }
};

const PressKey = struct {
    setting: *Registry.Setting = undefined,
    which: Press,
    camera: *Camera = undefined,

    fn fired(ctx: *anyopaque, phase: Keybinds.Phase) void {
        const self: *PressKey = @ptrCast(@alignCast(ctx));
        if (phase == .pressed) self.camera.pressed(self.which);
    }
};

/// Read each frame while it's on.
const Options = struct {
    speed: f32,
    smoothing: f32,
    hide: Hide,
    sensitivity: f32,
    mouse_look: MouseLook,
    gamepad: bool,
    pad_sensitivity: f32,
};

/// How close and far orbiting goes, in metres.
const min_distance = 0.2;
/// Degrees the field of view goes between, by the zoom keys or the slider.
const min_fov = 5;
const max_fov = 150;
const max_distance = 100;

const MouseLook = enum { right, middle, left, always };

/// What the game stops seeing while it's on.
const Hide = enum { controls, everything, nothing };
const hide_options = [_][]const u8{ "Only the camera's controls", "Everything", "Nothing" };

/// What it's hidden from the game, to change only what changed.
const Hidden = struct {
    everything: bool = false,
    keys: bool = false,
    button: ?tuft_input.MouseButton = null,
    wheel: bool = false,
    /// While looking, or always for mouse-look that's always on
    mouse: bool = false,
    pad: bool = false,
};
const mouse_look_options = [_][]const u8{ "While the right button's held", "While the middle button's held", "While the left button's held", "Always" };

const Corner = enum { top_left, top_right, bottom_left, bottom_right };
const corner_options = [_][]const u8{ "Top left", "Top right", "Bottom left", "Bottom right" };

registry: *Registry,
overlay: *Overlay,
keybinds: *Keybinds,
shared: Shared = .{},
speed: *Registry.Setting = undefined,
smoothing: *Registry.Setting = undefined,
hide_from_game: *Registry.Setting = undefined,
sensitivity: *Registry.Setting = undefined,
mouse_look: *Registry.Setting = undefined,
gamepad: *Registry.Setting = undefined,
pad_sensitivity: *Registry.Setting = undefined,
show_controls: *Registry.Setting = undefined,
corner: *Registry.Setting = undefined,
holds: std.EnumArray(Hold, HoldKey) = .initFill(.{}),
presses: std.EnumArray(Press, PressKey) = .init(.{
    .toggle = .{ .which = .toggle },
    .orbit = .{ .which = .orbit },
    .level = .{ .which = .level },
    .controls = .{ .which = .controls },
}),
/// Whether it's on, for any thread.
on_flag: Atomic(bool) = .init(false),
/// Everything it added to the registry, to take out again.
added: [40]*Registry.Setting = undefined,
added_len: usize = 0,

// Render thread only from here down

on: bool = false,
hidden: Hidden = .{},
/// Where the pose is heading, which it eases toward
goal: rig.Pose = undefined,
velocity: V3 = @splat(0),
/// From the mouse wheel, times the speed setting
boost: f32 = 1,
/// Orbiting round `pivot` from `distance` away, rather than flying. Both ease toward their goals
orbiting: bool = false,
pivot: V3 = @splat(0),
pivot_goal: V3 = @splat(0),
distance: f32 = 3,
distance_goal: f32 = 3,
/// Whether it's asked the overlay to hold the mouse
holding: bool = false,
last_ns: u64 = 0,
/// Pressed keys wait for the frame, so everything changes on the render thread.
want_toggle: Atomic(bool) = .init(false),

/// Keep it where it is, since its keys point at it.
pub fn init(self: *Camera, registry: *Registry, overlay: *Overlay, keybinds: *Keybinds) !void {
    self.* = .{ .registry = registry, .overlay = overlay, .keybinds = keybinds };
    errdefer self.removeSettings();
    self.speed = try self.number("speed", "Speed", "In metres a second. Faster and Slower change it while they're held, and so does the mouse wheel.", 3, 0.1, 100);
    self.smoothing = try self.number("smoothing", "Smoothing", "Seconds it takes to catch up with the controls. 0 is instant.", 0.3, 0, 2);
    self.hide_from_game = try self.add("hide_from_game", "What the game stops seeing while it's on", "Only its controls leaves the rest of the keyboard and mouse to the game: the keys bound here, the button you look with and the wheel. Everything takes them all, for games that read input in ways that get past that.", .{ .choice = .{ .default = hide_options[0], .options = &hide_options } });
    self.mouse_look = try self.add("mouse_look", "Look with the mouse", "", .{ .choice = .{ .default = mouse_look_options[0], .options = &mouse_look_options } });
    self.sensitivity = try self.number("sensitivity", "Mouse sensitivity", "Degrees a pixel.", 0.15, 0.01, 1);
    self.gamepad = try self.add("gamepad", "Use a controller", "The left stick moves, the right stick looks, and the triggers go down and up. Its buttons are with the keys, like RB for Faster.", .{ .toggle = false });
    self.pad_sensitivity = try self.number("pad_sensitivity", "Stick sensitivity", "Degrees a second with the right stick all the way over.", 120, 10, 360);
    self.show_controls = try self.add("show_controls", "Show the controls while flying", "", .{ .toggle = true });
    self.corner = try self.add("controls_corner", "Where they show", "", .{ .choice = .{ .default = corner_options[0], .options = &corner_options } });
    inline for (comptime std.enums.values(Hold)) |h| {
        const name, const keys = h.def();
        const slot = self.holds.getPtr(h);
        // The game still sees them while the camera's off, and hiding its controls hides them while it's on
        slot.setting = self.track(try self.registry.add(.{
            .id = idOf(@tagName(h)),
            .name = name,
            .group = Settings.group,
            .section = Photo.section,
            .heading = "Free camera keys",
            .kind = .{ .key = .{ .default = keysOf(keys), .consume = false, .held = true } },
        }, .{ .key = .{ .ctx = slot, .call = HoldKey.fired } }));
    }
    inline for (comptime std.enums.values(Press)) |p| {
        const name, const keys = p.def();
        const slot = self.presses.getPtr(p);
        slot.camera = self;
        slot.setting = self.track(try self.registry.add(.{
            .id = idOf(@tagName(p)),
            .name = name,
            .group = Settings.group,
            .section = Photo.section,
            .heading = "Free camera keys",
            .kind = .{ .key = .{ .default = keysOf(keys), .consume = p == .toggle } },
        }, .{ .key = .{ .ctx = slot, .call = PressKey.fired } }));
    }
}

/// Waits for keys in flight.
pub fn deinit(self: *Camera) void {
    self.shared.acquire();
    self.shared.on = false;
    self.shared.release();
    self.on_flag.store(false, .release);
    self.hideFromGame(.{});
    self.holdMouse(false);
    self.removeSettings();
}

fn removeSettings(self: *Camera) void {
    for (self.added[0..self.added_len]) |s| self.registry.remove(s);
    self.added_len = 0;
}

fn track(self: *Camera, s: *Registry.Setting) *Registry.Setting {
    self.added[self.added_len] = s;
    self.added_len += 1;
    return s;
}

fn idOf(comptime name: []const u8) []const u8 {
    return "wraith.camera." ++ name;
}

fn keysOf(keys: []const tuft_input.Key) ?Keys {
    var chords: [Keys.max]tuft_input.Chord = undefined;
    const n = @min(keys.len, chords.len);
    for (keys[0..n], chords[0..n]) |k, *c| c.* = .{ .key = k };
    return Keys.of(chords[0..n]);
}

fn add(self: *Camera, comptime id: []const u8, name: []const u8, help: []const u8, kind: Registry.Kind) !*Registry.Setting {
    return self.track(try self.registry.add(.{ .id = idOf(id), .name = name, .help = help, .group = Settings.group, .section = Photo.section, .heading = "Free camera", .kind = kind }, .{}));
}

fn number(self: *Camera, comptime id: []const u8, name: []const u8, help: []const u8, default: f64, min: f64, max: f64) !*Registry.Setting {
    const step: f64 = if (max - min >= 50) 1 else 0;
    return self.add(id, name, help, .{ .number = .{ .default = default, .min = min, .max = max, .step = step } });
}

// The API, from game and engine plugins, on any thread

pub fn world(self: *Camera, w: W.FreeCamera.World) void {
    self.shared.acquire();
    defer self.shared.release();
    self.shared.basis = .init(@fromBackingInt(@intCast(@backingInt(w.up))), @fromBackingInt(@intCast(@backingInt(w.look))), w.left_handed);
    self.shared.metre = if (w.metre > 0) w.metre else 1;
}

/// `id` says which of the game's cameras it is, so a cut to another carries on from there.
pub fn camera(self: *Camera, id: u64, cam: *W.FreeCamera.State) void {
    self.shared.acquire();
    defer self.shared.release();
    var c = fromApi(cam.*);
    const cut = self.shared.seen and id != self.shared.id;
    self.shared.id = id;
    if (!self.shared.on) {
        self.shared.game = c;
        self.shared.seen = true;
        return;
    }
    if (cut) {
        // Carries on from here, so the camera stays put
        self.shared.game = c;
        self.shared.pose = .fromCamera(self.shared.basis, c);
        self.shared.restarted = true;
        return;
    }
    self.shared.pose.toCamera(self.shared.basis, &c);
    toApi(c, cam);
}

pub fn focus(self: *Camera, point: math.Vec3) void {
    self.shared.acquire();
    defer self.shared.release();
    self.shared.focus_at = point.vec();
}

pub fn active(self: *const Camera) bool {
    return self.on_flag.load(.acquire);
}

/// Whether a game's plugin has handed it a camera yet.
pub fn hasCamera(self: *Camera) bool {
    self.shared.acquire();
    defer self.shared.release();
    return self.shared.seen;
}

fn fromApi(c: W.FreeCamera.State) rig.Camera {
    return .{
        .position = c.position,
        .aim = @fromBackingInt(@intCast(@backingInt(c.aim))),
        .target = c.target,
        .up = c.up,
        .rotation = c.rotation,
        .roll = c.roll,
        .fov = c.fov,
    };
}

fn toApi(c: rig.Camera, out: *W.FreeCamera.State) void {
    out.position = c.position;
    out.target = c.target;
    out.up = c.up;
    out.rotation = c.rotation;
    out.roll = c.roll;
    out.fov = c.fov;
}

// Render thread from here

fn pressed(self: *Camera, which: Press) void {
    switch (which) {
        .toggle => self.want_toggle.store(true, .release),
        .orbit => if (self.on and !uiHasKeys()) self.setOrbiting(!self.orbiting, null),
        .level => if (self.on and !uiHasKeys()) {
            self.goal.roll = 0;
        },
        .controls => if (self.on and !uiHasKeys()) {
            const shown = self.registry.get(self.show_controls).toggle;
            self.registry.set(self.show_controls, .{ .toggle = !shown }) catch {};
        },
    }
}

/// On or off, like its key. Render thread.
pub fn flip(self: *Camera) void {
    if (self.on) self.turnOff() else self.turnOn();
}

pub fn isOn(self: *const Camera) bool {
    return self.on;
}

pub fn isOrbiting(self: *const Camera) bool {
    return self.orbiting;
}

fn turnOn(self: *Camera) void {
    {
        self.shared.acquire();
        defer self.shared.release();
        if (!self.shared.seen) {
            self.toast(.warning, "No camera yet. The free camera needs a plugin for this game, or its engine, that hands it the camera.");
            return;
        }
        self.goal = .fromCamera(self.shared.basis, self.shared.game);
        self.shared.pose = self.goal;
        self.shared.on = true;
    }
    self.on = true;
    self.on_flag.store(true, .release);
    self.orbiting = false;
    self.velocity = @splat(0);
    self.last_ns = core.timing.now();
    self.hideFromGame(self.hiding(self.readOptions()));
    self.toast(.info, "On");
}

fn turnOff(self: *Camera) void {
    self.shared.acquire();
    self.shared.on = false;
    self.shared.release();
    self.on = false;
    self.on_flag.store(false, .release);
    self.holdMouse(false);
    self.hideFromGame(.{});
    self.toast(.info, "Off");
}

/// Where it is and its turn from the world's own axes, as `rig.matrixOf` gives. Where the free camera's
/// heading while it's on, else the game's own. Null till a game's plugin hands one over. Render thread.
pub fn transform(self: *Camera) ?math.Mat4 {
    self.shared.acquire();
    defer self.shared.release();
    if (!self.shared.seen) return null;
    const basis = self.shared.basis;
    const pose = if (self.on) self.goal else rig.Pose.fromCamera(basis, self.shared.game);
    return rig.matrixOf(pose, basis);
}

/// Puts it there, as `transform` gives, turning the free camera on to. Orbiting keeps its distance,
/// moving what it orbits along. Straight there, with no easing to fight. Render thread.
pub fn setTransform(self: *Camera, m: math.Mat4) void {
    if (!self.on) self.turnOn();
    if (!self.on) return;
    self.shared.acquire();
    defer self.shared.release();
    const basis = self.shared.basis;
    var pose = rig.poseOf(m, basis, self.goal);
    // The short way round from where it was, so easing never spins it
    pose.yaw = self.goal.yaw + std.math.wrap(pose.yaw - self.goal.yaw, std.math.pi);
    self.goal = pose;
    self.velocity = @splat(0);
    if (self.orbiting) {
        self.pivot = pose.ahead(basis, self.distance);
        self.pivot_goal = self.pivot;
        self.distance_goal = self.distance;
    }
    self.shared.pose = pose;
}

/// Round `around`, or a point ahead of it, from where it is now.
pub fn setOrbiting(self: *Camera, on: bool, around: ?V3) void {
    self.orbiting = on;
    self.velocity = @splat(0);
    if (!on) return;
    self.shared.acquire();
    const basis = self.shared.basis;
    const metre = self.shared.metre;
    const pose = self.shared.pose;
    self.shared.release();
    const pivot = around orelse pose.ahead(basis, 3 * metre);
    const away = rig.length(pivot - pose.position);
    // Keeps the camera where it is, and only turns it to face the pivot
    const distance = std.math.clamp(away, min_distance * metre, max_distance * metre);
    if (away > 1e-4) {
        const toward = (pivot - pose.position) / rig.splat(away);
        const facing: rig.Camera = .{ .position = .from(pose.position), .aim = .target, .target = .from(pose.position + toward), .rotation = .identity, .roll = pose.roll, .fov = pose.fov };
        const turned: rig.Pose = .fromCamera(basis, facing);
        self.goal.yaw = pose.yaw + std.math.wrap(turned.yaw - pose.yaw, std.math.pi);
        self.goal.pitch = turned.pitch;
    }
    self.pivot = if (around == null) pivot else pose.ahead(basis, distance);
    self.pivot_goal = pivot;
    self.distance = distance;
    self.distance_goal = distance;
    self.toast(.info, "Orbiting");
}

fn holdMouse(self: *Camera, hold: bool) void {
    if (self.holding == hold) return;
    self.overlay.holdMouse(hold);
    self.holding = hold;
}

/// What options hides while it's on.
fn hiding(self: *const Camera, options: Options) Hidden {
    return switch (options.hide) {
        .nothing => .{},
        .everything => .{ .everything = true },
        .controls => .{
            .keys = true,
            .button = switch (options.mouse_look) {
                .right => .right,
                .middle => .middle,
                .left => .left,
                .always => null,
            },
            .wheel = true,
            // The cursor goes back to the middle each frame while looking, which the game shouldn't see
            .mouse = options.mouse_look == .always or self.holding,
            .pad = options.gamepad,
        },
    };
}

/// Changes only what's different from what's hidden now.
fn hideFromGame(self: *Camera, want: Hidden) void {
    const have = self.hidden;
    const o = self.overlay;
    if (want.everything != have.everything) {
        o.take(.keyboard, want.everything);
        o.take(.mouse, want.everything);
        o.take(.gamepad, want.everything);
    }
    if (want.keys != have.keys) {
        const consume: ?bool = if (want.keys) true else null;
        for (&self.holds.values) |*h| self.registry.setConsume(h.setting, consume);
        // The toggle hides its key always
        for (&self.presses.values) |*p| if (p.which != .toggle) self.registry.setConsume(p.setting, consume);
    }
    if (want.button != have.button) {
        if (have.button) |b| o.consumeButton(b, false);
        if (want.button) |b| o.consumeButton(b, true);
    }
    if (want.wheel != have.wheel) o.consumeWheel(want.wheel);
    if (want.mouse != have.mouse) o.take(.mouse, want.mouse);
    if (want.pad != have.pad) o.take(.gamepad, want.pad);
    self.hidden = want;
}

fn toast(self: *Camera, kind: ui.Toasts.Kind, text: []const u8) void {
    _ = self.overlay.host.toasts.push(.{ .kind = kind, .title = title, .text = text, .seconds = if (kind == .info) 1.5 else 5 });
}

fn readOptions(self: *Camera) Options {
    const r = self.registry;
    return .{
        .speed = @floatCast(r.get(self.speed).number),
        .smoothing = @floatCast(r.get(self.smoothing).number),
        .hide = choice(Hide, r.get(self.hide_from_game).choice, &hide_options),
        .sensitivity = @floatCast(r.get(self.sensitivity).number),
        .mouse_look = choice(MouseLook, r.get(self.mouse_look).choice, &mouse_look_options),
        .gamepad = r.get(self.gamepad).toggle,
        .pad_sensitivity = @floatCast(r.get(self.pad_sensitivity).number),
    };
}

fn down(self: *const Camera, h: Hold) f32 {
    return if (self.isDown(h)) 1 else 0;
}

fn isDown(self: *const Camera, h: Hold) bool {
    return self.holds.getPtrConst(h).down.load(.acquire);
}

/// Moves the camera from the controls, once a frame.
pub fn tick(self: *Camera) void {
    if (self.want_toggle.swap(false, .acq_rel)) self.flip();
    self.shared.acquire();
    const focus_at = self.shared.focus_at;
    self.shared.focus_at = null;
    self.shared.release();
    if (focus_at) |point| {
        if (!self.on) self.turnOn();
        if (self.on) self.setOrbiting(true, point);
    }
    if (!self.on) return;
    const now = core.timing.now();
    // A long hitch shouldn't fling it
    const dt: f32 = @floatCast(@min(@as(f64, @floatFromInt(now -| self.last_ns)) / std.time.ns_per_s, 0.1));
    self.last_ns = now;
    const options = self.readOptions();

    self.shared.acquire();
    const basis = self.shared.basis;
    const metre = self.shared.metre;
    var pose = self.shared.pose;
    const restarted = self.shared.restarted;
    self.shared.restarted = false;
    self.shared.release();
    if (restarted) {
        // Another camera, so it starts again from where that one is
        self.goal = pose;
        self.velocity = @splat(0);
        self.orbiting = false;
    }

    const typing = uiHasKeys();
    const pad: ?tuft_input.Axes = if (options.gamepad) host_keys.gamepad() else null;
    self.look(options, pad, dt, typing);

    // Moving, relative to where it faces, with Up and Down straight along the world's up
    var want: V3 = @splat(0);
    if (!typing) {
        var ahead = self.down(.forward) - self.down(.back);
        var across = self.down(.right) - self.down(.left);
        var rise = self.down(.up) - self.down(.down);
        if (pad) |p| {
            const stick = deadZone(p.left_x, p.left_y);
            ahead += stick.y;
            across += stick.x;
            rise += p.right_trigger - p.left_trigger;
        }
        const sides = self.goal.sides(basis);
        want = rig.splat(ahead) * self.goal.forward(basis) + rig.splat(across) * sides.right + rig.splat(rise) * basis.up;
        const len = rig.length(want);
        if (len > 1) want /= rig.splat(len);
        var speed = options.speed * self.boost * metre;
        if (self.isDown(.faster)) speed *= 4;
        if (self.isDown(.slower)) speed *= 0.25;
        want *= rig.splat(speed);
    }
    self.velocity = rig.ease(self.velocity, want, options.smoothing, dt);
    // Moving takes the pivot along while orbiting
    if (self.orbiting) self.pivot_goal += self.velocity * rig.splat(dt) else self.goal.position += self.velocity * rig.splat(dt);

    pose.yaw = rig.ease(pose.yaw, self.goal.yaw, options.smoothing, dt);
    pose.pitch = rig.ease(pose.pitch, self.goal.pitch, options.smoothing, dt);
    pose.roll = rig.ease(pose.roll, self.goal.roll, options.smoothing, dt);
    pose.fov = rig.ease(pose.fov, self.goal.fov, options.smoothing, dt);
    if (self.orbiting) {
        self.pivot = rig.ease(self.pivot, self.pivot_goal, options.smoothing, dt);
        self.distance = rig.ease(self.distance, self.distance_goal, options.smoothing, dt);
        pose.position = pose.orbiting(basis, self.pivot, self.distance);
        // So flying picks up from here
        self.goal.position = pose.position;
    } else pose.position = self.goal.position;

    self.shared.acquire();
    // Not over a cut that came in meanwhile, which the next frame starts from
    if (!self.shared.restarted) self.shared.pose = pose;
    self.shared.release();

    if (self.registry.get(self.show_controls).toggle) self.drawControls(options, pad != null);
}

/// Turning, rolling, zooming and the wheel's speed, into `goal`.
fn look(self: *Camera, options: Options, pad: ?tuft_input.Axes, dt: f32, typing: bool) void {
    // Held still while looking, so it never hits the screen edge
    const button = switch (options.mouse_look) {
        .right => self.keybinds.isButtonDown(.right),
        .middle => self.keybinds.isButtonDown(.middle),
        .left => self.keybinds.isButtonDown(.left),
        .always => true,
    };
    const looking = button and (self.holding or !uiHasMouse());
    // So the keys move the camera, not whatever window last had focus
    if (looking and !self.holding and options.mouse_look != .always) ui.clearWindowFocus();
    self.holdMouse(looking);
    self.hideFromGame(self.hiding(options));
    if (looking) {
        const pushed = self.overlay.mouseMotion();
        const k = std.math.degreesToRadians(options.sensitivity);
        self.goal.yaw += @as(f32, @floatFromInt(pushed.x)) * k;
        self.goal.pitch -= @as(f32, @floatFromInt(pushed.y)) * k;
    }

    var turn_x: f32 = 0;
    var turn_y: f32 = 0;
    var roll: f32 = 0;
    var zoom: f32 = 0;
    if (!typing) {
        turn_x = self.down(.turn_right) - self.down(.turn_left);
        turn_y = self.down(.turn_up) - self.down(.turn_down);
        roll = self.down(.roll_right) - self.down(.roll_left);
        zoom = self.down(.zoom_out) - self.down(.zoom_in);
    }
    const keys_rate = std.math.degreesToRadians(90) * dt;
    self.goal.yaw += turn_x * keys_rate;
    self.goal.pitch += turn_y * keys_rate;
    if (pad) |p| {
        const stick = deadZone(p.right_x, p.right_y);
        const pad_rate = std.math.degreesToRadians(options.pad_sensitivity) * dt;
        self.goal.yaw += stick.x * pad_rate;
        self.goal.pitch += stick.y * pad_rate;
    }
    self.goal.roll += std.math.clamp(roll, -1, 1) * std.math.degreesToRadians(45) * dt;
    if (self.goal.fov > 0) {
        const change = std.math.clamp(zoom, -1, 1) * std.math.degreesToRadians(20) * dt;
        self.goal.fov = std.math.clamp(self.goal.fov + change, std.math.degreesToRadians(min_fov), std.math.degreesToRadians(max_fov));
    }
    self.goal.pitch = std.math.clamp(self.goal.pitch, -rig.Pose.max_pitch, rig.Pose.max_pitch);

    if (!uiHasMouse()) {
        const wheel = ui.getIO().MouseWheel;
        if (wheel != 0) {
            const step = std.math.pow(f32, 1.25, wheel);
            if (self.orbiting) {
                const metre = self.shared.metre;
                self.distance_goal = std.math.clamp(self.distance_goal / step, min_distance * metre, max_distance * metre);
            } else self.boost = std.math.clamp(self.boost * step, 0.05, 50);
        }
    }
}

/// What does what, in a corner, as the player has the keys.
fn drawControls(self: *Camera, options: Options, pad: bool) void {
    const vp = ui.mainViewport();
    const margin = ui.scaled(12);
    const corner = choice(Corner, self.registry.get(self.corner).choice, &corner_options);
    const right = corner == .top_right or corner == .bottom_right;
    const bottom = corner == .bottom_left or corner == .bottom_right;
    ui.setNextWindowPos(.{
        if (right) vp.work_pos[0] + vp.work_size[0] - margin else vp.work_pos[0] + margin,
        if (bottom) vp.work_pos[1] + vp.work_size[1] - margin else vp.work_pos[1] + margin,
    }, .always, .{ if (right) 1 else 0, if (bottom) 1 else 0 });
    ui.setNextWindowBgAlpha(0.6);
    const window = ui.window("##wraith.camera.controls", .{ .flags = .{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_collapse = true,
        .always_auto_resize = true,
        .no_saved_settings = true,
        .no_inputs = true,
        .no_focus_on_appearing = true,
        .no_nav = true,
        .no_docking = true,
    } }) orelse return;
    defer window.end();
    ui.textDisabled("{s}", .{if (self.orbiting) "Orbiting" else "Flying"});
    self.drawKeys(options.mouse_look, pad);
}

/// What does what, as a table, as the player has the keys.
fn drawKeys(self: *Camera, mouse_look: MouseLook, pad: bool) void {
    const table = ui.table("keys", 2, .{ .sizing = .fixed_fit }) orelse return;
    defer table.end();
    var buf: [160]u8 = undefined;
    for ([_]Hold{ .forward, .back, .left, .right, .up, .down, .faster, .slower }) |h| row(Hold.def(h)[0], "{s}", .{self.keyNames(&buf, self.holds.getPtrConst(h).setting)});
    row("Look", "{s}", .{switch (mouse_look) {
        .right => "Hold the right mouse button",
        .middle => "Hold the middle mouse button",
        .left => "Hold the left mouse button",
        .always => "The mouse",
    }});
    for ([_]Hold{ .turn_left, .turn_right, .turn_up, .turn_down, .roll_left, .roll_right, .zoom_in, .zoom_out }) |h| row(Hold.def(h)[0], "{s}", .{self.keyNames(&buf, self.holds.getPtrConst(h).setting)});
    row("Level", "{s}", .{self.keyNames(&buf, self.presses.getPtrConst(.level).setting)});
    if (self.orbiting) row("Closer and further", "Mouse wheel", .{}) else row("Speed", "Mouse wheel", .{});
    row(if (self.orbiting) "Fly instead" else "Orbit instead", "{s}", .{self.keyNames(&buf, self.presses.getPtrConst(.orbit).setting)});
    if (pad) row("Controller", "Sticks move and look, triggers go down and up", .{});
    row("Hide these", "{s}", .{self.keyNames(&buf, self.presses.getPtrConst(.controls).setting)});
    row("Stop", "{s}", .{self.keyNames(&buf, self.presses.getPtrConst(.toggle).setting)});
}

/// The game's cameras and the Follow selection toggle. Render thread.
/// The keys, for Photo mode's camera panel.
pub fn drawKeyList(self: *Camera) void {
    const options = self.readOptions();
    self.drawKeys(options.mouse_look, options.gamepad);
}

/// Rolls back to level, like its key.
pub fn level(self: *Camera) void {
    if (self.on) self.goal.roll = 0;
}

/// Its field of view in degrees, or null while it's off or the game doesn't say one.
pub fn fovDegrees(self: *const Camera) ?f32 {
    if (!self.on or self.goal.fov <= 0) return null;
    return std.math.radiansToDegrees(self.goal.fov);
}

/// Like the zoom keys, eased to like everything else.
pub fn setFov(self: *Camera, degrees: f32) void {
    if (!self.on or self.goal.fov <= 0) return;
    self.goal.fov = std.math.degreesToRadians(std.math.clamp(degrees, min_fov, max_fov));
}

/// Back to the game's, as it was when the free camera came on.
pub fn resetFov(self: *Camera) void {
    if (!self.on) return;
    self.shared.acquire();
    const game = self.shared.game.fov;
    self.shared.release();
    if (game > 0) self.goal.fov = game;
}

/// Both zoom keys as the player has them, like `= and -`.
pub fn zoomKeyNames(self: *Camera, buf: []u8) []const u8 {
    var in_buf: [96]u8 = undefined;
    var out_buf: [96]u8 = undefined;
    const in = self.keyNames(&in_buf, self.holds.getPtrConst(.zoom_in).setting);
    const out = self.keyNames(&out_buf, self.holds.getPtrConst(.zoom_out).setting);
    return std.fmt.bufPrint(buf, "{s} and {s}", .{ in, out }) catch in;
}

pub fn orbitKeyName(self: *Camera, buf: []u8) []const u8 {
    return self.keyNames(buf, self.presses.getPtrConst(.orbit).setting);
}

pub fn levelKeyName(self: *Camera, buf: []u8) []const u8 {
    return self.keyNames(buf, self.presses.getPtrConst(.level).setting);
}

/// A key setting's keys as the player has them, like `Left Shift / RB`, or `none`.
pub fn keyNames(self: *Camera, buf: []u8, setting: *Registry.Setting) []const u8 {
    const keys = self.registry.get(setting).key orelse return "none";
    var w: std.Io.Writer = .fixed(buf);
    for (0..keys.count()) |i| {
        var name_buf: [48]u8 = undefined;
        w.print("{s}{s}", .{ if (i > 0) " / " else "", ui.chordName(&name_buf, keys.get(i).?) }) catch break;
    }
    return w.buffered();
}

/// The toggle's keys, for saying how to stop.
pub fn toggleKeyName(self: *Camera, buf: []u8) []const u8 {
    return self.keyNames(buf, self.presses.getPtrConst(.toggle).setting);
}

fn row(label: []const u8, comptime fmt: []const u8, args: anytype) void {
    ui.tableNextRow();
    _ = ui.tableNextColumn();
    ui.textDisabled("{s}", .{label});
    _ = ui.tableNextColumn();
    ui.text(fmt, args);
}

/// A window has the keyboard. Clicking in the game gives it back.
fn uiHasKeys() bool {
    return ui.getIO().WantTextInput or ui.isAnyWindowFocused();
}

/// The mouse is over a window, or dragging something in one.
fn uiHasMouse() bool {
    return ui.getIO().WantCaptureMouse;
}

/// Nothing near the middle, then all of the stick's travel past that.
fn deadZone(x: f32, y: f32) math.Vec2 {
    const zone = 0.2;
    const stick: math.Vec2 = .init(x, y);
    const len = stick.length();
    if (len < zone) return .zero;
    return stick.scale(@min((len - zone) / (1 - zone), 1) / len);
}

/// Which of `options` it's on, as `E`'s values in the same order.
fn choice(comptime E: type, value: []const u8, options: []const []const u8) E {
    for (options, 0..) |o, i| if (std.mem.eql(u8, o, value)) return @fromBackingInt(@intCast(i));
    return @fromBackingInt(0);
}

test {
    _ = rig;
}
