//! What a crash waits in. It shows what happened, the report and what to do next. An AppWindow,
//! so it has its own thread and window like the workbench.

const Window = @This();

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const platform = @import("wraith_platform");
const sys = @import("tuft_sys");
const ui = @import("wraith_ui");
const AppWindow = @import("tuft_imgui").AppWindow;

const imgui = @import("../ui/imgui.zig");
const c = imgui.c;
const Report = @import("Report.zig");

report: *const Report,
summary: []const u8,
logs_dir: []const u8,
can_open_workbench: bool,
/// Set once picked, from its thread.
picked: Atomic(?*const Choice) = .init(null),
copied: bool = false,

pub const Choice = enum {
    /// Hand it on to the game.
    crash,
    /// Stop it in the workbench's debugger.
    workbench,
};

const crash_choice: Choice = .crash;
const workbench_choice: Choice = .workbench;

/// Tests pick this once it's drawn a few frames, so it really shows and closes.
pub var test_pick: ?Choice = null;

/// Until something's picked. Closing it is `crash`, and so is a window that couldn't open, found
/// once its thread gives up.
/// `up` gets set once it's drawn something, so a caller can tell it from a hang.
pub fn run(report: *const Report, summary: []const u8, logs_dir: []const u8, can_open_workbench: bool, up: *Atomic(bool)) Choice {
    var self: Window = .{ .report = report, .summary = summary, .logs_dir = logs_dir, .can_open_workbench = can_open_workbench };
    // Not the runtime's heap, the crash might have broken it
    const app = AppWindow.create(std.heap.page_allocator, .{
        .title = "Wraith: the game crashed",
        .draw = .{ .ctx = &self, .func = drawThunk },
        .size = .{ 900, 640 },
        .topmost = true,
        .icon = "WRAITH_ICON",
    }) catch return .crash;
    defer app.destroy();
    app.show();
    while (app.isOpen()) {
        if (app.failed() != null) return .crash;
        if (self.picked.load(.acquire)) |choice| return choice.*;
        if (app.frameCount() > 0) up.store(true, .release);
        if (@import("builtin").is_test) if (test_pick) |p| if (app.frameCount() >= 3) return p;
        sys.thread.sleepMs(20);
    }
    return .crash;
}

fn drawThunk(ctx: *anyopaque) void {
    const self: *Window = @ptrCast(@alignCast(ctx));
    self.draw();
}

fn draw(self: *Window) void {
    const viewport = c.ImGui_GetMainViewport();
    c.ImGui_SetNextWindowPos(viewport.*.WorkPos, c.ImGuiCond_Always);
    c.ImGui_SetNextWindowSize(viewport.*.WorkSize, c.ImGuiCond_Always);
    const scope = ui.window("crash", .{ .flags = .{ .no_title_bar = true, .no_resize = true, .no_move = true, .no_collapse = true, .no_saved_settings = true } }) orelse return;
    defer scope.end();

    ui.textColored(.{ 1, 0.45, 0.45, 1 }, "The game crashed", .{});
    ui.textWrapped("{s}", .{self.summary});
    ui.textDisabled("The log, this report and a minidump are in {s}", .{self.logs_dir});
    ui.spacing();
    if (ui.button(if (self.copied) "Copied" else "Copy report")) {
        ui.setClipboard(self.report.text());
        self.copied = true;
    }
    ui.sameLine();
    if (ui.button("Open logs folder")) platform.process.openUri(std.heap.page_allocator, self.logs_dir) catch {};
    ui.sameLine();
    {
        const off = ui.disabled(!self.can_open_workbench);
        defer off.end();
        if (ui.button("Open in workbench")) self.picked.store(&workbench_choice, .release);
    }
    ui.tooltip("Stop it in the debugger, with the game frozen. From there it can try again, skip what crashed, or still crash", .{});
    ui.sameLine();
    if (ui.button("Close the game")) self.picked.store(&crash_choice, .release);
    ui.separator();

    if (ui.child("report", .{ 0, 0 }, .{ .border = true, .horizontal_scrollbar = true })) |region| {
        defer region.end();
        const mono = ui.monospace();
        defer mono.end();
        const text = self.report.text();
        c.ImGui_TextUnformattedEx(@ptrCast(text.ptr), @ptrCast(text.ptr + text.len));
    }
}
