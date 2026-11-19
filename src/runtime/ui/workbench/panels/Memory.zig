//! The process's memory, each heap we track, and how long heap calls take.

const Memory = @This();

const std = @import("std");

const wraith_platform = @import("wraith_platform");
const memory = @import("tuft_mem");
const core = @import("wraith_core");
const ui = @import("wraith_ui");

const Rates = @import("../Rates.zig");

const Stats = core.heap.Stats;
const max_heaps = 64;
const refresh_seconds = 0.5;

/// tuft keeps the counts.
var pages: core.heap.Usage = .init("pages");
var pages_listed = false;

pub fn refreshPages() void {
    if (!pages_listed) {
        core.heap.registry.add(&pages);
        pages_listed = true;
    }
    const s = memory.pages.stats();
    pages.mirror(s.live_bytes, s.allocs, s.frees);
}

window: ui.Window = .{ .title = "Memory use", .size = .{ 680, 400 }, .min_size = .{ 440, 200 } },
stats: [max_heaps]Stats = undefined,
len: usize = 0,
process: ?wraith_platform.process.MemoryInfo = null,
since_refresh: f32 = refresh_seconds,
rates: Rates = .{},
op_rates: Rates = .{ .unit = .us },

pub fn draw(self: *Memory) void {
    self.since_refresh += ui.getIO().DeltaTime;
    if (self.since_refresh >= refresh_seconds) {
        self.since_refresh = 0;
        self.process = wraith_platform.process.memoryInfo();
    }
    refreshPages();
    self.len = core.heap.registry.snapshot(&self.stats);
    const heaps = self.stats[0..self.len];

    var samples: [max_heaps]Rates.Sample = undefined;
    var op_samples: [max_heaps * 4]Rates.Sample = undefined;
    var tracked: u64 = 0;
    for (heaps, 0..) |*s, i| {
        samples[i] = allocSample(s);
        for (s.ops, 0..) |f, op| op_samples[i * 4 + op] = .{ .id = s.id + op, .figures = f };
        tracked += s.live_bytes;
    }
    self.rates.tick(samples[0..heaps.len]);
    self.op_rates.tick(op_samples[0 .. heaps.len * 4]);

    if (self.process) |p| {
        ui.textWrapped("Working set {Bi:.1} (peak {Bi:.1})   Private {Bi:.1}", .{ p.working_set, p.peak_working_set, p.private_bytes });
        ui.tooltip("The whole game process, as Windows sees it", .{});
    }
    ui.text("Tracked by Wraith {Bi:.1}", .{tracked});

    self.heapTable(heaps);
    if (ui.collapsingHeader("Call timings", true)) self.callTable(heaps);
}

const table_options: ui.TableOptions = .{ .borders = true, .row_background = true, .resizable = true, .sortable = true, .sizing = .stretch_prop };

fn nameColumns() void {
    ui.tableColumnWith("Group", .{ .stretch = true });
    ui.tableColumnWith("Heap", .{ .stretch = true });
}

fn allocSample(s: *const Stats) Rates.Sample {
    return .{ .id = s.id, .figures = .{ .calls = s.allocs } };
}

const HeapColumn = enum { group, heap, live, peak, live_allocs, per_second, allocs, frees };

fn heapOrder(rates: *const Rates, column: ?HeapColumn, a: *const Stats, b: *const Stats) std.math.Order {
    return switch (column orelse return byName(a, b)) {
        .group => std.mem.order(u8, a.ownerName(), b.ownerName()),
        .heap => std.mem.order(u8, a.name(), b.name()),
        .live => std.math.order(a.live_bytes, b.live_bytes),
        .peak => std.math.order(a.peak_bytes, b.peak_bytes),
        .live_allocs => std.math.order(a.live_allocs, b.live_allocs),
        .per_second => rates.order(.per_second, allocSample(a), allocSample(b)),
        .allocs => std.math.order(a.allocs, b.allocs),
        .frees => std.math.order(a.frees, b.frees),
    };
}

fn heapTable(self: *Memory, heaps: []const Stats) void {
    const table = ui.table("heaps", 8, table_options) orelse return;
    defer table.end();
    nameColumns();
    inline for (.{ "Live", "Peak", "Live allocs", "Allocs/s", "Allocs", "Frees" }) |label| ui.tableColumnWith(label, .{ .fixed = true });
    ui.tableHeaders();

    var rows: [max_heaps]*const Stats = undefined;
    for (rows[0..heaps.len], heaps) |*row, *s| row.* = s;
    table.sort(HeapColumn, *const Stats, rows[0..heaps.len], &self.rates, heapOrder);

    for (rows[0..heaps.len]) |s| {
        ui.tableNextRow();
        _ = ui.tableNextColumn();
        ui.text("{s}", .{if (s.ownerName().len == 0) "wraith" else s.ownerName()});
        _ = ui.tableNextColumn();
        ui.text("{s}", .{s.name()});
        _ = ui.tableNextColumn();
        ui.text("{Bi:.1}", .{s.live_bytes});
        _ = ui.tableNextColumn();
        ui.text("{Bi:.1}", .{s.peak_bytes});
        _ = ui.tableNextColumn();
        ui.text("{d}", .{s.live_allocs});
        _ = ui.tableNextColumn();
        if (self.rates.find(s.id)) |r| ui.text("{d:.0}", .{r.per_second}) else ui.textDisabled("-", .{});
        _ = ui.tableNextColumn();
        ui.text("{d}", .{s.allocs});
        _ = ui.tableNextColumn();
        ui.text("{d}", .{s.frees});
    }
}

const CallRow = struct {
    heap: *const Stats,
    op: core.heap.Op,

    fn sample(row: CallRow) Rates.Sample {
        const op = @backingInt(row.op);
        return .{ .id = row.heap.id + op, .figures = row.heap.ops[op] };
    }
};

const CallColumn = enum { group, heap, call, per_second, avg, max, last, calls };

fn callOrder(rates: *const Rates, column: ?CallColumn, a: CallRow, b: CallRow) std.math.Order {
    const by = column orelse {
        const by_heap = byName(a.heap, b.heap);
        return if (by_heap != .eq) by_heap else std.math.order(@backingInt(a.op), @backingInt(b.op));
    };
    return switch (by) {
        .group => std.mem.order(u8, a.heap.ownerName(), b.heap.ownerName()),
        .heap => std.mem.order(u8, a.heap.name(), b.heap.name()),
        .call => std.math.order(@backingInt(a.op), @backingInt(b.op)),
        inline else => |figure| rates.order(@field(Rates.Figure, @tagName(figure)), a.sample(), b.sample()),
    };
}

fn callTable(self: *Memory, heaps: []const Stats) void {
    const table = ui.table("calls", 3 + Rates.columns(.us).len, table_options) orelse return;
    defer table.end();
    nameColumns();
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
    table.sort(CallColumn, CallRow, rows[0..len], &self.op_rates, callOrder);

    for (rows[0..len]) |row| {
        const s = row.heap;
        ui.tableNextRow();
        _ = ui.tableNextColumn();
        ui.text("{s}", .{if (s.ownerName().len == 0) "wraith" else s.ownerName()});
        _ = ui.tableNextColumn();
        ui.text("{s}", .{s.name()});
        _ = ui.tableNextColumn();
        ui.text("{t}", .{row.op});
        const sample = row.sample();
        self.op_rates.row(sample.id, sample.figures);
    }
}

fn byName(a: *const Stats, b: *const Stats) std.math.Order {
    const by_owner = std.mem.order(u8, a.ownerName(), b.ownerName());
    return if (by_owner != .eq) by_owner else std.mem.order(u8, a.name(), b.name());
}
