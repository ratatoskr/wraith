//! The Wraith overlay. The overlay key brings up a menu along the top and a window in the middle,
//! over the dimmed game. Plugin windows still work while it's up. Render thread.

const Hub = @This();

const std = @import("std");

const ui = @import("wraith_ui");

const MenuItems = @import("../MenuItems.zig");
const icons = @import("../fonts.zig").icons;
const Dim = @import("Dim.zig");
const Shell = @import("Shell.zig");
const SettingsPage = @import("SettingsPage.zig");
const AboutPage = @import("AboutPage.zig");
const ModsPage = @import("ModsPage.zig");
const TweaksPage = @import("TweaksPage.zig");
const ui_area = @import("../../host/ui_area.zig");

const c = ui.c;

open: bool = false,
dim: Dim = .{},
page: Page = .home,
settings: SettingsPage = .{},
about: AboutPage = .{},
mods: ModsPage = .{},
tweaks: TweaksPage = .{},

pub const Page = enum { home, mods, tweaks, settings, about };

const tile_size = 120;
/// Unscaled, like the tile.
const icon_size = 44;

/// Settings' page size, unscaled.
const settings_size: ui.Vec2 = .{ 720, 560 };
/// The same whichever part's showing, so it doesn't jump about.
const about_size: ui.Vec2 = .{ 680, 520 };
const mods_size: ui.Vec2 = .{ 880, 600 };
const tweaks_size: ui.Vec2 = .{ 820, 600 };

const Tile = struct {
    label: [:0]const u8,
    icon: []const u8,
    /// Null till it has one.
    page: ?Page = null,
};

const tiles = [_]Tile{
    .{ .label = "Mods", .icon = icons.puzzle, .page = .mods },
    .{ .label = "Tweaks", .icon = icons.sliders_horizontal, .page = .tweaks },
    .{ .label = "Settings", .icon = icons.settings, .page = .settings },
    .{ .label = "About", .icon = icons.info, .page = .about },
};

/// Back to the tiles each time it opens.
pub fn toggle(self: *Hub) void {
    self.open = !self.open;
    self.page = .home;
}

pub fn show(self: *Hub, shell: *Shell, page: Page) void {
    if (page == .settings) self.settings.open(shell);
    if (page == .mods) self.mods.open(shell);
    if (page == .tweaks) self.tweaks.open();
    if (page == .about) self.about.section = .about;
    self.page = page;
}

pub fn draw(self: *Hub, shell: *Shell) void {
    const fade = self.dim.update(shell.overlay, self.open, .behind, "##wraith.hub_dim");
    if (!self.open) return;
    // Unless it's for a menu, popup, text box or a key being picked. A page goes back to the tiles
    const io = ui.getIO();
    const in_popup = ui.raw("ImGui_IsPopupOpen")(null, c.ImGuiPopupFlags_AnyPopupId);
    if (ui.isKeyPressed(.escape, false) and !io.WantTextInput and !in_popup and !ui.listeningForKeys()) {
        if (self.page == .home) {
            self.open = false;
            return;
        }
        self.page = .home;
    }
    ui.raw("ImGui_PushStyleVar")(c.ImGuiStyleVar_Alpha, fade);
    defer ui.raw("ImGui_PopStyleVar")();
    self.drawMenuBar(shell);
    self.drawWindow(shell);
}

pub fn deinit(self: *Hub, shell: *Shell) void {
    self.dim.release(shell.overlay);
    self.settings.deinit();
    self.mods.deinit(shell.options.io);
    self.tweaks.deinit(shell.allocator);
}

fn drawMenuBar(self: *Hub, shell: *Shell) void {
    const bar = ui.mainMenuBar() orelse return;
    defer bar.end();
    if (ui.menu("Wraith")) |menu| {
        defer menu.end();
        var key_buf: [64]u8 = undefined;
        const key: ?[:0]const u8 = if (shell.overlayKey()) |k| std.fmt.bufPrintSentinel(&key_buf, "{f}", .{k}, 0) catch null else null;
        if (ui.menuItem(icons.settings ++ "  Settings", .{})) self.show(shell, .settings);
        ui.separator();
        if (ui.menuItem("Close", .{ .shortcut = key })) self.open = false;
    }
    if (ui.menu("Plugins")) |menu| {
        defer menu.end();
        self.drawPluginsMenu(shell);
    }
    if (ui.menu("Tweaks")) |menu| {
        defer menu.end();
        if (self.tweaks.drawMenu(shell)) self.show(shell, .tweaks);
    }
    pluginMenus(shell.developerMode());
    if (shell.developerMode()) if (ui.menu("Developer")) |menu| {
        defer menu.end();
        var key_buf: [64]u8 = undefined;
        const key: ?[:0]const u8 = if (shell.workbenchKey()) |k| std.fmt.bufPrintSentinel(&key_buf, "{f}", .{k}, 0) catch null else null;
        var workbench_open = shell.workbench.isOpen();
        if (ui.menuItem("Workbench", .{ .shortcut = key, .checked = &workbench_open })) shell.toggleWorkbench();
    };
}

/// Manage, then every plugin that's on. Picking one opens its settings, like its cog on the Mods page.
fn drawPluginsMenu(self: *Hub, shell: *Shell) void {
    if (ui.menuItem(icons.puzzle ++ "  Manage", .{})) self.show(shell, .mods);
    ui.separator();
    // The Mods page's copy of the list, since it's too big for the stack
    self.mods.snapshot(shell);
    const plugins = self.mods.plugins[0..self.mods.plugins_len];
    var order: [ModsPage.max_plugins]usize = undefined;
    var n: usize = 0;
    for (plugins, 0..) |*p, i| {
        if (p.state != .loaded) continue;
        order[n] = i;
        n += 1;
    }
    std.mem.sort(usize, order[0..n], plugins, struct {
        fn lessThan(list: @TypeOf(plugins), a: usize, b: usize) bool {
            return std.ascii.lessThanIgnoreCase(titleOf(&list[a]), titleOf(&list[b]));
        }
    }.lessThan);
    if (n == 0) ui.textDisabled("None are on", .{});
    for (order[0..n]) |i| {
        const p = &plugins[i];
        const scope = ui.id(i);
        defer scope.end();
        var buf: [96]u8 = undefined;
        const label = std.fmt.bufPrintSentinel(&buf, "{s}", .{titleOf(p)}, 0) catch continue;
        const has = ui_area.hasSettings(p.name.get());
        if (ui.menuItem(label, .{ .enabled = has })) _ = ui_area.openSettings(p.name.get());
        if (!has) ui.tooltip("It has no settings", .{});
    }
}

fn titleOf(p: *const @import("../../PluginLoader.zig").Info) []const u8 {
    return if (p.about.title.len() > 0) p.about.title.get() else p.name.get();
}

/// One window in the middle, the tiles or a page.
fn drawWindow(self: *Hub, shell: *Shell) void {
    const viewport = ui.raw("ImGui_GetMainViewport")();
    const centre: c.ImVec2 = .{ .x = viewport.*.WorkPos.x + viewport.*.WorkSize.x / 2, .y = viewport.*.WorkPos.y + viewport.*.WorkSize.y / 2 };
    ui.raw("ImGui_SetNextWindowViewport")(viewport.*.ID);
    ui.raw("ImGui_SetNextWindowPosEx")(centre, c.ImGuiCond_Always, .{ .x = 0.5, .y = 0.5 });
    const home = self.page == .home;
    const title: [:0]const u8 = switch (self.page) {
        .home => "Wraith###wraith.hub",
        .mods => "Wraith Mods###wraith.hub",
        .tweaks => "Wraith Tweaks###wraith.hub",
        .settings => "Wraith Settings###wraith.hub",
        .about => "About Wraith###wraith.hub",
    };
    const win = ui.window(title, .{
        .size = switch (self.page) {
            .home => null,
            .mods => mods_size,
            .tweaks => tweaks_size,
            .settings => settings_size,
            .about => about_size,
        },
        .size_cond = .always,
        .flags = .{
            .no_resize = true,
            .no_move = true,
            .no_collapse = true,
            .always_auto_resize = home,
            .no_saved_settings = true,
            .no_docking = true,
        },
    }) orelse return;
    defer win.end();
    switch (self.page) {
        .home => for (tiles, 0..) |t, i| {
            if (i > 0) ui.sameLine();
            if (tile(t)) if (t.page) |p| self.show(shell, p);
            if (t.page == null) ui.tooltip("Coming soon", .{});
        },
        .settings => switch (self.settings.draw(shell)) {
            .stay => {},
            .back => self.page = .home,
            .welcome => {
                self.open = false;
                shell.showWelcome();
            },
        },
        .mods => if (self.mods.draw(shell)) {
            self.page = .home;
        },
        .tweaks => if (self.tweaks.draw(shell)) {
            self.page = .home;
        },
        .about => if (self.about.draw()) {
            self.page = .home;
        },
    }
}

/// A big button with an icon over its label. True when clicked.
fn tile(t: Tile) bool {
    const size = ui.scaled(tile_size);
    const at = ui.getCursorScreenPos();
    const clicked = ui.invisibleButton(t.label, .{ size, size });
    const colour: c.ImGuiCol = if (ui.isItemActive()) c.ImGuiCol_ButtonActive else if (ui.isItemHovered()) c.ImGuiCol_ButtonHovered else c.ImGuiCol_Button;
    const list = ui.getWindowDrawList();
    const rounding = ui.raw("ImGui_GetStyle")().*.FrameRounding * 2;
    ui.raw("ImDrawList_AddRectFilledEx")(list.ptr, vec(at[0], at[1]), vec(at[0] + size, at[1] + size), ui.raw("ImGui_GetColorU32")(colour), rounding, 0);

    const ink = ui.raw("ImGui_GetColorU32")(c.ImGuiCol_Text);
    {
        // Null keeps the font, just bigger
        ui.raw("ImGui_PushFontFloat")(null, icon_size);
        defer ui.raw("ImGui_PopFont")();
        const box = ui.calcTextSize(t.icon);
        list.addText(.{ at[0] + (size - box[0]) / 2, at[1] + size * 0.42 - box[1] / 2 }, ink, t.icon);
    }
    const text = ui.calcTextSize(t.label);
    list.addText(.{ at[0] + (size - text[0]) / 2, at[1] + size * 0.78 - text[1] / 2 }, ink, t.label);
    return clicked;
}

fn vec(x: f32, y: f32) c.ImVec2 {
    return .{ .x = x, .y = y };
}

/// A menu per plugin, under its name, in the order they added their first item. Dev items only in
/// developer mode. Holds `MenuItems` only while drawing them, since closing owners wait on it.
fn pluginMenus(dev_mode: bool) void {
    const items = MenuItems.read();
    defer items.end();
    const all = items.entries;
    for (all, 0..) |e, i| {
        if (e.item.dev and !dev_mode) continue;
        const seen = for (all[0..i]) |before| {
            if (before.owner == e.owner and (!before.item.dev or dev_mode)) break true;
        } else false;
        if (seen) continue;
        const scope = ui.id(e.owner);
        defer scope.end();
        var buf: [96]u8 = undefined;
        const name = if (e.item.menu.len > 0) e.item.menu else e.owner.name;
        const label = std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch continue;
        const menu = ui.menu(label) orelse continue;
        defer menu.end();
        for (all[i..]) |item| {
            if (item.owner != e.owner or (item.item.dev and !dev_mode)) continue;
            const item_scope = ui.id(item.item);
            defer item_scope.end();
            var item_buf: [128]u8 = undefined;
            const item_label = std.fmt.bufPrintSentinel(&item_buf, "{s}", .{item.item.label}, 0) catch continue;
            _ = ui.menuItem(item_label, .{ .checked = item.item.open });
        }
    }
}
