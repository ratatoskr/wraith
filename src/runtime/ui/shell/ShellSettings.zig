//! The shell's own settings in the registry, applied as they change. That's the theme, developer
//! mode, frame stats, whether the overlay takes controllers, the workbench's command keys, the
//! tweaks' on-screen list and toasts, and whether the welcome's been seen.

const ShellSettings = @This();

const std = @import("std");

const Registry = @import("../../settings/Registry.zig");
const Settings = @import("../../Settings.zig");
const Themes = @import("../Themes.zig");
const WorkbenchKeys = @import("../workbench/Settings.zig").Keys;
const FrameStats = @import("../../FrameStats.zig");
const Shell = @import("Shell.zig");

pub const match_windows = "Match Windows";

const key_names = @typeInfo(WorkbenchKeys).@"struct".field_names;

registry: *Registry,
theme: *Registry.Setting,
developer_mode: *Registry.Setting,
welcome_seen: *Registry.Setting,
frame_window: *Registry.Setting,
frame_hitch: *Registry.Setting,
overlay_gamepad: *Registry.Setting,
tweaks_on_screen: *Registry.Setting,
tweaks_toasts: *Registry.Setting,
/// Who exported a mod last, to start the next with.
export_author: *Registry.Setting,
workbench_keys: [key_names.len]*Registry.Setting,

pub fn add(shell: *Shell, registry: *Registry) !ShellSettings {
    var self: ShellSettings = undefined;
    self.registry = registry;
    var added: std.ArrayList(*Registry.Setting) = .empty;
    defer added.deinit(shell.allocator);
    errdefer for (added.items) |s| registry.remove(s);

    var names: [64][]const u8 = undefined;
    names[0] = match_windows;
    var n: usize = 1;
    if (shell.options.themes) |themes| for (themes.list()) |t| {
        if (n == names.len) break;
        names[n] = t.name;
        n += 1;
    };
    self.theme = try registry.add(.{
        .id = "wraith.theme",
        .name = "Theme",
        .help = "The colours of the overlay and the workbench.",
        .group = Settings.group,
        .section = "Look & Feel",
        .kind = .{ .choice = .{ .default = match_windows, .options = names[0..n] } },
    }, .{ .changed = .{ .ctx = shell, .call = themeChanged } });
    try added.append(shell.allocator, self.theme);

    self.developer_mode = try registry.add(.{
        .id = "wraith.developer_mode",
        .name = "Developer mode",
        .help = "Turns on the workbench and the other tools for making plugins and digging into games.",
        .group = Settings.group,
        .section = "Developer",
        .kind = .{ .toggle = false },
    }, .{ .changed = .{ .ctx = shell, .call = developerModeChanged } });
    try added.append(shell.allocator, self.developer_mode);

    self.welcome_seen = try registry.add(.{
        .id = "wraith.welcome_seen",
        .name = "Welcome seen",
        .group = Settings.group,
        .hidden = true,
        .kind = .{ .toggle = false },
    }, .{});
    try added.append(shell.allocator, self.welcome_seen);

    const defaults: Settings.FrameStats = .{};
    self.frame_window = try registry.add(.{
        .id = "wraith.frame_stats.window",
        .name = "Frame stats window (seconds)",
        .help = "How many seconds of frames the frame stats cover.",
        .group = Settings.group,
        .section = "Frame stats",
        .kind = .{ .number = .{ .default = defaults.window_seconds, .min = FrameStats.min_window_seconds, .max = FrameStats.max_window_seconds } },
    }, .{ .changed = .{ .ctx = shell, .call = frameStatsChanged } });
    try added.append(shell.allocator, self.frame_window);
    self.frame_hitch = try registry.add(.{
        .id = "wraith.frame_stats.hitch",
        .name = "Hitch at (times the median)",
        .help = "Frames this many times the median count as hitches.",
        .group = Settings.group,
        .section = "Frame stats",
        .kind = .{ .number = .{ .default = defaults.hitch_factor, .min = FrameStats.min_hitch_factor, .max = FrameStats.max_hitch_factor } },
    }, .{ .changed = .{ .ctx = shell, .call = frameStatsChanged } });
    try added.append(shell.allocator, self.frame_hitch);

    self.overlay_gamepad = try registry.add(.{
        .id = "wraith.overlay_captures_gamepad",
        .name = "Overlay captures gamepad",
        .help = "Takes controllers from the game while the overlay's open, to move around it with. Needs Allow gamepad capture.",
        .group = Settings.group,
        .section = "Controls",
        .kind = .{ .toggle = false },
    }, .{ .changed = .{ .ctx = shell, .call = overlayGamepadChanged } });
    try added.append(shell.allocator, self.overlay_gamepad);
    shell.overlay.ui_takes_gamepad.store(registry.get(self.overlay_gamepad).toggle, .release);

    self.tweaks_on_screen = try registry.add(.{
        .id = "wraith.tweaks.on_screen",
        .name = "Show tweaks on screen",
        .help = "A small list in a corner of the game of the tweaks with keys, and which are on. Move it while the overlay's open.",
        .group = Settings.group,
        .section = "Tweaks",
        .kind = .{ .toggle = false },
    }, .{});
    try added.append(shell.allocator, self.tweaks_on_screen);
    self.tweaks_toasts = try registry.add(.{
        .id = "wraith.tweaks.toasts",
        .name = "Say when a key switches a tweak",
        .help = "A toast in the corner each time a tweak's key turns it on or off.",
        .group = Settings.group,
        .section = "Tweaks",
        .kind = .{ .toggle = true },
    }, .{});
    try added.append(shell.allocator, self.tweaks_toasts);
    self.export_author = try registry.add(.{
        .id = "wraith.export.author",
        .name = "Mod author",
        .group = Settings.group,
        .hidden = true,
        .kind = .{ .text = "" },
    }, .{});
    try added.append(shell.allocator, self.export_author);

    const key_defaults: WorkbenchKeys = .{};
    inline for (key_names, 0..) |field, i| {
        var name_buf: [64]u8 = undefined;
        var id_buf: [96]u8 = undefined;
        self.workbench_keys[i] = try registry.add(.{
            .id = std.fmt.bufPrint(&id_buf, "wraith.workbench.{s}", .{field}) catch unreachable,
            .name = humanName(&name_buf, field),
            .group = Settings.group,
            .section = "Workbench",
            // Inside the workbench's window, not the game's
            .kind = .{ .key = .{ .default = @field(key_defaults, field), .in_game = false } },
        }, .{ .changed = .{ .ctx = shell, .call = workbenchKeyChanged } });
        try added.append(shell.allocator, self.workbench_keys[i]);
    }
    return self;
}

pub fn remove(self: *const ShellSettings) void {
    const r = self.registry;
    inline for (.{ "theme", "developer_mode", "welcome_seen", "frame_window", "frame_hitch", "overlay_gamepad", "tweaks_on_screen", "tweaks_toasts", "export_author" }) |name| r.remove(@field(self, name));
    for (self.workbench_keys) |s| r.remove(s);
}

/// Null for Match Windows.
pub fn themeName(self: *const ShellSettings) ?[]const u8 {
    const name = self.registry.get(self.theme).choice;
    return if (std.mem.eql(u8, name, match_windows)) null else name;
}

pub fn frameStats(self: *const ShellSettings) Settings.FrameStats {
    return .{
        .window_seconds = @floatCast(self.registry.get(self.frame_window).number),
        .hitch_factor = @floatCast(self.registry.get(self.frame_hitch).number),
    };
}

/// The workbench's command keys as picked.
pub fn workbenchKeys(self: *const ShellSettings) WorkbenchKeys {
    var keys: WorkbenchKeys = .{};
    inline for (key_names, 0..) |field, i| {
        if (self.registry.get(self.workbench_keys[i]).key) |k| @field(keys, field) = k;
    }
    return keys;
}

/// `copy_address` as "Copy address".
fn humanName(buf: []u8, comptime field: []const u8) []const u8 {
    const n = @min(field.len, buf.len);
    for (field[0..n], buf[0..n], 0..) |ch, *out, i| out.* = if (ch == '_') ' ' else if (i == 0) std.ascii.toUpper(ch) else ch;
    return buf[0..n];
}

fn themeChanged(ctx: *anyopaque, _: *Registry.Setting) void {
    const shell: *Shell = @ptrCast(@alignCast(ctx));
    shell.applyThemeSetting();
}

fn developerModeChanged(ctx: *anyopaque, s: *Registry.Setting) void {
    const shell: *Shell = @ptrCast(@alignCast(ctx));
    shell.applyDeveloperMode(shell.registry.get(s).toggle) catch |err| std.log.scoped(.wraith_ui).warn("Couldn't change developer mode: {t}", .{err});
}

fn frameStatsChanged(ctx: *anyopaque, _: *Registry.Setting) void {
    const shell: *Shell = @ptrCast(@alignCast(ctx));
    shell.applyFrameSettings(shell.own.frameStats());
}

fn overlayGamepadChanged(ctx: *anyopaque, s: *Registry.Setting) void {
    const shell: *Shell = @ptrCast(@alignCast(ctx));
    shell.overlay.ui_takes_gamepad.store(shell.registry.get(s).toggle, .release);
}

fn workbenchKeyChanged(ctx: *anyopaque, _: *Registry.Setting) void {
    const shell: *Shell = @ptrCast(@alignCast(ctx));
    @import("../workbench/keys.zig").apply(shell.own.workbenchKeys());
}

test "human names" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Copy address", humanName(&buf, "copy_address"));
}
