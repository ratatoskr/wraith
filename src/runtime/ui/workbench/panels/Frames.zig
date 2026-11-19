//! Frame times, fps, lows, percentiles and hitches, with a graph.

const Frames = @This();

const std = @import("std");

const api = @import("wraith_api");
const devtools = @import("tuft_devtools");
const ui = @import("wraith_ui");

const Shell = @import("../../shell/Shell.zig");
const Settings = @import("../../../Settings.zig");
const FrameStats = @import("../../../FrameStats.zig");
const Clip = @import("../Clip.zig");

const plot = ui.plot;

window: ui.Window = .{ .title = "Frame stats", .size = .{ 640, 520 }, .min_size = .{ 420, 300 } },
/// Null without a runtime around it, like in tests.
shell: ?*Shell,
/// The graph's frames, newest last.
graph: [graph_max]f32 = undefined,
/// The same, for ImPlot.
graph_f64: [graph_max]f64 = undefined,

const graph_max = 4096;

pub fn draw(self: *Frames) void {
    const shell = self.shell orelse {
        ui.textDisabled("No game", .{});
        return;
    };
    const frames = &shell.overlay.frames;
    const s = frames.stats();

    if (s.frames == 0) {
        ui.textDisabled("Waiting for frames", .{});
    } else {
        const big = ui.bold();
        ui.text("{d:.0} fps  {d:.2} ms", .{ s.fps, s.avg_ms });
        big.end();
        ui.sameLine();
        ui.textDisabled("over the last {d:.1} s", .{s.window_seconds});
    }
    drawTable(s);
    self.drawGraphs(frames, s);
    drawSettings(shell);

    var menu = ui.commands("frames", .{});
    defer menu.end();
    if (menu.item(.{ .label = "Copy", .chord = devtools.keys.copy, .tooltip = "These stats as text" })) copy(s);
    menu.separator();
    if (menu.item(.{ .label = "Reset", .tooltip = "Starts the totals and the window over" })) frames.reset();
}

fn drawTable(s: api.FrameStats) void {
    const table = ui.table("frame_stats", 3, .{ .borders = true, .row_background = true, .sizing = .stretch_prop }) orelse return;
    defer table.end();
    ui.tableColumnWith("", .{ .stretch = true, .width = 1 });
    ui.tableColumnWith("Window", .{ .stretch = true, .width = 1 });
    ui.tableColumnWith("Since reset", .{ .stretch = true, .width = 1 });
    ui.tableHeaders();
    row("Frames", "{d}", .{s.frames}, "{d}", .{s.total_frames});
    row("Fps", "{d:.1}", .{s.fps}, "{d:.1}", .{fps(s.total_avg_ms)});
    row("Average", "{d:.2} ms", .{s.avg_ms}, "{d:.2} ms", .{s.total_avg_ms});
    row("Fastest", "{d:.2} ms", .{s.min_ms}, "{d:.2} ms", .{s.total_min_ms});
    row("Slowest", "{d:.2} ms", .{s.max_ms}, "{d:.2} ms", .{s.total_max_ms});
    row("Median", "{d:.2} ms", .{s.p50_ms}, "", .{});
    row("95th percentile", "{d:.2} ms", .{s.p95_ms}, "", .{});
    row("99th percentile", "{d:.2} ms", .{s.p99_ms}, "", .{});
    row("1% low", "{d:.1} fps", .{s.low_1_fps}, "", .{});
    row("0.1% low", "{d:.1} fps", .{s.low_01_fps}, "", .{});
    row("Hitches", "{d}", .{s.hitches}, "", .{});
    ui.tooltip("Frames over {d:.1} times the median", .{s.hitch_factor});
}

fn row(label: []const u8, comptime window_fmt: []const u8, window_args: anytype, comptime total_fmt: []const u8, total_args: anytype) void {
    ui.tableNextRow();
    _ = ui.tableNextColumn();
    ui.text("{s}", .{label});
    _ = ui.tableNextColumn();
    ui.text(window_fmt, window_args);
    _ = ui.tableNextColumn();
    if (total_fmt.len == 0) ui.textDisabled("-", .{}) else ui.text(total_fmt, total_args);
}

fn drawGraphs(self: *Frames, frames: *const FrameStats, s: api.FrameStats) void {
    const n = @min(s.frames, graph_max);
    const times = self.graph_f64[0..frames.times(self.graph[0..n]).len];
    for (times, self.graph[0..times.len]) |*d, t| d.* = t;
    const tabs = ui.tabBar("graphs") orelse return;
    defer tabs.end();
    if (ui.tabItem("Frame times", .{})) |tab| {
        defer tab.end();
        if (plot.chart("##times", .{ .size = .{ -1, ui.scaled(220) }, .flags = .{ .no_menus = true } })) |chart| {
            defer chart.end();
            plot.setupAxes("Frames ago", "ms", .{}, .{ .auto_fit = true });
            plot.setupAxisLimits(.x1, -@as(f64, @floatFromInt(times.len)), 0, .always);
            plot.setupLegend(.north_west, .{ .horizontal = true });
            plot.line("Frame time", times, .{ .x_start = -@as(f64, @floatFromInt(times.len)), .shaded = true }, .{ .fill_alpha = 0.25 });
            plot.infLines("Average", &.{s.avg_ms}, .{ .horizontal = true }, .{});
            plot.infLines("99th percentile", &.{s.p99_ms}, .{ .horizontal = true }, .{});
            plot.infLines("Hitch", &.{s.p50_ms * s.hitch_factor}, .{ .horizontal = true }, .{ .line_color = .{ 1, 0.35, 0.35, 1 } });
        }
    }
    if (ui.tabItem("Histogram", .{})) |tab| {
        defer tab.end();
        if (plot.chart("##histogram", .{ .size = .{ -1, ui.scaled(220) }, .flags = .{ .no_menus = true, .no_legend = true } })) |chart| {
            defer chart.end();
            plot.setupAxes("ms", "Frames", .{ .auto_fit = true }, .{ .auto_fit = true });
            if (times.len > 0) _ = plot.histogram("Frames", times, .{ .bins = 50 }, .{});
        }
    }
}

fn drawSettings(shell: *Shell) void {
    if (!ui.collapsingHeader("Settings", false)) return;
    var settings = shell.frameSettings();
    var changed = false;
    var save = false;

    if (ui.slider("Window (seconds)", &settings.window_seconds, FrameStats.min_window_seconds, FrameStats.max_window_seconds)) changed = true;
    if (ui.isItemDeactivated()) save = true;
    if (ui.slider("Hitch at (times the median)", &settings.hitch_factor, FrameStats.min_hitch_factor, FrameStats.max_hitch_factor)) changed = true;
    if (ui.isItemDeactivated()) save = true;

    if (changed or save) shell.setFrameSettings(settings, save);
}

fn copy(s: api.FrameStats) void {
    var clip: Clip = .{};
    clip.line("Window\t{d:.1} s\t{d} frames", .{ s.window_seconds, s.frames });
    clip.line("Fps\t{d:.1}", .{s.fps});
    clip.line("Average\t{d:.2} ms", .{s.avg_ms});
    clip.line("Fastest\t{d:.2} ms", .{s.min_ms});
    clip.line("Slowest\t{d:.2} ms", .{s.max_ms});
    clip.line("Median\t{d:.2} ms", .{s.p50_ms});
    clip.line("95th percentile\t{d:.2} ms", .{s.p95_ms});
    clip.line("99th percentile\t{d:.2} ms", .{s.p99_ms});
    clip.line("1% low\t{d:.1} fps", .{s.low_1_fps});
    clip.line("0.1% low\t{d:.1} fps", .{s.low_01_fps});
    clip.line("Hitches\t{d}\tover {d:.1}x the median", .{ s.hitches, s.hitch_factor });
    clip.line("Since reset\t{d} frames\t{d:.2} ms average\t{d:.2} ms fastest\t{d:.2} ms slowest", .{ s.total_frames, s.total_avg_ms, s.total_min_ms, s.total_max_ms });
    clip.copy();
}

fn fps(frame_ms: f32) f32 {
    return if (frame_ms > 0) 1000 / frame_ms else 0;
}
