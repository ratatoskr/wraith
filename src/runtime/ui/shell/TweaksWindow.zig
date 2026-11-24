//! The overlay's Tweaks window, and the small list it leaves on screen when it's pinned. Plugins'
//! `[Tweak]` structs show here too, as a row that opens up into the game's values. Every tweak this game has: your project's, installed projects' and
//! plugins', with what's on, their values and their keys. Headings and groups fold, and rows drag
//! or move from the right-click menu among the ones next to them. Render thread.

const TweaksWindow = @This();

const std = @import("std");

const ui = @import("wraith_ui");

const icons = @import("../fonts.zig").icons;
const Tweaks = @import("../../Tweaks.zig");
const TweakFields = @import("../TweakFields.zig");
const TweakLayout = @import("../TweakLayout.zig");
const struct_tweaks = @import("../../host/struct_tweaks.zig");
const Shell = @import("Shell.zig");

const Info = Tweaks.Info;
const Entry = TweakLayout.Entry;

window: ui.Window = .{ .title = "Tweaks###wraith.tweaks", .size = .{ 820, 600 } },
shell: *Shell = undefined,
search: [128]u8 = @splat(0),
only_on: bool = false,
/// Dragging rows about. What's folded and the order are in the shell's `tweak_layout`.
reorder: ui.Reorder = .{ .kind = "wraith.tweaks", .siblings_only = true },
/// Tweaks showing their fields and `[Tweak]` structs showing their values, by `openKey` and
/// `structKey`. Shut to start, so the list stays short.
opened: std.ArrayList(u64) = .empty,

const red: ui.Color = .{ 1, 0.5, 0.5, 1 };
const green: ui.Color = .{ 0.45, 0.85, 0.45, 1 };
const amber: ui.Color = .{ 1, 0.75, 0.3, 1 };
const dim: ui.Color = .{ 0.6, 0.6, 0.6, 1 };

/// Unscaled.
const key_width = 130;
const field_width = 220;
/// On the on-screen list, at most.
const max_on_screen = 32;
/// `[Tweak]` structs listed, at most.
const max_structs = 64;

pub fn onOpen(self: *TweaksWindow) void {
    self.search = @splat(0);
}

pub fn deinit(self: *TweaksWindow, gpa: std.mem.Allocator) void {
    self.reorder.deinit();
    self.opened.deinit(gpa);
}

fn sourceLabel(t: *const Info) []const u8 {
    return t.source_title;
}

fn isAction(t: *const Info) bool {
    return !t.is_group and t.mode == .action;
}

fn matches(t: *const Info, query: []const u8) bool {
    if (query.len == 0) return true;
    return std.ascii.findIgnoreCase(t.title, query) != null or std.ascii.findIgnoreCase(sourceLabel(t), query) != null;
}

fn isActive(t: *const Info) bool {
    return t.on or t.partial or t.running;
}

pub fn draw(self: *TweaksWindow) void {
    const shell = self.shell;
    ui.setNextItemWidthPixels(-ui.scaled(240));
    _ = ui.inputTextHint("##search", icons.search ++ "  Search tweaks", &self.search);
    ui.sameLine();
    _ = ui.checkbox("Only what's on", &self.only_on);
    const tweaks = shell.tweaks orelse {
        ui.textDisabled("Tweaks need the game's folder, which Wraith doesn't have here.", .{});
        return;
    };
    var arena: std.heap.ArenaAllocator = .init(shell.allocator);
    defer arena.deinit();
    const list = tweaks.snapshot(arena.allocator()) catch return;
    ui.sameLine();
    const any_on = for (list) |*t| {
        if (t.on or t.partial) break true;
    } else false;
    {
        const off = ui.disabled(!any_on);
        defer off.end();
        if (ui.button(icons.power ++ "  All off")) turnAllOff(tweaks, list);
    }
    ui.tooltip("Turns every tweak off", .{});
    ui.sameLine();
    const pinned = shell.registry.get(shell.own.tweaks_on_screen).toggle;
    const lit: ui.StyleColors = if (pinned) ui.withStyleColor(.button, .button_active) else .{ .n = 0 };
    const pin = ui.iconButton(if (pinned) icons.pin ++ "##pin" else icons.pin_off ++ "##pin", if (pinned) "Pinned. Closing this leaves a small list on screen, of the ones with keys and which are on" else "Pin it, so closing this leaves a small list on screen, of the ones with keys and which are on");
    lit.end();
    if (pin) shell.registry.set(shell.own.tweaks_on_screen, .{ .toggle = !pinned }) catch {};

    const query = std.mem.trim(u8, std.mem.sliceTo(&self.search, 0), " ");
    if (ui.child("##tweaks", .{ 0, 0 }, .{})) |body| {
        defer body.end();
        // A copy, since rows call into `tweaks` and a struct's fields are only drawn under its lock
        const structs = struct_tweaks.snapshot(arena.allocator(), query);
        self.drawList(shell, tweaks, arena.allocator(), list, structs[0..@min(structs.len, max_structs)], query);
    }
}

pub fn turnAllOff(tweaks: *Tweaks, list: []const Info) void {
    // A whole file goes at once, whatever its groups' @children say
    for (list) |*t| if (t.group == null and (t.on or t.partial)) tweaks.turnOff(t.name);
}

fn drawList(self: *TweaksWindow, shell: *Shell, tweaks: *Tweaks, arena: std.mem.Allocator, list: []const Info, structs: []const struct_tweaks.Summary, query: []const u8) void {
    if (list.len == 0 and structs.len == 0) {
        ui.textWrapped("No tweaks for this game yet. Install a project from Mods, or write your own in the Workbench.", .{});
        return;
    }
    const layout = &shell.tweak_layout;
    const all = layout.entries(arena, list, structs) catch return;
    // Searching shows what matches, whatever's folded
    const folds = query.len == 0;
    {
        // Striped, so each tweak and what it opens up into reads as one
        const table = ui.table("##rows", 3, .{ .row_background = true }) orelse return;
        defer table.end();
        ui.tableColumnWith("On", .{ .fixed = true, .width = 28 });
        ui.tableColumnWith("Tweak", .{ .stretch = true, .width = 1 });
        ui.tableColumnWith("Key", .{ .fixed = true, .width = key_width });
        self.reorder.begin();
        var any = false;
        // What's in something folded or hidden, deeper than this
        var skip_below: ?u32 = null;
        for (all, 0..) |*e, i| {
            if (skip_below) |depth| {
                if (e.depth > depth) continue;
                skip_below = null;
            }
            const scope = ui.id(@as(i32, @intCast(i)));
            defer scope.end();
            switch (e.what) {
                .source => |s| {
                    if (!self.anyShown(all[i + 1 ..], e.depth, query)) {
                        skip_below = e.depth;
                        continue;
                    }
                    self.drawHeading(layout, e, s.title, folds);
                    if (folds and e.folded) skip_below = e.depth;
                },
                .section => |name| {
                    if (!self.anyShown(all[i + 1 ..], e.depth, query)) {
                        skip_below = e.depth;
                        continue;
                    }
                    self.drawSection(layout, e, name, folds);
                    if (folds and e.folded) skip_below = e.depth;
                },
                .tweak => |t| {
                    if (!self.showsTweak(t, query)) continue;
                    self.drawRow(shell.allocator, tweaks, layout, e, t, folds);
                    if (folds and t.is_group and e.folded) skip_below = e.depth;
                    any = true;
                },
                .structure => |s| if (self.showsStruct(s, query)) {
                    self.drawStruct(shell.allocator, e, s);
                    any = true;
                },
            }
        }
        if (!any) {
            ui.tableNextRow();
            _ = ui.tableNextColumn();
            _ = ui.tableNextColumn();
            ui.textDisabled("{s}", .{if (query.len > 0) "Nothing matches" else "Nothing's on"});
        }
    }
    _ = self.reorder.drawMenu(null);
    if (self.reorder.take()) |move| _ = layout.apply(all, move);
}

fn withOpen(row: ui.Reorder.Item, open: bool) ui.Reorder.Item {
    var r = row;
    r.open = open;
    return r;
}

fn showsTweak(self: *const TweaksWindow, t: *const Info, query: []const u8) bool {
    // Searching shows tweaks alone, wherever they are
    if (query.len > 0 and (t.is_group or !matches(t, query))) return false;
    return !self.only_on or isActive(t);
}

/// Anything under a heading or section, up to the next one as deep or shallower.
fn anyShown(self: *const TweaksWindow, rest: []const Entry, depth: u32, query: []const u8) bool {
    for (rest) |*e| {
        if (e.depth <= depth) return false;
        switch (e.what) {
            .source, .section => {},
            .tweak => |t| if (self.showsTweak(t, query)) return true,
            .structure => |s| if (self.showsStruct(s, query)) return true,
        }
    }
    return false;
}

/// A plugin's heading inside its own, in bold, folding what's under it.
fn drawSection(self: *TweaksWindow, layout: *TweakLayout, e: *const Entry, name: []const u8, folds: bool) void {
    ui.tableNextRow();
    _ = ui.tableNextColumn();
    _ = ui.tableNextColumn();
    const bold = ui.bold();
    defer bold.end();
    if (ui.Outline.node(&self.reorder, .{ .id = e.id, .parent = e.parent, .label = name, .open = !(folds and e.folded) }, .folds) and folds) layout.toggle(e.id);
    _ = ui.tableNextColumn();
}

/// Where they're from, as a bar across the row. Clicking folds it, and it drags to put a source
/// above or below another.
fn drawHeading(self: *TweaksWindow, layout: *TweakLayout, e: *const Entry, title: []const u8, folds: bool) void {
    ui.tableNextRow();
    _ = ui.tableNextColumn();
    if (ui.Outline.node(&self.reorder, .{ .id = e.id, .label = title, .open = !(folds and e.folded) }, .heading) and folds) layout.toggle(e.id);
}

/// They're never on, so "only what's on" hides them. Searching finds their fields too.
fn showsStruct(self: *const TweaksWindow, e: *const struct_tweaks.Summary, query: []const u8) bool {
    _ = query;
    return !self.only_on and e.matches;
}

fn openKey(name: []const u8) u64 {
    return std.hash.Wyhash.hash(1, name);
}

fn isOpen(self: *const TweaksWindow, key: u64) bool {
    return std.mem.indexOfScalar(u64, self.opened.items, key) != null;
}

pub fn setOpen(self: *TweaksWindow, gpa: std.mem.Allocator, key: u64, open: bool) void {
    const at = std.mem.indexOfScalar(u64, self.opened.items, key);
    if (open and at == null) self.opened.append(gpa, key) catch {};
    if (!open) if (at) |i| {
        _ = self.opened.swapRemove(i);
    };
}

fn structKey(e: *const struct_tweaks.Summary) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(e.source);
    h.update("/");
    h.update(e.type_name);
    return h.final();
}

/// One row, that opens up into the game's values, edited as they're changed.
fn drawStruct(self: *TweaksWindow, gpa: std.mem.Allocator, entry: *const Entry, e: *const struct_tweaks.Summary) void {
    const scope = ui.id(e.type_name.ptr);
    defer scope.end();
    const key = structKey(e);
    const at = std.mem.indexOfScalar(u64, self.opened.items, key);
    ui.tableNextRow();
    _ = ui.tableNextColumn();
    _ = ui.tableNextColumn();
    const toggle = ui.Outline.node(&self.reorder, .{ .id = entry.id, .parent = entry.parent, .label = e.title, .open = at != null }, .folds);
    if (toggle) {
        if (at) |i| {
            _ = self.opened.swapRemove(i);
        } else self.opened.append(gpa, key) catch {};
    }
    if (at != null and !toggle) {
        const inside = ui.Outline.inside();
        defer inside.end();
        switch (struct_tweaks.drawFields(e.source, e.type_name)) {
            .drawn, .gone => {},
            .not_there_yet => ui.textDisabled("Not in the game yet. It shows up once the game makes it, like after loading a save.", .{}),
        }
    }
    _ = ui.tableNextColumn();
}

fn drawRow(self: *TweaksWindow, gpa: std.mem.Allocator, tweaks: *Tweaks, layout: *TweakLayout, e: *const Entry, t: *const Info, nested: bool) void {
    ui.tableNextRow();
    _ = ui.tableNextColumn();
    // The same size as a checkbox, so they line up
    if (t.opens) {
        if (ui.iconButton(icons.app_window ++ "##open", "Opens it")) tweaks.setOn(t.name, true);
    } else if (isAction(t)) {
        if (ui.iconButton(icons.play ++ "##run", "Runs it once")) tweaks.setOn(t.name, true);
    } else {
        var on = t.on;
        // Off, with something in it on
        const mixed = ui.mixedValue(t.partial);
        const clicked = ui.checkbox("##on", &on);
        mixed.end();
        if (clicked) tweaks.setOn(t.name, on);
        if (t.partial) ui.tooltip("Off, but something in it is on", .{});
    }

    _ = ui.tableNextColumn();
    const indent: f32 = if (nested) @floatFromInt((e.depth -| 1) * 16) else 0;
    if (indent > 0) ui.indent(indent);
    defer if (indent > 0) ui.unindent(indent);
    const has_fields = !t.is_group and t.fields.len > 0;
    var open = false;
    const row: ui.Reorder.Item = .{ .id = e.id, .parent = e.parent, .label = t.title };
    if (t.is_group and nested) {
        const bold = ui.bold();
        defer bold.end();
        if (ui.Outline.node(&self.reorder, withOpen(row, !e.folded), .folds)) layout.toggle(e.id);
    } else if (has_fields) {
        open = self.isOpen(openKey(t.name));
        if (ui.Outline.node(&self.reorder, withOpen(row, open), .folds)) {
            self.setOpen(gpa, openKey(t.name), !open);
            open = !open;
        }
    } else {
        _ = ui.Outline.node(&self.reorder, row, .leaf);
    }
    const inside = ui.Outline.inside();
    defer inside.end();
    if (t.problem) |p| {
        const first = p[0 .. std.mem.indexOfScalar(u8, p, '\n') orelse p.len];
        ui.textColored(red, "{s}", .{first});
        ui.tooltip("{s}", .{p});
    } else if (t.on and !t.running and !t.is_group) {
        ui.sameLine();
        ui.textDisabled("starting...", .{});
    }
    if (open) TweakFields.draw(tweaks, t, field_width);

    _ = ui.tableNextColumn();
    var key = t.key;
    ui.setNextItemWidth(ui.fill);
    if (ui.chordInput("##key", &key, .{ .none = "no key" })) tweaks.setKey(t.name, key);
    if (!ui.listeningForKeys()) ui.tooltip("{s}. Click to change it", .{if (t.key == null) "No key" else if (t.own_key) "Yours" else "The tweak's own"});
}

/// The pinned list on screen, of tweaks with keys and ones that are on. It only takes the mouse,
/// to be moved, while the overlay's open.
pub fn drawOnScreen(self: *TweaksWindow, shell: *Shell, interactive: bool) void {
    _ = self;
    if (!shell.registry.get(shell.own.tweaks_on_screen).toggle) return;
    const tweaks = shell.tweaks orelse return;
    var arena: std.heap.ArenaAllocator = .init(shell.allocator);
    defer arena.deinit();
    const list = tweaks.snapshot(arena.allocator()) catch return;
    var shown: [max_on_screen]*const Info = undefined;
    var n: usize = 0;
    for (list) |*t| {
        if (t.is_group or (t.key == null and !t.on) or n == shown.len) continue;
        shown[n] = t;
        n += 1;
    }
    if (n == 0) return;

    const viewport = ui.mainViewport();
    ui.setNextWindowOnMainViewport();
    ui.setNextWindowPos(.{ viewport.work_pos[0] + ui.scaled(12), viewport.work_pos[1] + ui.scaled(40) }, .first_use_ever, .{ 0, 0 });
    ui.setNextWindowBgAlpha(0.6);
    const win = ui.window("Tweaks##wraith.tweaks_on_screen", .{ .flags = .{
        .no_title_bar = true,
        .always_auto_resize = true,
        .no_focus_on_appearing = true,
        .no_nav = true,
        .no_docking = true,
        .no_collapse = true,
        .no_inputs = !interactive,
        .no_move = !interactive,
    } }) orelse return;
    defer win.end();
    for (shown[0..n]) |t| {
        const colour = if (t.problem != null) red else if (t.on and t.running) green else if (t.on) amber else dim;
        ui.textColored(colour, "{s}", .{if (t.opens) icons.app_window else if (isAction(t)) icons.play else if (t.on) icons.circle_check else icons.circle});
        ui.sameLine();
        ui.textColored(if (t.on) colour else dim, "{s}", .{t.title});
        if (t.key) |k| {
            ui.sameLine();
            var buf: [64]u8 = undefined;
            ui.textDisabled("{s}", .{ui.chordName(&buf, k)});
        }
    }
}
