//! The runtime's own UI. That's the welcome, the overlay's bar and windows and the workbench, plus
//! the settings and keys they register.

const Shell = @This();

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const core = @import("wraith_core");
const wraith_platform = @import("wraith_platform");
const tuft_sys = @import("tuft_sys");
const ui = @import("wraith_ui");

const Overlay = @import("../Overlay.zig");
const Themes = @import("../Themes.zig");
const Settings = @import("../../Settings.zig");
const Workbench = @import("../workbench/Workbench.zig");
const Project = @import("../../Project.zig");
const Tweaks = @import("../../Tweaks.zig");
const GameSettings = @import("../../GameSettings.zig");

const log = core.log.scoped(.wraith_ui);
const Keybinds = @import("tuft_input").Keybinds;
const ModProjects = @import("../../ModProjects.zig");
const PluginLoader = @import("../../PluginLoader.zig");
const Sessions = @import("../../sessions/Sessions.zig");
const Welcome = @import("Welcome.zig");
const Hub = @import("Hub.zig");
const ModsWindow = @import("ModsWindow.zig");
const TweaksWindow = @import("TweaksWindow.zig");
const TweakLayout = @import("../TweakLayout.zig");
const ui_area = @import("../../host/ui_area.zig");
const SettingsWindow = @import("SettingsWindow.zig");
const AboutWindow = @import("AboutWindow.zig");
const ShellSettings = @import("ShellSettings.zig");
pub const DevPlugins = @import("DevPlugins.zig");
pub const Registry = @import("../../settings/Registry.zig");
const Chord = wraith_platform.input.Chord;

pub const overlay_key_default: Chord = .{ .key = .insert };
pub const workbench_key_default: Chord = .{ .key = .home, .mods = .{ .ctrl = true } };

pub const Options = struct {
    /// Where its settings and keys are kept. Without one it makes its own that saves nothing, like
    /// in tests.
    registry: ?*Registry = null,
    themes: ?*const Themes = null,
    /// The game's own state, like its project, tweaks and address keys. Must outlive the shell.
    /// Without it, like in tests, there's no project and no welcome.
    game: ?*core.Config(GameSettings) = null,
    /// The workbench's address list and layout are only kept with this.
    io: ?std.Io = null,
};

allocator: std.mem.Allocator,
overlay: *Overlay,
keybinds: *Keybinds,
options: Options,
scope: core.Scope,
workbench: *Workbench,
welcome: Welcome = .{},
registry: *Registry,
owns_registry: bool,
overlay_key: *Registry.Setting = undefined,
workbench_key: *Registry.Setting = undefined,
/// For Settings.
dev_plugins: DevPlugins = .{},
/// Its settings in the registry.
own: ShellSettings = undefined,
/// What the overlay key brings up. Render thread.
hub: Hub = .{},
/// Wraith's own windows, which the bar opens. Render thread.
windows: Windows = undefined,
/// Says the overlay key on the first frame, once the welcome's been seen before.
ready_toast: bool = false,
/// No theme picked, so it follows Windows' light or dark mode. Either UI can change it.
theme_follows_os: Atomic(bool) = .init(false),
/// When it last asked Windows. Render thread.
theme_checked_ns: u64 = 0,
/// The keys' change count when it last looked for clashes. Render thread.
keys_seen: u32 = 0,
/// Clashes it's warned about already, hashed. Render thread.
clashes_told: std.ArrayList(u64) = .empty,
/// Null without files, like in tests. Outlives the workbench.
project: ?*Project = null,
/// The project's tweaks. Null without a project.
tweaks: ?*Tweaks = null,
/// How the Tweaks window and the workbench's panel lay them out. Any thread.
tweak_layout: TweakLayout = .{},
/// Hold `loader_lock` to use it.
loader: ?*PluginLoader = null,
/// Script sessions and tweaks, while there's a loader. Under `loader_lock` too.
sessions: ?*Sessions = null,
loader_lock: tuft_sys.sync.RwLock = .{},
/// Reading installed projects' tweaks when the loader comes.
mod_projects: std.Io.Group = .init,
/// Either UI can change the game's state, and saving isn't safe from two threads at once.
settings_lock: tuft_sys.sync.RwLock = .{},
started_ns: u64 = 0,

pub const Windows = struct {
    system: ui.WindowSystem,
    mods: ModsWindow = .{},
    tweaks: TweaksWindow = .{},
    settings: SettingsWindow = .{},
    about: AboutWindow = .{},
};

pub fn create(allocator: std.mem.Allocator, overlay: *Overlay, keybinds: *Keybinds, options: Options) !*Shell {
    const self = try allocator.create(Shell);
    errdefer allocator.destroy(self);

    // The game's files sit next to its settings
    var ini_path: ?[]u8 = null;
    defer if (ini_path) |p| allocator.free(p);
    var project: ?*Project = null;
    errdefer if (project) |p| p.destroy();
    if (options.io) |io| if (options.game) |game| if (std.fs.path.dirname(game.path)) |game_dir| {
        ini_path = try std.fs.path.join(allocator, &.{ game_dir, "workbench.ini" });
        project = openProject(allocator, io, game_dir, game.value.project_file) catch |err| blk: {
            log.warn("Couldn't open the project: {t}", .{err});
            break :blk null;
        };
    };
    const workbench = try Workbench.create(allocator, .{ .io = options.io, .overlay = overlay, .shell = self, .project = project, .ini_path = ini_path, .theme = overlay.options.theme });
    errdefer workbench.destroy();
    const registry = options.registry orelse try Registry.create(allocator, .{ .keybinds = keybinds });
    errdefer if (options.registry == null) registry.destroy();

    self.* = .{
        .allocator = allocator,
        .overlay = overlay,
        .keybinds = keybinds,
        .options = options,
        .scope = .init(allocator),
        .workbench = workbench,
        .registry = registry,
        .owns_registry = options.registry == null,
        .project = project,
        .tweaks = null,
        .started_ns = core.timing.now(),
    };
    errdefer self.scope.deinit();
    self.windows = .{ .system = .init(allocator) };
    errdefer self.windows.system.deinit();
    self.windows.system.before_each = .{ .ctx = self, .func = startCentred };
    self.windows.mods.shell = self;
    self.windows.tweaks.shell = self;
    self.windows.settings.shell = self;
    inline for (.{ "mods", "tweaks", "settings", "about" }) |name| try self.windows.system.add(&@field(self.windows, name));
    self.own = try ShellSettings.add(self, registry);
    errdefer self.own.remove();
    self.applyFrameSettings(self.own.frameStats());
    self.applyThemeSetting();
    Workbench.keys.apply(self.own.workbenchKeys());
    if (options.game != null) {
        self.welcome.open = !registry.get(self.own.welcome_seen).toggle;
        self.ready_toast = !self.welcome.open;
    }

    if (project) |p| {
        const settings = if (options.game) |g| g.value.tweaks else GameSettings.Tweaks{};
        if (options.game) |g| self.tweak_layout.load(g.value.tweak_layout);
        self.tweaks = Tweaks.create(allocator, p, registry, settings, .{ .context = self, .ready = tweaksReady, .save = saveTweakSettings, .keyed = tweakKeyed }) catch |err| blk: {
            log.warn("Couldn't start tweaks: {t}", .{err});
            break :blk null;
        };
    }
    errdefer if (self.tweaks) |t| t.destroy();
    self.workbench.tweaks = self.tweaks;
    self.workbench.tweak_layout = &self.tweak_layout;
    self.workbench.panels.addresses.keys.attach(registry);
    try overlay.draw.subscribe(&self.scope, self, draw);
    self.overlay_key = try registry.add(.{
        .id = "wraith.toggle_overlay",
        .name = "Open or close the Wraith overlay",
        .help = "Brings up Wraith over the game, and closes it again.",
        .group = Settings.group,
        .kind = .{ .key = .{ .default = overlay_key_default, .while_typing = true } },
    }, .{ .key = .{ .ctx = self, .call = overlayKeyPressed } });
    errdefer registry.remove(self.overlay_key);
    self.workbench_key = try registry.add(.{
        .id = "wraith.toggle_workbench",
        .name = "Open or close the workbench",
        .help = "Disassembly, memory, addresses, search and the other developer tools, in a window of their own.",
        .group = Settings.group,
        .section = "Developer",
        .kind = .{ .key = .{ .default = workbench_key_default } },
    }, .{ .key = .{ .ctx = self, .call = workbenchKeyPressed } });
    errdefer registry.remove(self.workbench_key);
    self.welcome.choices = .{ .overlay_key = self.overlayKey() orelse overlay_key_default };
    return self;
}

/// The last one saved, taking in the game's address list from before projects.
fn openProject(allocator: std.mem.Allocator, io: std.Io, game_dir: []const u8, last: []const u8) !*Project {
    const project = try Project.create(allocator, io, game_dir);
    project.startUp(last);
    const old = try std.fs.path.join(allocator, &.{ game_dir, "addresses.zon" });
    defer allocator.free(old);
    project.adopt(old) catch |err| log.warn("Couldn't move the old address list into the project: {t}", .{err});
    return project;
}

pub fn destroy(self: *Shell) void {
    self.scope.deinit(); // waits for a draw in flight
    // Before the keys its scripts bound go
    self.setLoader(null);
    if (self.options.io) |io| {
        self.mod_projects.await(io) catch {};
        self.dev_plugins.deinit(io);
    }
    // These wait for their keys in flight
    self.registry.remove(self.overlay_key);
    self.registry.remove(self.workbench_key);
    self.own.remove();
    self.clashes_told.deinit(self.allocator);
    self.welcome.deinit(self.overlay);
    self.hub.deinit(self);
    self.windows.system.deinit();
    self.windows.settings.deinit();
    self.windows.mods.deinit(self.options.io);
    self.windows.tweaks.deinit(self.allocator);
    // Waits for its thread, and saves its layout
    self.workbench.destroy();
    if (self.tweaks) |t| t.destroy();
    self.tweak_layout.deinit();
    // Unsaved changes go with it
    if (self.project) |p| p.destroy();
    // Last, since tweaks take their keys out of it
    if (self.owns_registry) self.registry.destroy();
    self.allocator.destroy(self);
}

/// Waits for any window using it. Set null before the loader goes away. Script sessions come and
/// go with it.
pub fn setLoader(self: *Shell, loader: ?*PluginLoader) void {
    const gone = blk: {
        self.loader_lock.lock();
        defer self.loader_lock.unlock();
        self.loader = loader;
        if (loader) |l| {
            if (self.sessions == null) self.sessions = Sessions.create(self.allocator, l.config_dir, l.game_config_dir) catch |err| s: {
                log.warn("Couldn't start script sessions: {t}", .{err});
                break :s null;
            };
            break :blk null;
        }
        const s = self.sessions;
        self.sessions = null;
        break :blk s;
    };
    // Unlocked, since it waits for a pump that may be asking
    if (gone) |s| s.destroy();
    if (loader != null) if (self.options.io) |io| if (self.tweaks != null) {
        self.mod_projects.concurrent(io, readModProjects, .{ self, io }) catch |err| log.warn("Couldn't read the installed projects: {t}", .{err});
    };
}

fn readModProjects(self: *Shell, io: std.Io) void {
    const loader = self.acquireLoader() orelse return;
    defer self.releaseLoader();
    self.refreshModProjects(io, loader);
}

/// Gives tweaks the installed projects for this game again, after one's installed, updated or
/// removed. Not the render thread.
pub fn refreshModProjects(self: *Shell, io: std.Io, loader: *PluginLoader) void {
    const tweaks = self.tweaks orelse return;
    ModProjects.refresh(tweaks, self.allocator, io, loader.plugins_dir, loader.cache_dir, loader.here());
}

/// Whether scripts and tweaks can run.
pub fn scriptsReady(self: *Shell) bool {
    self.loader_lock.lockShared();
    defer self.loader_lock.unlockShared();
    return self.sessions != null;
}

pub fn acquireLoader(self: *Shell) ?*PluginLoader {
    self.loader_lock.lockShared();
    if (self.loader) |l| return l;
    self.loader_lock.unlockShared();
    return null;
}

pub fn releaseLoader(self: *Shell) void {
    self.loader_lock.unlockShared();
}

pub fn pluginCount(self: *Shell) usize {
    const loader = self.acquireLoader() orelse return 0;
    defer self.releaseLoader();
    return loader.count();
}

/// Null if it's been cleared.
pub fn overlayKey(self: *Shell) ?Chord {
    return self.registry.get(self.overlay_key).key;
}

/// Null if it's been cleared.
pub fn workbenchKey(self: *Shell) ?Chord {
    return self.registry.get(self.workbench_key).key;
}

pub fn setOverlayKey(self: *Shell, chord: ?Chord) !void {
    try self.registry.set(self.overlay_key, .{ .key = chord });
}

pub fn setWorkbenchKey(self: *Shell, chord: ?Chord) !void {
    try self.registry.set(self.workbench_key, .{ .key = chord });
}

fn overlayKeyPressed(ctx: *anyopaque, phase: Keybinds.Phase) void {
    const self: *Shell = @ptrCast(@alignCast(ctx));
    if (phase == .pressed) self.toggleOverlay();
}

fn workbenchKeyPressed(ctx: *anyopaque, phase: Keybinds.Phase) void {
    const self: *Shell = @ptrCast(@alignCast(ctx));
    if (phase == .pressed) self.toggleWorkbench();
}

/// Brings the welcome back, with what's picked now. Render thread.
pub fn showWelcome(self: *Shell) void {
    self.hub.open = false;
    self.welcome.open = true;
    self.welcome.leaving = false;
    self.welcome.choices = .{ .overlay_key = self.overlayKey() orelse overlay_key_default };
}

/// Not while the welcome's up. Render thread.
pub fn toggleOverlay(self: *Shell) void {
    if (self.welcome.open) return;
    self.hub.toggle();
}

/// Render thread.
pub fn toggleWorkbench(self: *Shell) void {
    self.workbench.toggle();
}

/// Whether a plugin gets a Settings button, on the Mods page and under its button on the bar: one
/// of its own, or for its settings in Wraith's. `title` is what it's shown as.
pub fn pluginHasSettings(self: *Shell, name: []const u8, title: []const u8) bool {
    return ui_area.hasSettings(name) or self.registry.listsAny(title);
}

/// What its Settings button does. Its own if it has one, else its heading in Wraith's Settings.
/// Render thread, in a frame.
pub fn openPluginSettings(self: *Shell, name: []const u8, title: []const u8) void {
    if (ui_area.openSettings(name)) return;
    self.windows.settings.showGroup(title);
}

/// For tweaks, in JS or Lua.
fn tweaksReady(context: ?*anyopaque, _: []const u8) bool {
    const self: *Shell = @ptrCast(@alignCast(context.?));
    return self.scriptsReady();
}

/// The project to open next time, and where the file dialogs start. Any thread.
pub fn rememberProject(self: *Shell, path: []const u8) void {
    const game = self.options.game orelse return;
    self.settings_lock.lock();
    defer self.settings_lock.unlock();
    const a = game.arena.allocator();
    game.value.project_file = a.dupe(u8, path) catch return;
    if (std.fs.path.dirname(path)) |folder| game.value.project_folder = a.dupe(u8, folder) catch return;
    game.save() catch |err| log.warn("Couldn't save which project is open: {t}", .{err});
}

/// Where the file dialogs start. Empty if they never ran.
pub fn projectFolder(self: *Shell, gpa: std.mem.Allocator) ![]u8 {
    const game = self.options.game orelse return gpa.dupe(u8, "");
    self.settings_lock.lock();
    defer self.settings_lock.unlock();
    return gpa.dupe(u8, game.value.project_folder);
}

fn saveTweakSettings(context: ?*anyopaque, tweaks: GameSettings.Tweaks) void {
    const self: *Shell = @ptrCast(@alignCast(context.?));
    const game = self.options.game orelse return;
    self.settings_lock.lock();
    defer self.settings_lock.unlock();
    game.value.tweaks = Tweaks.copySettings(game.arena.allocator(), tweaks) catch return;
    game.save() catch |err| log.warn("Couldn't save the tweak settings: {t}", .{err});
}

/// Once it's changed, from either UI.
fn saveTweakLayout(self: *Shell) void {
    const game = self.options.game orelse return;
    self.settings_lock.lock();
    defer self.settings_lock.unlock();
    game.value.tweak_layout = self.tweak_layout.takeChanged(game.arena.allocator()) orelse return;
    game.save() catch |err| log.warn("Couldn't save how the tweaks are laid out: {t}", .{err});
}

fn draw(self: *Shell) void {
    if (self.tweaks) |t| t.tick();
    self.saveTweakLayout();
    self.workbench.tickUnopened();
    self.followOsTheme();
    self.watchClashes();
    self.hub.draw(self);
    self.windows.system.draw();
    if (self.welcome.draw(self.overlay)) |choices| {
        self.finishWelcome(choices);
        self.openAfterWelcome();
    }
    if (self.ready_toast) {
        self.ready_toast = false;
        self.toastReady();
    }
}

/// In the middle of the game the first time, wherever it's moved after.
fn startCentred(_: *anyopaque) void {
    ui.setNextWindowPos(ui.mainViewport().centre(), .first_use_ever, .{ 0.5, 0.5 });
}

/// Straight into the overlay, without letting go of the input, so the welcome leads somewhere.
pub fn openAfterWelcome(self: *Shell) void {
    self.hub.open = true;
    self.hub.dim.takeOver(self.overlay, &self.welcome.dim);
    self.welcome.open = false;
    self.welcome.leaving = false;
}

/// A tweak's key switched it. From the tweaks' tick, on the render thread.
fn tweakKeyed(ctx: ?*anyopaque, title: []const u8, now: Tweaks.Keyed) void {
    const self: *Shell = @ptrCast(@alignCast(ctx.?));
    if (!self.registry.get(self.own.tweaks_toasts).toggle) return;
    _ = self.overlay.host.toasts.push(.{
        .kind = if (now == .off) .info else .success,
        .title = title,
        .text = switch (now) {
            .on => "On",
            .off => "Off",
            .ran => "Done",
        },
        .seconds = 2,
    });
}

/// On the render thread, for ImGui's key names.
fn toastReady(self: *Shell) void {
    // Without a key there's nothing to say
    const key = self.overlayKey() orelse return;
    var key_buf: [64]u8 = undefined;
    var text_buf: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, "Press {s} to open it.", .{ui.chordName(&key_buf, key)}) catch return;
    _ = self.overlay.host.toasts.push(.{ .kind = .success, .title = "Wraith is ready", .text = text });
}

/// Takes effect now, and saves them with the welcome as seen. Render thread.
pub fn finishWelcome(self: *Shell, choices: Welcome.Choices) void {
    self.setOverlayKey(choices.overlay_key) catch |err| log.warn("Couldn't use {f} for the overlay: {t}", .{ choices.overlay_key, err });
    self.registry.set(self.own.welcome_seen, .{ .toggle = true }) catch |err| log.warn("Couldn't save that the welcome's been seen: {t}", .{err});
}

/// Saved, and applied to the overlay and the workbench by the setting's hook. Null follows
/// Windows. Any thread.
pub fn setTheme(self: *Shell, choice: ?*const Themes.Theme) void {
    const name = if (choice) |t| t.name else ShellSettings.match_windows;
    self.registry.set(self.own.theme, .{ .choice = name }) catch |err| log.warn("Couldn't set the theme: {t}", .{err});
}

/// What the theme setting says, now. Any thread.
pub fn applyThemeSetting(self: *Shell) void {
    const name = self.own.themeName();
    self.theme_follows_os.store(name == null, .release);
    const themes = self.options.themes orelse return;
    self.applyTheme(themes.pick(name));
}

pub fn themeFollowsOs(self: *const Shell) bool {
    return self.theme_follows_os.load(.acquire);
}

fn applyTheme(self: *Shell, theme: *const Themes.Theme) void {
    self.overlay.setTheme(theme);
    self.workbench.setTheme(theme);
}

/// Once a key's on more than one thing, they all fire, so it warns once about each new clash.
/// Render thread.
fn watchClashes(self: *Shell) void {
    const now = self.keybinds.changes.load(.acquire);
    if (now == self.keys_seen) return;
    self.keys_seen = now;
    const clashes = self.keybinds.clashesAlloc(self.allocator) catch return;
    defer Keybinds.freeClashes(self.allocator, clashes);
    for (clashes) |c| {
        var h: std.hash.Wyhash = .init(0);
        h.update(std.mem.asBytes(&c.chord));
        for (c.ids) |id| h.update(id);
        const key = h.final();
        if (std.mem.indexOfScalar(u64, self.clashes_told.items, key) != null) continue;
        self.clashes_told.append(self.allocator, key) catch return;
        self.toastClash(c);
    }
}

fn toastClash(self: *Shell, clash: Keybinds.Clash) void {
    var text_buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&text_buf);
    var key_buf: [64]u8 = undefined;
    w.print("{s} is used by ", .{ui.chordName(&key_buf, clash.chord)}) catch {};
    for (clash.ids, 0..) |id, i| {
        const sep = if (i == 0) "" else if (i + 1 == clash.ids.len) " and " else ", ";
        if (self.registry.find(id)) |s| {
            w.writeAll(sep) catch {};
            s.def.describe(&w) catch {};
        } else w.print("{s}{s}", .{ sep, id }) catch {};
    }
    w.writeAll(". They all go off. You can change them in Settings.") catch {};
    _ = self.overlay.host.toasts.push(.{ .kind = .warning, .title = "Keys clash", .text = w.buffered(), .seconds = 8 });
}

/// How often to ask Windows if it's switched between light and dark.
const os_theme_check_ns = 2 * std.time.ns_per_s;

/// Render thread.
fn followOsTheme(self: *Shell) void {
    if (!self.themeFollowsOs()) return;
    const themes = self.options.themes orelse return;
    const now = core.timing.now();
    if (now -| self.theme_checked_ns < os_theme_check_ns) return;
    self.theme_checked_ns = now;
    const wanted = themes.pick(null);
    if (self.overlay.currentTheme() != wanted) self.applyTheme(wanted);
}

pub fn frameSettings(self: *Shell) Settings.FrameStats {
    return self.own.frameStats();
}

/// Takes effect now. `save` writes it on a worker, so pass it once an edit's done, not every frame
/// of a drag. Any thread.
pub fn setFrameSettings(self: *Shell, value: Settings.FrameStats, save: bool) void {
    self.registry.setWith(self.own.frame_window, .{ .number = value.window_seconds }, .{ .save = save }) catch {};
    self.registry.setWith(self.own.frame_hitch, .{ .number = value.hitch_factor }, .{ .save = save }) catch {};
}

pub fn applyFrameSettings(self: *Shell, value: Settings.FrameStats) void {
    self.overlay.frames.setWindow(value.window_seconds);
    self.overlay.frames.setHitchFactor(value.hitch_factor);
}

const tests = struct {
    const testing = std.testing;
    const api = wraith_platform.win.api;
    const c = @import("../imgui.zig").c;
    const tuft_imgui = @import("tuft_imgui");
    const Rig = @import("../../testing/Rig.zig");

    const VK_F8 = 0x77;
    const VK_F9 = 0x78;
    const VK_INSERT = 0x2D;
    const VK_ESCAPE = 0x1B;
    const key_up: isize = @bitCast(@as(usize, 0xC000_0001));

    fn press(rig: *Rig, vk: usize) void {
        _ = rig.send(api.WM_KEYDOWN, vk, 1);
        _ = rig.send(api.WM_KEYUP, vk, key_up);
    }

    test "address hotkeys and holds with the workbench never opened" {
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        const shell = try Shell.create(testing.allocator, rig.overlay, rig.keybinds, .{});
        defer shell.destroy();
        rig.present();

        var value: u32 = 5;
        var buf: [32]u8 = undefined;
        try shell.workbench.panels.addresses.list.load(&.{.{ .name = "Mira", .address = try std.fmt.bufPrint(&buf, "0x{x}", .{@intFromPtr(&value)}), .hotkeys = &.{
            .{ .chord = .{ .key = .f8 }, .action = .set, .value = "999999" },
            .{ .chord = .{ .key = .f9 }, .action = .toggle_hold },
        } }});
        rig.present(); // binds them
        try testing.expectEqual(2, rig.keybinds.countPrefix("wraith.address."));
        var named = false;
        for (rig.keybinds.bindings.items) |b| named = named or std.mem.eql(u8, b.name, "Mira: set 999999");
        try testing.expect(named);

        press(&rig, VK_F8);
        rig.present();
        rig.present();
        try testing.expectEqual(999999, value);
        press(&rig, VK_F9);
        rig.present();
        rig.present();
        value = 1;
        rig.present();
        try testing.expectEqual(999999, value);
        try testing.expectEqual(null, shell.workbench.app);
        try testing.expectEqual(0, Rig.game.count(api.WM_KEYDOWN));
    }

    test "workbench opens and closes" {
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        const shell = try Shell.create(testing.allocator, rig.overlay, rig.keybinds, .{});
        defer shell.destroy();
        rig.present();

        // What Ctrl+Home does
        shell.toggleWorkbench();
        rig.present();
        // No GPU for its window here
        const app = shell.workbench.app orelse return error.SkipZigTest;
        try testing.expect(shell.workbench.isOpen());
        for (0..3000) |_| {
            if (app.frameCount() >= 3) break;
            tuft_sys.thread.sleepMs(1);
        }
        try testing.expect(app.frameCount() >= 3);
        // Nothing of it drawn in the game's frame
        try testing.expectEqual(0, c.ImGui_GetIO().*.MetricsRenderWindows);
        // Opening it keeps the game thinking it's active while ours is
        try testing.expect(rig.overlay.focus.load(.acquire) != null);
        // It takes the game's input before it's even in front, so a game holding the mouse can't keep it
        try testing.expect(rig.overlay.taken(.keyboard));
        try testing.expect(rig.overlay.cursorRequested());

        shell.toggleWorkbench();
        try testing.expect(!shell.workbench.isOpen());
        // Closed, the game gets it back on its next tick. Its thread lets go of each in turn
        for (0..3000) |_| {
            if (!rig.overlay.taken(.keyboard) and !rig.overlay.cursorRequested()) break;
            tuft_sys.thread.sleepMs(1);
        }
        try testing.expect(!rig.overlay.taken(.keyboard));
        try testing.expect(!rig.overlay.cursorRequested());
    }

    noinline fn stopHere(x: u32) callconv(.c) u32 {
        return x *% 5 +% 2;
    }

    /// Waits up to 30 s by the clock, failing if it never happens. Loaded CI machines can be slow
    /// to open and draw a real window.
    fn waitUntil(what: []const u8, ctx: anytype, comptime check: fn (@TypeOf(ctx)) bool) !void {
        const start = core.timing.now();
        while (core.timing.now() - start < 30 * std.time.ns_per_s) {
            if (check(ctx)) return;
            tuft_sys.thread.sleepMs(1);
        }
        if (check(ctx)) return;
        std.debug.print("timed out waiting until {s}\n", .{what});
        return error.TimedOut;
    }

    test "breakpoints bring the code to the front, open or closed" {
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        const shell = try Shell.create(testing.allocator, rig.overlay, rig.keybinds, .{});
        defer shell.destroy();
        rig.present();
        const wb = shell.workbench;

        shell.toggleWorkbench();
        const app = wb.app orelse return error.SkipZigTest;
        const Checks = struct {
            fn drawn(a: *tuft_imgui.AppWindow) bool {
                return a.frameCount() >= 10;
            }
            fn hidden(a: *tuft_imgui.AppWindow) bool {
                return !a.isOpen();
            }
            fn stopShown(s: *const Since) bool {
                var out: [Workbench.Debugger.max_paused]Workbench.Debugger.Paused = undefined;
                // New frames, since it keeps the last one's answer while it's hidden
                return s.wb.debugger.paused(&out) == 1 and s.wb.isOpen() and s.app.frameCount() >= s.frames + 2 and s.wb.code_in_front.load(.acquire);
            }
            const Since = struct { wb: *Workbench, app: *tuft_imgui.AppWindow, frames: u32 };
        };
        try waitUntil("it's drawn a few frames", app, Checks.drawn);
        // The memory view's in front to start with
        try testing.expect(!wb.code_in_front.load(.acquire));

        const at = @intFromPtr(&stopHere);
        try wb.toggleHardwareBreakpoint(at);
        for (0..2) |round| {
            if (round == 1) {
                // The memory view in front again, then closed
                const Front = struct {
                    fn memory(w: *Workbench) bool {
                        return w.memory_in_front.load(.acquire);
                    }
                };
                // Asks again now and then, since the desktop giving the window focus back can put
                // the last focused tab in front again. This is only the setup
                const start = core.timing.now();
                while (!Front.memory(wb) and core.timing.now() - start < 30 * std.time.ns_per_s) {
                    wb.remote().openMemory(at, 16, null);
                    const asked = core.timing.now();
                    while (!Front.memory(wb) and core.timing.now() - asked < std.time.ns_per_s) tuft_sys.thread.sleepMs(1);
                }
                if (!Front.memory(wb)) {
                    std.debug.print("timed out waiting until the memory view's in front\n", .{});
                    return error.TimedOut;
                }
                shell.toggleWorkbench();
                try waitUntil("it's closed", app, Checks.hidden);
            }
            const Caller = struct {
                result: Atomic(u32) = .init(0),
                started: Atomic(bool) = .init(false),
                go: Atomic(bool) = .init(false),
                fn run(self: *@This()) void {
                    self.started.store(true, .release);
                    while (!self.go.load(.acquire)) tuft_sys.thread.sleepMs(1);
                    self.result.store(stopHere(3), .release);
                }
            };
            var caller: Caller = .{};
            const thread = try std.Thread.spawn(.{}, Caller.run, .{&caller});
            while (!caller.started.load(.acquire)) tuft_sys.thread.sleepMs(1);
            // New threads get breakpoints on the next refresh
            wb.debugger.refresh();
            caller.go.store(true, .release);

            const since: Checks.Since = .{ .wb = wb, .app = app, .frames = app.frameCount() };
            waitUntil(if (round == 0) "the stop's code is in front" else "it's back with the stop's code in front", &since, Checks.stopShown) catch |err| {
                wb.debugger.resumeAll();
                thread.join();
                return err;
            };
            wb.debugger.resumeAll();
            thread.join();
            try testing.expectEqual(17, caller.result.load(.acquire));
        }
    }

    test "the welcome dims the game and holds input till it's dismissed" {
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        const shell = try Shell.create(testing.allocator, rig.overlay, rig.keybinds, .{});
        defer shell.destroy();
        // No settings here, so it'd be off
        try testing.expect(!shell.welcome.open);
        shell.welcome.open = true;
        for (0..3) |_| rig.present();
        // It and what dims the game
        try testing.expectEqual(2, c.ImGui_GetIO().*.MetricsRenderWindows);
        try testing.expect(rig.overlay.cursorRequested());
        try testing.expect(rig.overlay.taken(.keyboard));

        shell.welcome.dismiss(rig.overlay);
        // The game has its input back while it fades
        try testing.expect(!rig.overlay.cursorRequested());
        for (0..3000) |_| {
            rig.present();
            if (!shell.welcome.open) break;
            tuft_sys.thread.sleepMs(1);
        }
        try testing.expect(!shell.welcome.open);
        rig.present();
        try testing.expectEqual(0, c.ImGui_GetIO().*.MetricsRenderWindows);
        try testing.expect(!rig.overlay.taken(.keyboard));
    }

    test "the hub only takes the controller when set to" {
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        const shell = try Shell.create(testing.allocator, rig.overlay, rig.keybinds, .{});
        defer shell.destroy();
        rig.present();

        shell.hub.open = true;
        for (0..3) |_| rig.present();
        try testing.expect(rig.overlay.taken(.keyboard));
        try testing.expect(!rig.overlay.taken(.gamepad)); // off by default

        // Changing it while open counts straight away
        rig.overlay.ui_takes_gamepad.store(true, .release);
        rig.present();
        try testing.expect(rig.overlay.taken(.gamepad));
        rig.overlay.setEnabled(.gamepad, false); // not allowed at all
        try testing.expect(!rig.overlay.taken(.gamepad));
        rig.overlay.setEnabled(.gamepad, true);

        shell.hub.open = false;
        for (0..3) |_| rig.present();
        try testing.expectEqual(0, rig.overlay.takes.getPtrConst(.gamepad).load(.acquire));
        rig.overlay.ui_takes_gamepad.store(false, .release);
    }

    test "the bar's tiles move within their group and stay put" {
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        const shell = try Shell.create(testing.allocator, rig.overlay, rig.keybinds, .{});
        defer shell.destroy();
        shell.hub.open = true;
        for (0..2) |_| rig.present();
        // Like a drag, or Move left from its menu
        const tweaks = shell.hub.reorder.moveOf(Hub.tileId("window", "tweaks"), .up).?;
        shell.hub.reorder.pending = tweaks;
        rig.present();
        const saved = shell.registry.get(shell.own.hub_order).text;
        try testing.expect(saved.len > 0);
        try testing.expectEqual(Hub.tileId("window", "tweaks"), shell.hub.order.orderIds()[0]);

        // Read back next time
        shell.hub.order.load(&.{}, &.{});
        shell.hub.order_loaded = false;
        rig.present();
        try testing.expectEqual(Hub.tileId("window", "tweaks"), shell.hub.order.orderIds()[0]);
    }

    test "the overlay key slides the bar in" {
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        const shell = try Shell.create(testing.allocator, rig.overlay, rig.keybinds, .{});
        defer shell.destroy();
        rig.overlay.setCursorHint(.hidden); // mouse-look
        rig.present(); // attaches
        rig.present();
        try testing.expectEqual(0, c.ImGui_GetIO().*.MetricsRenderWindows);

        press(&rig, VK_INSERT);
        for (0..3) |_| rig.present();
        try testing.expect(shell.hub.open);
        // Just the bar
        try testing.expectEqual(1, c.ImGui_GetIO().*.MetricsRenderWindows);
        try testing.expect(c.ImGui_GetIO().*.MouseDrawCursor);
        try testing.expect(rig.overlay.taken(.keyboard));
        try testing.expectEqual(0, Rig.game.count(api.WM_KEYDOWN)); // Insert is ours

        press(&rig, VK_INSERT);
        for (0..3) |_| rig.present();
        try testing.expect(!shell.hub.open);
        try testing.expect(!rig.overlay.taken(.keyboard));
        // Gone once it's slid away
        for (0..3000) |_| {
            rig.present();
            if (shell.hub.dim.fade == 0) break;
            tuft_sys.thread.sleepMs(1);
        }
        rig.present();
        try testing.expectEqual(0, c.ImGui_GetIO().*.MetricsRenderWindows);

        // Its windows stay up without the bar, and let the game have the mouse
        shell.toggleOverlay();
        shell.windows.about.window.show();
        for (0..3) |_| rig.present();
        shell.toggleOverlay();
        for (0..3) |_| rig.present();
        try testing.expect(!shell.hub.open and shell.windows.about.window.open);
        try testing.expect(!rig.overlay.taken(.mouse));
        shell.windows.about.window.close();

        // Escape closes it too
        press(&rig, VK_INSERT);
        for (0..3) |_| rig.present();
        try testing.expect(shell.hub.open);
        press(&rig, VK_ESCAPE);
        for (0..3) |_| rig.present();
        try testing.expect(!shell.hub.open);

        // Not over the welcome
        shell.welcome.open = true;
        shell.toggleOverlay();
        try testing.expect(!shell.hub.open);
    }

    test "settings take effect as they change" {
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        const shell = try Shell.create(testing.allocator, rig.overlay, rig.keybinds, .{});
        defer shell.destroy();
        rig.present();
        shell.windows.settings.window.show();
        for (0..3) |_| rig.present();

        // One that only changes on a restart, like the game's own
        const scale = try shell.registry.add(.{ .id = "test.scale", .name = "Scale", .group = Settings.group, .section = "Look & Feel", .restart = true, .kind = .{ .number = .{ .default = 1, .min = 0.5, .max = 3 } } }, .{});
        defer shell.registry.remove(scale);

        const page = &shell.windows.settings;
        // Searching shows matches from every tab, which draws nearly every row
        page.search[0] = 'e';
        for (0..2) |_| rig.present();
        page.search = @splat(0);
        try testing.expect(!page.restart_pending);
        try page.edit(shell, "wraith.toggle_overlay", .{ .key = .{ .key = .f8 } });
        try page.edit(shell, "test.scale", .{ .number = 2 });
        var overlay_key: ?Keybinds.Binding = null;
        var workbench_bound = false;
        for (rig.keybinds.bindings.items) |b| {
            if (std.mem.eql(u8, b.id, "wraith.toggle_overlay")) overlay_key = b.*;
            if (std.mem.eql(u8, b.id, "wraith.toggle_workbench")) workbench_bound = true;
        }
        try testing.expectEqual(.f8, overlay_key.?.chord.key);
        try testing.expect(workbench_bound);
        // The scale only changes on a restart, which it says
        try testing.expect(page.restart_pending);
        try testing.expectEqual(2, shell.registry.get(scale).number);

        // About draws too, and both licenses, next to Settings
        shell.windows.about.window.show();
        rig.present();
        for (std.enums.values(@TypeOf(shell.windows.about.section))) |section| {
            shell.windows.about.section = section;
            for (0..2) |_| rig.present();
        }
        try testing.expect(shell.windows.about.window.open and shell.windows.settings.window.open);
    }

    test "plugins get a Settings page of their own, which their Settings button opens" {
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        const shell = try Shell.create(testing.allocator, rig.overlay, rig.keybinds, .{});
        defer shell.destroy();
        rig.present();
        // Like a plugin's, a folder and a key under a heading of its own
        const folder = try shell.registry.add(.{ .id = "kai.folder", .name = "Folder", .group = "Kai", .kind = .{ .path = .{ .placeholder = "Pictures" } } }, .{});
        defer shell.registry.remove(folder);
        const key = try shell.registry.add(.{ .id = "kai.shoot", .name = "Shoot", .group = "Kai", .section = "Camera", .kind = .{ .key = .{ .default = .{ .key = .f10 } } } }, .{});
        defer shell.registry.remove(key);

        try testing.expect(shell.pluginHasSettings("kai", "Kai"));
        try testing.expect(!shell.pluginHasSettings("nobody", "Nobody"));
        // Without a button of its own, it's its page in Wraith's Settings, keys and all
        shell.openPluginSettings("kai", "Kai");
        const page = &shell.windows.settings;
        try testing.expect(page.window.open and page.page == .owner);
        try testing.expectEqualStrings("Kai", page.page_name[0..page.page_name_len]);
        for (0..2) |_| rig.present();
        // And every key on one page
        page.page = .all_keys;
        for (0..2) |_| rig.present();
        // Browse's pick lands next frame
        try SettingsWindow.browsed("kai.folder", "C:\\shots");
        rig.present();
        try testing.expectEqualStrings("C:\\shots", shell.registry.get(folder).path);
    }

    test "after the welcome the overlay comes up, without letting go of the input" {
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        const shell = try Shell.create(testing.allocator, rig.overlay, rig.keybinds, .{});
        defer shell.destroy();
        shell.welcome.open = true;
        for (0..3) |_| rig.present();
        try testing.expect(rig.overlay.taken(.keyboard));

        // What Continue does
        shell.welcome.leaving = true;
        shell.finishWelcome(shell.welcome.choices);
        shell.openAfterWelcome();
        try testing.expect(rig.overlay.taken(.keyboard));
        try testing.expect(rig.overlay.cursorRequested());
        for (0..3) |_| rig.present();
        try testing.expect(shell.hub.open and !shell.welcome.open);
        try testing.expect(rig.overlay.taken(.keyboard));

        // Holds once, so closing it lets go
        shell.toggleOverlay();
        for (0..3) |_| rig.present();
        try testing.expect(!rig.overlay.taken(.keyboard));
        try testing.expect(!rig.overlay.cursorRequested());
    }

    test "clashing keys get a warning, once" {
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        const shell = try Shell.create(testing.allocator, rig.overlay, rig.keybinds, .{});
        defer shell.destroy();
        for (0..2) |_| rig.present();
        try testing.expectEqual(0, rig.overlay.host.toasts.count());

        const Noop = struct {
            fn call(_: *@This()) void {}
        };
        var noop: Noop = .{};
        // On the overlay's own key
        const clash = try rig.keybinds.bindUnscoped(.{ .id = "kai.toggle", .name = "Toggle", .chord = Shell.overlay_key_default }, &noop, Noop.call);
        defer clash.unbind();
        for (0..2) |_| rig.present();
        try testing.expectEqual(1, rig.overlay.host.toasts.count());
        for (0..2) |_| rig.present();
        try testing.expectEqual(1, rig.overlay.host.toasts.count());
    }

    test "a toast says how to open it" {
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        const shell = try Shell.create(testing.allocator, rig.overlay, rig.keybinds, .{});
        defer shell.destroy();
        // No settings here, so as if the welcome's been seen
        shell.ready_toast = true;
        for (0..2) |_| rig.present();
        try testing.expectEqual(1, rig.overlay.host.toasts.count());
        try testing.expect(!shell.ready_toast);
    }

    test "the welcome's choices take effect" {
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        const shell = try Shell.create(testing.allocator, rig.overlay, rig.keybinds, .{});
        defer shell.destroy();
        const Find = struct {
            fn binding(k: *Keybinds, id: []const u8) ?*Keybinds.Binding {
                for (k.bindings.items) |b| if (std.mem.eql(u8, b.id, id)) return b;
                return null;
            }
        };
        try testing.expectEqual(.insert, Find.binding(rig.keybinds, "wraith.toggle_overlay").?.chord.key);
        try testing.expect(Find.binding(rig.keybinds, "wraith.toggle_workbench") != null);

        shell.finishWelcome(.{ .overlay_key = .{ .key = .f8 } });
        try testing.expectEqual(.f8, Find.binding(rig.keybinds, "wraith.toggle_overlay").?.chord.key);
    }

    test "Settings lists dev plugins" {
        const io = testing.io;
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        const saved = core.log.mute(&.{ .ui, .runtime });
        defer core.log.setFilter(saved);

        var install: @import("../../testing/Install.zig") = undefined;
        try install.init(.{ .dev_plugins = &.{"dev" ++ std.fs.path.sep_str ++ "mine"} });
        defer install.deinit();
        try install.tmp.dir.createDirPath(io, "dev/mine");
        try install.writeManifest("dev/mine", "mine", "");
        try install.loader.start(&.{});

        const shell = try Shell.create(testing.allocator, rig.overlay, rig.keybinds, .{ .io = io });
        defer shell.destroy();
        shell.setLoader(&install.loader);
        defer shell.setLoader(null);
        shell.dev_plugins.refresh(shell);
        try shell.dev_plugins.group.await(io);
        {
            const v = shell.dev_plugins.view(io);
            defer v.end();
            try testing.expectEqual(1, v.entries().len);
            try testing.expectEqualStrings("mine", v.entries()[0].id.?);
        }

        try install.tmp.dir.createDirPath(io, "dev/other");
        try install.writeManifest("dev/other", "other", "");
        const other = try std.fs.path.join(testing.allocator, &.{ install.root, "dev", "other" });
        defer testing.allocator.free(other);
        shell.dev_plugins.add(shell, other);
        try shell.dev_plugins.group.await(io);
        try (try install.loader.rescan()).wait();
        {
            const v = shell.dev_plugins.view(io);
            defer v.end();
            try testing.expectEqual(2, v.entries().len);
        }
        try testing.expectEqual(2, install.loader.devCount());

        shell.dev_plugins.remove(shell, other);
        try shell.dev_plugins.group.await(io);
        const v = shell.dev_plugins.view(io);
        defer v.end();
        try testing.expectEqual(1, v.entries().len);
    }

    test "the mods page lists what's installed, dev plugins and the hub's, and turns plugins on and off" {
        const io = testing.io;
        const options = @import("test_options");
        const registry = @import("wraith_registry");
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        const saved = core.log.mute(&.{ .ui, .runtime, .plugin });
        defer core.log.setFilter(saved);

        var install: @import("../../testing/Install.zig") = undefined;
        try install.init(.{ .plugins = &.{.{ "fixture", options.fixture_plugin }}, .dev_plugins = &.{"dev" ++ std.fs.path.sep_str ++ "mine"} });
        defer install.deinit();
        try install.pluginManifest("fixture", "\"title\": \"Fixture\", \"version\": \"1.0.0\"");
        try install.tmp.dir.createDirPath(io, "dev/mine");
        try install.writeManifest("dev/mine", "mine", "\"autoLoad\": false");
        try install.loader.start(&.{});

        const shell = try Shell.create(testing.allocator, rig.overlay, rig.keybinds, .{ .io = io });
        defer shell.destroy();
        shell.setLoader(&install.loader);
        defer shell.setLoader(null);

        // The hub's answer, without asking it
        const page = &shell.windows.mods;
        const listed = [_]registry.mods.Listed{
            .{ .id = "fixture", .kind = .plugin, .title = "Fixture", .summary = "Draws things", .author = "Us", .any_game = true, .games = &.{}, .featured = false, .why = null, .latest = "1.1.0", .needs_wraith = null, .installed = "1.0.0", .revoked = false },
            .{ .id = "other", .kind = .project, .title = "Other", .summary = "Tables", .author = "Them", .any_game = true, .games = &.{}, .featured = true, .why = null, .latest = "2.0.0", .needs_wraith = null, .installed = null, .revoked = false },
        };
        page.work.listing = .{ .generated = "", .mods = &listed };
        page.work.fetched.store(true, .release);
        defer page.work.listing = null;

        // An installed copy under the dev one
        const folders = [_]ModsWindow.Folder{.{ .id = "mine", .version = "0.9.0" }};
        page.work.folders = &folders;
        defer page.work.folders = &.{};

        page.snapshot(shell);
        {
            const installed = page.collect(.installed, "");
            try testing.expectEqual(1, installed.len);
            try testing.expectEqualStrings("fixture", installed[0].id);
            try testing.expectEqual(null, installed[0].over);
            const dev = page.collect(.dev, "");
            try testing.expectEqual(1, dev.len);
            try testing.expect(dev[0].dev);
            try testing.expectEqualStrings("0.9.0", dev[0].over.?.version);
            try testing.expectEqualStrings("fixture", page.collect(.updates, "")[0].id);
            try testing.expectEqual(1, page.collect(.updates, "").len);
            try testing.expectEqualStrings("other", page.collect(.browse, "")[0].id);
            try testing.expectEqual(0, page.collect(.installed, "nothing like it").len);
            try testing.expectEqual(1, page.collect(.installed, "draws").len);
        }

        // Every section draws, with a row open
        rig.present();
        shell.windows.mods.window.show();
        for ([_][]const u8{ "fixture", "mine" }) |open| {
            page.expanded.set(open);
            for (std.enums.values(ModsWindow.Section)) |section| {
                page.section = section;
                for (0..2) |_| rig.present();
            }
        }
        try testing.expect(shell.windows.mods.window.open);

        // On and off happen on the worker
        try testing.expectEqual(.loaded, install.info("fixture").?.state);
        page.startOn(shell, .unload, "fixture");
        try page.work.group.await(io);
        try testing.expectEqual(.unloaded, install.info("fixture").?.state);
        page.startOn(shell, .load, "fixture");
        try page.work.group.await(io);
        try testing.expectEqual(.loaded, install.info("fixture").?.state);
        page.startOn(shell, .reload, "fixture");
        try page.work.group.await(io);
        try testing.expectEqual(.loaded, install.info("fixture").?.state);
        try testing.expectEqualStrings("", page.work.problem.message());
    }

    test "the tweaks page, the list on screen and toasts for keys" {
        const support = @import("../../tweaks/test_support.zig");
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        var s: support.Setup = try .init(&.{
            .{ "tweaks/speed.rwt", "@tweak \"Speed\"\n@key F8\n@data\n  [Max(5)] u64 times = 1\n@js\n" },
            .{ "tweaks/kai.rwt", "@group \"Kai\"\n@js\n@tweak \"One\"\n@js\n@tweak \"Two\"\n@js\n" },
        });
        defer s.deinit();
        const shell = try Shell.create(testing.allocator, rig.overlay, rig.keybinds, .{});
        defer shell.destroy();
        shell.tweaks = try Tweaks.create(testing.allocator, s.project, shell.registry, .{}, .{ .context = shell, .keyed = tweakKeyed });
        const tweaks = shell.tweaks.?;

        // The page draws with a folded group, searching and only what's on
        rig.present();
        const window = &shell.windows.tweaks;
        window.window.show();
        for (0..2) |_| rig.present();
        const layout = &shell.tweak_layout;
        layout.toggle(TweakLayout.tweakId("kai"));
        // Moved, like by a drag or the menu, it stays among the ones next to it
        window.reorder.pending = .{ .dragged = TweakLayout.tweakId("kai"), .target = TweakLayout.tweakId("speed"), .place = .before };
        for (0..2) |_| rig.present();
        {
            var a: std.heap.ArenaAllocator = .init(testing.allocator);
            defer a.deinit();
            const all = try layout.entries(a.allocator(), try tweaks.snapshot(a.allocator()), &.{});
            try testing.expectEqual(TweakLayout.tweakId("kai"), all[1].id);
            try testing.expect(all[1].folded);
        }
        // Its fields, opened
        window.setOpen(testing.allocator, std.hash.Wyhash.hash(1, "speed"), true);
        window.search[0] = 'o';
        for (0..2) |_| rig.present();
        window.search = @splat(0);
        window.only_on = true;
        for (0..2) |_| rig.present();

        // All off turns a whole group's file off too
        tweaks.setOn("speed", true);
        tweaks.setOn("kai/One", true);
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        TweaksWindow.turnAllOff(tweaks, try tweaks.snapshot(arena.allocator()));
        for (try tweaks.snapshot(arena.allocator())) |t| try testing.expect(!t.on and !t.partial);

        // Pinned, its small list shows with the window closed and the overlay too
        try shell.registry.set(shell.own.tweaks_on_screen, .{ .toggle = true });
        for (0..2) |_| rig.present();
        window.window.close();
        for (0..2) |_| rig.present();
        shell.toggleOverlay();
        for (0..2) |_| rig.present();

        // A key's switch says so, unless that's turned off
        const before = rig.overlay.host.toasts.count();
        tweakKeyed(shell, "Speed", .on);
        try testing.expectEqual(before + 1, rig.overlay.host.toasts.count());
        try shell.registry.set(shell.own.tweaks_toasts, .{ .toggle = false });
        tweakKeyed(shell, "Speed", .off);
        try testing.expectEqual(before + 1, rig.overlay.host.toasts.count());
    }

    test "[Tweak] structs list in the Tweaks window and draw their fields" {
        const support = @import("../../tweaks/test_support.zig");
        const host_schemas = @import("../../host/schemas.zig");
        const struct_tweaks = @import("../../host/struct_tweaks.zig");
        const StructEditor = @import("../StructEditor.zig");
        const Loaded = @import("../../PluginLoader.zig").Loaded;
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        var s: support.Setup = try .init(&.{});
        defer s.deinit();
        const shell = try Shell.create(testing.allocator, rig.overlay, rig.keybinds, .{});
        defer shell.destroy();
        shell.tweaks = try Tweaks.create(testing.allocator, s.project, shell.registry, .{}, .{ .context = shell });

        // Needs [Instance] to be found
        var diag: @import("salamander_schema").Schema.Diagnostic = .{};
        try testing.expectError(error.InvalidSchema, host_schemas.fromFilesWhy(&.{.{ .name = "kai/a.sal", .text = "[Tweak(\"Money\")] struct Bank { u32 mira; }" }}, &diag));
        try testing.expect(std.mem.indexOf(u8, diag.message(), "[Instance]") != null);
        try testing.expectError(error.InvalidSchema, host_schemas.fromFilesWhy(&.{.{ .name = "kai/a.sal", .text = "[Instance(\"90\")] struct A { u32 n; [Choices(\"A.n\", id, name)] u32 pick; }" }}, &diag));
        try testing.expect(std.mem.indexOf(u8, diag.message(), "lead to an array") != null);

        var loaded: Loaded = undefined;
        loaded.initForTest(testing.allocator, "kai");
        defer loaded.deinitForTest();
        loaded.schemas = try host_schemas.fromFiles(&.{
            // Not this plugin's, so not listed
            .{ .name = "other/b.sal", .text = "[Instance(\"90 90\"), Tweak(\"Theirs\")] struct Theirs { u32 x; }" },
            .{ .name = "kai/game.sal", .text =
            \\enum Mode : u8 { slow, fast }
            \\bitfield Flags : u8 { bool shown; [Bit(1)] u8 level : 3; }
            \\struct Inner { [Label("Hit points")] i32 hp; }
            \\struct Item { u32 id; cstring name; }
            \\[Instance("CC 13 37 CC 13 37 CC 13 37 CC", Rip), Tweak("Money")]
            \\struct Bank {
            \\    u32 mira;
            \\    [Range(0, 10)] f32 speed;
            \\    Mode mode;
            \\    Flags flags;
            \\    [ReadOnly] u16[3] slots;
            \\    [Hidden] u32 secret;
            \\    [Flatten] Inner inner;
            \\    [Flatten] Inner* next;
            \\    Inner* none;
            \\    [Choices("Bank.items")] u32 pick;
            \\    u32 used;
            \\    Item[used] items;
            \\}
            },
        });
        struct_tweaks.publish(&loaded);
        {
            var a: std.heap.ArenaAllocator = .init(testing.allocator);
            defer a.deinit();
            const listed = struct_tweaks.snapshot(a.allocator(), "hit points");
            try testing.expectEqual(1, listed.len);
            try testing.expectEqualStrings("Money", listed[0].title);
            try testing.expectEqualStrings("kai", listed[0].source_title);
            // Found by a field inside
            try testing.expect(listed[0].matches);
        }

        // Opened, though the game hasn't made it, then searched by a field
        const window = &shell.windows.tweaks;
        window.window.show();
        rig.present();
        try window.opened.append(testing.allocator, std.hash.Wyhash.hash(0, "kai/Bank"));
        for (0..2) |_| rig.present();
        window.search[0] = 'm';
        window.search[1] = 'i';
        for (0..2) |_| rig.present();

        // Over memory of our own, every kind of field
        const Inner = extern struct { hp: i32 };
        const Item = extern struct { id: u32, name: [*:0]const u8 };
        const Bank = extern struct { mira: u32, speed: f32, mode: u8, flags: u8, slots: [3]u16, secret: u32, inner: Inner, next: ?*Inner, none: ?*Inner, pick: u32, used: u32, items: [3]Item };
        var other: Inner = .{ .hp = 7 };
        var bank: Bank = .{ .mira = 500, .speed = 2, .mode = 1, .flags = 0b101, .slots = .{ 1, 2, 3 }, .secret = 9, .inner = .{ .hp = 30 }, .next = &other, .none = null, .pick = 20, .used = 2, .items = .{ .{ .id = 10, .name = "Tear Balm" }, .{ .id = 20, .name = "Potion" }, .{ .id = 30, .name = "past the count" } } };
        const Drawer = struct {
            schema: *const @import("salamander_schema").Schema,
            address: usize,
            drew: bool = false,
            fn draw(d: *@This()) void {
                const win = ui.window("Bank##test", .{}) orelse return;
                defer win.end();
                d.drew = StructEditor.draw(d.schema, "Bank", d.address);
            }
        };
        var drawer: Drawer = .{ .schema = &loaded.schemas.?.parsed.schema, .address = @intFromPtr(&bank) };
        var scope: core.Scope = .init(testing.allocator);
        defer scope.deinit();
        try rig.overlay.draw.subscribe(&scope, &drawer, Drawer.draw);
        for (0..2) |_| rig.present();
        try testing.expect(drawer.drew);
        try testing.expectEqual(500, bank.mira);

        // The list a [Choices] reads, only as long as its [Count] says
        var list_arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer list_arena.deinit();
        const schema = &loaded.schemas.?.parsed.schema;
        const picks = try StructEditor.readList(@import("tuft_schema").Ref.of(schema, "Bank", @intFromPtr(&bank)), "items", "id", "name", list_arena.allocator());
        try testing.expectEqual(2, picks.len);
        try testing.expectEqualStrings("Potion", picks[1].label);
        try testing.expectEqual(20, picks[1].value);

        loaded.owner.close();
        try testing.expectEqual(0, struct_tweaks.count());
    }

    test "a theme, or whatever Windows says" {
        var themes = try Themes.load(testing.allocator, testing.io, null);
        defer themes.deinit();
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        const shell = try Shell.create(testing.allocator, rig.overlay, rig.keybinds, .{ .themes = &themes });
        defer shell.destroy();

        shell.setTheme(themes.find("Light"));
        for (0..2) |_| rig.present();
        try testing.expect(!shell.themeFollowsOs());
        try testing.expectEqualStrings("Light", rig.overlay.currentTheme().?.name);

        shell.setTheme(null);
        for (0..2) |_| rig.present();
        try testing.expect(shell.themeFollowsOs());
        try testing.expectEqual(themes.pick(null), rig.overlay.currentTheme().?);
    }

    test "frame settings reach the stats" {
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        const shell = try Shell.create(testing.allocator, rig.overlay, rig.keybinds, .{});
        defer shell.destroy();

        shell.setFrameSettings(.{ .window_seconds = 2, .hitch_factor = 3 }, false);
        try testing.expectEqual(2, rig.overlay.frames.window());
        try testing.expectEqual(3, rig.overlay.frames.hitchFactor());
        try testing.expectEqual(2, shell.frameSettings().window_seconds);
    }

    test "script session answers" {
        const host = @import("../../host/root.zig");

        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        const shell = try Shell.create(testing.allocator, rig.overlay, rig.keybinds, .{});
        defer shell.destroy();
        _ = core.log.mute(&.{ .ui, .plugin, .runtime });
        host.ui.setOverlay(rig.overlay);
        defer host.ui.setOverlay(null);
        host.messages.setFrames(true);
        defer host.messages.setFrames(false);
        try rig.runPluginFrames();

        var install: @import("../../testing/Install.zig") = undefined;
        try install.init(.{});
        defer install.deinit();
        try install.loader.start(&.{});
        try testing.expect(!shell.scriptsReady());
        shell.setLoader(&install.loader);
        defer shell.setLoader(null);
        try testing.expect(shell.scriptsReady());

        const scripts = &shell.workbench.scripts;
        const session = try scripts.newSession("test");
        scripts.run(session, "frame.onFrame(() => {}); 40 + 2");
        settle(&rig, scripts, session, 2);
        try testing.expectEqual(.code, scripts.console.items[0].kind);
        try testing.expectEqualStrings("42", scripts.console.items[1].text);
        try testing.expectEqual(1, scripts.find(session).?.running.?.frames);
        scripts.reset(session);
        for (0..5) |_| step(&rig, scripts);
        try testing.expectEqual(0, scripts.find(session).?.running.?.total());

        // Lua runs in the same sessions
        const lua = try scripts.newSession("lua");
        scripts.setLanguage(lua, .lua);
        const before = scripts.console.items.len;
        scripts.run(lua, "x = 40; return x + 2");
        settle(&rig, scripts, lua, before + 2);
        try testing.expectEqualStrings("42", scripts.console.items[before + 1].text);
        try testing.expect(scripts.find(session).?.running != null);
    }

    fn step(rig: *Rig, scripts: anytype) void {
        host_messages.deliver();
        rig.present();
        host_messages.deliver();
        scripts.pump();
    }

    /// Till there are `lines` and its report's in.
    fn settle(rig: *Rig, scripts: anytype, session: u32, lines: usize) void {
        for (0..200) |_| {
            step(rig, scripts);
            if (scripts.console.items.len >= lines and scripts.find(session).?.running != null) return;
            tuft_sys.thread.sleepMs(1);
        }
    }

    const host_messages = @import("../../host/messages.zig");
};

test {
    _ = tests;
    _ = ShellSettings;
}
