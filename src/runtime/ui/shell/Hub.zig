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
    field: []const u8,
    label: []const u8,
    icon: []const u8,
};

const buttons = [_]Button{
    .{ .field = "mods", .label = "Mods", .icon = icons.puzzle },
    .{ .field = "tweaks", .label = "Tweaks", .icon = icons.sliders_horizontal },
    .{ .field = "settings", .label = "Settings", .icon = icons.settings },
    .{ .field = "about", .label = "About", .icon = icons.info },
};

/// Unscaled. Between the bar and the edge of the screen.
const margin = 12;

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
    } }) orelse return;
    defer win.end();
    self.bar_height = ui.raw("ImGui_GetWindowSize")().y;
    self.bar_focused = ui.raw("ImGui_IsWindowFocused")(0);

    const on = tweaksOn(shell);
    inline for (buttons, 0..) |b, i| {
        if (i > 0) ui.sameLine();
        const w = &@field(shell.windows, b.field).window;
        const count = if (comptime std.mem.eql(u8, b.field, "tweaks")) on else 0;
        if (barButton(b.label, b.icon, w.open, count)) w.toggle();
    }
    pluginButtons(shell);
    divider();
    if (barButton("Workbench", icons.square_terminal, shell.workbench.isOpen(), 0)) shell.toggleWorkbench();
    var key_buf: [64]u8 = undefined;
    if (shell.workbenchKey()) |k| {
        ui.tooltip("Disassembly, memory, addresses and the other developer tools, in a window of their own. {s}", .{ui.chordName(&key_buf, k)});
    } else ui.tooltip("Disassembly, memory, addresses and the other developer tools, in a window of their own", .{});
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

/// Lit while what it opens is open. A count in its corner if there's one.
fn barButton(label: []const u8, icon: []const u8, lit: bool, count: usize) bool {
    var buf: [128]u8 = undefined;
    const text = (if (icon.len > 0) std.fmt.bufPrintSentinel(&buf, "{s}  {s}", .{ icon, label }, 0) else std.fmt.bufPrintSentinel(&buf, "{s}", .{label}, 0)) catch return false;
    if (lit) {
        const colour = ui.raw("ImGui_GetStyleColorVec4")(c.ImGuiCol_ButtonActive);
        ui.raw("ImGui_PushStyleColorImVec4")(c.ImGuiCol_Button, colour.*);
    }
    const clicked = ui.button(text);
    if (lit) ui.raw("ImGui_PopStyleColor")();
    if (count > 0) badge(count);
    return clicked;
}

fn badge(count: usize) void {
    var buf: [8]u8 = undefined;
    const text = if (count > 99) "99+" else std.fmt.bufPrint(&buf, "{d}", .{count}) catch return;
    const size = ui.calcTextSize(text);
    const max = ui.raw("ImGui_GetItemRectMax")();
    const min = ui.raw("ImGui_GetItemRectMin")();
    const r = @max(size[0], size[1]) / 2 + ui.scaled(2);
    const centre: ui.Vec2 = .{ max.x - r * 0.5, min.y + r * 0.5 };
    const list = ui.getWindowDrawList();
    list.pushClipRectFullScreen();
    defer list.popClipRect();
    list.addCircleFilled(centre, r, ui.rgba(214, 72, 84, 255));
    list.addText(.{ centre[0] - size[0] / 2, centre[1] - size[1] / 2 }, ui.rgba(255, 255, 255, 255), text);
}

/// A thin line between groups of buttons, on the same row.
fn divider() void {
    ui.sameLine();
    const at = ui.getCursorScreenPos();
    const h = ui.frameHeight();
    const colour = ui.raw("ImGui_GetColorU32")(c.ImGuiCol_Separator);
    ui.getWindowDrawList().addLine(.{ at[0], at[1] + h * 0.15 }, .{ at[0], at[1] + h * 0.85 }, colour, 1);
    ui.raw("ImGui_Dummy")(.{ .x = 1, .y = h });
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
                if (barButton(name, "", e.item.open.*, 0)) e.item.open.* = !e.item.open.*;
                continue;
            }
            var label_buf: [96]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "{s}  {s}", .{ name, icons.chevron_up }) catch name;
            if (barButton(label, "", any_open, 0)) _ = ui.raw("ImGui_OpenPopup")("##items", 0);
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
