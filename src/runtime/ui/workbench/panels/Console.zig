//! What script sessions printed.

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

pub fn deinit(self: *Console) void {
    self.picked.deinit();
    self.shown.deinit(self.wb.allocator);
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

    if (ui.child("lines", .{ 0, 0 }, .{ .border = true, .horizontal_scrollbar = true })) |child| {
        defer child.end();
        if (self.shown.items.len == 0) ui.textDisabled("Nothing yet. Run a Script document (View > New script)", .{});
        var picking = self.picked.begin(self.shown.items.len, Shown{ .console = self }, .{});
        var rows = ui.clip(self.shown.items.len);
        rows.include(picking.keep());
        while (rows.next()) |row| line(&picking, row, self.lineAt(row), self.only == null);
        picking.end();
        if (self.follow and added and ui.getScrollY() >= ui.getScrollMaxY() - ui.getTextLineHeightWithSpacing() * 2) ui.setScrollHereY(1);

        var menu = ui.commands("console", .{});
        defer menu.end();
        if (menu.item(.{ .label = "Copy", .chord = devtools.keys.copy, .enabled = self.picked.count() > 0 })) self.copy();
        menu.separator();
        if (menu.item(.{ .label = "Clear" })) {
            scripts.clearConsole();
            self.picked.clear();
        }
    }
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
    const coloured = ui.withColor(ui.c.ImGuiCol_Text, colour);
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
