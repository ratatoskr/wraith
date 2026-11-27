//! The project's tweaks: turn them on and off, give them keys and edit them. Groups fold, and rows
//! reorder among their siblings, laid out like the Tweaks window.

const TweaksPanel = @This();

const std = @import("std");

const devtools = @import("tuft_devtools");
const format = @import("wraith_api").tweak;
const ui = @import("wraith_ui");

const Workbench = @import("../Workbench.zig");
const Project = @import("../../../Project.zig");
const Tweaks = @import("../../../Tweaks.zig");
const TweakFields = @import("../../TweakFields.zig");
const TweakLayout = @import("../../TweakLayout.zig");
const TweakEditor = @import("../documents/TweakEditor.zig");

const Entry = TweakLayout.Entry;

const red: ui.Color = .{ 1, 0.4, 0.4, 1 };

wb: *Workbench,
picked: ui.Selection = .{},
/// The one getting a key, or about to go.
target: [256]u8 = undefined,
target_len: usize = 0,
/// The target's key input starts listening.
listen_key: bool = false,
confirm_delete: ui.Confirm = .{},
/// By `idOf`.
renaming: ?u64 = null,
rename: [64:0]u8 = @splat(0),
focus_rename: bool = false,
problem: ?devtools.Problem = null,
reorder: ui.Reorder = .{ .kind = "wraith.tweaks", .siblings_only = true },
/// Without the shell's, like in tests.
own_layout: TweakLayout = .{},
/// Values shown or hidden by hand, by `idOf`. Otherwise they show while on; toggling resets it.
values: std.AutoHashMapUnmanaged(u64, ValuesShown) = .empty,

const ValuesShown = struct { shown: bool, active: bool };

pub fn deinit(self: *TweaksPanel) void {
    self.picked.deinit();
    self.reorder.deinit();
    self.own_layout.deinit();
    self.values.deinit(self.wb.allocator);
}

fn layout(self: *TweaksPanel) *TweakLayout {
    return self.wb.tweak_layout orelse &self.own_layout;
}

fn isActive(t: *const Tweaks.Info) bool {
    return t.on or t.running or t.partial;
}

fn showsValues(self: *const TweaksPanel, t: *const Tweaks.Info) bool {
    if (self.values.get(idOf(t))) |v| if (v.active == isActive(t)) return v.shown;
    return isActive(t);
}

fn toggleValues(self: *TweaksPanel, t: *const Tweaks.Info) void {
    self.values.put(self.wb.allocator, idOf(t), .{ .shown = !self.showsValues(t), .active = isActive(t) }) catch {};
}

fn idOf(t: *const Tweaks.Info) u64 {
    return TweakLayout.tweakId(t.name);
}

fn entryId(e: *const Entry) u64 {
    return e.id;
}

pub fn draw(self: *TweaksPanel) void {
    const tweaks = self.wb.tweaks orelse {
        ui.textDisabled("No project open, so no tweaks", .{});
        return;
    };
    const project = self.wb.project.?;
    var arena: std.heap.ArenaAllocator = .init(self.wb.allocator);
    defer arena.deinit();
    const all = tweaks.snapshot(arena.allocator()) catch return;
    if (self.problem) |*p| ui.textColored(red, "{s}", .{p.message()});
    if (all.len == 0) ui.textDisabled("None yet. Right-click for a new one", .{});
    const lay = self.layout();
    const entries = lay.entries(arena.allocator(), all, &.{}) catch return;
    // Just your project's needs no heading
    var sources: usize = 0;
    for (entries) |*e| sources += @intFromBool(e.what == .source);
    const headings = sources > 1;
    // What's in something folded isn't a row
    var shown: std.ArrayList(Entry) = .empty;
    var folded_at: ?u32 = null;
    for (entries) |e| {
        if (folded_at) |d| {
            if (e.depth > d) continue;
            folded_at = null;
        }
        switch (e.what) {
            .source => if (!headings) continue,
            .section => {},
            .tweak => |t| if (!t.is_group) {
                shown.append(arena.allocator(), e) catch return;
                continue;
            },
            .structure => continue,
        }
        shown.append(arena.allocator(), e) catch return;
        if (e.folded) folded_at = e.depth;
    }
    const list = shown.items;

    if (ui.table("tweaks", 4, .{ .borders = true, .row_background = true, .resizable = true, .sizing = .stretch_prop, .scroll_y = true })) |table| {
        defer table.end();
        ui.tableColumnWith("On", .{ .fixed = true, .width = 32 });
        ui.tableColumnWith("Tweak", .{ .stretch = true, .width = 2 });
        ui.tableColumnWith("Key", .{ .fixed = true, .width = 110 });
        ui.tableColumnWith("Status", .{ .stretch = true, .width = 3 });
        ui.tableHeaders();
        self.reorder.begin();
        var picking = self.picked.begin(list.len, ui.Selection.Rows(Entry, entryId){ .rows = list }, .{});
        for (list, 0..) |*e, i| {
            const scope = ui.id(@as(i32, @intCast(i)));
            defer scope.end();
            const t = switch (e.what) {
                .tweak => |t| t,
                .source => |s| {
                    ui.tableNextRow();
                    _ = ui.tableNextColumn();
                    _ = picking.row(i, "##row");
                    self.reorder.item(.{ .id = e.id, .label = s.title });
                    _ = ui.tableNextColumn();
                    if (ui.Outline.arrow(!e.folded)) lay.toggle(e.id);
                    if (s.id.len == 0) ui.textDisabled("{s}", .{s.title}) else ui.textDisabled("From {s}", .{s.title});
                    continue;
                },
                .section => |name| {
                    ui.tableNextRow();
                    _ = ui.tableNextColumn();
                    _ = picking.row(i, "##row");
                    self.reorder.item(.{ .id = e.id, .parent = e.parent, .label = name });
                    _ = ui.tableNextColumn();
                    ui.indent(16);
                    if (ui.Outline.arrow(!e.folded)) lay.toggle(e.id);
                    ui.text("{s}", .{name});
                    ui.unindent(16);
                    continue;
                },
                .structure => continue,
            };
            ui.tableNextRow();
            _ = ui.tableNextColumn();
            _ = picking.row(i, "##row");
            self.reorder.item(.{ .id = e.id, .parent = e.parent, .label = t.title });
            ui.sameLine();
            var on = t.on;
            // Off, with something in it on
            const mixed = ui.mixedValue(t.partial);
            const clicked = ui.checkbox("##on", &on);
            mixed.end();
            if (clicked) tweaks.setOn(t.name, on);
            if (t.opens) ui.tooltip("Opens it", .{}) else if (t.mode == .action) ui.tooltip("Runs it once", .{}) else if (t.partial) ui.tooltip("Off, but something in it is on, so its shared part is up", .{});
            _ = ui.tableNextColumn();
            const indent: f32 = @floatFromInt((e.depth -| 1) * 16);
            if (indent > 0) ui.indent(indent);
            if (self.renaming == e.id) {
                self.drawRename(t);
            } else if (t.is_group) {
                if (ui.Outline.arrow(!e.folded)) lay.toggle(e.id);
                ui.text("{s}", .{t.title});
                ui.tooltip("A group, in {s}. Its box turns it on, and @children says what that does to what's in it. Its shared part is up while it or anything in it is on", .{t.path});
            } else {
                if (t.fields.len > 0) {
                    if (ui.Outline.arrow(self.showsValues(t))) self.toggleValues(t);
                    ui.tooltip("{s} its values. They show while it's on", .{if (self.showsValues(t)) "Hides" else "Shows"});
                } else ui.Outline.noArrow();
                ui.text("{s}", .{t.title});
                if (t.source != .project) ui.tooltip("{s}'s, so it has no file to edit", .{t.source_title}) else if (t.group == null and !std.mem.eql(u8, t.title, t.name)) ui.tooltip("{s}", .{t.path});
            }
            if (indent > 0) ui.unindent(indent);
            _ = ui.tableNextColumn();
            var key = t.key;
            const listen = self.listen_key and std.mem.eql(u8, self.targetName(), t.name);
            if (listen) self.listen_key = false;
            ui.setNextItemWidth(ui.fill);
            if (ui.chordInput("##key", &key, .{ .listen = listen, .none = "none" })) tweaks.setKey(t.name, key);
            if (t.key != null and !ui.listeningForKeys()) ui.tooltip("{s}. Click to change it", .{if (t.own_key) "Yours" else "The project's"});
            _ = ui.tableNextColumn();
            if (t.is_group) drawGroupStatus(t, all) else drawStatus(t);
            if (self.showsValues(t) and !(t.is_group and e.folded)) drawFields(tweaks, t);
        }
        picking.end();
    }
    // After the table, not in it, or its items can't be clicked
    self.commands(tweaks, project, all);
    if (self.reorder.take()) |move| _ = lay.apply(entries, move);
    self.drawDelete(project, all);
}

fn focusedTweak(self: *const TweaksPanel, list: []const Tweaks.Info) ?*const Tweaks.Info {
    const id = self.picked.focused() orelse return null;
    for (list) |*t| if (idOf(t) == id) return t;
    return null;
}

fn drawStatus(t: *const Tweaks.Info) void {
    if (t.problem) |p| {
        const first = p[0 .. std.mem.indexOfScalar(u8, p, '\n') orelse p.len];
        ui.textColored(red, "{s}", .{first});
        ui.tooltip("{s}", .{p});
    } else if (t.running) {
        ui.text("on", .{});
    } else if (t.on) {
        ui.textDisabled("starting", .{});
    } else {
        ui.textDisabled("{s}", .{if (t.opens) "opens" else if (t.mode == .action) "runs once" else "off"});
    }
}

/// Its problem, else whether it's up and how many of the tweaks in it are on.
fn drawGroupStatus(g: *const Tweaks.Info, all: []const Tweaks.Info) void {
    if (g.problem != null) return drawStatus(g);
    if (!g.running) return ui.textDisabled("{s}", .{if (g.on) "starting" else "off"});
    var on: usize = 0;
    var count: usize = 0;
    const at = for (all, 0..) |t, k| {
        if (std.mem.eql(u8, t.name, g.name)) break k;
    } else all.len;
    for (all[@min(at + 1, all.len)..]) |t| {
        if (t.depth <= g.depth) break;
        if (t.is_group or t.mode == .action) continue;
        count += 1;
        on += @intFromBool(t.running);
    }
    const lead = if (g.on) "on" else "up for what's in it";
    if (count == 0) return ui.text("{s}", .{lead});
    ui.text("{s}, {d} of {d} on", .{ lead, on, count });
}

/// A row for each, under the tweak's.
fn drawFields(tweaks: *Tweaks, t: *const Tweaks.Info) void {
    const indent: f32 = @floatFromInt(12 + t.depth * 16);
    for (t.fields, 0..) |*f, i| {
        const scope = ui.id(@as(i32, @intCast(i)));
        defer scope.end();
        ui.tableNextRow();
        _ = ui.tableNextColumn();
        _ = ui.tableNextColumn();
        ui.indent(indent);
        ui.textDisabled("{s}", .{f.label});
        ui.unindent(indent);
        _ = ui.tableNextColumn();
        if (f.key) |k| ui.textDisabled("{f}", .{k});
        _ = ui.tableNextColumn();
        ui.setNextItemWidth(ui.fill);
        if (TweakFields.control(f, "##value")) |v| tweaks.setValue(t.name, f.name, v);
        TweakFields.tip(f);
    }
}

fn commands(self: *TweaksPanel, tweaks: *Tweaks, project: *Project, list: []const Tweaks.Info) void {
    const keys = &devtools.keys;
    var menu = ui.commands("tweaks", .{ .activated = self.picked.activated });
    defer menu.end();
    const one = self.focusedTweak(list);
    // A plugin's or an installed mod's has no file in the project
    const file = if (one) |t| t.source == .project else false;
    // Renaming or deleting goes for a group's whole file
    const whole = file and one.?.group == null;
    const any = self.picked.count() > 0;
    if (menu.item(.{ .label = "Edit", .enabled = file, .default = true })) self.wb.openTweak(one.?.path);
    var all_on = any;
    for (list) |*t| if (self.picked.contains(idOf(t)) and !t.on) {
        all_on = false;
    };
    if (menu.item(.{ .label = if (all_on) "Turn off" else "Turn on", .chord = keys.hold, .enabled = any })) {
        for (list) |*t| if (self.picked.contains(idOf(t))) tweaks.setOn(t.name, !all_on);
    }
    if (menu.item(.{ .label = "Run again", .chord = keys.run, .enabled = one != null and (one.?.on or one.?.partial), .tooltip = "As it is now, saved or not" })) tweaks.rerun(one.?.name);
    if (menu.item(.{ .label = "Reset values", .enabled = one != null and one.?.fields.len > 0, .tooltip = "Back to the tweak's own" })) {
        for (one.?.fields) |f| tweaks.resetValue(one.?.name, f.name);
    }
    const shown = one != null and self.showsValues(one.?);
    if (menu.item(.{ .label = if (shown) "Hide values" else "Show values", .enabled = one != null and one.?.fields.len > 0, .tooltip = "They show while it's on and hide while it's off, unless you say" })) self.toggleValues(one.?);
    menu.separator();
    if (menu.item(.{ .label = "New tweak", .chord = keys.new_entry })) self.wb.openNewTweak(.tweak);
    if (menu.item(.{ .label = "New group", .tooltip = "A file of tweaks that share data and code, with a group nested in it" })) self.wb.openNewTweak(.group);
    if (menu.item(.{ .label = "Rename", .chord = keys.edit, .enabled = whole })) {
        self.renaming = idOf(one.?);
        _ = std.fmt.bufPrintSentinel(&self.rename, "{s}", .{one.?.name}, 0) catch {};
        self.focus_rename = true;
    }
    if (menu.item(.{ .label = "Delete", .chord = keys.delete, .enabled = file })) {
        self.setTarget(one.?.name);
        self.confirm_delete.open();
    }
    menu.separator();
    if (menu.item(.{ .label = "Set key", .enabled = one != null, .tooltip = "Yours, over the project's" })) {
        self.setTarget(one.?.name);
        self.listen_key = true;
    }
    if (menu.item(.{ .label = "Remove key", .enabled = one != null and one.?.key != null, .tooltip = "Leaves it with none, even if the project has one" })) tweaks.setKey(one.?.name, null);
    if (menu.item(.{ .label = "Use the project's key", .enabled = one != null and one.?.own_key })) tweaks.clearKey(one.?.name);
    const project_keys = tweaks.projectKeys();
    if (menu.item(.{ .label = if (project_keys) "Ignore project keys" else "Use project keys", .tooltip = "The keys the project suggests. Yours always count" })) tweaks.setProjectKeys(!project_keys);
    menu.separator();
    const files = self.wb.io != null;
    if (menu.item(.{ .label = "Export...", .chord = keys.export_file, .enabled = files and file, .tooltip = "To a .rwt file of its own" })) exportTweak(self.wb, one.?.path);
    if (menu.item(.{ .label = "Import...", .chord = keys.import_file, .enabled = files, .tooltip = "A .rwt file, into the project. It starts off" })) {
        if (self.wb.importFile(Workbench.FileType.tweak, "tweaks")) |path| {
            defer project.allocator.free(path);
            self.wb.openTweak(path);
        }
    }
    menu.separator();
    self.reorder.commands(&menu, self.picked.focused(), .{ .up = keys.move_up, .down = keys.move_down });
}

/// Asks where, then writes the tweak at `path` there. Its editor's text is in the project by then.
pub fn exportTweak(wb: *Workbench, path: []const u8) void {
    const project = wb.project orelse return;
    wb.flushEditors();
    const text = (project.read(wb.allocator, path) catch null) orelse return;
    defer wb.allocator.free(text);
    wb.exportText(Workbench.FileType.tweak, std.fs.path.basename(path), text);
}

fn setTarget(self: *TweaksPanel, name: []const u8) void {
    self.target_len = @min(name.len, self.target.len);
    @memcpy(self.target[0..self.target_len], name[0..self.target_len]);
}

fn targetName(self: *const TweaksPanel) []const u8 {
    return self.target[0..self.target_len];
}

/// `tweaks/tweak.rwt`, or `tweak_2` and so on if that's taken.
fn drawRename(self: *TweaksPanel, t: *const Tweaks.Info) void {
    if (self.focus_rename) {
        self.focus_rename = false;
        ui.focusNext();
    }
    ui.setNextItemWidth(ui.fill);
    const entered = ui.inputTextWith("##rename", &self.rename, .{ .flags = .{ .enter_returns_true = true, .auto_select_all = true }, .tight = true });
    if (entered) {
        self.renameTo(t, std.mem.trim(u8, std.mem.sliceTo(&self.rename, 0), " "));
        self.renaming = null;
    } else if (ui.isItemDeactivated()) self.renaming = null;
}

fn renameTo(self: *TweaksPanel, t: *const Tweaks.Info, to: []const u8) void {
    if (to.len == 0 or std.mem.eql(u8, to, t.name)) return;
    if (std.mem.indexOfAny(u8, to, "/\\:*?\"<>|") != null) {
        self.problem = .init("A name can't have / \\ : * ? \" < > |", .{});
        return;
    }
    const project = self.wb.project orelse return;
    const tweaks = self.wb.tweaks orelse return;
    var buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "tweaks/{s}{s}", .{ to, Project.ext.tweak }) catch return;
    const gpa = self.wb.allocator;
    if (project.read(gpa, path) catch null) |there| {
        gpa.free(there);
        self.problem = .init("There's a tweak called {s} already", .{to});
        return;
    }
    self.wb.flushEditors();
    self.wb.closeTweak(t.path);
    const text = (project.read(gpa, t.path) catch null) orelse return;
    defer gpa.free(text);
    const was_on = t.on;
    tweaks.setOn(t.name, false);
    project.write(path, text) catch |err| {
        self.problem = .init("Couldn't rename it: {t}", .{err});
        return;
    };
    project.delete(t.path);
    self.problem = null;
    if (was_on) tweaks.setOn(to, true);
}

fn drawDelete(self: *TweaksPanel, project: *Project, all: []const Tweaks.Info) void {
    const t = for (all) |*x| {
        if (std.mem.eql(u8, x.name, self.targetName())) break x;
    } else null;
    const what = if (t) |x| x.title else self.targetName();
    const from = if (t != null and t.?.part.len > 0) " from its group's file" else "";
    if (!self.confirm_delete.draw("Delete tweak##tweak", "Delete {s}{s}?", .{ what, from }, .{ .yes = "Delete" })) return;
    const tweaks = self.wb.tweaks orelse return;
    const it = t orelse return;
    tweaks.turnOff(it.name);
    if (it.part.len == 0) {
        self.wb.closeTweak(it.path);
        project.delete(it.path);
        return;
    }
    // A part of a group's file. Cut it out of the file, and its editor picks that up
    self.wb.flushEditors();
    const gpa = self.wb.allocator;
    const text = (project.read(gpa, it.path) catch null) orelse return;
    defer gpa.free(text);
    var problem: format.Problem = .{};
    const cut = format.removePart(gpa, text, it.part, &problem) catch |err| {
        self.problem = if (err == error.Invalid) .init("Couldn't delete {s}: {s}", .{ it.title, problem.message() }) else .init("Couldn't delete {s}: {t}", .{ it.title, err });
        return;
    };
    defer gpa.free(cut);
    project.write(it.path, cut) catch |err| {
        self.problem = .init("Couldn't delete {s}: {t}", .{ it.title, err });
        return;
    };
    self.problem = null;
}
