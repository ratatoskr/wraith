//! The overlay's Tweaks window, and the small list it leaves on screen when it's pinned. Plugins'
//! `[Tweak]` structs show here too, as a row that opens up into the game's values. Every tweak this game has: your project's, installed projects' and
//! plugins', with what's on, their values and their keys. Render thread.

const TweaksWindow = @This();

const std = @import("std");

const ui = @import("wraith_ui");

const icons = @import("../fonts.zig").icons;
const Tweaks = @import("../../Tweaks.zig");
const TweakFields = @import("../TweakFields.zig");
const StructEditor = @import("../StructEditor.zig");
const struct_tweaks = @import("../../host/struct_tweaks.zig");
const Shell = @import("Shell.zig");

const Info = Tweaks.Info;

window: ui.Window = .{ .title = "Tweaks###wraith.tweaks", .size = .{ 820, 600 } },
shell: *Shell = undefined,
search: [128]u8 = @splat(0),
only_on: bool = false,
/// Folded groups, by their names' hashes.
folded: std.ArrayList(u64) = .empty,
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
    self.folded.deinit(gpa);
    self.opened.deinit(gpa);
}

/// Where it's from, for its heading. Empty for your project.
fn sourceId(t: *const Info) []const u8 {
    return t.mod orelse t.plugin orelse "";
}

fn sourceLabel(t: *const Info) []const u8 {
    if (t.mod_title orelse t.plugin_title) |title| return title;
    if (t.mod orelse t.plugin) |id| return id;
    return "Your project";
}

fn isAction(t: *const Info) bool {
    return !t.is_group and t.mode == .action;
}

fn isFolded(self: *const TweaksWindow, name: []const u8) bool {
    return std.mem.indexOfScalar(u64, self.folded.items, std.hash.Wyhash.hash(0, name)) != null;
}

pub fn fold(self: *TweaksWindow, gpa: std.mem.Allocator, name: []const u8) void {
    const id = std.hash.Wyhash.hash(0, name);
    if (std.mem.indexOfScalar(u64, self.folded.items, id)) |i| {
        _ = self.folded.swapRemove(i);
    } else self.folded.append(gpa, id) catch {};
}

/// In a folded group, at any depth.
fn hidden(self: *const TweaksWindow, list: []const Info, t: *const Info) bool {
    var at = t.group;
    while (at) |name| {
        if (self.isFolded(name)) return true;
        at = for (list) |*g| {
            if (std.mem.eql(u8, g.name, name)) break g.group;
        } else null;
    }
    return false;
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
    if (pinned) {
        const colour = ui.raw("ImGui_GetStyleColorVec4")(ui.c.ImGuiCol_ButtonActive);
        ui.raw("ImGui_PushStyleColorImVec4")(ui.c.ImGuiCol_Button, colour.*);
    }
    const pin = ui.iconButton(if (pinned) icons.pin ++ "##pin" else icons.pin_off ++ "##pin", if (pinned) "Pinned. Closing this leaves a small list on screen, of the ones with keys and which are on" else "Pin it, so closing this leaves a small list on screen, of the ones with keys and which are on");
    if (pinned) ui.raw("ImGui_PopStyleColor")();
    if (pin) shell.registry.set(shell.own.tweaks_on_screen, .{ .toggle = !pinned }) catch {};

    const query = std.mem.trim(u8, std.mem.sliceTo(&self.search, 0), " ");
    if (ui.child("##tweaks", .{ 0, 0 }, .{})) |body| {
        defer body.end();
        // Plugins can't close till it's done, so only while drawing
        const structs = struct_tweaks.read();
        defer structs.end();
        self.drawList(shell, tweaks, list, structs.entries[0..@min(structs.entries.len, max_structs)], query);
    }
}

pub fn turnAllOff(tweaks: *Tweaks, list: []const Info) void {
    // A whole file goes at once, whatever its groups' @children say
    for (list) |*t| if (t.group == null and (t.on or t.partial)) tweaks.turnOff(t.name);
}

fn drawList(self: *TweaksWindow, shell: *Shell, tweaks: *Tweaks, list: []const Info, structs: []const struct_tweaks.Entry, query: []const u8) void {
    if (list.len == 0 and structs.len == 0) {
        ui.textWrapped("No tweaks for this game yet. Install a project from Mods, or write your own in the Workbench.", .{});
        return;
    }
    const table = ui.table("##rows", 3, .{}) orelse return;
    defer table.end();
    ui.tableColumnWith("On", .{ .fixed = true, .width = 28 });
    ui.tableColumnWith("Tweak", .{ .stretch = true, .width = 1 });
    ui.tableColumnWith("Key", .{ .fixed = true, .width = key_width });
    var source: ?[]const u8 = null;
    var any = false;
    var drawn: [max_structs]bool = @splat(false);
    for (list, 0..) |*t, i| {
        // Searching shows tweaks alone, wherever they are
        if (query.len > 0 and (t.is_group or !matches(t, query))) continue;
        if (query.len == 0 and self.hidden(list, t)) continue;
        if (self.only_on and !isActive(t)) continue;
        any = true;
        if (source == null or !std.mem.eql(u8, source.?, sourceId(t))) {
            // A plugin's structs go after its other tweaks
            if (source) |before| any = self.drawStructs(shell.allocator, structs, &drawn, before, query) or any;
            source = sourceId(t);
            ui.tableNextRow();
            _ = ui.tableNextColumn();
            _ = ui.tableNextColumn();
            var buf: [96]u8 = undefined;
            ui.separatorText(std.fmt.bufPrintSentinel(&buf, "{s}", .{sourceLabel(t)}, 0) catch "?");
        }
        const scope = ui.id(@as(i32, @intCast(i)));
        defer scope.end();
        self.drawRow(shell.allocator, tweaks, t, query.len == 0);
    }
    if (source) |last| any = self.drawStructs(shell.allocator, structs, &drawn, last, query) or any;
    // Plugins with only structs, under headings of their own
    var heading: ?[]const u8 = null;
    for (structs, 0..) |*e, i| {
        if (drawn[i] or !self.showsStruct(e, query)) continue;
        if (heading == null or !std.mem.eql(u8, heading.?, e.plugin)) {
            heading = e.plugin;
            ui.tableNextRow();
            _ = ui.tableNextColumn();
            _ = ui.tableNextColumn();
            var buf: [96]u8 = undefined;
            ui.separatorText(std.fmt.bufPrintSentinel(&buf, "{s}", .{e.plugin_title}, 0) catch "?");
        }
        self.drawStruct(shell.allocator, e);
        any = true;
    }
    if (!any) {
        ui.tableNextRow();
        _ = ui.tableNextColumn();
        _ = ui.tableNextColumn();
        ui.textDisabled("{s}", .{if (query.len > 0) "Nothing matches" else "Nothing's on"});
    }
}

/// `source`'s structs, marked drawn. True if any were.
fn drawStructs(self: *TweaksWindow, gpa: std.mem.Allocator, structs: []const struct_tweaks.Entry, drawn: []bool, source: []const u8, query: []const u8) bool {
    var any = false;
    for (structs, 0..) |*e, i| {
        if (drawn[i] or !std.mem.eql(u8, e.plugin, source)) continue;
        drawn[i] = true;
        if (!self.showsStruct(e, query)) continue;
        self.drawStruct(gpa, e);
        any = true;
    }
    return any;
}

/// They're never on, so "only what's on" hides them. Searching finds their fields too.
fn showsStruct(self: *const TweaksWindow, e: *const struct_tweaks.Entry, query: []const u8) bool {
    if (self.only_on) return false;
    if (query.len == 0) return true;
    return std.ascii.findIgnoreCase(e.title, query) != null or
        std.ascii.findIgnoreCase(e.plugin_title, query) != null or
        StructEditor.mentions(&e.schemas.parsed.schema, e.type_name, query);
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

fn structKey(e: *const struct_tweaks.Entry) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(e.plugin);
    h.update("/");
    h.update(e.type_name);
    return h.final();
}

/// One row, that opens up into the game's values, edited as they're changed.
fn drawStruct(self: *TweaksWindow, gpa: std.mem.Allocator, e: *const struct_tweaks.Entry) void {
    const scope = ui.id(e.type_name.ptr);
    defer scope.end();
    const key = structKey(e);
    const at = std.mem.indexOfScalar(u64, self.opened.items, key);
    ui.tableNextRow();
    _ = ui.tableNextColumn();
    var toggle = ui.smallButton(if (at != null) icons.chevron_down ++ "##open" else icons.chevron_right ++ "##open");
    ui.tooltip("{s}", .{if (at != null) "Hide its values" else "Show its values"});
    _ = ui.tableNextColumn();
    var buf: [128]u8 = undefined;
    if (ui.selectable(std.fmt.bufPrintSentinel(&buf, "{s}", .{e.title}, 0) catch "?", false)) toggle = true;
    if (toggle) {
        if (at) |i| {
            _ = self.opened.swapRemove(i);
        } else self.opened.append(gpa, key) catch {};
    }
    if (at != null and !toggle) {
        if (struct_tweaks.instance(e.schemas, e.type_name)) |address| {
            _ = StructEditor.draw(&e.schemas.parsed.schema, e.type_name, address);
        } else ui.textDisabled("Not in the game yet. It shows up once the game makes it, like after loading a save.", .{});
    }
    _ = ui.tableNextColumn();
}

fn drawRow(self: *TweaksWindow, gpa: std.mem.Allocator, tweaks: *Tweaks, t: *const Info, nested: bool) void {
    ui.tableNextRow();
    _ = ui.tableNextColumn();
    if (isAction(t)) {
        if (ui.smallButton(icons.play ++ "##run")) tweaks.setOn(t.name, true);
        ui.tooltip("Runs it once", .{});
    } else {
        var on = t.on;
        // Off, with something in it on
        if (t.partial) ui.raw("ImGui_PushItemFlag")(ui.c.ImGuiItemFlags_MixedValue, true);
        const clicked = ui.checkbox("##on", &on);
        if (t.partial) ui.raw("ImGui_PopItemFlag")();
        if (clicked) tweaks.setOn(t.name, on);
        if (t.partial) ui.tooltip("Off, but something in it is on", .{});
    }

    _ = ui.tableNextColumn();
    const indent: f32 = if (nested) ui.scaled(@floatFromInt(t.depth * 16)) else 0;
    if (indent > 0) ui.indent(indent);
    defer if (indent > 0) ui.unindent(indent);
    ui.alignTextToFramePadding();
    const has_fields = !t.is_group and t.fields.len > 0;
    var open = false;
    if (t.is_group and nested) {
        const folded = self.isFolded(t.name);
        if (ui.smallButton(if (folded) icons.chevron_right ++ "##fold" else icons.chevron_down ++ "##fold")) self.fold(gpa, t.name);
        ui.sameLine();
        const bold = ui.bold();
        defer bold.end();
        ui.text("{s}", .{t.title});
    } else if (has_fields) {
        open = self.isOpen(openKey(t.name));
        var toggle = ui.smallButton(if (open) icons.chevron_down ++ "##open" else icons.chevron_right ++ "##open");
        ui.tooltip("{s}", .{if (open) "Hide its settings" else "Show its settings"});
        ui.sameLine();
        var buf: [128]u8 = undefined;
        if (ui.selectable(std.fmt.bufPrintSentinel(&buf, "{s}##title", .{t.title}, 0) catch "?", false)) toggle = true;
        if (toggle) {
            self.setOpen(gpa, openKey(t.name), !open);
            open = !open;
        }
    } else {
        ui.text("{s}", .{t.title});
    }
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

    const viewport = ui.raw("ImGui_GetMainViewport")();
    ui.raw("ImGui_SetNextWindowViewport")(viewport.*.ID);
    ui.raw("ImGui_SetNextWindowPosEx")(.{ .x = viewport.*.WorkPos.x + ui.scaled(12), .y = viewport.*.WorkPos.y + ui.scaled(40) }, ui.c.ImGuiCond_FirstUseEver, .{ .x = 0, .y = 0 });
    ui.raw("ImGui_SetNextWindowBgAlpha")(0.6);
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
        ui.textColored(colour, "{s}", .{if (isAction(t)) icons.play else if (t.on) icons.circle_check else icons.circle});
        ui.sameLine();
        ui.textColored(if (t.on) colour else dim, "{s}", .{t.title});
        if (t.key) |k| {
            ui.sameLine();
            var buf: [64]u8 = undefined;
            ui.textDisabled("{s}", .{ui.chordName(&buf, k)});
        }
    }
}
