//! How often things run and how long they take: each zone, and each heap's calls. Memory counts what they allocate.

const Timings = @This();

const std = @import("std");

const core = @import("wraith_core");
const devtools = @import("tuft_devtools");
const ui = @import("wraith_ui");

const Rates = @import("../Rates.zig");
const Clip = @import("wraith_ui").Clip;

const Stats = core.timing.Stats;
const HeapStats = core.heap.Stats;
const max_heaps = 64;

stats: [Rates.max]Stats = undefined,
rates: Rates = .{},
heaps: [max_heaps]HeapStats = undefined,
call_rates: Rates = .{ .unit = .us },
picked: ui.Selection = .{},

const table_options: ui.TableOptions = .{ .borders = true, .row_background = true, .resizable = true, .sortable = true, .sizing = .stretch_prop };

pub fn deinit(self: *Timings) void {
    self.picked.deinit();
}

pub fn draw(self: *Timings) void {
    const n = core.timing.registry.snapshot(&self.stats);
    const zones = self.stats[0..n];
    var samples: [Rates.max]Rates.Sample = undefined;
    for (zones, 0..) |*s, i| samples[i] = sample(s);
    self.rates.tick(samples[0..n]);

    const heaps = self.heaps[0..core.heap.registry.snapshot(&self.heaps)];
    var call_samples: [max_heaps * 4]Rates.Sample = undefined;
    for (heaps, 0..) |*s, i| {
        for (s.ops, 0..) |f, op| call_samples[i * 4 + op] = .{ .id = s.id + op, .figures = f };
    }
    self.call_rates.tick(call_samples[0 .. heaps.len * 4]);

    self.zoneTable(zones);
    if (ui.collapsingHeader("Heap calls", false)) self.callTable(heaps);
}

fn zoneTable(self: *Timings, zones: []Stats) void {
    const table = ui.table("timings", 2 + Rates.columns(.ms).len, table_options) orelse return;
    ui.tableColumnWith("Group", .{ .stretch = true, .width = 1 });
    ui.tableColumnWith("Zone", .{ .stretch = true, .width = 2 });
    Rates.setupColumns(.ms);
    ui.tableHeaders();
    table.sort(Column, Stats, zones, &self.rates, order);

    var picking = self.picked.begin(zones.len, ui.Selection.Rows(Stats, idOf){ .rows = zones }, .{});
    for (zones, 0..) |*s, i| {
        ui.tableNextRow();
        _ = ui.tableNextColumn();
        _ = picking.row(i, ui.format("{s}##{d}", .{ groupOf(s.ownerName()), s.id }));
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
            clip.line("{s}\t{s}\t{d}\t{d:.3}\t{d:.3}", .{ groupOf(s.ownerName()), s.name(), f.calls, ms(f.max_ns), ms(f.last_ns) });
        };
        clip.copy();
    }
    menu.separator();
    if (menu.item(.{ .label = "Reset all", .tooltip = "Clears every zone's counts and maximum" })) core.timing.registry.forEach(core.timing.Zone.reset);
}

/// How long each heap takes to allocate, resize and free.
const CallRow = struct {
    heap: *const HeapStats,
    op: core.heap.Op,

    fn sample(row: CallRow) Rates.Sample {
        const op = @backingInt(row.op);
        return .{ .id = row.heap.id + op, .figures = row.heap.ops[op] };
    }
};

const CallColumn = enum { group, heap, call, per_second, avg, max, last, calls };

fn callOrder(rates: *const Rates, column: ?CallColumn, a: CallRow, b: CallRow) std.math.Order {
    const by = column orelse {
        const by_heap = byHeap(a.heap, b.heap);
        return if (by_heap != .eq) by_heap else std.math.order(@backingInt(a.op), @backingInt(b.op));
    };
    return switch (by) {
        .group => std.mem.order(u8, a.heap.ownerName(), b.heap.ownerName()),
        .heap => std.mem.order(u8, a.heap.name(), b.heap.name()),
        .call => std.math.order(@backingInt(a.op), @backingInt(b.op)),
        inline else => |figure| rates.order(@field(Rates.Figure, @tagName(figure)), a.sample(), b.sample()),
    };
}

fn callTable(self: *Timings, heaps: []const HeapStats) void {
    const table = ui.table("calls", 3 + Rates.columns(.us).len, table_options) orelse return;
    defer table.end();
    ui.tableColumnWith("Group", .{ .stretch = true });
    ui.tableColumnWith("Heap", .{ .stretch = true });
    ui.tableColumnWith("Call", .{ .fixed = true });
    Rates.setupColumns(.us);
    ui.tableHeaders();

    var rows: [max_heaps * 4]CallRow = undefined;
    var len: usize = 0;
    for (heaps) |*s| {
        for (s.ops, 0..) |f, op| {
            if (f.calls == 0) continue;
            rows[len] = .{ .heap = s, .op = @fromBackingInt(@intCast(op)) };
            len += 1;
        }
    }
    table.sort(CallColumn, CallRow, rows[0..len], &self.call_rates, callOrder);

    for (rows[0..len]) |row| {
        ui.tableNextRow();
        _ = ui.tableNextColumn();
        ui.text("{s}", .{groupOf(row.heap.ownerName())});
        _ = ui.tableNextColumn();
        ui.text("{s}", .{row.heap.name()});
        _ = ui.tableNextColumn();
        ui.text("{t}", .{row.op});
        const s = row.sample();
        self.call_rates.row(s.id, s.figures);
    }
}

fn groupOf(owner: []const u8) []const u8 {
    return if (owner.len == 0) "wraith" else owner;
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

fn byHeap(a: *const HeapStats, b: *const HeapStats) std.math.Order {
    const by_owner = std.mem.order(u8, a.ownerName(), b.ownerName());
    return if (by_owner != .eq) by_owner else std.mem.order(u8, a.name(), b.name());
}
