//! How often things run and how long they take.

const Timings = @This();

const std = @import("std");

const core = @import("wraith_core");
const devtools = @import("tuft_devtools");
const ui = @import("wraith_ui");

const Rates = @import("../Rates.zig");
const Clip = @import("wraith_ui").Clip;

const Stats = core.timing.Stats;

window: ui.Window = .{ .title = "Timings", .size = .{ 620, 320 }, .min_size = .{ 400, 160 } },
stats: [Rates.max]Stats = undefined,
rates: Rates = .{},
picked: ui.Selection = .{},

pub fn deinit(self: *Timings) void {
    self.picked.deinit();
}

pub fn draw(self: *Timings) void {
    const n = core.timing.registry.snapshot(&self.stats);
    const zones = self.stats[0..n];

    var samples: [Rates.max]Rates.Sample = undefined;
    for (zones, 0..) |*s, i| samples[i] = sample(s);
    self.rates.tick(samples[0..n]);

    const table = ui.table("timings", 2 + Rates.columns(.ms).len, .{
        .borders = true,
        .row_background = true,
        .resizable = true,
        .sortable = true,
        .sizing = .stretch_prop,
        .scroll_y = true,
    }) orelse return;
    ui.tableColumnWith("Group", .{ .stretch = true, .width = 1 });
    ui.tableColumnWith("Zone", .{ .stretch = true, .width = 2 });
    Rates.setupColumns(.ms);
    ui.tableHeaders();
    table.sort(Column, Stats, zones, &self.rates, order);

    var picking = self.picked.begin(n, ui.Selection.Rows(Stats, idOf){ .rows = zones }, .{});
    for (zones, 0..) |*s, i| {
        ui.tableNextRow();
        _ = ui.tableNextColumn();
        _ = picking.row(i, ui.format("{s}##{d}", .{ if (s.ownerName().len == 0) "wraith" else s.ownerName(), s.id }));
        _ = ui.tableNextColumn();
        ui.text("{s}", .{s.name()});
        self.rates.row(s.id, figures(s));
    }
    picking.end();
    // The menu after the table, not in it, or its items can't be clicked
    table.end();

    var menu = ui.commands("timings", .{});
    defer menu.end();
    if (menu.item(.{ .label = "Copy", .chord = devtools.keys.copy, .enabled = self.picked.count() > 0, .tooltip = "Group, zone, calls and times in ms, one zone per line" })) {
        var clip: Clip = .{};
        for (zones) |*s| if (self.picked.contains(s.id)) {
            const f = figures(s);
            clip.line("{s}\t{s}\t{d}\t{d:.3}\t{d:.3}", .{ if (s.ownerName().len == 0) "wraith" else s.ownerName(), s.name(), f.calls, ms(f.max_ns), ms(f.last_ns) });
        };
        clip.copy();
    }
    menu.separator();
    if (menu.item(.{ .label = "Reset all", .tooltip = "Clears every zone's counts and maximum" })) core.timing.registry.forEach(core.timing.Zone.reset);
}

fn idOf(s: *const Stats) u64 {
    return s.id;
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

fn figures(s: *const Stats) core.timing.Figures {
    return .{ .calls = s.calls, .total_ns = s.total_ns, .max_ns = s.max_ns, .last_ns = s.last_ns };
}

fn sample(s: *const Stats) Rates.Sample {
    return .{ .id = s.id, .figures = figures(s) };
}

const Column = enum { group, zone, per_second, avg, max, last, calls };

fn order(rates: *const Rates, column: ?Column, a: Stats, b: Stats) std.math.Order {
    return switch (column orelse return byName(&a, &b)) {
        .group => std.mem.order(u8, a.ownerName(), b.ownerName()),
        .zone => std.mem.order(u8, a.name(), b.name()),
        inline else => |figure| rates.order(@field(Rates.Figure, @tagName(figure)), sample(&a), sample(&b)),
    };
}

fn byName(a: *const Stats, b: *const Stats) std.math.Order {
    const by_owner = std.mem.order(u8, a.ownerName(), b.ownerName());
    return if (by_owner != .eq) by_owner else std.mem.order(u8, a.name(), b.name());
}
