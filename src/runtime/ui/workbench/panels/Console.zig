//! What script sessions printed, and a prompt under it to type JS or Lua into, like a REPL. It
//! runs in a Console session of its own for each language, or in any script's session. Enter runs
//! it, Shift+Enter adds a line and Up and Down go back through what ran.

const Console = @This();

const std = @import("std");

const devtools = @import("tuft_devtools");
const ui = @import("wraith_ui");

const Workbench = @import("../Workbench.zig");
const Scripts = @import("../Scripts.zig");
const Clip = @import("../Clip.zig");

window: ui.Window = .{ .title = "Console", .size = .{ 700, 300 }, .min_size = .{ 300, 120 } },
wb: *Workbench,
only: ?u32 = null,
follow: bool = true,
seen_changes: u32 = 0,
picked: ui.Selection = .{},
shown: std.ArrayList(u32) = .empty,
prompt: ui.Prompt = .{},
/// What the prompt runs in.
target: Target = .{ .console = .js },
/// The Console's own sessions, made the first time they're used.
own: std.EnumArray(Scripts.Language, ?u32) = .initFill(null),
/// Something ran from the prompt, so the lines go to the end.
ran: bool = false,

const Target = union(enum) {
    console: Scripts.Language,
    session: u32,
};

pub fn deinit(self: *Console) void {
    self.picked.deinit();
    self.shown.deinit(self.wb.allocator);
    self.prompt.deinit();
}

pub fn draw(self: *Console) void {
    const scripts = &self.wb.scripts;
    self.drawFilter(scripts);

    self.shown.clearRetainingCapacity();
    for (scripts.console.items, 0..) |l, i| {
        if (self.only) |id| if (l.session != id) continue;
        self.shown.append(self.wb.allocator, @intCast(i)) catch break;
    }
    const added = scripts.console_changes != self.seen_changes;
    self.seen_changes = scripts.console_changes;

    // Room under it for the prompt
    const footer = self.prompt.height() + ui.scaled(ui.getStyle().item_spacing[1]);
    if (ui.child("lines", .{ 0, -footer }, .{ .border = true, .horizontal_scrollbar = true })) |child| {
        defer child.end();
        if (self.shown.items.len == 0) ui.textDisabled("Nothing yet. Type JS or Lua below, or run a Script document (View > New script)", .{});
        var picking = self.picked.begin(self.shown.items.len, Shown{ .console = self }, .{});
        var rows = ui.clip(self.shown.items.len);
        rows.include(picking.keep());
        while (rows.next()) |row| line(&picking, row, self.lineAt(row), self.only == null);
        picking.end();
        const at_end = ui.getScrollY() >= ui.getScrollMaxY() - ui.getTextLineHeightWithSpacing() * 2;
        if ((self.follow and added and at_end) or (self.ran and added)) {
            ui.setScrollHereY(1);
            self.ran = false;
        }

        var menu = ui.commands("console", .{});
        defer menu.end();
        if (menu.item(.{ .label = "Copy", .chord = devtools.keys.copy, .enabled = self.picked.count() > 0 })) self.copy();
        menu.separator();
        if (menu.item(.{ .label = "Clear" })) {
            scripts.clearConsole();
            self.picked.clear();
        }
    }
    self.drawPrompt(scripts);
}

/// Where it runs, then what to run.
fn drawPrompt(self: *Console, scripts: *Scripts) void {
    var names: [34][:0]const u8 = undefined;
    var bufs: [34][96]u8 = undefined;
    var targets: [34]Target = undefined;
    var n: usize = 0;
    for (std.enums.values(Scripts.Language)) |l| {
        names[n] = std.fmt.bufPrintSentinel(&bufs[n], "{s} console", .{l.title()}, 0) catch continue;
        targets[n] = .{ .console = l };
        n += 1;
    }
    var current: usize = 0;
    for (scripts.sessions.items) |*s| {
        if (n == names.len) break;
        if (self.isOwn(s.id)) continue;
        names[n] = std.fmt.bufPrintSentinel(&bufs[n], "{s} ({s})##{d}", .{ s.label(), s.language.title(), s.id }, 0) catch continue;
        targets[n] = .{ .session = s.id };
        n += 1;
    }
    for (targets[0..n], 0..) |t, i| if (std.meta.eql(t, self.target)) {
        current = i;
    };
    // The session went
    if (self.target == .session and current == 0) self.target = .{ .console = .js };
    ui.setNextItemWidth(170);
    if (ui.combo("##run_in", &current, names[0..n])) self.target = targets[current];
    ui.tooltip("What it runs in. A script's session has what it made", .{});
    ui.sameLine();
    const hint = switch (self.language(scripts)) {
        .js => "JavaScript. Enter runs it, Shift+Enter for a new line, Up for what ran",
        .lua => "Lua. Enter runs it, Shift+Enter for a new line, Up for what ran",
    };
    if (self.prompt.draw("##prompt", hint)) |code| self.enter(code);
}

/// Runs `code` as if it was typed at the prompt.
pub fn enter(self: *Console, code: []const u8) void {
    const scripts = &self.wb.scripts;
    const id = self.sessionFor(scripts) orelse return;
    scripts.eval(id, code);
    self.ran = true;
    // Its lines show even if the list was on another session's
    if (self.only) |only| if (only != id) {
        self.only = id;
    };
}

fn isOwn(self: *const Console, id: u32) bool {
    for (self.own.values) |o| if (o == id) return true;
    return false;
}

fn language(self: *const Console, scripts: *Scripts) Scripts.Language {
    return switch (self.target) {
        .console => |l| l,
        .session => |id| if (scripts.find(id)) |s| s.language else .js,
    };
}

/// Made the first time, and again if it was stopped.
fn sessionFor(self: *Console, scripts: *Scripts) ?u32 {
    switch (self.target) {
        .session => |id| if (scripts.find(id) != null) return id,
        .console => {},
    }
    const l = self.language(scripts);
    if (self.own.get(l)) |id| if (scripts.find(id) != null) return id;
    var buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "{s} console", .{l.title()}) catch "Console";
    const id = scripts.newSession(name) catch return null;
    scripts.setLanguage(id, l);
    self.own.set(l, id);
    return id;
}

fn drawFilter(self: *Console, scripts: *Scripts) void {
    var names: [33][:0]const u8 = undefined;
    var bufs: [33][80]u8 = undefined;
    var ids: [33]?u32 = undefined;
    names[0] = "All sessions";
    ids[0] = null;
    var n: usize = 1;
    var current: usize = 0;
    for (scripts.sessions.items) |*s| {
        if (n == names.len) break;
        names[n] = std.fmt.bufPrintSentinel(&bufs[n], "{s}##{d}", .{ s.label(), s.id }, 0) catch continue;
        ids[n] = s.id;
        if (self.only == s.id) current = n;
        n += 1;
    }
    // The session went
    if (self.only != null and current == 0) self.only = null;
    ui.setNextItemWidth(200);
    if (ui.combo("##session", &current, names[0..n])) self.only = ids[current];
    ui.sameLine();
    _ = ui.checkbox("Follow", &self.follow);
}

const Shown = struct {
    console: *const Console,

    pub fn id(self: Shown, row: usize) u64 {
        return self.console.lineAt(row).seq;
    }
};

fn lineAt(self: *const Console, row: usize) *const Scripts.Line {
    return &self.wb.scripts.console.items[self.shown.items[row]];
}

fn line(picking: anytype, row: usize, l: *const Scripts.Line, with_session: bool) void {
    // Packed ABGR, like ImGui's
    const colour: ?u32 = switch (l.kind) {
        .thrown, .err => 0xFF6666FF,
        .warn => 0xFF4DCCFF,
        .code, .debug => ui.getColorU32(.text_disabled),
        .value, .info => null,
    };
    const coloured = ui.withColor(.text, colour);
    defer coloured.end();
    const prefix = if (l.kind == .code) "> " else "";
    if (with_session) {
        _ = picking.row(row, ui.format("[{d}] {s}{s}##{d}", .{ l.session, prefix, l.text, l.seq }));
    } else {
        _ = picking.row(row, ui.format("{s}{s}##{d}", .{ prefix, l.text, l.seq }));
    }
}

fn copy(self: *Console) void {
    var clip: Clip = .{};
    for (0..self.shown.items.len) |row| {
        const l = self.lineAt(row);
        if (self.picked.contains(l.seq)) clip.line("{s}", .{l.text});
    }
    clip.copy();
}
