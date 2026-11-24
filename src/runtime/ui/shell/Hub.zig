//! The Wraith overlay's bar. The overlay key slides it in from the bottom of the screen, or the
//! top, with buttons for Wraith's windows, plugins' and the workbench. It holds the mouse and
//! keyboard while it's up, unless the game leaves its mouse free. The windows are the shell's, in a `ui.WindowSystem`, so they stay up
//! till they're closed and the bar just opens and closes them. Tiles drag about within their group,
//! or move from their right-click menu, and the order's kept. Render thread.

const Hub = @This();

const std = @import("std");

const ui = @import("wraith_ui");

const MenuItems = @import("../MenuItems.zig");
const icons = @import("../fonts.zig").icons;
const Dim = @import("Dim.zig");
const UiHold = @import("UiHold.zig");
const Shell = @import("Shell.zig");

open: bool = false,
/// The bar's slide. Nothing's drawn.
dim: Dim = .{},
hold: UiHold = .{},
/// Last frame's, to slide it by.
bar_height: f32 = 0,
/// Last frame, so Escape only closes it when no window has the keys.
bar_focused: bool = false,
/// Tiles move along the bar, within their group.
reorder: ui.Reorder = .{ .kind = "wraith.hub", .siblings_only = true, .horizontal = true },
/// Kept in the shell's `hub_order` setting.
order: ui.Reorder.Arrangement = .{},
order_loaded: bool = false,

const windows_group = 1;
const plugins_group = 2;

/// A tile, by `tileId`, and where it came from.
const Tile = struct {
    id: u64,
    index: usize = 0,
};

/// They're all at the top of their own list.
const Flat = struct {
    pub fn id(_: Flat, t: *const Tile) u64 {
        return t.id;
    }
    pub fn depth(_: Flat, _: *const Tile) u32 {
        return 0;
    }
};

pub fn tileId(kind: []const u8, name: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(kind);
    h.update(&.{0});
    h.update(name);
    return h.final() | 1;
}

const Button = struct {
    /// In `Shell.Windows`.
    field: [:0]const u8,
    label: []const u8,
    icon: []const u8,
};

const buttons = [_]Button{
    .{ .field = "mods", .label = "Mods", .icon = icons.puzzle },
    .{ .field = "tweaks", .label = "Tweaks", .icon = icons.sliders_horizontal },
    .{ .field = "photo", .label = "Photo mode", .icon = icons.camera },
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
    self.hold.set(shell.overlay, self.open);
    const fade = self.dim.update(self.open, .none, "##wraith.hub");
    const tweaks = &shell.windows.tweaks;
    if (!tweaks.window.open) tweaks.drawOnScreen(shell, self.open);
    if (fade == 0) return;
    // Unless a window, menu, popup, text box or a key being picked has it
    const io = ui.getIO();
    const in_popup = ui.isAnyPopupOpen();
    const window_has_it = ui.isAnyWindowFocused() and !self.bar_focused;
    if (self.open and ui.isKeyPressed(.escape, false) and !window_has_it and !io.WantTextInput and !in_popup and !ui.listeningForKeys()) self.open = false;
    const faded = ui.styleVars(.{ .alpha = fade });
    defer faded.end();
    // Still drawn while it slides away
    self.drawBar(shell, fade);
}

pub fn deinit(self: *Hub, shell: *Shell) void {
    self.hold.release(shell.overlay);
    self.reorder.deinit();
    self.order.deinit();
}

fn loadOrder(self: *Hub, shell: *Shell) void {
    if (self.order_loaded) return;
    self.order_loaded = true;
    var ids: [128]u64 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, shell.registry.get(shell.own.hub_order).text, ',');
    while (it.next()) |hex| {
        if (n == ids.len) break;
        ids[n] = std.fmt.parseInt(u64, hex, 16) catch continue;
        n += 1;
    }
    self.order.load(ids[0..n], &.{});
}

fn saveOrder(self: *Hub, shell: *Shell) void {
    if (!self.order.takeChanged()) return;
    var buf: [128 * 17]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    for (self.order.orderIds(), 0..) |id, i| {
        if (i > 0) w.writeByte(',') catch break;
        w.print("{x}", .{id}) catch break;
    }
    shell.registry.set(shell.own.hub_order, .{ .text = w.buffered() }) catch {};
}

fn drawBar(self: *Hub, shell: *Shell, fade: f32) void {
    const viewport = ui.mainViewport();
    const top = shell.own.barAtTop();
    const eased = 1 - std.math.pow(f32, 1 - fade, 3);
    const gap = ui.scaled(margin);
    const tucked = (1 - eased) * (self.bar_height + gap);
    const x = viewport.work_pos[0] + viewport.work_size[0] / 2;
    const y = if (top) viewport.work_pos[1] + gap - tucked else viewport.work_pos[1] + viewport.work_size[1] - gap + tucked;
    ui.setNextWindowOnMainViewport();
    ui.setNextWindowPos(.{ x, y }, .always, .{ 0.5, if (top) 0 else 1 });
    ui.setNextWindowBgAlpha(0.85);
    const style = ui.styleVars(.{
        .window_rounding = ui.scaled(18),
        .window_padding = .{ ui.scaled(10), ui.scaled(8) },
        .item_spacing = .{ ui.scaled(6), 0 },
    });
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
        style.end();
        return;
    };
    defer win.end();
    style.end();
    self.bar_height = ui.getWindowSize()[1];
    self.bar_focused = ui.isWindowFocused();

    self.loadOrder(shell);
    self.reorder.begin();
    const on = tweaksOn(shell);
    var windows: [buttons.len]Tile = undefined;
    inline for (buttons, 0..) |b, i| windows[i] = .{ .id = tileId("window", b.field), .index = i };
    self.order.arrange(Tile, &windows, Flat{});
    for (windows, 0..) |w_tile, i| {
        if (i > 0) ui.sameLine();
        inline for (buttons, 0..) |b, k| if (w_tile.index == k) {
            const w = &@field(shell.windows, b.field).window;
            const count = if (comptime std.mem.eql(u8, b.field, "tweaks")) on else 0;
            if (tile(b.field, b.icon, w.open, count)) w.toggle();
            self.reorder.item(.{ .id = w_tile.id, .parent = windows_group, .label = b.label });
            ui.tooltip("{s}", .{b.label});
        };
    }
    var plugins: [max_plugins]Tile = undefined;
    const plugin_count = self.pluginButtons(shell, &plugins);
    divider();
    if (tile("workbench", icons.square_terminal, shell.workbench.isOpen(), 0)) shell.toggleWorkbench();
    var key_buf: [64]u8 = undefined;
    if (shell.workbenchKey()) |k| {
        ui.tooltip("Workbench  {s}", .{ui.chordName(&key_buf, k)});
    } else ui.tooltip("Workbench", .{});
    _ = self.reorder.drawMenu(null);
    if (self.reorder.take()) |move| {
        if (!self.order.apply(Tile, &windows, Flat{}, move)) _ = self.order.apply(Tile, plugins[0..plugin_count], Flat{}, move);
        self.saveOrder(shell);
    }
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
    const fill: ui.Col = if (held) .button_active else if (hovered or lit) .button_hovered else .button;
    list.addRectFilledRounded(min, max, ui.getColorU32(fill), ui.scaled(14));
    {
        const big = ui.fontSized(icon_size);
        defer big.end();
        const box = ui.calcTextSize(icon);
        list.addText(.{ min[0] + (size - box[0]) / 2, min[1] + (size - box[1]) / 2 }, ui.getColorU32(.text), icon);
    }
    if (lit) list.addCircleFilled(.{ at[0] + size / 2, at[1] + size + ui.scaled(dot_room) / 2 }, ui.scaled(2.5), ui.getColorU32(.text));
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
    const colour = ui.getColorU32(.separator);
    ui.getWindowDrawList().addLine(.{ at[0] + ui.scaled(3), at[1] + h * 0.15 }, .{ at[0] + ui.scaled(3), at[1] + h * 0.85 }, colour, 1);
    ui.dummy(.{ ui.scaled(6), h });
    ui.sameLine();
}

/// At most this many plugins on the bar.
const max_plugins = 32;

/// A button per plugin with menu items, in the order they added their first unless they've been
/// moved. One item and no settings opens it straight away, otherwise it's a list. `out` gets the
/// tiles in the order drawn, and how many there are comes back.
fn pluginButtons(self: *Hub, shell: *Shell, out: []Tile) usize {
    // Asked first, since a plugin going away waits on `MenuItems`
    var names: [max_plugins][64]u8 = undefined;
    var name_lens: [max_plugins]usize = @splat(0);
    var titles: [max_plugins][96]u8 = undefined;
    var title_lens: [max_plugins]usize = @splat(0);
    var has: [max_plugins]bool = @splat(false);
    var n: usize = 0;
    {
        const items = MenuItems.read();
        defer items.end();
        for (items.entries, 0..) |e, i| {
            if (n == max_plugins or firstSeen(items.entries, i) != i) continue;
            name_lens[n] = copyInto(&names[n], e.owner.name);
            title_lens[n] = copyInto(&titles[n], if (e.item.menu.len > 0) e.item.menu else e.owner.name);
            n += 1;
        }
    }
    for (0..n) |i| has[i] = shell.pluginHasSettings(names[i][0..name_lens[i]], titles[i][0..title_lens[i]]);

    var settings_for: ?usize = null;
    var drawn: usize = 0;
    {
        const items = MenuItems.read();
        defer items.end();
        const all = items.entries;
        var tiles: usize = 0;
        for (all, 0..) |e, i| {
            if (tiles == out.len or firstSeen(all, i) != i) continue;
            out[tiles] = .{ .id = tileId("plugin", e.owner.name), .index = i };
            tiles += 1;
        }
        self.order.arrange(Tile, out[0..tiles], Flat{});
        drawn = tiles;
        for (out[0..tiles], 0..) |t, k| {
            const i = t.index;
            const e = all[i];
            const plugin = for (names[0..n], name_lens[0..n], 0..) |*name, len, at| {
                if (std.mem.eql(u8, name[0..len], e.owner.name)) break at;
            } else null;
            const with_settings = if (plugin) |at| has[at] else false;
            if (k == 0) divider() else ui.sameLine();
            const scope = ui.id(e.owner);
            defer scope.end();
            const name = if (e.item.menu.len > 0) e.item.menu else e.owner.name;
            var count: usize = 0;
            var any_open = false;
            for (all[i..]) |item| if (item.owner == e.owner) {
                count += 1;
                if (item.item.open.*) any_open = true;
            };
            const it: ui.Reorder.Item = .{ .id = t.id, .parent = plugins_group, .label = name };
            if (count == 1 and !with_settings) {
                if (letterTile("##plugin", name, e.item.open.*)) e.item.open.* = !e.item.open.*;
                self.reorder.item(it);
                ui.tooltip("{s}", .{name});
                continue;
            }
            if (letterTile("##plugin", name, any_open)) ui.openPopup("##items");
            self.reorder.item(it);
            ui.tooltip("{s}", .{name});
            const list = ui.popup("##items") orelse continue;
            defer list.end();
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
                if (ui.menuItem(icons.settings ++ "  Settings", .{})) settings_for = plugin;
            }
        }
    }
    // Outside `MenuItems`, since it calls into the plugin
    if (settings_for) |at| shell.openPluginSettings(names[at][0..name_lens[at]], titles[at][0..title_lens[at]]);
    return drawn;
}

/// As much of `from` as fits. How much that was.
fn copyInto(to: []u8, from: []const u8) usize {
    const len = @min(from.len, to.len);
    @memcpy(to[0..len], from[0..len]);
    return len;
}

/// Where the owner of `all[i]` first shows up.
fn firstSeen(all: []const MenuItems.Entry, i: usize) usize {
    for (all[0..i], 0..) |before, j| if (before.owner == all[i].owner) return j;
    return i;
}
