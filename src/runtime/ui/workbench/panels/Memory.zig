//! The process's memory, each heap we track, and which timing zone allocations came from. Timings has how long heap calls take.

const Memory = @This();

const std = @import("std");

const wraith_platform = @import("wraith_platform");
const memory = @import("tuft_mem");
const core = @import("wraith_core");
const ui = @import("wraith_ui");

const Rates = @import("../Rates.zig");
const Clip = ui.Clip;
const Symbols = memory.Symbols;

const Stats = core.heap.Stats;
const ZoneStats = core.timing.Stats;
const Trace = core.heap.Trace;
const max_heaps = 64;
const refresh_seconds = 0.5;
/// The row for allocations outside every zone. Zones' ids are addresses, so never this
const outside_id = 1;

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

stats: [max_heaps]Stats = undefined,
len: usize = 0,
zone_stats: [Rates.max]ZoneStats = undefined,
zone_rows: [Rates.max + 1]ZoneRow = undefined,
process: ?wraith_platform.process.MemoryInfo = null,
since_refresh: f32 = refresh_seconds,
rates: Rates = .{},
alloc_rates: Rates = .{},
byte_rates: Rates = .{},
traces: [64]Trace = undefined,
/// What's traced, for showing; the heap keeps which by address
traced_name: @import("tuft_text").Message(48) = .{},
/// Names for traces' addresses, looked up once
names: std.AutoHashMapUnmanaged(usize, []const u8) = .empty,
names_text: std.heap.ArenaAllocator = .init(gpa),

const gpa = core.heap.named("memory panel", core.heap.main);

pub fn deinit(self: *Memory) void {
    self.names.deinit(gpa);
    self.names_text.deinit();
}

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
    var tracked: u64 = 0;
    for (heaps, 0..) |*s, i| {
        samples[i] = allocSample(s);
        // One inside another is counted there already
        if (s.within().len == 0) tracked += s.live_bytes;
    }
    self.rates.tick(samples[0..heaps.len]);

    if (self.process) |p| {
        ui.textWrapped("Working set {Bi:.1} (peak {Bi:.1})   Private {Bi:.1}", .{ p.working_set, p.peak_working_set, p.private_bytes });
        ui.tooltip("The whole game process, as Windows sees it", .{});
    }
    ui.text("Tracked by Wraith {Bi:.1}", .{tracked});

    self.heapTable(heaps);
    if (ui.collapsingHeader("By zone", true)) self.zoneTable();
    if (ui.collapsingHeader("Where allocations come from", false)) self.drawTraces();
}

const table_options: ui.TableOptions = .{ .borders = true, .row_background = true, .resizable = true, .sortable = true, .sizing = .stretch_prop };

fn nameColumns(second: [:0]const u8) void {
    ui.tableColumnWith("Group", .{ .stretch = true });
    ui.tableColumnWith(second, .{ .stretch = true });
}

fn groupOf(owner: []const u8) []const u8 {
    return if (owner.len == 0) "wraith" else owner;
}

// Heaps

fn allocSample(s: *const Stats) Rates.Sample {
    return .{ .id = s.id, .figures = .{ .calls = s.allocs } };
}

const HeapColumn = enum { group, heap, live, peak, live_allocs, per_second, allocs, frees };

fn heapOrder(rates: *const Rates, column: ?HeapColumn, a: *const Stats, b: *const Stats) std.math.Order {
    return switch (column orelse return byName(a.ownerName(), a.name(), b.ownerName(), b.name())) {
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
    nameColumns("Heap");
    inline for (.{ "Live", "Peak", "Live allocs", "Allocs/s", "Allocs", "Frees" }) |label| ui.tableColumnWith(label, .{ .fixed = true });
    ui.tableHeaders();

    var rows: [max_heaps]*const Stats = undefined;
    for (rows[0..heaps.len], heaps) |*row, *s| row.* = s;
    table.sort(HeapColumn, *const Stats, rows[0..heaps.len], &self.rates, heapOrder);

    for (rows[0..heaps.len]) |s| {
        ui.tableNextRow();
        _ = ui.tableNextColumn();
        ui.text("{s}", .{groupOf(s.ownerName())});
        _ = ui.tableNextColumn();
        if (s.within().len > 0) {
            ui.text("{s} / {s}", .{ s.within(), s.name() });
            ui.tooltip("Takes from {s}, so its bytes are counted there too", .{s.within()});
        } else ui.text("{s}", .{s.name()});
        _ = ui.tableNextColumn();
        ui.text("{Bi:.1}", .{s.live_bytes});
        _ = ui.tableNextColumn();
        ui.text("{Bi:.1}", .{s.peak_bytes});
        _ = ui.tableNextColumn();
        ui.text("{d}", .{s.live_allocs});
        _ = ui.tableNextColumn();
        perSecond(&self.rates, s.id);
        _ = ui.tableNextColumn();
        ui.text("{d}", .{s.allocs});
        _ = ui.tableNextColumn();
        ui.text("{d}", .{s.frees});
    }
}

fn perSecond(rates: *const Rates, id: u64) void {
    if (rates.find(id)) |r| ui.text("{d:.0}", .{r.per_second}) else ui.textDisabled("-", .{});
}

// Zones

/// A zone that's allocated, or everything outside every zone.
const ZoneRow = struct {
    id: u64,
    group: []const u8,
    name: []const u8,
    allocs: u64,
    bytes: u64,

    fn allocSample(r: ZoneRow) Rates.Sample {
        return .{ .id = r.id, .figures = .{ .calls = r.allocs } };
    }

    fn byteSample(r: ZoneRow) Rates.Sample {
        return .{ .id = r.id, .figures = .{ .calls = r.bytes } };
    }
};

const ZoneColumn = enum { group, zone, allocs_per_second, bytes_per_second, allocs, bytes };

fn zoneOrder(self: *const Memory, column: ?ZoneColumn, a: ZoneRow, b: ZoneRow) std.math.Order {
    return switch (column orelse return byName(a.group, a.name, b.group, b.name)) {
        .group => std.mem.order(u8, a.group, b.group),
        .zone => std.mem.order(u8, a.name, b.name),
        .allocs_per_second => self.alloc_rates.order(.per_second, a.allocSample(), b.allocSample()),
        .bytes_per_second => self.byte_rates.order(.per_second, a.byteSample(), b.byteSample()),
        .allocs => std.math.order(a.allocs, b.allocs),
        .bytes => std.math.order(a.bytes, b.bytes),
    };
}

/// Allocations on Wraith's heaps by the innermost timing zone on their thread.
fn zoneTable(self: *Memory) void {
    const zones = self.zone_stats[0..core.timing.registry.snapshot(&self.zone_stats)];
    var len: usize = 0;
    const outside = core.heap.unscopedCounts();
    self.zone_rows[len] = .{ .id = outside_id, .group = "wraith", .name = "(outside any zone)", .allocs = outside.allocs, .bytes = outside.bytes };
    len += 1;
    for (zones) |*z| {
        if (z.allocs == 0) continue;
        self.zone_rows[len] = .{ .id = z.id, .group = groupOf(z.ownerName()), .name = z.name(), .allocs = z.allocs, .bytes = z.alloc_bytes };
        len += 1;
    }
    const rows = self.zone_rows[0..len];
    var samples: [Rates.max + 1]Rates.Sample = undefined;
    for (rows, 0..) |r, i| samples[i] = r.allocSample();
    self.alloc_rates.tick(samples[0..len]);
    for (rows, 0..) |r, i| samples[i] = r.byteSample();
    self.byte_rates.tick(samples[0..len]);

    const table = ui.table("zones", 6, table_options) orelse return;
    defer table.end();
    nameColumns("Zone");
    inline for (.{ "Allocs/s", "Bytes/s", "Allocs", "Bytes" }) |label| ui.tableColumnWith(label, .{ .fixed = true });
    ui.tableHeaders();
    table.sort(ZoneColumn, ZoneRow, rows, @as(*const Memory, self), zoneOrder);
    for (rows) |r| {
        ui.tableNextRow();
        _ = ui.tableNextColumn();
        ui.text("{s}", .{r.group});
        _ = ui.tableNextColumn();
        // Picks what's traced below
        const traced = core.heap.tracedZone() == if (r.id == outside_id) 0 else @as(usize, @intCast(r.id));
        if (ui.selectable(ui.format("{s}##zone{d}", .{ r.name, r.id }), traced) and !traced) {
            core.heap.traceZone(if (r.id == outside_id) null else @ptrFromInt(@as(usize, @intCast(r.id))));
            self.traced_name.set(r.name);
        }
        ui.tooltip("{s}Click to trace where its allocations come from, under Where allocations come from.", .{if (r.id == outside_id) "Not in any zone's scope on their thread. " else ""});
        _ = ui.tableNextColumn();
        perSecond(&self.alloc_rates, r.id);
        _ = ui.tableNextColumn();
        if (self.byte_rates.find(r.id)) |rate| ui.text("{Bi:.1}", .{@as(u64, @intFromFloat(rate.per_second))}) else ui.textDisabled("-", .{});
        _ = ui.tableNextColumn();
        ui.text("{d}", .{r.allocs});
        _ = ui.tableNextColumn();
        ui.text("{Bi:.1}", .{r.bytes});
    }
}

// Traces

/// Call stacks of the picked zone's allocations, while asked.
fn drawTraces(self: *Memory) void {
    ui.text("Tracing {s}", .{if (core.heap.tracedZone() == 0) "(outside any zone)" else self.traced_name.message()});
    ui.sameLine();
    ui.textDisabled("Pick another in By zone.", .{});
    var on = core.heap.tracing.load(.monotonic);
    if (ui.checkbox("Record", &on)) core.heap.tracing.store(on, .monotonic);
    ui.tooltip("Walks the stack for each one, so it's slow while it's on", .{});
    ui.sameLine();
    if (ui.smallButton("Clear")) core.heap.clearTraces();
    const got = core.heap.traces(&self.traces);
    ui.sameLine();
    const none = ui.disabled(got.len == 0);
    if (ui.smallButton("Copy all")) self.copyTraces(self.traces[0..got.len]);
    none.end();
    ui.tooltip("Each trace's count, then its stack, newest first", .{});
    if (got.len == 0) return ui.textDisabled("{s}", .{if (on) "None yet." else "Turn on Record to see where they come from."});
    for (self.traces[0..got.len], 0..) |*t, i| {
        const node = ui.treeNode(ui.format("{d}  {s}##trace{d}", .{ t.count, self.where(t), i })) orelse continue;
        defer node.end();
        for (t.addresses()) |address| ui.textDisabled("{s}", .{self.nameOf(address)});
        if (ui.smallButton("Copy")) self.copyTraces(t[0..1]);
    }
    if (got.missed > 0) ui.textDisabled("And {d} from other places, past the first {d}.", .{ got.missed, self.traces.len });
}

fn copyTraces(self: *Memory, traces: []const Trace) void {
    var clip: Clip = .{};
    for (traces) |*t| {
        clip.line("{d} allocations", .{t.count});
        for (t.addresses()) |address| clip.line("  {s}", .{self.nameOf(address)});
    }
    clip.copy();
}

/// Past the tracked heap's own frames, which are always the first few, toward who asked.
fn where(self: *Memory, t: *const Trace) []const u8 {
    const own_frames = 3;
    if (t.len == 0) return "?";
    return self.nameOf(t.frames[@min(own_frames, t.len - 1)]);
}

/// Its module and offset, or an export's name. Not the PDB: std looks for it by the game's exe, and reading it is slow.
fn nameOf(self: *Memory, address: usize) []const u8 {
    if (self.names.get(address)) |n| return n;
    var buf: [256]u8 = undefined;
    const found = Symbols.local.describe(address, &buf) orelse (std.fmt.bufPrint(&buf, "0x{x}", .{address}) catch "?");
    const text = self.names_text.allocator().dupe(u8, found) catch "?";
    self.names.put(gpa, address, text) catch {};
    return text;
}

fn byName(a_group: []const u8, a_name: []const u8, b_group: []const u8, b_name: []const u8) std.math.Order {
    const by_group = std.mem.order(u8, a_group, b_group);
    return if (by_group != .eq) by_group else std.mem.order(u8, a_name, b_name);
}
