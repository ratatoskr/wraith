//! The Wraith overlay's bar. The overlay key slides it in from the bottom of the screen, or the
//! top, with buttons for Wraith's windows, plugins' and the workbench. It holds the mouse and
//! keyboard while it's up. The windows are the shell's, in a `ui.WindowSystem`, so they stay up
//! till they're closed and the bar just opens and closes them. Render thread.

const Hub = @This();

const std = @import("std");

const ui = @import("wraith_ui");

const MenuItems = @import("../MenuItems.zig");
const icons = @import("../fonts.zig").icons;
const Dim = @import("Dim.zig");
const Shell = @import("Shell.zig");
const ui_area = @import("../../host/ui_area.zig");

const c = ui.c;

open: bool = false,
/// The bar's slide, and holding the input while it's up. Nothing's drawn.
dim: Dim = .{},
/// Last frame's, to slide it by.
bar_height: f32 = 0,
/// Last frame, so Escape only closes it when no window has the keys.
bar_focused: bool = false,

const Button = struct {
    /// In `Shell.Windows`.
    field: [:0]const u8,
    label: []const u8,
    icon: []const u8,
};

const buttons = [_]Button{
    .{ .field = "mods", .label = "Mods", .icon = icons.puzzle },
    .{ .field = "tweaks", .label = "Tweaks", .icon = icons.sliders_horizontal },
    .{ .field = "settings", .label = "Settings", .icon = icons.settings },
    .{ .field = "about", .label = "About", .icon = icons.info },
};

/// Unscaled. Between the dock and the edge of the screen.
const margin = 12;
/// Unscaled, a tile's square and the icon in it.
const tile_size = 56;
const icon_size = 30;
/// Under each tile, for the dot that says it's open. Unscaled.
const dot_room = 8;
/// How far a tile rises when hovered. Unscaled.
const lift = 4;

pub fn toggle(self: *Hub) void {
    self.open = !self.open;
}

pub fn draw(self: *Hub, shell: *Shell) void {
    const fade = self.dim.update(shell.overlay, self.open, .none, "##wraith.hub");
    const tweaks = &shell.windows.tweaks;
    if (!tweaks.window.open) tweaks.drawOnScreen(shell, self.open);
    if (fade == 0) return;
    // Unless a window, menu, popup, text box or a key being picked has it
    const io = ui.getIO();
    const in_popup = ui.raw("ImGui_IsPopupOpen")(null, c.ImGuiPopupFlags_AnyPopupId);
    const window_has_it = ui.raw("ImGui_IsWindowFocused")(c.ImGuiFocusedFlags_AnyWindow) and !self.bar_focused;
    if (self.open and ui.isKeyPressed(.escape, false) and !window_has_it and !io.WantTextInput and !in_popup and !ui.listeningForKeys()) self.open = false;
    ui.raw("ImGui_PushStyleVar")(c.ImGuiStyleVar_Alpha, fade);
    defer ui.raw("ImGui_PopStyleVar")();
    // Still drawn while it slides away
    self.drawBar(shell, fade);
}

pub fn deinit(self: *Hub, shell: *Shell) void {
    self.dim.release(shell.overlay);
}

fn drawBar(self: *Hub, shell: *Shell, fade: f32) void {
    const viewport = ui.raw("ImGui_GetMainViewport")();
    const top = shell.own.barAtTop();
    const eased = 1 - std.math.pow(f32, 1 - fade, 3);
    const gap = ui.scaled(margin);
    const tucked = (1 - eased) * (self.bar_height + gap);
    const x = viewport.*.WorkPos.x + viewport.*.WorkSize.x / 2;
    const y = if (top) viewport.*.WorkPos.y + gap - tucked else viewport.*.WorkPos.y + viewport.*.WorkSize.y - gap + tucked;
    ui.raw("ImGui_SetNextWindowViewport")(viewport.*.ID);
    ui.raw("ImGui_SetNextWindowPosEx")(.{ .x = x, .y = y }, c.ImGuiCond_Always, .{ .x = 0.5, .y = if (top) 0 else 1 });
    ui.raw("ImGui_SetNextWindowBgAlpha")(0.85);
    ui.raw("ImGui_PushStyleVar")(c.ImGuiStyleVar_WindowRounding, ui.scaled(18));
    ui.raw("ImGui_PushStyleVarImVec2")(c.ImGuiStyleVar_WindowPadding, .{ .x = ui.scaled(10), .y = ui.scaled(8) });
    ui.raw("ImGui_PushStyleVarImVec2")(c.ImGuiStyleVar_ItemSpacing, .{ .x = ui.scaled(6), .y = 0 });
    const win = ui.window("##wraith.bar", .{ .flags = .{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_scrollbar = true,
        .no_collapse = true,
        .always_auto_resize = true,
        .no_saved_settings = true,
        .no_docking = true,
        .no_inputs = !self.open,
    } }) orelse {
        ui.raw("ImGui_PopStyleVarEx")(3);
        return;
    };
    defer win.end();
    ui.raw("ImGui_PopStyleVarEx")(3);
    self.bar_height = ui.raw("ImGui_GetWindowSize")().y;
    self.bar_focused = ui.raw("ImGui_IsWindowFocused")(0);

    const on = tweaksOn(shell);
    inline for (buttons, 0..) |b, i| {
        if (i > 0) ui.sameLine();
        const w = &@field(shell.windows, b.field).window;
        const count = if (comptime std.mem.eql(u8, b.field, "tweaks")) on else 0;
        if (tile(b.field, b.icon, w.open, count)) w.toggle();
        ui.tooltip("{s}", .{b.label});
    }
    pluginButtons(shell);
    divider();
    if (tile("workbench", icons.square_terminal, shell.workbench.isOpen(), 0)) shell.toggleWorkbench();
    var key_buf: [64]u8 = undefined;
    if (shell.workbenchKey()) |k| {
        ui.tooltip("Workbench  {s}", .{ui.chordName(&key_buf, k)});
    } else ui.tooltip("Workbench", .{});
}

fn tweaksOn(shell: *Shell) usize {
    const tweaks = shell.tweaks orelse return 0;
    var arena: std.heap.ArenaAllocator = .init(shell.allocator);
    defer arena.deinit();
    const list = tweaks.snapshot(arena.allocator()) catch return 0;
    var n: usize = 0;
    for (list) |*t| {
        if (!t.is_group and t.on) n += 1;
    }
    return n;
}

/// A dock tile, a big icon on a rounded square that rises when hovered. A dot under it while
/// what it opens is open, and a count in its corner if there's one.
fn tile(id: [:0]const u8, icon: []const u8, lit: bool, count: usize) bool {
    const size = ui.scaled(tile_size);
    const at = ui.getCursorScreenPos();
    const clicked = ui.invisibleButton(id, .{ size, size + ui.scaled(dot_room) });
    const hovered = ui.isItemHovered();
    const held = ui.isItemActive();
    const up = if (hovered and !held) ui.scaled(lift) else 0;
    const min: ui.Vec2 = .{ at[0], at[1] - up };
    const max: ui.Vec2 = .{ at[0] + size, at[1] + size - up };
    const list = ui.getWindowDrawList();
    list.pushClipRectFullScreen();
    defer list.popClipRect();
    const fill: c.ImGuiCol = if (held) c.ImGuiCol_ButtonActive else if (hovered or lit) c.ImGuiCol_ButtonHovered else c.ImGuiCol_Button;
    ui.raw("ImDrawList_AddRectFilledEx")(list.ptr, .{ .x = min[0], .y = min[1] }, .{ .x = max[0], .y = max[1] }, ui.raw("ImGui_GetColorU32")(fill), ui.scaled(14), 0);
    {
        // Null keeps the font, just bigger
        ui.raw("ImGui_PushFontFloat")(null, icon_size);
        defer ui.raw("ImGui_PopFont")();
        const box = ui.calcTextSize(icon);
        list.addText(.{ min[0] + (size - box[0]) / 2, min[1] + (size - box[1]) / 2 }, ui.raw("ImGui_GetColorU32")(c.ImGuiCol_Text), icon);
    }
    if (lit) list.addCircleFilled(.{ at[0] + size / 2, at[1] + size + ui.scaled(dot_room) / 2 }, ui.scaled(2.5), ui.raw("ImGui_GetColorU32")(c.ImGuiCol_Text));
    if (count > 0) badge(count, max[0], min[1]);
    return clicked;
}

/// A plugin's tile, its first letter, since plugins have no icons yet.
fn letterTile(id: [:0]const u8, name: []const u8, lit: bool) bool {
    var buf: [4]u8 = undefined;
    const first = if (name.len > 0) std.ascii.toUpper(name[0]) else '?';
    buf[0] = first;
    return tile(id, buf[0..1], lit, 0);
}

/// On the corner at `right`, `top`.
fn badge(count: usize, right: f32, top: f32) void {
    var buf: [8]u8 = undefined;
    const text = if (count > 99) "99+" else std.fmt.bufPrint(&buf, "{d}", .{count}) catch return;
    const size = ui.calcTextSize(text);
    const r = @max(size[0], size[1]) / 2 + ui.scaled(3);
    const centre: ui.Vec2 = .{ right - r * 0.4, top + r * 0.4 };
    const list = ui.getWindowDrawList();
    list.addCircleFilled(centre, r, ui.rgba(214, 72, 84, 255));
    list.addText(.{ centre[0] - size[0] / 2, centre[1] - size[1] / 2 }, ui.rgba(255, 255, 255, 255), text);
}

/// A thin line between groups of tiles, like the dock's.
fn divider() void {
    ui.sameLine();
    const at = ui.getCursorScreenPos();
    const h = ui.scaled(tile_size);
    const colour = ui.raw("ImGui_GetColorU32")(c.ImGuiCol_Separator);
    ui.getWindowDrawList().addLine(.{ at[0] + ui.scaled(3), at[1] + h * 0.15 }, .{ at[0] + ui.scaled(3), at[1] + h * 0.85 }, colour, 1);
    ui.raw("ImGui_Dummy")(.{ .x = ui.scaled(6), .y = h });
    ui.sameLine();
}

/// At most this many plugins on the bar.
const max_plugins = 32;

/// A button per plugin with menu items, in the order they added their first. One item and no
/// settings opens it straight away, otherwise it's a list.
fn pluginButtons(shell: *Shell) void {
    _ = shell;
    // Asked first, since a plugin going away waits on `MenuItems`
    var names: [max_plugins][64]u8 = undefined;
    var name_lens: [max_plugins]usize = @splat(0);
    var has: [max_plugins]bool = @splat(false);
    var n: usize = 0;
    {
        const items = MenuItems.read();
        defer items.end();
        for (items.entries, 0..) |e, i| {
            if (n == max_plugins or firstSeen(items.entries, i) != i) continue;
            const len = @min(e.owner.name.len, names[n].len);
            @memcpy(names[n][0..len], e.owner.name[0..len]);
            name_lens[n] = len;
            n += 1;
        }
    }
    for (0..n) |i| has[i] = ui_area.hasSettings(names[i][0..name_lens[i]]);

    var settings_buf: [64]u8 = undefined;
    var settings_for: ?[]const u8 = null;
    {
        const items = MenuItems.read();
        defer items.end();
        const all = items.entries;
        var first = true;
        for (all, 0..) |e, i| {
            if (firstSeen(all, i) != i) continue;
            const with_settings = for (names[0..n], name_lens[0..n], has[0..n]) |*name, len, h| {
                if (std.mem.eql(u8, name[0..len], e.owner.name)) break h;
            } else false;
            if (first) divider() else ui.sameLine();
            first = false;
            const scope = ui.id(e.owner);
            defer scope.end();
            const name = if (e.item.menu.len > 0) e.item.menu else e.owner.name;
            var count: usize = 0;
            var any_open = false;
            for (all[i..]) |item| if (item.owner == e.owner) {
                count += 1;
                if (item.item.open.*) any_open = true;
            };
            if (count == 1 and !with_settings) {
                if (letterTile("##plugin", name, e.item.open.*)) e.item.open.* = !e.item.open.*;
                ui.tooltip("{s}", .{name});
                continue;
            }
            if (letterTile("##plugin", name, any_open)) _ = ui.raw("ImGui_OpenPopup")("##items", 0);
            ui.tooltip("{s}", .{name});
            if (!ui.raw("ImGui_BeginPopup")("##items", 0)) continue;
            defer ui.raw("ImGui_EndPopup")();
            for (all[i..]) |item| {
                if (item.owner != e.owner) continue;
                const item_scope = ui.id(item.item);
                defer item_scope.end();
                var item_buf: [128]u8 = undefined;
                const item_label = std.fmt.bufPrintSentinel(&item_buf, "{s}", .{item.item.label}, 0) catch continue;
                _ = ui.menuItem(item_label, .{ .checked = item.item.open });
            }
            if (with_settings) {
                ui.separator();
                if (ui.menuItem(icons.settings ++ "  Settings", .{})) {
                    const len = @min(e.owner.name.len, settings_buf.len);
                    @memcpy(settings_buf[0..len], e.owner.name[0..len]);
                    settings_for = settings_buf[0..len];
                }
            }
        }
    }
    // Outside `MenuItems`, since it calls into the plugin
    if (settings_for) |plugin| _ = ui_area.openSettings(plugin);
}

/// Where the owner of `all[i]` first shows up.
fn firstSeen(all: []const MenuItems.Entry, i: usize) usize {
    for (all[0..i], 0..) |before, j| if (before.owner == all[i].owner) return j;
    return i;
}
