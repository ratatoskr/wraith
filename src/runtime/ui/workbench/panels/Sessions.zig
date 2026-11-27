//! Every script session and what it has going, even after its document closes.

const SessionsPanel = @This();

const std = @import("std");

const devtools = @import("tuft_devtools");
const ui = @import("wraith_ui");

const Workbench = @import("../Workbench.zig");
const Scripts = @import("../Scripts.zig");
const Clip = @import("wraith_ui").Clip;

wb: *Workbench,
picked: ui.Selection = .{},

pub fn deinit(self: *SessionsPanel) void {
    self.picked.deinit();
}

pub fn draw(self: *SessionsPanel) void {
    const scripts = &self.wb.scripts;
    const sessions = scripts.sessions.items;
    if (sessions.len == 0) ui.textDisabled("No sessions. Each Script document has one (View > New script)", .{});

    if (ui.table("sessions", 7, .{ .borders = true, .row_background = true, .resizable = true, .sizing = .stretch_prop, .scroll_y = true })) |table| {
        defer table.end();
        ui.tableColumnWith("Session", .{ .stretch = true, .width = 3 });
        ui.tableColumnWith("State", .{ .fixed = true, .width = 80 });
        inline for (.{ "Frames", "Keybinds", "Messages", "Hooks" }) |label| ui.tableColumnWith(label, .{ .fixed = true, .width = 70 });
        ui.tableColumnWith("Document", .{ .fixed = true, .width = 80 });
        ui.tableHeaders();
        var picking = self.picked.begin(sessions.len, ui.Selection.Rows(Scripts.Session, idOf){ .rows = sessions }, .{});
        for (sessions, 0..) |*s, i| {
            const scope = ui.id(@as(i32, @intCast(s.id)));
            defer scope.end();
            ui.tableNextRow();
            _ = ui.tableNextColumn();
            _ = picking.row(i, ui.format("{s}", .{s.label()}));
            _ = ui.tableNextColumn();
            if (s.pending != null) {
                ui.textDisabled("waiting", .{});
            } else if (s.running) |r| {
                if (r.total() > 0) ui.textColored(.{ 0.4, 0.9, 0.4, 1 }, "running", .{}) else ui.text("idle", .{});
            } else {
                ui.textDisabled("not started", .{});
            }
            const r: @import("wraith_api").script.Running = s.running orelse .{ .session = s.id };
            inline for (.{ "frames", "keybinds", "hooks" }) |field| {
                _ = ui.tableNextColumn();
                const n = @field(r, field);
                if (n == 0) ui.textDisabled("-", .{}) else ui.text("{d}", .{n});
            }
            _ = ui.tableNextColumn();
            if (self.wb.scriptDocument(s.id) != null) ui.text("open", .{}) else ui.textDisabled("closed", .{});
        }
        picking.end();
    }
    // After the table, not in it, or its items can't be clicked
    self.commands();
}

fn commands(self: *SessionsPanel) void {
    const scripts = &self.wb.scripts;
    const keys = &devtools.keys;
    var menu = ui.commands("sessions", .{ .activated = self.picked.activated });
    defer menu.end();
    const one = self.picked.focused();
    const any = self.picked.count() > 0;
    if (menu.item(.{ .label = "Open", .enabled = one != null, .default = true, .tooltip = "Its document, or a new one with what it last ran" })) self.wb.openScript(@intCast(one.?));
    if (menu.item(.{ .label = "Reset", .enabled = any, .tooltip = "Stop what they started, like their windows, and forget their variables" })) {
        for (scripts.sessions.items) |s| if (self.picked.contains(s.id)) scripts.reset(s.id);
    }
    if (menu.item(.{ .label = "Stop", .chord = keys.delete, .enabled = any, .tooltip = "End them and close their documents" })) {
        // From the end, since stopping drops them
        var i = scripts.sessions.items.len;
        while (i > 0) {
            i -= 1;
            const id = scripts.sessions.items[i].id;
            if (!self.picked.contains(id)) continue;
            self.wb.closeScript(id);
            scripts.stop(id);
        }
    }
    menu.separator();
    if (menu.item(.{ .label = "Copy code", .chord = keys.copy, .enabled = one != null, .tooltip = "What it last ran" })) {
        if (scripts.find(@intCast(one.?))) |s| {
            var clip: Clip = .{};
            clip.line("{s}", .{s.code});
            clip.copy();
        }
    }
    menu.separator();
    if (menu.item(.{ .label = "New script" })) self.wb.openNew(.script);
}

fn idOf(s: *const Scripts.Session) u64 {
    return s.id;
}
