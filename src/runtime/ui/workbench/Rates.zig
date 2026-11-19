//! Calls per second and average duration, for the Timings and Hooks windows.

const Rates = @This();

const std = @import("std");

const core = @import("wraith_core");
const ui = @import("wraith_ui");

pub const max = 256;

pub const Sample = struct {
    id: u64,
    figures: core.timing.Figures,
};

pub const Rate = struct {
    per_second: f64 = 0,
    avg_ns: f64 = 0,
};

const Entry = struct {
    id: u64,
    calls: u64,
    total_ns: u64,
    /// Null until we have two samples to compare.
    rate: ?Rate = null,
};

unit: Unit = .ms,
entries: [max]Entry = undefined,
len: usize = 0,
since_update: f32 = 0,

pub const Unit = enum {
    ms,
    us,

    fn per(comptime self: Unit) f64 {
        return switch (self) {
            .ms => std.time.ns_per_ms,
            .us => std.time.ns_per_us,
        };
    }
};

/// Call every frame. Rates update once a second.
pub fn tick(self: *Rates, samples: []const Sample) void {
    self.since_update += ui.getIO().DeltaTime;
    if (self.since_update < 1 and self.len != 0) return;
    self.update(samples, self.since_update);
    self.since_update = 0;
}

pub fn update(self: *Rates, samples: []const Sample, seconds: f32) void {
    var next: [max]Entry = undefined;
    const n = @min(samples.len, max);
    for (samples[0..n], 0..) |s, i| {
        next[i] = .{ .id = s.id, .calls = s.figures.calls, .total_ns = s.figures.total_ns };
        const before = self.entry(s.id) orelse continue;
        if (seconds <= 0) continue;
        const calls = s.figures.calls -| before.calls;
        var rate: Rate = .{ .per_second = @as(f64, @floatFromInt(calls)) / seconds };
        if (calls != 0) rate.avg_ns = @as(f64, @floatFromInt(s.figures.total_ns -| before.total_ns)) / @as(f64, @floatFromInt(calls));
        next[i].rate = rate;
    }
    @memcpy(self.entries[0..n], next[0..n]);
    self.len = n;
}

pub fn find(self: *const Rates, id: u64) ?Rate {
    const e = self.entry(id) orelse return null;
    return e.rate;
}

fn entry(self: *const Rates, id: u64) ?*const Entry {
    for (self.entries[0..self.len]) |*e| {
        if (e.id == id) return e;
    }
    return null;
}

pub fn columns(comptime unit: Unit) [5][:0]const u8 {
    const u = @tagName(unit);
    return .{ "Calls/s", "Avg (" ++ u ++ ")", "Max (" ++ u ++ ")", "Last (" ++ u ++ ")", "Calls" };
}

pub const Figure = enum { per_second, avg, max, last, calls };

/// A rate not worked out yet counts as 0.
pub fn order(self: *const Rates, figure: Figure, a: Sample, b: Sample) std.math.Order {
    const ra: Rate = self.find(a.id) orelse .{};
    const rb: Rate = self.find(b.id) orelse .{};
    return switch (figure) {
        .per_second => std.math.order(ra.per_second, rb.per_second),
        .avg => std.math.order(ra.avg_ns, rb.avg_ns),
        .max => std.math.order(a.figures.max_ns, b.figures.max_ns),
        .last => std.math.order(a.figures.last_ns, b.figures.last_ns),
        .calls => std.math.order(a.figures.calls, b.figures.calls),
    };
}

/// Fixed width, so name columns get the rest.
pub fn setupColumns(comptime unit: Unit) void {
    inline for (columns(unit)) |label| ui.tableColumnWith(label, .{ .fixed = true });
}

pub fn row(self: *const Rates, id: u64, figures: core.timing.Figures) void {
    switch (self.unit) {
        inline else => |unit| self.rowIn(unit, id, figures),
    }
}

fn rowIn(self: *const Rates, comptime unit: Unit, id: u64, figures: core.timing.Figures) void {
    const rate = self.find(id);
    _ = ui.tableNextColumn();
    if (rate) |r| ui.text("{d:.0}", .{r.per_second}) else ui.textDisabled("-", .{});
    _ = ui.tableNextColumn();
    if (rate) |r| ui.text("{d:.3}", .{r.avg_ns / unit.per()}) else ui.textDisabled("-", .{});
    _ = ui.tableNextColumn();
    ui.text("{d:.3}", .{@as(f64, @floatFromInt(figures.max_ns)) / unit.per()});
    _ = ui.tableNextColumn();
    ui.text("{d:.3}", .{@as(f64, @floatFromInt(figures.last_ns)) / unit.per()});
    _ = ui.tableNextColumn();
    ui.text("{d}", .{figures.calls});
}

test "rates over a second" {
    var rates: Rates = .{};
    rates.update(&.{.{ .id = 1, .figures = .{ .calls = 10, .total_ns = 1000 } }}, 1);
    try std.testing.expectEqual(null, rates.find(1));

    rates.update(&.{.{ .id = 1, .figures = .{ .calls = 30, .total_ns = 5000 } }}, 2);
    const r = rates.find(1).?;
    try std.testing.expectEqual(10, r.per_second);
    try std.testing.expectEqual(200, r.avg_ns);

    // A reset counts as no calls, not a huge number
    rates.update(&.{.{ .id = 1, .figures = .{} }}, 1);
    try std.testing.expectEqual(0, rates.find(1).?.per_second);
}
