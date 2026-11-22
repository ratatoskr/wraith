//! Wraith's API as Salamander traits, from `src/api/schemas`. Each plugin gets its own root, and every
//! object it hands out is guarded by the plugin's owner, so they all stop once it's unloaded.

const std = @import("std");

const api = @import("wraith_api");
const core = @import("wraith_core");
const tuft_input = @import("tuft_input");
const platform = @import("wraith_platform");
const sync = @import("tuft_sys").sync;

const host = @import("root.zig");
const settings = @import("settings.zig");
const frame = @import("frame.zig");
const keybinds = @import("keybinds.zig");
const Libraries = @import("../Libraries.zig");
const memory_area = @import("memory_area.zig");
const code_area = @import("code_area.zig");
const files_area = @import("files_area.zig");
const game_area = @import("game_area.zig");
const hooks_area = @import("hooks_area.zig");
const ui_area = @import("ui_area.zig");
const scans = @import("scans.zig");
const scratch = @import("scratch.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;

const sal = api.salamander;
const W = api.wraith;
pub const Wraith = W.Wraith;
pub const Clipboard = W.Clipboard;
pub const Settings = W.Settings;
pub const Setting = W.Setting;
pub const Config = W.Config;
pub const Frame = W.Frame;
pub const Game = game_area.Game;
pub const SchemaArea = host.schemas.Area;
pub const FrameSubscription = W.FrameSubscription;
pub const Input = W.Input;
pub const Keybind = W.Keybind;
pub const Library = W.Libraries;
pub const Log = W.Log;
pub const Memory = memory_area.Memory;
pub const MemoryScan = memory_area.MemoryScan;
pub const Addresses = code_area.Addresses;
pub const Code = code_area.Code;
pub const Patch = code_area.Patch;
pub const Vfs = files_area.Vfs;
pub const VfsWatch = files_area.VfsWatch;
pub const Images = files_area.Images;
pub const Image = files_area.Image;
pub const Tweaks = W.Tweaks;
pub const TweakSwitchSubscription = W.TweakSwitchSubscription;
pub const Hooks = hooks_area.Hooks;
pub const ImGui = W.ImGui;
pub const Hook = hooks_area.Hook;
pub const Watches = hooks_area.Watches;
pub const Watch = hooks_area.Watch;
pub const Sound = W.Sound;
pub const Diagnostics = W.Diagnostics;
pub const Plugin = W.Plugin;
pub const PluginKind = W.PluginKind;
pub const Guest = W.Guest;
pub const Service = W.Service;

const allocator = std.heap.page_allocator;
const log = core.log.scoped(.wraith_runtime);

/// For work that waits on the system, like the clipboard. Null before the runtime's up.
var io: ?std.Io = null;

pub fn setIo(i: ?std.Io) void {
    io = i;
}

pub fn ioOf() ?std.Io {
    return io;
}

/// A plugin's tables, made once, and what its objects keep.
pub const Tables = struct {
    owner: *sal.Owner,
    root: *const sal.Table(Wraith),
    clipboard: *const sal.Table(Clipboard),
    settings: *const sal.Table(Settings),
    setting: *const sal.Table(Setting),
    config: *const sal.Table(Config),
    diagnostics: *const sal.Table(Diagnostics),
    frame: *const sal.Table(Frame),
    game: *const sal.Table(Game),
    schema: *const sal.Table(SchemaArea),
    frame_subscription: *const sal.Table(FrameSubscription),
    input: *const sal.Table(Input),
    keybind: *const sal.Table(Keybind),
    libraries: *const sal.Table(Library),
    log: *const sal.Table(Log),
    sound: *const sal.Table(Sound),
    memory: *const sal.Table(Memory),
    memory_scan: *const sal.Table(MemoryScan),
    addresses: *const sal.Table(Addresses),
    code: *const sal.Table(Code),
    /// For code patches.
    patch: *const sal.Table(Patch),
    /// For injects, which are hooks underneath.
    inject: *const sal.Table(Patch),
    vfs: *const sal.Table(Vfs),
    vfs_watch: *const sal.Table(VfsWatch),
    images: *const sal.Table(Images),
    image: *const sal.Table(Image),
    tweaks: *const sal.Table(Tweaks),
    tweak_switch: *const sal.Table(TweakSwitchSubscription),
    hooks: *const sal.Table(Hooks),
    imgui: *const sal.Table(ImGui),
    ui_area: *const sal.Table(ui_area.Ui),
    menu_item: *const sal.Table(ui_area.MenuItem),
    draw_list: *const sal.Table(ui_area.DrawList),
    /// What its UI keeps between frames.
    ui: ui_area.State = .{},
    hook: *const sal.Table(Hook),
    watches: *const sal.Table(Watches),
    watch: *const sal.Table(Watch),
};

/// Every ImGui function calls dcimgui's, only while the plugin's drawing in a frame callback.
const imgui_table = sal.forwarding(ImGui, struct {
    pub fn allowed() bool {
        return host.ui.inFrame();
    }

    pub fn function(comptime name: []const u8) *const anyopaque {
        return host.ui.imguiFunction(name);
    }
});

/// Most frame times `times` gives.
const max_times = 1024;

var made_lock: sync.RwLock = .{};

/// Null once the plugin's going, or out of memory.
pub fn tablesOf(loaded: *Loaded) ?*Tables {
    made_lock.lock();
    defer made_lock.unlock();
    if (loaded.wraith) |t| return t;
    const o = host.salamander.owner(loaded) orelse return null;
    const h = sal.host();
    const t = allocator.create(Tables) catch return null;
    t.* = .{
        .owner = o,
        .root = h.adopt(Wraith, sal.implement(Wraith, Root), o) catch return null,
        .clipboard = h.adopt(Clipboard, sal.implement(Clipboard, ClipboardImpl), o) catch return null,
        .settings = h.adopt(Settings, sal.implement(Settings, SettingsImpl), o) catch return null,
        .setting = h.adopt(Setting, sal.implement(Setting, SettingImpl), o) catch return null,
        .config = h.adopt(Config, sal.implement(Config, ConfigImpl), o) catch return null,
        .diagnostics = h.adopt(Diagnostics, sal.implement(Diagnostics, DiagnosticsImpl), o) catch return null,
        .frame = h.adopt(Frame, sal.implement(Frame, FrameImpl), o) catch return null,
        .game = h.adopt(Game, sal.implement(Game, game_area.Impl), o) catch return null,
        .schema = h.adopt(SchemaArea, sal.implement(SchemaArea, host.schemas.SchemaImpl), o) catch return null,
        .frame_subscription = h.adopt(FrameSubscription, sal.implement(FrameSubscription, SubscriptionImpl), o) catch return null,
        .input = h.adopt(Input, sal.implement(Input, InputImpl), o) catch return null,
        .keybind = h.adopt(Keybind, sal.implement(Keybind, KeybindImpl), o) catch return null,
        .libraries = h.adopt(Library, sal.implement(Library, LibrariesImpl), o) catch return null,
        .log = h.adopt(Log, sal.implement(Log, LogImpl), o) catch return null,
        .sound = h.adopt(Sound, sal.implement(Sound, SoundImpl), o) catch return null,
        .memory = h.adopt(Memory, sal.implement(Memory, memory_area.Impl), o) catch return null,
        .memory_scan = h.adopt(MemoryScan, sal.implement(MemoryScan, memory_area.ScanImpl), o) catch return null,
        .addresses = h.adopt(Addresses, sal.implement(Addresses, code_area.AddressesImpl), o) catch return null,
        .code = h.adopt(Code, sal.implement(Code, code_area.CodeImpl), o) catch return null,
        .patch = h.adopt(Patch, sal.implement(Patch, code_area.PatchImpl), o) catch return null,
        .inject = h.adopt(Patch, sal.implement(Patch, code_area.InjectImpl), o) catch return null,
        .vfs = h.adopt(Vfs, sal.implement(Vfs, files_area.VfsImpl), o) catch return null,
        .vfs_watch = h.adopt(VfsWatch, sal.implement(VfsWatch, files_area.WatchImpl), o) catch return null,
        .images = h.adopt(Images, sal.implement(Images, files_area.ImagesImpl), o) catch return null,
        .image = h.adopt(Image, sal.implement(Image, files_area.ImageImpl), o) catch return null,
        .tweaks = h.adopt(Tweaks, sal.implement(Tweaks, TweaksImpl), o) catch return null,
        .tweak_switch = h.adopt(TweakSwitchSubscription, sal.implement(TweakSwitchSubscription, TweakSwitchImpl), o) catch return null,
        .hooks = h.adopt(Hooks, sal.implement(Hooks, hooks_area.HooksImpl), o) catch return null,
        .imgui = h.adopt(ImGui, imgui_table, o) catch return null,
        .ui_area = h.adopt(ui_area.Ui, sal.implement(ui_area.Ui, ui_area.UiImpl), o) catch return null,
        .menu_item = h.adopt(ui_area.MenuItem, sal.implement(ui_area.MenuItem, ui_area.MenuItemImpl), o) catch return null,
        .draw_list = h.adopt(ui_area.DrawList, ui_area.draw_list_table, o) catch return null,
        .hook = h.adopt(Hook, sal.implement(Hook, hooks_area.HookImpl), o) catch return null,
        .watches = h.adopt(Watches, sal.implement(Watches, hooks_area.WatchesImpl), o) catch return null,
        .watch = h.adopt(Watch, sal.implement(Watch, hooks_area.WatchImpl), o) catch return null,
    };
    loaded.wraith = t;
    return t;
}

/// Once nothing can call into the plugin's objects, as it's destroyed.
pub fn forget(loaded: *Loaded) void {
    const t = loaded.wraith orelse return;
    t.ui.deinit(allocator);
    allocator.destroy(t);
    loaded.wraith = null;
}

/// The `wraith_root` host entry: the plugin's `Wraith`.
pub fn root(loaded: *Loaded) sal.AnyObject {
    const t = tablesOf(loaded) orelse return .{};
    return .of(sal.Object(Wraith).init(loaded, t.root));
}

/// Each area's object is the plugin's `Loaded` with that area's table.
const Root = struct {
    fn area(loaded: *Loaded, comptime Desc: type, comptime field: []const u8) sal.Object(Desc) {
        const t = tablesOf(loaded) orelse return .{};
        return .init(loaded, @field(t, field));
    }

    pub fn addresses(loaded: *Loaded) sal.Object(Addresses) {
        return area(loaded, Addresses, "addresses");
    }

    pub fn code(loaded: *Loaded) sal.Object(Code) {
        return area(loaded, Code, "code");
    }

    pub fn clipboard(loaded: *Loaded) sal.Object(Clipboard) {
        return area(loaded, Clipboard, "clipboard");
    }

    pub fn config(loaded: *Loaded) sal.Object(Config) {
        return area(loaded, Config, "config");
    }

    pub fn frame(loaded: *Loaded) sal.Object(Frame) {
        return area(loaded, Frame, "frame");
    }

    pub fn game(loaded: *Loaded) sal.Object(Game) {
        return area(loaded, Game, "game");
    }

    pub fn diagnostics(loaded: *Loaded) sal.Object(Diagnostics) {
        return area(loaded, Diagnostics, "diagnostics");
    }

    pub fn schema(loaded: *Loaded) sal.Object(SchemaArea) {
        return area(loaded, SchemaArea, "schema");
    }

    pub fn images(loaded: *Loaded) sal.Object(Images) {
        return area(loaded, Images, "images");
    }

    pub fn hooks(loaded: *Loaded) sal.Object(Hooks) {
        return area(loaded, Hooks, "hooks");
    }

    pub fn imgui(loaded: *Loaded) sal.Object(ImGui) {
        return area(loaded, ImGui, "imgui");
    }

    pub fn ui(loaded: *Loaded) sal.Object(ui_area.Ui) {
        return area(loaded, ui_area.Ui, "ui_area");
    }

    pub fn watches(loaded: *Loaded) sal.Object(Watches) {
        return area(loaded, Watches, "watches");
    }

    pub fn tweaks(loaded: *Loaded) sal.Object(Tweaks) {
        return area(loaded, Tweaks, "tweaks");
    }

    pub fn vfs(loaded: *Loaded) sal.Object(Vfs) {
        return area(loaded, Vfs, "vfs");
    }

    pub fn input(loaded: *Loaded) sal.Object(Input) {
        return area(loaded, Input, "input");
    }

    pub fn libraries(loaded: *Loaded) sal.Object(Library) {
        return area(loaded, Library, "libraries");
    }

    pub fn memory(loaded: *Loaded) sal.Object(Memory) {
        return area(loaded, Memory, "memory");
    }

    pub fn log(loaded: *Loaded) sal.Object(Log) {
        return area(loaded, Log, "log");
    }

    pub fn settings(loaded: *Loaded) sal.Object(Settings) {
        return area(loaded, Settings, "settings");
    }

    pub fn sound(loaded: *Loaded) sal.Object(Sound) {
        return area(loaded, Sound, "sound");
    }
};

// Clipboard

const TextPromise = sal.Plain(Clipboard, "text");
const SetPromise = sal.Plain(Clipboard, "setText");

/// What settles a `P`.
pub fn ResolverOf(comptime P: type) type {
    const Pair = @typeInfo(@typeInfo(@TypeOf(P.make)).@"fn".return_type.?).error_union.payload;
    return @FieldType(Pair, "resolver");
}

/// Clipboard work, on its own thread. It enters the plugin's owner before touching anything of the
/// plugin's, so unloading waits for it, and it gives up once the plugin's gone.
const Job = struct {
    owner: *sal.Owner,
    work: union(enum) {
        read: ResolverOf(TextPromise),
        write: struct { resolver: ResolverOf(SetPromise), text: []u8 },
    },

    fn run(job: *Job) void {
        defer allocator.destroy(job);
        switch (job.work) {
            .read => |r| {
                if (!job.owner.enter()) return r.drop();
                defer job.owner.leave();
                const i = io orelse return r.fail(error.Failed);
                const got = platform.clipboard.getText(i, allocator) catch return r.fail(error.Failed);
                defer allocator.free(got);
                // Kept with the value, so it's there whenever it's taken
                r.settle(r.hold(got) catch return r.fail(error.Failed));
            },
            .write => |w| {
                defer allocator.free(w.text);
                if (!job.owner.enter()) return w.resolver.drop();
                defer job.owner.leave();
                const i = io orelse return w.resolver.fail(error.Failed);
                platform.clipboard.setText(i, w.text) catch return w.resolver.fail(error.Failed);
                w.resolver.settle({});
            },
        }
    }

    fn start(job: *Job) bool {
        const thread = std.Thread.spawn(.{}, run, .{job}) catch return false;
        thread.detach();
        return true;
    }
};

const ClipboardImpl = struct {
    pub fn text(loaded: *Loaded) TextPromise {
        const pair = TextPromise.make() catch return .{};
        const t = tablesOf(loaded) orelse {
            pair.resolver.drop();
            return pair.promise;
        };
        const job = allocator.create(Job) catch {
            pair.resolver.fail(error.Failed);
            return pair.promise;
        };
        job.* = .{ .owner = t.owner, .work = .{ .read = pair.resolver } };
        if (!job.start()) {
            allocator.destroy(job);
            pair.resolver.fail(error.Failed);
        }
        return pair.promise;
    }

    pub fn setText(loaded: *Loaded, value: []const u8) SetPromise {
        const pair = SetPromise.make() catch return .{};
        const t = tablesOf(loaded) orelse {
            pair.resolver.drop();
            return pair.promise;
        };
        // Borrowed for the call, so the job gets a copy
        const copy = allocator.dupe(u8, value) catch {
            pair.resolver.fail(error.Failed);
            return pair.promise;
        };
        const job = allocator.create(Job) catch {
            allocator.free(copy);
            pair.resolver.fail(error.Failed);
            return pair.promise;
        };
        job.* = .{ .owner = t.owner, .work = .{ .write = .{ .resolver = pair.resolver, .text = copy } } };
        if (!job.start()) {
            allocator.free(copy);
            allocator.destroy(job);
            pair.resolver.fail(error.Failed);
        }
        return pair.promise;
    }
};

// Settings

const SettingsImpl = struct {
    pub fn add(loaded: *Loaded, definition: W.SettingDefinition, changed: settings.Changed) sal.Plain(Settings, "add") {
        const t = tablesOf(loaded) orelse return error.Unavailable;
        const record = try settings.add(loaded, definition, changed, t.setting);
        return .init(record, t.setting);
    }
};

const SettingImpl = struct {
    pub fn get(record: *settings.Record) sal.Plain(Setting, "get") {
        return settings.get(record);
    }

    pub fn set(record: *settings.Record, value: W.SettingValue) sal.Plain(Setting, "set") {
        return settings.set(record, value);
    }

    pub fn remove(record: *settings.Record) void {
        record.stop();
    }
};

// Tweaks

const TweaksImpl = struct {
    pub fn add(loaded: *Loaded, definition: W.TweakDefinition, handler: host.tweaks.Handler) sal.Plain(Tweaks, "add") {
        host.tweaks.add(loaded, definition, handler) catch |err| return switch (err) {
            error.InvalidId => error.InvalidId,
            error.InvalidDefinition => error.InvalidDefinition,
            error.OutOfMemory, error.OwnerGone => error.Failed,
        };
    }

    pub fn remove(loaded: *Loaded, id: []const u8) void {
        host.tweaks.remove(loaded, id);
    }

    pub fn isOn(loaded: *Loaded, name: []const u8) sal.Plain(Tweaks, "isOn") {
        return host.tweaks.isOn(loaded, name) catch |err| switch (err) {
            error.NotFound => error.NotFound,
            error.OutOfMemory => error.Failed,
        };
    }

    pub fn setOn(loaded: *Loaded, name: []const u8, on: bool) sal.Plain(Tweaks, "setOn") {
        host.tweaks.setOn(loaded, name, on) catch |err| return switch (err) {
            error.NotFound => error.NotFound,
            error.OutOfMemory => error.Failed,
        };
    }

    pub fn onSwitched(loaded: *Loaded, handler: host.tweaks.Switched) sal.Plain(Tweaks, "onSwitched") {
        const t = tablesOf(loaded) orelse {
            handler.release();
            return error.Failed;
        };
        const l = host.tweaks.onSwitched(loaded, handler) catch return error.Failed;
        return .init(l, t.tweak_switch);
    }
};

const TweakSwitchImpl = struct {
    pub fn cancel(l: *host.tweaks.Listener) void {
        l.stop();
    }
};

// Config

const ConfigImpl = struct {
    pub fn directory(loaded: *Loaded) []const u8 {
        return host.config.directory(loaded);
    }

    pub fn gameDirectory(loaded: *Loaded) []const u8 {
        return host.config.gameDirectory(loaded);
    }
};

// Frame

const FrameImpl = struct {
    fn frameError(err: api.FrameError) error{ NoFrames, Failed } {
        return if (err == error.NoFrames) error.NoFrames else error.Failed;
    }

    pub fn onFrame(loaded: *Loaded, tick: frame.Tick) sal.Plain(Frame, "onFrame") {
        const t = tablesOf(loaded) orelse {
            tick.release();
            return error.Failed;
        };
        const f = frame.onFrame(loaded, tick) catch |err| return frameError(err);
        return .init(f, t.frame_subscription);
    }

    pub fn post(loaded: *Loaded, task: frame.Task) sal.Plain(Frame, "post") {
        frame.post(loaded, task) catch |err| return frameError(err);
    }

    pub fn capture(loaded: *Loaded, point: W.CapturePoint) sal.Plain(Frame, "capture") {
        return host.capture.capture(loaded, switch (point) {
            .before_overlay => .before_overlay,
            else => .after_overlay,
        });
    }

    pub fn stats(loaded: *Loaded) W.FrameStats {
        const Out = W.FrameStats;
        const s = host.ui.frameStats(loaded);
        var out: Out = .{};
        inline for (comptime std.meta.fieldNames(api.FrameStats)) |n| {
            @field(out, n) = if (comptime std.mem.eql(u8, n, "total_frames")) @intCast(@field(s, n)) else @field(s, n);
        }
        return out;
    }

    pub fn times(loaded: *Loaded) []const f32 {
        const out = scratch.begin().alloc(f32, max_times) catch return &.{};
        return out[0..host.ui.frameTimes(loaded, out)];
    }

    pub fn next(loaded: *Loaded) sal.Plain(Frame, "next") {
        const P = sal.Plain(Frame, "next");
        const pair = P.make() catch return .{};
        frame.postNext(loaded, pair.resolver) catch |err| pair.resolver.fail(frameError(err));
        return pair.promise;
    }

    pub fn now(_: *Loaded) f64 {
        return @as(f64, @floatFromInt(@import("wraith_core").timing.now())) / std.time.ns_per_ms;
    }
};

/// What `Frame.next` settles.
pub const NextResolver = ResolverOf(sal.Plain(Frame, "next"));

const SubscriptionImpl = struct {
    pub fn cancel(f: *frame.Frame) void {
        f.stop();
    }
};

// Input

const SalKey = W.Key;

comptime {
    // The same keys in the same order, with digits named so every language can use them
    const ours = std.meta.fieldNames(SalKey);
    const theirs = std.meta.fieldNames(tuft_input.Key);
    if (ours.len != theirs.len) @compileError("input.sal's Key doesn't match tuft's");
    for (ours, theirs) |a, b| {
        const want = if (b.len == 1 and std.ascii.isDigit(b[0])) "digit_" ++ b else b;
        if (!std.mem.eql(u8, a, want)) @compileError("input.sal's Key has " ++ a ++ " where tuft has " ++ b);
    }
}

fn keyOf(k: SalKey) ?tuft_input.Key {
    const v = @backingInt(k);
    if (v >= std.meta.fieldNames(tuft_input.Key).len) return null;
    return @fromBackingInt(@intCast(v));
}

fn chordOf(c: W.Chord) ?tuft_input.Chord {
    const bits: u8 = @bitCast(c.mods);
    return .{ .key = keyOf(c.key) orelse return null, .mods = @bitCast(bits & 0xF) };
}

fn keybindError(err: api.KeybindError) error{ Unavailable, AlreadyBound, InvalidChord, Failed } {
    return switch (err) {
        error.KeybindsUnavailable => error.Unavailable,
        error.AlreadyBound => error.AlreadyBound,
        error.InvalidChord => error.InvalidChord,
        error.OutOfMemory, error.KeybindFailed => error.Failed,
    };
}

const InputImpl = struct {
    pub fn keyDown(loaded: *Loaded, key: SalKey) bool {
        return keybinds.keyDown(loaded, keyOf(key) orelse return false);
    }

    pub fn buttonDown(loaded: *Loaded, button: W.MouseButton) bool {
        return switch (button) {
            inline .left, .right, .middle, .x1, .x2 => |b| keybinds.buttonDown(loaded, @field(tuft_input.MouseButton, @tagName(b))),
            else => false,
        };
    }

    pub fn mousePos(loaded: *Loaded) ?W.Point {
        const p = keybinds.mousePos(loaded) orelse return null;
        return .{ .x = p.x, .y = p.y };
    }

    pub fn bind(loaded: *Loaded, action: W.Action, fired: keybinds.Fired) sal.Plain(Input, "bind") {
        const t = tablesOf(loaded) orelse {
            fired.release();
            return error.Failed;
        };
        const chord = chordOf(action.chord) orelse {
            fired.release();
            return error.InvalidChord;
        };
        const record = keybinds.bind(loaded, .{
            .id = action.id,
            .name = action.name,
            .chord = chord,
            .consume = !action.passthrough,
            .while_typing = action.while_typing,
            .held = action.held,
            .scope = if (action.scope == .game) .game else .global,
        }, fired) catch |err| return keybindError(err);
        return .init(record, t.keybind);
    }

    pub fn gamepad(_: *Loaded) ?W.GamepadAxes {
        const a = keybinds.gamepad() orelse return null;
        return .{ .left_x = a.left_x, .left_y = a.left_y, .right_x = a.right_x, .right_y = a.right_y, .left_trigger = a.left_trigger, .right_trigger = a.right_trigger };
    }
};

const KeybindImpl = struct {
    pub fn rebind(record: *keybinds.Record, to: W.Chord) sal.Plain(Keybind, "rebind") {
        keybinds.rebind(record, chordOf(to) orelse return error.InvalidChord) catch |err| return keybindError(err);
    }

    pub fn unbind(record: *keybinds.Record) void {
        record.stop();
    }

    pub fn chord(record: *keybinds.Record) ?W.Chord {
        const c = keybinds.chordOf(record) orelse return null;
        const bits: u8 = @bitCast(c.mods);
        return .{ .key = @fromBackingInt(@backingInt(c.key)), .mods = @bitCast(bits & 0xF) };
    }
};

// Libraries

fn libraryError(err: api.LibraryError) error{ InvalidName, NotFound, NoSource, Taken, TooBig, Failed } {
    return switch (err) {
        error.InvalidName => error.InvalidName,
        error.NotFound => error.NotFound,
        error.NoSource => error.NoSource,
        error.Taken => error.Taken,
        error.TooBig => error.TooBig,
        error.OutOfMemory => error.Failed,
    };
}

const LibrariesImpl = struct {
    pub fn get(_: *Loaded, name: []const u8, language: []const u8) sal.Plain(Library, "get") {
        const a = scratch.begin();
        // Asked for its size first, and again if it grew in between
        var len = Libraries.global.get(name, language, &.{}) catch |err| return libraryError(err);
        while (true) {
            const buf = a.alloc(u8, len) catch return error.Failed;
            const got = Libraries.global.get(name, language, buf) catch |err| return libraryError(err);
            if (got <= len) return buf[0..got];
            len = got;
        }
    }

    pub fn add(loaded: *Loaded, name: []const u8, language: []const u8, source: []const u8) sal.Plain(Library, "add") {
        host.libraries.add(loaded, name, language, source) catch |err| return libraryError(err);
    }
};

// Log

fn levelOf(level: W.LogLevel) ?std.log.Level {
    return switch (level) {
        inline .err, .warn, .info, .debug => |l| @field(std.log.Level, @tagName(l)),
        else => null,
    };
}

const LogImpl = struct {
    const default_scope = @tagName(std.log.default_log_scope);

    pub fn err(loaded: *Loaded, message: []const u8) void {
        host.log.write(loaded, .err, default_scope, message);
    }

    pub fn warn(loaded: *Loaded, message: []const u8) void {
        host.log.write(loaded, .warn, default_scope, message);
    }

    pub fn info(loaded: *Loaded, message: []const u8) void {
        host.log.write(loaded, .info, default_scope, message);
    }

    pub fn debug(loaded: *Loaded, message: []const u8) void {
        host.log.write(loaded, .debug, default_scope, message);
    }

    pub fn write(loaded: *Loaded, level: W.LogLevel, scope: []const u8, message: []const u8) void {
        host.log.write(loaded, levelOf(level) orelse return, scope, message);
    }

    pub fn enabled(loaded: *Loaded, level: W.LogLevel) bool {
        return host.log.enabled(loaded, levelOf(level) orelse return false);
    }
};

// Diagnostics

const DiagnosticsImpl = struct {
    pub fn addZone(loaded: *Loaded, zone: usize, version: u32) void {
        if (zone == 0) return;
        if (version != core.timing.Zone.version) return log.warn("{s}'s timing zones are another version, so they aren't listed", .{loaded.name});
        host.diagnostics.addZone(loaded, @ptrFromInt(zone));
    }

    pub fn removeZone(_: *Loaded, zone: usize) void {
        if (zone == 0) return;
        host.diagnostics.removeZone(zone);
    }

    pub fn addHeap(loaded: *Loaded, heap: usize, version: u32) void {
        if (heap == 0) return;
        if (version != core.heap.Usage.version) return log.warn("{s}'s heaps are another version, so they aren't listed", .{loaded.name});
        host.diagnostics.addHeap(loaded, @ptrFromInt(heap));
    }

    pub fn removeHeap(_: *Loaded, heap: usize) void {
        if (heap == 0) return;
        host.diagnostics.removeHeap(heap);
    }

    pub fn recordScan(loaded: *Loaded, scan: W.SignatureScan) void {
        host.signatures.record(loaded, .{
            .name = scan.name,
            .pattern = scan.pattern,
            .start = scan.start,
            .len = scan.length,
            .original = scan.original,
            .outcome = switch (scan.outcome) {
                .found => .found,
                .not_unique => .not_unique,
                else => .not_found,
            },
            .address = scan.address,
            .ns = scan.ns,
        });
    }

    pub fn original(_: *Loaded, start: usize, length: usize) usize {
        return @intFromPtr(host.signatures.original(start, length));
    }
};

// Sound

const SoundImpl = struct {
    pub fn play(loaded: *Loaded, wav: []const u8) sal.Plain(Sound, "play") {
        host.sound.play(loaded, wav) catch |err| return switch (err) {
            error.InvalidSound => error.InvalidSound,
            error.OutOfMemory => error.Failed,
        };
    }

    pub fn playSystem(loaded: *Loaded, which: W.SystemSound) void {
        host.sound.playSystem(loaded, switch (which) {
            inline .default, .info, .warning, .@"error", .question, .notification => |s| @field(api.SystemSound, @tagName(s)),
            else => .default,
        });
    }

    pub fn stop(loaded: *Loaded) void {
        host.sound.stopSound(loaded);
    }
};

const tests = struct {
    const testing = std.testing;
    const Registry = @import("../settings/Registry.zig");

    var changes: u32 = 0;

    fn onChange(_: *u32, setting: sal.Object(Setting)) void {
        changes += 1;
        // It can look at itself from in here
        _ = setting.get() catch {};
    }

    test "a plugin's settings, through its Wraith" {
        const sdk = @import("wraith_sdk");
        const r = try Registry.create(testing.allocator, .{});
        defer r.destroy();
        settings.setRegistry(r);
        defer settings.setRegistry(null);
        var loaded: Loaded = undefined;
        loaded.initForTest(testing.allocator, "kai");
        sdk.Owner.attach(loaded.root());
        defer sdk.Owner.detach();

        const w = sdk.wraith.root().?;
        const list = w.settings();
        const Changed = W.SettingChanged;
        var ctx: u32 = 0;
        const fov = try list.add(.{ .id = "fov", .name = "Field of view", .kind = .number, .scope = .game, .min = 60, .max = 120, .has_default = true, .default_value = .{ .number = 90 } }, Changed.init(&ctx, onChange));
        const mode = try list.add(.{ .id = "mode", .kind = .choice, .options = &.{ "fast", "slow" } }, null);
        try testing.expectError(error.AlreadyAdded, list.add(.{ .id = "fov", .kind = .toggle }, null));
        try testing.expectError(error.InvalidId, list.add(.{ .id = "no spaces", .kind = .toggle }, null));

        const listed = r.find("kai.fov").?;
        try testing.expectEqualStrings("kai", listed.def.group);
        try testing.expectEqual(.game, listed.def.scope);
        try testing.expectEqual(90, (try fov.get()).number);

        try fov.set(.{ .number = 200 });
        try testing.expectEqual(120, (try fov.get()).number);
        try testing.expectEqual(1, changes);
        // From Wraith's Settings too
        try r.set(listed, .{ .number = 75 });
        try testing.expectEqual(2, changes);

        try testing.expectEqualStrings("fast", (try mode.get()).text);
        try mode.set(.{ .text = "slow" });
        try testing.expectEqualStrings("slow", (try mode.get()).text);
        try testing.expectError(error.InvalidValue, mode.set(.{ .text = "medium" }));

        // Removed, its value kept
        mode.remove();
        try testing.expectEqual(null, r.find("kai.mode"));
        try testing.expectError(error.Failed, mode.get());

        // Gone with the plugin, and so is everything it was given
        loaded.deinitForTest();
        forget(&loaded);
        try testing.expectEqual(null, r.find("kai.fov"));
        try testing.expectEqual(75, r.stores[1].values.get("kai.fov").?.number);
        try testing.expectError(error.Gone, fov.get());
        try testing.expectEqual(sal.Object(Settings){}, w.settings());
    }

    const Counts = struct {
        ticks: u32 = 0,
        posts: u32 = 0,

        fn tick(self: *Counts) void {
            self.ticks += 1;
        }

        fn post(self: *Counts) void {
            self.posts += 1;
        }

        fn fired(_: *Counts, _: W.KeyPhase) void {}
    };

    test "plain areas, through a plugin's Wraith" {
        const sdk = @import("wraith_sdk");
        Libraries.global = .init(testing.allocator);
        defer Libraries.global.deinit();
        frame.setFrames(true);
        defer frame.setFrames(false);
        var loaded: Loaded = undefined;
        loaded.initForTest(testing.allocator, "kai");
        loaded.config_dir = "config/kai";
        loaded.game_config_dir = "games/kai";
        sdk.Owner.attach(loaded.root());
        defer sdk.Owner.detach();
        const w = sdk.wraith.root().?;

        const config = w.config();
        try testing.expectEqualStrings("config/kai", config.directory());
        try testing.expectEqualStrings("games/kai", config.gameDirectory());

        const libs = w.libraries();
        try libs.add("util", "lua", "return 1");
        try testing.expectEqualStrings("return 1", try libs.get("util", "lua"));
        try testing.expectError(error.NoSource, libs.get("util", "js"));
        try testing.expectError(error.NotFound, libs.get("nope", "js"));
        try testing.expectError(error.InvalidName, libs.add("no spaces", "lua", ""));

        try testing.expectError(error.InvalidSound, w.sound().play("not a wav"));
        w.log().info("hello from kai");

        // No window, so nothing's held and keybinds can't be made
        var counts: Counts = .{};
        const input = w.input();
        try testing.expect(!input.keyDown(.f8));
        try testing.expect(!input.buttonDown(.left));
        try testing.expectEqual(null, input.mousePos());
        try testing.expectError(error.Unavailable, input.bind(.{ .id = "toggle", .chord = .{ .key = .f8 } }, W.KeybindFired.init(&counts, Counts.fired)));

        const fr = w.frame();
        const sub = try fr.onFrame(W.FrameTick.init(&counts, Counts.tick));
        try fr.post(W.FrameTask.init(&counts, Counts.post));
        frame.run();
        try testing.expectEqual(1, counts.ticks);
        try testing.expectEqual(1, counts.posts);
        frame.run();
        try testing.expectEqual(2, counts.ticks);
        try testing.expectEqual(1, counts.posts);
        sub.cancel();
        sub.cancel();
        frame.run();
        try testing.expectEqual(2, counts.ticks);
        _ = fr.stats();
        try testing.expectEqual(0, fr.times().len);

        // What's left waiting never runs, and what it shared goes with it
        try fr.post(W.FrameTask.init(&counts, Counts.post));
        loaded.deinitForTest();
        forget(&loaded);
        frame.run();
        try testing.expectEqual(1, counts.posts);
        try testing.expectError(error.NotFound, Libraries.global.get("util", "lua", &.{}));
    }
};

test {
    _ = tests;
}
