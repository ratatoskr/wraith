//! The overlay's settings window. Built from the registry, so Wraith's settings, plugins' and
//! every key bound on the game show up the same way. Changes take effect as you make them, and
//! drags and typing get saved once they're done. Render thread.

const SettingsWindow = @This();

const std = @import("std");

const core = @import("wraith_core");
const ui = @import("wraith_ui");
const Chord = @import("wraith_platform").input.Chord;
const Keybinds = @import("tuft_input").Keybinds;
const tuft_window = @import("tuft_window");

const icons = @import("../fonts.zig").icons;
const Settings = @import("../../Settings.zig");
const Registry = Settings.Registry;
const Setting = Registry.Setting;
const Shell = @import("Shell.zig");
const Workbench = @import("../workbench/Workbench.zig");

const c = ui.c;
const log = core.log.scoped(.wraith_ui);

window: ui.Window = .{ .title = "Wraith Settings###wraith.settings", .size = .{ 720, 560 } },
shell: *Shell = undefined,
allocator: std.mem.Allocator = std.heap.page_allocator,
/// What's registered, refreshed when the registry changes.
settings: []*Setting = &.{},
seen_changes: u32 = std.math.maxInt(u32),
search: [128]u8 = @splat(0),
/// Something changed only takes effect next start.
restart_pending: bool = false,
/// Keys on more than one thing, refreshed when the keys change.
clashes: []Keybinds.Clash = &.{},
seen_keys: u32 = std.math.maxInt(u32),

/// Wraith's settings by section, all the game's keys, or plugins'.
const Tab = union(enum) {
    section: []const u8,
    keybinds,
    plugins,
};

/// Fresh, each time it's opened.
pub fn onOpen(self: *SettingsWindow) void {
    const shell = self.shell;
    self.allocator = shell.allocator;
    self.search = @splat(0);
    self.seen_changes = std.math.maxInt(u32);
    self.seen_keys = std.math.maxInt(u32);
    self.refresh(shell);
    shell.dev_plugins.refresh(shell);
}

pub fn deinit(self: *SettingsWindow) void {
    if (self.settings.len > 0) self.allocator.free(self.settings);
    if (self.clashes.len > 0) Keybinds.freeClashes(self.allocator, self.clashes);
    self.* = .{};
}

fn refresh(self: *SettingsWindow, shell: *Shell) void {
    const now = shell.registry.changes.load(.acquire);
    if (now != self.seen_changes) {
        if (shell.registry.list(self.allocator)) |list| {
            if (self.settings.len > 0) self.allocator.free(self.settings);
            self.settings = list;
            self.seen_changes = now;
        } else |_| {}
    }
    const keys = shell.keybinds.changes.load(.acquire);
    if (keys != self.seen_keys) {
        if (shell.keybinds.clashesAlloc(self.allocator)) |found| {
            if (self.clashes.len > 0) Keybinds.freeClashes(self.allocator, self.clashes);
            self.clashes = found;
            self.seen_keys = keys;
        } else |_| {}
    }
}

pub fn draw(self: *SettingsWindow) void {
    const shell = self.shell;
    self.refresh(shell);
    ui.setNextItemWidthPixels(-1);
    _ = ui.inputTextHint("##search", icons.search ++ "  Search settings", &self.search);
    const query = std.mem.sliceTo(&self.search, 0);

    var welcome = false;
    if (self.restart_pending) ui.textColored(.{ 1, 0.8, 0.3, 1 }, "{s}  Some changes take effect next time the game starts.", .{icons.triangle_alert});
    if (ui.child("##settings", .{ 0, 0 }, .{})) |body| {
        defer body.end();
        if (query.len > 0) {
            self.drawFound(shell, query);
        } else if (ui.tabBar("##tabs")) |bar| {
            defer bar.end();
            var found: [16]Tab = undefined;
            for (self.tabs(&found)) |tab| {
                var label_buf: [64]u8 = undefined;
                const label: [:0]const u8 = switch (tab) {
                    .section => |s| if (s.len == 0) "General" else std.fmt.bufPrintSentinel(&label_buf, "{s}", .{s}, 0) catch "?",
                    .keybinds => "Keybinds",
                    .plugins => "Plugins",
                };
                const item = ui.tabItem(label, .{}) orelse continue;
                defer item.end();
                if (self.drawTab(shell, tab)) welcome = true;
            }
        }
    }
    if (welcome) shell.showWelcome();
}

/// General first, then Wraith's sections in the order they were added, then keys and plugins.
/// `last_sections` go at the end, in that order.
fn tabs(self: *SettingsWindow, out: []Tab) []Tab {
    var n: usize = 0;
    out[n] = .{ .section = "" };
    n += 1;
    var plugins = false;
    var last: [last_sections.len]bool = @splat(false);
    for (self.settings) |s| {
        if (s.def.hidden) continue;
        if (!isWraith(s)) {
            if (!isGameKey(s)) plugins = true;
            continue;
        }
        if (lastIndex(s.def.section)) |i| {
            last[i] = true;
            continue;
        }
        const known = for (out[0..n]) |t| {
            if (t == .section and std.mem.eql(u8, t.section, s.def.section)) break true;
        } else false;
        if (!known and n < out.len - 2 - last_sections.len) {
            out[n] = .{ .section = s.def.section };
            n += 1;
        }
    }
    out[n] = .keybinds;
    n += 1;
    if (plugins) {
        out[n] = .plugins;
        n += 1;
    }
    for (last_sections, last) |section, any| if (any) {
        out[n] = .{ .section = section };
        n += 1;
    };
    return out[0..n];
}

/// On the far right, after everything else.
const last_sections = [_][]const u8{ "Advanced", "Developer" };

fn lastIndex(section: []const u8) ?usize {
    for (last_sections, 0..) |l, i| if (std.mem.eql(u8, l, section)) return i;
    return null;
}

fn isWraith(s: *const Setting) bool {
    return std.mem.eql(u8, s.def.group, Settings.group);
}

fn isGameKey(s: *const Setting) bool {
    return switch (s.def.kind) {
        .key => |k| k.in_game,
        else => false,
    };
}

/// True if it asked for the welcome.
fn drawTab(self: *SettingsWindow, shell: *Shell, tab: Tab) bool {
    switch (tab) {
        .section => |section| {
            for (self.settings) |s| {
                if (s.def.hidden or !isWraith(s) or !std.mem.eql(u8, s.def.section, section)) continue;
                self.row(shell, s);
            }
            if (std.mem.eql(u8, section, "Developer")) drawDevPlugins(shell);
            if (section.len != 0) return false;
            ui.spacing();
            {
                const bold = ui.bold();
                defer bold.end();
                ui.text("Welcome", .{});
            }
            const welcome = ui.button("Show the welcome");
            helpText("Go through the first-run welcome again.", false, .global);
            return welcome;
        },
        .keybinds => self.grouped(shell, true),
        .plugins => self.grouped(shell, false),
    }
    return false;
}

/// Under a heading per owner, Wraith first. Keys from everyone, or plugins' other settings.
fn grouped(self: *SettingsWindow, shell: *Shell, keys: bool) void {
    var last: []const u8 = "";
    var any = false;
    for ([_]bool{ true, false }) |wraith_pass| for (self.settings) |s| {
        if (s.def.hidden or isGameKey(s) != keys or isWraith(s) != wraith_pass) continue;
        if (!keys and isWraith(s)) continue;
        if (!std.mem.eql(u8, last, s.def.group)) {
            last = s.def.group;
            var buf: [96]u8 = undefined;
            ui.separatorText(std.fmt.bufPrintSentinel(&buf, "{s}", .{s.def.group}, 0) catch "?");
        }
        any = true;
        self.row(shell, s);
    };
    if (!any) ui.textDisabled("{s}", .{if (keys) "No keys yet" else "No plugin settings yet"});
}

fn drawFound(self: *SettingsWindow, shell: *Shell, query: []const u8) void {
    var any = false;
    for (self.settings) |s| {
        if (s.def.hidden) continue;
        const hit = std.ascii.findIgnoreCase(s.def.name, query) != null or
            std.ascii.findIgnoreCase(s.def.help, query) != null or
            std.ascii.findIgnoreCase(s.def.group, query) != null or
            std.ascii.findIgnoreCase(s.def.section, query) != null;
        if (!hit) continue;
        any = true;
        self.row(shell, s);
    }
    if (!any) ui.textDisabled("Nothing matches", .{});
}

/// Takes effect now. Saved too, unless it's mid-drag or mid-typing.
fn apply(self: *SettingsWindow, shell: *Shell, s: *Setting, v: Registry.Value, save: bool) void {
    const was = shell.registry.get(s);
    shell.registry.setWith(s, v, .{ .save = save }) catch |err| return log.warn("Couldn't change {s}: {t}", .{ s.def.id, err });
    if (s.def.restart and !was.eql(shell.registry.get(s))) self.restart_pending = true;
}

/// Once a drag or typing's done, so it's written.
fn finish(self: *SettingsWindow, shell: *Shell, s: *Setting) void {
    if (ui.isItemDeactivated()) self.apply(shell, s, shell.registry.get(s), true);
}

fn row(self: *SettingsWindow, shell: *Shell, s: *Setting) void {
    const scope = ui.id(s);
    defer scope.end();
    const v = shell.registry.get(s);
    ui.spacing();
    var name_buf: [128]u8 = undefined;
    const name = std.fmt.bufPrintSentinel(&name_buf, "{s}", .{s.def.name}, 0) catch "?";
    switch (s.def.kind) {
        .toggle => {
            var on = v.toggle;
            const bold = ui.bold();
            defer bold.end();
            if (ui.checkbox(name, &on)) self.apply(shell, s, .{ .toggle = on }, true);
        },
        else => {
            const bold = ui.bold();
            defer bold.end();
            ui.alignTextToFramePadding();
            ui.text("{s}", .{name});
        },
    }
    if (!v.eql(Registry.defaultOf(s.def.kind))) {
        ui.sameLine();
        if (ui.iconButton(icons.rotate_ccw ++ "##reset", "Back to its default")) self.apply(shell, s, Registry.defaultOf(s.def.kind), true);
    }
    switch (s.def.kind) {
        .toggle => {},
        .number => |n| {
            var x: f32 = @floatCast(v.number);
            ui.setNextItemWidth(240);
            const format: [:0]const u8 = if (n.step >= 1) "%.0f" else "%.2f";
            if (ui.raw("ImGui_SliderFloatEx")(@ptrCast("##value"), &x, @floatCast(n.min), @floatCast(n.max), @ptrCast(format.ptr), 0)) self.apply(shell, s, .{ .number = x }, false);
            self.finish(shell, s);
        },
        .choice => |ch| {
            var names: [64][:0]const u8 = undefined;
            var bufs: [64][64]u8 = undefined;
            const count = @min(ch.options.len, names.len);
            var index: usize = count;
            for (ch.options[0..count], 0..) |o, i| {
                names[i] = std.fmt.bufPrintSentinel(&bufs[i], "{s}", .{o}, 0) catch "?";
                if (std.mem.eql(u8, o, v.choice)) index = i;
            }
            ui.setNextItemWidth(240);
            if (ui.combo("##value", &index, names[0..count])) self.apply(shell, s, .{ .choice = ch.options[index] }, true);
        },
        .text => {
            var buf: [256]u8 = @splat(0);
            const n = @min(v.text.len, buf.len - 1);
            @memcpy(buf[0..n], v.text[0..n]);
            ui.setNextItemWidth(320);
            if (ui.inputText("##value", &buf)) self.apply(shell, s, .{ .text = std.mem.sliceTo(&buf, 0) }, false);
            self.finish(shell, s);
        },
        .colour => {
            var colour = v.colour;
            if (ui.raw("ImGui_ColorEdit4")(@ptrCast("##value"), @ptrCast(&colour), 0)) self.apply(shell, s, .{ .colour = colour }, false);
            self.finish(shell, s);
        },
        .key => self.keyRow(shell, s, v.key),
    }
    helpText(s.def.help, s.def.restart, s.def.scope);
}

fn keyRow(self: *SettingsWindow, shell: *Shell, s: *Setting, current: ?Chord) void {
    var picked = current;
    ui.setNextItemWidth(200);
    if (ui.chordInput("##key", &picked, .{ .none = "No key" })) self.apply(shell, s, .{ .key = picked }, true);
    if (current != null) {
        ui.sameLine();
        if (ui.iconButton(icons.x ++ "##clear", "No key")) self.apply(shell, s, .{ .key = null }, true);
    }
    // Who else is on it, as it's bound now
    for (self.clashes) |clash| {
        const mine = for (clash.ids) |id| {
            if (std.mem.eql(u8, id, s.def.id)) break true;
        } else false;
        if (!mine) continue;
        var text_buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&text_buf);
        w.writeAll(icons.triangle_alert ++ "  Also on this key: ") catch {};
        var first = true;
        for (clash.ids) |id| {
            if (std.mem.eql(u8, id, s.def.id)) continue;
            const sep = if (first) "" else ", ";
            first = false;
            if (shell.registry.find(id)) |other| {
                w.print("{s}{s}: {s}", .{ sep, other.def.group, other.def.name }) catch {};
            } else w.print("{s}{s}", .{ sep, id }) catch {};
        }
        ui.textColored(.{ 1, 0.75, 0.3, 1 }, "{s}", .{w.buffered()});
        ui.tooltip("They all go off when it's pressed", .{});
    }
}

/// Folders Wraith loads plugins from while you build them. Changes take effect right away.
fn drawDevPlugins(shell: *Shell) void {
    const io = shell.options.io orelse return;
    ui.spacing();
    {
        const bold = ui.bold();
        defer bold.end();
        ui.alignTextToFramePadding();
        ui.text("Dev plugins", .{});
    }
    var remove_buf: [512]u8 = undefined;
    var remove: ?[]const u8 = null;
    {
        const v = shell.dev_plugins.view(io);
        defer v.end();
        if (!v.loaded()) {
            ui.textDisabled("Reading the list...", .{});
        } else if (v.entries().len == 0) {
            ui.textDisabled("None yet", .{});
        }
        for (v.entries(), 0..) |e, i| {
            const scope = ui.id(i);
            defer scope.end();
            if (ui.iconButton(icons.x ++ "##remove", "Stop loading it from here")) {
                const n = @min(e.folder.len, remove_buf.len);
                @memcpy(remove_buf[0..n], e.folder[0..n]);
                remove = remove_buf[0..n];
            }
            ui.sameLine();
            ui.alignTextToFramePadding();
            if (e.id) |id| {
                ui.text("{s}", .{id});
                ui.sameLine();
                ui.textDisabled("{s}", .{e.folder});
            } else {
                ui.textColored(.{ 1, 0.75, 0.3, 1 }, "{s}  {s}", .{ icons.triangle_alert, e.folder });
                ui.tooltip("No usable wraith.json: {t}", .{e.problem orelse error.NoManifest});
            }
        }
        if (v.problem().len > 0) ui.textColored(.{ 1, 0.5, 0.5, 1 }, "{s}", .{v.problem()});
    }
    if (remove) |folder| shell.dev_plugins.remove(shell, folder);
    {
        const off = ui.disabled(shell.dev_plugins.isBusy());
        defer off.end();
        if (ui.button(icons.folder_plus ++ "  Add plugin folder")) addDevPlugin(shell);
    }
    helpText("Plugins you're building. Wraith loads them from these folders instead of installed copies. Pick a plugin's wraith.json. Changes take effect right away.", false, .global);
}

fn addDevPlugin(shell: *Shell) void {
    const picked = tuft_window.pickFile(shell.allocator, .{
        .mode = .open,
        .owner = Workbench.dialogOwner(shell.workbench),
        .alive = Workbench.dialogAlive(shell.workbench),
        .title = "Pick a plugin's wraith.json",
        .kind = "Plugin manifest",
        .extension = ".json",
        .file_name = core.manifest.file_name,
    }) catch |err| return log.warn("Couldn't show the file dialog: {t}", .{err});
    const path = picked orelse return;
    defer shell.allocator.free(path);
    const folder = std.fs.path.dirname(path) orelse return;
    shell.dev_plugins.add(shell, folder);
}

fn helpText(help: []const u8, restart: bool, scope: Registry.Scope) void {
    if (help.len == 0 and !restart and scope == .global) return;
    const dim = ui.raw("ImGui_GetStyleColorVec4")(c.ImGuiCol_TextDisabled);
    ui.raw("ImGui_PushStyleColorImVec4")(c.ImGuiCol_Text, dim.*);
    defer ui.raw("ImGui_PopStyleColor")();
    ui.textWrapped("{s}{s}{s}", .{
        help,
        if (restart) " Takes a restart." else "",
        if (scope == .game) " Just for this game." else "",
    });
}

/// As if picked in the window, for tests.
pub fn edit(self: *SettingsWindow, shell: *Shell, id: []const u8, v: Registry.Value) !void {
    const s = shell.registry.find(id) orelse return error.NoSuchSetting;
    self.apply(shell, s, v, true);
}
