//! Threads stopped at a breakpoint, a step or a crash. Registers shows the picked one's.

const Stopped = @This();

const std = @import("std");
const Names = @import("../../../Names.zig");

const devtools = @import("tuft_devtools");
const Debugger = @import("tuft_hook").Debugger;
const Symbols = @import("tuft_mem").Symbols;
const sys = @import("tuft_sys");
const ui = @import("wraith_ui");

const Workbench = @import("../Workbench.zig");
const Breakpoints = @import("Breakpoints.zig");
const CrashReport = @import("../../../crash/Report.zig");
const Clip = @import("wraith_ui").Clip;

const Paused = Debugger.Paused;

wb: *Workbench,
threads: [Debugger.max_paused]Paused = undefined,
len: usize = 0,
/// By thread id, so a pick stays through steps.
picked: ui.Selection = .{},

pub fn deinit(self: *Stopped) void {
    self.picked.deinit();
}

pub fn draw(self: *Stopped) void {
    const d = &self.wb.debugger;
    self.len = d.paused(&self.threads);
    const threads = self.threads[0..self.len];
    self.drawStatus(d);
    if (self.focused(threads)) |p| if (p.crash) |crash| drawCrash(p, crash);

    if (ui.child("stopped_list", .{ 0, 0 }, .{})) |region| {
        defer region.end();
        if (ui.table("stopped", 5, .{ .borders = true, .row_background = true, .resizable = true, .sizing = .stretch_prop, .scroll_y = true })) |table| {
            defer table.end();
            ui.tableColumnWith("Thread", .{ .fixed = true, .width = 80 });
            ui.tableColumnWith("Where", .{ .stretch = true, .width = 3 });
            ui.tableColumnWith("Why", .{ .fixed = true, .width = 80 });
            ui.tableColumnWith("Stops", .{ .fixed = true, .width = 90 });
            ui.tableColumnWith("For", .{ .fixed = true, .width = 60 });
            ui.tableHeaders();
            var picking = self.picked.begin(threads.len, ui.Selection.Rows(Paused, threadOf){ .rows = threads }, .{});
            const now = sys.thread.tickMs();
            for (threads, 0..) |*p, i| {
                const scope = ui.id(@as(i32, @intCast(p.thread_id)));
                defer scope.end();
                ui.tableNextRow();
                _ = ui.tableNextColumn();
                _ = picking.row(i, ui.format("{d}", .{p.thread_id}));
                _ = ui.tableNextColumn();
                var buf: [300]u8 = undefined;
                ui.text("{s}", .{Names.global.describe(p.cpu.ip(), &buf) orelse ui.format("0x{x}", .{p.cpu.ip()})});
                _ = ui.tableNextColumn();
                ui.text("{t}", .{p.reason});
                _ = ui.tableNextColumn();
                ui.text("{s}", .{Breakpoints.stopLabel(p.stop)});
                _ = ui.tableNextColumn();
                ui.text("{d:.0}s", .{@as(f64, @floatFromInt(now -% p.since_ms)) / 1000});
            }
            picking.end();
        }
        // After the table, not in it, or its items can't be clicked
        self.commands(threads);
    }
}

fn drawStatus(self: *Stopped, d: *Debugger) void {
    _ = self;
    switch (d.freezeState()) {
        .frozen => ui.textColored(.{ 1, 0.8, 0.3, 1 }, "The game's frozen until the thread that stopped it goes", .{}),
        .failed => ui.textColored(.{ 1, 0.4, 0.4, 1 }, "Couldn't freeze the game's other threads. Trying again", .{}),
        .idle => {},
    }
    const rescues = d.rescues();
    if (rescues > 0) {
        ui.textDisabled("Let everything go {d} time(s) because the workbench stopped responding", .{rescues});
        ui.tooltip("A stopped or frozen thread was probably holding something the workbench needed, like the heap's lock", .{});
    }
}

fn commands(self: *Stopped, threads: []const Paused) void {
    const keys = &devtools.keys;
    const d = &self.wb.debugger;
    var menu = ui.commands("stopped", .{ .activated = self.picked.activated });
    defer menu.end();
    const one = self.focused(threads);
    const any = self.picked.count() > 0 or one != null;
    if (menu.item(.{ .label = "Show as code", .chord = keys.show_code, .enabled = one != null, .default = true })) self.wb.openCode(one.?.cpu.ip());
    if (menu.item(.{ .label = "Continue", .chord = keys.continue_thread, .global = true, .enabled = any, .tooltip = "Let the picked threads go. The key lets the focused one go, from anywhere" })) {
        if (self.picked.count() == 0) _ = d.resumeThread(one.?.id, .run);
        for (threads) |p| if (self.picked.contains(p.thread_id)) {
            _ = d.resumeThread(p.id, .run);
        };
    }
    const crashed = one != null and one.?.reason == .crash;
    if (menu.item(.{ .label = "Step into", .chord = keys.step_into, .global = true, .enabled = one != null and !crashed, .tooltip = "Run its next instruction and stop again" })) {
        _ = d.resumeThread(one.?.id, .step);
    }
    if (menu.item(.{ .label = "Step over", .chord = keys.step_over, .global = true, .enabled = one != null and !crashed, .tooltip = "Like step into, but a call runs through to where it returns" })) {
        _ = d.resumeThread(one.?.id, .step_over);
    }
    if (menu.item(.{ .label = "Skip instruction", .enabled = crashed, .tooltip = "Go on after the instruction that crashed, as if it worked" })) {
        _ = d.resumeThread(one.?.id, .skip);
    }
    if (menu.item(.{ .label = "Let it crash", .enabled = crashed, .tooltip = "Hand the crash on to the game, which usually closes it" })) {
        _ = d.resumeThread(one.?.id, .crash);
    }
    if (menu.item(.{ .label = "Continue all", .enabled = threads.len > 0 })) d.resumeAll();
    menu.separator();
    if (menu.item(.{ .label = "Copy address", .chord = keys.copy_address, .enabled = any })) {
        var clip: Clip = .{};
        if (self.picked.count() == 0) clip.line("0x{x}", .{one.?.cpu.ip()});
        for (threads) |p| if (self.picked.contains(p.thread_id)) clip.line("0x{x}", .{p.cpu.ip()});
        clip.copy();
    }
}

/// Else the first stopped one.
pub fn focused(self: *const Stopped, threads: []const Paused) ?*const Paused {
    if (self.picked.focused()) |id| {
        for (threads) |*p| if (p.thread_id == id) return p;
    }
    return if (threads.len > 0) &threads[0] else null;
}

fn drawCrash(p: *const Paused, crash: Debugger.Crash) void {
    var buf: [400]u8 = undefined;
    const what = CrashReport.summaryOf(.{ .kind = crash.kind, .code = crash.code, .fault = crash.fault }, p.cpu.ip(), &buf);
    ui.textColored(.{ 1, 0.45, 0.45, 1 }, "Crashed: {s}", .{what});
    ui.textDisabled("Continue tries it again, Skip instruction goes past it, Let it crash hands it to the game", .{});
}

fn threadOf(p: *const Paused) u64 {
    return p.thread_id;
}
