//! The overlay's settings page, from the hub. Built from the registry, so Wraith's settings,
//! plugins' and every key bound on the game show up the same way. Changes wait for Save, like
//! Dalamud's. Render thread.

const SettingsPage = @This();

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

allocator: std.mem.Allocator = std.heap.page_allocator,
/// What's registered, refreshed when the registry changes.
settings: []*Setting = &.{},
seen_changes: u32 = std.math.maxInt(u32),
/// Edits waiting for Save.
pending: std.ArrayList(Pending) = .empty,
search: [128]u8 = @splat(0),
/// Something saved only takes effect next start.
restart_pending: bool = false,
/// Keys on more than one thing, refreshed when the keys change.
clashes: []Keybinds.Clash = &.{},
seen_keys: u32 = std.math.maxInt(u32),

pub const Result = enum { stay, back, welcome };

const Pending = struct {
    setting: *Setting,
    value: Registry.Value,
    /// Text values point here.
    text: [256]u8 = undefined,
};

/// Wraith's settings by section, all the game's keys, or plugins'.
const Tab = union(enum) {
    section: []const u8,
    keybinds,
    plugins,
};

/// Only shown in developer mode.
const developer_sections = [_][]const u8{ "Workbench", "Frame stats" };
const footer_height = 36;

/// Starts editing what's in effect now.
pub fn open(self: *SettingsPage, shell: *Shell) void {
    self.allocator = shell.allocator;
    self.pending.clearRetainingCapacity();
    self.search = @splat(0);
    self.seen_changes = std.math.maxInt(u32);
    self.seen_keys = std.math.maxInt(u32);
    self.refresh(shell);
    shell.dev_plugins.refresh(shell);
}

pub fn deinit(self: *SettingsPage) void {
    if (self.settings.len > 0) self.allocator.free(self.settings);
    if (self.clashes.len > 0) Keybinds.freeClashes(self.allocator, self.clashes);
    self.pending.deinit(self.allocator);
    self.* = .{};
}

fn refresh(self: *SettingsPage, shell: *Shell) void {
    const now = shell.registry.changes.load(.acquire);
    if (now != self.seen_changes) {
        if (shell.registry.list(self.allocator)) |list| {
            if (self.settings.len > 0) self.allocator.free(self.settings);
            self.settings = list;
            self.seen_changes = now;
        } else |_| {}
        // Edits to ones that went away
        var i: usize = 0;
        while (i < self.pending.items.len) {
            if (self.pending.items[i].setting.removed) _ = self.pending.orderedRemove(i) else i += 1;
        }
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

pub fn draw(self: *SettingsPage, shell: *Shell) Result {
    self.refresh(shell);
    if (ui.iconButton(icons.arrow_left ++ "##back", "Back, without saving")) return .back;
    ui.sameLine();
    ui.setNextItemWidthPixels(-1);
    _ = ui.inputTextHint("##search", icons.search ++ "  Search settings", &self.search);
    const query = std.mem.sliceTo(&self.search, 0);

    var result: Result = .stay;
    if (ui.child("##settings", .{ 0, -ui.scaled(footer_height) }, .{})) |body| {
        defer body.end();
        if (query.len > 0) {
            self.drawFound(shell, query);
        } else if (ui.tabBar("##tabs")) |bar| {
            defer bar.end();
            var found: [16]Tab = undefined;
            for (self.tabs(shell, &found)) |tab| {
                var label_buf: [64]u8 = undefined;
                const label: [:0]const u8 = switch (tab) {
                    .section => |s| if (s.len == 0) "General" else std.fmt.bufPrintSentinel(&label_buf, "{s}", .{s}, 0) catch "?",
                    .keybinds => "Keybinds",
                    .plugins => "Plugins",
                };
                const item = ui.tabItem(label, .{}) orelse continue;
                defer item.end();
                if (self.drawTab(shell, tab)) result = .welcome;
            }
        }
    }
    if (self.drawFooter(shell)) result = .back;
    return result;
}

/// General first, then Wraith's sections in the order they were added, then keys and plugins.
fn tabs(self: *SettingsPage, shell: *Shell, out: []Tab) []Tab {
    var n: usize = 0;
    out[n] = .{ .section = "" };
    n += 1;
    var plugins = false;
    for (self.settings) |s| {
        if (s.def.hidden) continue;
        if (!isWraith(s)) {
            if (!isGameKey(s)) plugins = true;
            continue;
        }
        if (!shell.developerMode() and isDeveloperSection(s.def.section)) continue;
        const known = for (out[0..n]) |t| {
            if (t == .section and std.mem.eql(u8, t.section, s.def.section)) break true;
        } else false;
        if (!known and n < out.len - 2) {
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
    return out[0..n];
}

fn isDeveloperSection(section: []const u8) bool {
    for (developer_sections) |d| if (std.mem.eql(u8, d, section)) return true;
    return false;
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
fn drawTab(self: *SettingsPage, shell: *Shell, tab: Tab) bool {
    switch (tab) {
        .section => |section| {
            for (self.settings) |s| {
                if (s.def.hidden or !isWraith(s) or !std.mem.eql(u8, s.def.section, section)) continue;
                self.row(shell, s);
            }
            if (std.mem.eql(u8, section, "Developer") and shell.developerMode()) drawDevPlugins(shell);
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
fn grouped(self: *SettingsPage, shell: *Shell, keys: bool) void {
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

fn drawFound(self: *SettingsPage, shell: *Shell, query: []const u8) void {
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

/// What it'll be on Save, so the edit if there is one.
fn valueOf(self: *SettingsPage, shell: *Shell, s: *Setting) Registry.Value {
    if (self.pendingFor(s)) |p| return p.value;
    return shell.registry.get(s);
}

fn pendingFor(self: *SettingsPage, s: *const Setting) ?*Pending {
    for (self.pending.items) |*p| if (p.setting == s) return p;
    return null;
}

/// An edit to save, or none if it's back to what's in effect.
fn stage(self: *SettingsPage, shell: *Shell, s: *Setting, v: Registry.Value) void {
    const same = v.eql(shell.registry.get(s));
    for (self.pending.items, 0..) |*p, i| if (p.setting == s) {
        if (same) _ = self.pending.orderedRemove(i) else p.value = self.ownText(p, v);
        return;
    };
    if (same) return;
    self.pending.append(self.allocator, .{ .setting = s, .value = v }) catch return;
    const p = &self.pending.items[self.pending.items.len - 1];
    p.value = self.ownText(p, v);
}

/// Text points into the edit, since what it came from goes away.
fn ownText(_: *SettingsPage, p: *Pending, v: Registry.Value) Registry.Value {
    if (v != .text) return v;
    const n = @min(v.text.len, p.text.len);
    std.mem.copyForwards(u8, p.text[0..n], v.text[0..n]);
    return .{ .text = p.text[0..n] };
}

fn row(self: *SettingsPage, shell: *Shell, s: *Setting) void {
    const scope = ui.id(s);
    defer scope.end();
    const v = self.valueOf(shell, s);
    ui.spacing();
    var name_buf: [128]u8 = undefined;
    const name = std.fmt.bufPrintSentinel(&name_buf, "{s}", .{s.def.name}, 0) catch "?";
    switch (s.def.kind) {
        .toggle => {
            var on = v.toggle;
            const bold = ui.bold();
            defer bold.end();
            if (ui.checkbox(name, &on)) self.stage(shell, s, .{ .toggle = on });
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
        if (ui.iconButton(icons.rotate_ccw ++ "##reset", "Back to its default")) self.stage(shell, s, Registry.defaultOf(s.def.kind));
    }
    switch (s.def.kind) {
        .toggle => {},
        .number => |n| {
            var x: f32 = @floatCast(v.number);
            ui.setNextItemWidth(240);
            const format: [:0]const u8 = if (n.step >= 1) "%.0f" else "%.2f";
            if (ui.raw("ImGui_SliderFloatEx")(@ptrCast("##value"), &x, @floatCast(n.min), @floatCast(n.max), @ptrCast(format.ptr), 0)) self.stage(shell, s, .{ .number = x });
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
            if (ui.combo("##value", &index, names[0..count])) self.stage(shell, s, .{ .choice = ch.options[index] });
        },
        .text => {
            var buf: [256]u8 = @splat(0);
            const n = @min(v.text.len, buf.len - 1);
            @memcpy(buf[0..n], v.text[0..n]);
            ui.setNextItemWidth(320);
            if (ui.inputText("##value", &buf)) self.stage(shell, s, .{ .text = std.mem.sliceTo(&buf, 0) });
        },
        .colour => {
            var colour = v.colour;
            if (ui.raw("ImGui_ColorEdit4")(@ptrCast("##value"), @ptrCast(&colour), 0)) self.stage(shell, s, .{ .colour = colour });
        },
        .key => self.keyRow(shell, s, v.key),
    }
    helpText(s.def.help, s.def.restart, s.def.scope);
}

fn keyRow(self: *SettingsPage, shell: *Shell, s: *Setting, current: ?Chord) void {
    var picked = current;
    ui.setNextItemWidth(200);
    if (ui.chordInput("##key", &picked, .{ .none = "No key" })) self.stage(shell, s, .{ .key = picked });
    if (current != null) {
        ui.sameLine();
        if (ui.iconButton(icons.x ++ "##clear", "No key")) self.stage(shell, s, .{ .key = null });
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

/// True to go back.
fn drawFooter(self: *SettingsPage, shell: *Shell) bool {
    ui.separator();
    if (self.restart_pending) {
        ui.textColored(.{ 1, 0.8, 0.3, 1 }, "{s}  Some changes take effect next time the game starts.", .{icons.triangle_alert});
        ui.sameLine();
    }
    const style = ui.raw("ImGui_GetStyle")();
    const pad = style.*.FramePadding.x * 2;
    const close_w = @max(ui.frameHeight(), ui.calcTextSize(icons.x)[0] + pad);
    const save_w = ui.calcTextSize(icons.save ++ "  Save")[0] + pad;
    // Right-aligned, after the note if there is one
    const free = ui.getContentRegionAvailPixels()[0] - close_w - save_w - style.*.ItemSpacing.x;
    if (free > 0) ui.raw("ImGui_SetCursorPosX")(ui.raw("ImGui_GetCursorPosX")() + free);
    const back = ui.iconButton(icons.x ++ "##close", "Close, without saving");
    ui.sameLine();
    {
        const off = ui.disabled(self.pending.items.len == 0);
        defer off.end();
        if (ui.button(icons.save ++ "  Save")) self.save(shell);
    }
    return back;
}

/// Each change goes to the registry, which saves it and applies it.
pub fn save(self: *SettingsPage, shell: *Shell) void {
    // Developer mode first, since the workbench's key is only there in it
    for ([_]bool{ true, false }) |developer_pass| for (self.pending.items) |p| {
        const is_dev = std.mem.eql(u8, p.setting.def.id, "wraith.developer_mode");
        if (is_dev != developer_pass) continue;
        shell.registry.set(p.setting, p.value) catch |err| {
            log.warn("Couldn't save {s}: {t}", .{ p.setting.def.id, err });
            continue;
        };
        if (p.setting.def.restart) self.restart_pending = true;
    };
    self.pending.clearRetainingCapacity();
}

/// As if picked on the page, for tests.
pub fn edit(self: *SettingsPage, shell: *Shell, id: []const u8, v: Registry.Value) !void {
    const s = shell.registry.find(id) orelse return error.NoSuchSetting;
    self.stage(shell, s, v);
}

pub fn hasEdits(self: *const SettingsPage) bool {
    return self.pending.items.len > 0;
}
