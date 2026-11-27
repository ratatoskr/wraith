//! Breakpoints, each stopping its thread, every game thread, or nothing.

const BreakpointsPanel = @This();

const std = @import("std");
const Names = @import("../../../Names.zig");

const devtools = @import("tuft_devtools");
const Debugger = @import("tuft_hook").Debugger;
const Symbols = @import("tuft_mem").Symbols;
const ui = @import("wraith_ui");

const Workbench = @import("../Workbench.zig");
const Clip = @import("wraith_ui").Clip;

const Breakpoint = Debugger.Breakpoint;

wb: *Workbench,
infos: [Debugger.max_breakpoints]Breakpoint = undefined,
len: usize = 0,
picked: ui.Selection = .{},
problem: ?devtools.Problem = null,

pub fn deinit(self: *BreakpointsPanel) void {
    self.picked.deinit();
}

pub fn draw(self: *BreakpointsPanel) void {
    self.len = self.wb.debugger.list(&self.infos);
    const infos = self.infos[0..self.len];
    if (self.problem) |*p| ui.textColored(.{ 1, 0.4, 0.4, 1 }, "{s}", .{p.message()});
    if (infos.len == 0) ui.textDisabled("None. Select an instruction in a Disassembly and press F9, or Shift+F9 for a hardware one", .{});

    if (ui.table("breakpoints", 5, .{ .borders = true, .row_background = true, .resizable = true, .sizing = .stretch_prop, .scroll_y = true })) |table| {
        defer table.end();
        ui.tableColumnWith("Where", .{ .stretch = true, .width = 3 });
        ui.tableColumnWith("Kind", .{ .fixed = true, .width = 80 });
        ui.tableColumnWith("Stops", .{ .fixed = true, .width = 100 });
        ui.tableColumnWith("Hits", .{ .fixed = true, .width = 70 });
        ui.tableColumnWith("State", .{ .fixed = true, .width = 70 });
        ui.tableHeaders();
        var picking = self.picked.begin(infos.len, ui.Selection.Rows(Breakpoint, idOf){ .rows = infos }, .{});
        for (infos, 0..) |*b, i| {
            const scope = ui.id(@as(i32, @truncate(@as(isize, @bitCast(b.address)))));
            defer scope.end();
            ui.tableNextRow();
            _ = ui.tableNextColumn();
            var buf: [300]u8 = undefined;
            _ = picking.row(i, ui.format("{s}", .{Names.global.describe(b.address, &buf) orelse ui.format("0x{x}", .{b.address})}));
            _ = ui.tableNextColumn();
            ui.text("{t}", .{b.kind});
            _ = ui.tableNextColumn();
            ui.text("{s}", .{stopLabel(b.stop)});
            _ = ui.tableNextColumn();
            ui.text("{d}", .{b.hits});
            _ = ui.tableNextColumn();
            if (b.enabled) ui.text("on", .{}) else ui.textDisabled("off", .{});
        }
        picking.end();
    }
    // After the table, not in it, or its items can't be clicked
    self.commands(infos);
}

pub fn stopLabel(stop: Debugger.Stop) []const u8 {
    return switch (stop) {
        .thread => "its thread",
        .all => "everything",
        .none => "nothing",
    };
}

fn commands(self: *BreakpointsPanel, infos: []const Breakpoint) void {
    const keys = &devtools.keys;
    const d = &self.wb.debugger;
    var menu = ui.commands("breakpoints", .{ .activated = self.picked.activated });
    defer menu.end();
    const one = self.picked.focused();
    const any = self.picked.count() > 0;
    if (menu.item(.{ .label = "Show as code", .chord = keys.show_code, .enabled = one != null, .default = true })) self.wb.openCode(@intCast(one.?));
    menu.separator();
    var all_on = true;
    for (infos) |b| if (self.picked.contains(b.address) and !b.enabled) {
        all_on = false;
    };
    if (menu.item(.{ .label = if (all_on) "Disable" else "Enable", .chord = keys.enable_breakpoint, .enabled = any, .tooltip = "A disabled one puts the code back or gives up its debug register" })) {
        self.problem = null;
        for (infos) |b| if (self.picked.contains(b.address)) {
            d.setEnabled(b.address, !all_on) catch |err| {
                self.problem = .init("Couldn't enable 0x{x}: {t}", .{ b.address, err });
            };
        };
    }
    inline for (.{
        .{ Debugger.Stop.thread, "Stop its thread", "Just the thread that hits it stops. The game carries on" },
        .{ Debugger.Stop.all, "Stop everything", "The thread that hits it stops and the game's other threads freeze" },
        .{ Debugger.Stop.none, "Only count hits", "Nothing stops" },
    }) |choice| {
        if (menu.item(.{ .label = choice[1], .enabled = any, .tooltip = choice[2] })) {
            for (infos) |b| if (self.picked.contains(b.address)) d.setStop(b.address, choice[0]);
        }
    }
    menu.separator();
    inline for (.{
        .{ Debugger.Kind.software, "Make software", "An int3 in the code. As many as you like" },
        .{ Debugger.Kind.hardware, "Make hardware", "One of the CPU's four debug registers. Leaves the code alone, for games that check it" },
    }) |choice| {
        if (menu.item(.{ .label = choice[1], .enabled = any, .tooltip = choice[2] })) {
            self.problem = null;
            for (infos) |b| if (self.picked.contains(b.address)) {
                self.wb.setBreakpointKind(b.address, choice[0]) catch |err| {
                    self.problem = .init("Couldn't change 0x{x}: {t}", .{ b.address, err });
                };
            };
        }
    }
    menu.separator();
    if (menu.item(.{ .label = "Copy address", .chord = keys.copy_address, .enabled = any })) {
        var clip: Clip = .{};
        for (infos) |b| if (self.picked.contains(b.address)) clip.line("0x{x}", .{b.address});
        clip.copy();
    }
    if (menu.item(.{ .label = "Delete", .chord = keys.delete, .enabled = any })) {
        for (infos) |b| if (self.picked.contains(b.address)) d.remove(b.address);
        self.picked.clear();
    }
    if (menu.item(.{ .label = "Delete all", .chord = keys.delete_all_breakpoints, .global = true, .enabled = infos.len > 0 })) {
        self.wb.deleteAllBreakpoints();
        self.picked.clear();
    }
}

fn idOf(b: *const Breakpoint) u64 {
    return b.address;
}
