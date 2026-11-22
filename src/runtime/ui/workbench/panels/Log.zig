//! Recent log messages, filtered by level and text.

const Log = @This();

const std = @import("std");

const devtools = @import("tuft_devtools");
const ui = @import("wraith_ui");

const LogHistory = @import("../../../LogHistory.zig");
const Clip = @import("wraith_ui").Clip;
const Entry = LogHistory.Entry;

window: ui.Window = .{ .title = "Log", .size = .{ 760, 380 }, .min_size = .{ 480, 200 } },
/// Render thread only, oldest at `head`.
lines: [LogHistory.capacity]Entry = undefined,
head: usize = 0,
len: usize = 0,
next_seq: u64 = 0,
shown: [LogHistory.capacity]u16 = undefined,
levels: std.EnumArray(std.log.Level, bool) = .initFill(true),
filter: [64:0]u8 = @splat(0),
follow: bool = true,
picked: ui.Selection = .{},

pub fn deinit(self: *Log) void {
    self.picked.deinit();
}

pub fn draw(self: *Log) void {
    const added = self.pull();

    inline for (.{ .{ .err, "Errors" }, .{ .warn, "Warnings" }, .{ .info, "Info" }, .{ .debug, "Debug" } }) |pair| {
        _ = ui.checkbox(pair[1], self.levels.getPtr(pair[0]));
        ui.sameLine();
    }
    _ = ui.checkbox("Follow", &self.follow);
    ui.setNextItemWidth(ui.fill);
    _ = ui.inputTextHint("##filter", "Filter", &self.filter);

    const count = self.select();
    const child = ui.child("lines", .{ 0, 0 }, .{ .border = true, .horizontal_scrollbar = true }) orelse return;
    defer child.end();
    var picking = self.picked.begin(count, Shown{ .log = self }, .{});
    var rows = ui.clip(count);
    rows.include(picking.keep());
    while (rows.next()) |row| self.line(&picking, row, self.at(self.shown[row]));
    picking.end();
    if (self.follow and added and ui.getScrollY() >= ui.getScrollMaxY()) ui.setScrollHereY(1);

    var menu = ui.commands("lines", .{});
    defer menu.end();
    if (menu.item(.{ .label = "Copy", .chord = devtools.keys.copy, .enabled = self.picked.count() > 0, .tooltip = "The picked lines as shown" })) {
        var clip: Clip = .{};
        for (self.shown[0..count]) |i| {
            const e = self.at(i);
            if (self.picked.contains(e.seq)) clip.line(line_fmt, lineArgs(e));
        }
        clip.copy();
    }
    menu.separator();
    if (menu.item(.{ .label = "Clear", .tooltip = "Forget what's shown so far. New lines still come in" })) {
        self.head = 0;
        self.len = 0;
        self.picked.clear();
    }
}

const Shown = struct {
    log: *const Log,

    pub fn id(self: Shown, row: usize) u64 {
        return self.log.at(self.log.shown[row]).seq;
    }
};

fn pull(self: *Log) bool {
    var added = false;
    var batch: [32]Entry = undefined;
    while (true) {
        const got = LogHistory.global.readSince(self.next_seq, &batch);
        if (got.len == 0) return added;
        for (got) |e| self.push(e);
        self.next_seq = got[got.len - 1].seq + 1;
        added = true;
    }
}

fn push(self: *Log, e: Entry) void {
    if (self.len < self.lines.len) {
        self.lines[(self.head + self.len) % self.lines.len] = e;
        self.len += 1;
    } else {
        self.lines[self.head] = e;
        self.head = (self.head + 1) % self.lines.len;
    }
}

pub fn at(self: *const Log, i: usize) *const Entry {
    return &self.lines[(self.head + i) % self.lines.len];
}

fn select(self: *Log) usize {
    const text = std.mem.sliceTo(&self.filter, 0);
    var n: usize = 0;
    for (0..self.len) |i| {
        const e = self.at(i);
        if (!self.levels.get(e.level)) continue;
        if (text.len != 0 and std.ascii.findIgnoreCase(e.message(), text) == null) continue;
        self.shown[n] = @intCast(i);
        n += 1;
    }
    return n;
}

const line_fmt = "{d:>9.3}  {s:<5}  {t:<8}  {s}";

fn lineArgs(e: *const Entry) struct { f64, []const u8, @TypeOf(e.subsystem), []const u8 } {
    return .{ @as(f64, @floatFromInt(e.time_ns)) / std.time.ns_per_s, @tagName(e.level), e.subsystem, e.message() };
}

fn line(_: *Log, picking: anytype, row: usize, e: *const Entry) void {
    // Packed ABGR, like ImGui's
    const colour: ?u32 = switch (e.level) {
        .err => 0xFF6666FF,
        .warn => 0xFF4DCCFF,
        .info => null,
        .debug => ui.getColorU32(.text_disabled),
    };
    const coloured = ui.withColor(.text, colour);
    defer coloured.end();
    _ = picking.row(row, ui.format(line_fmt ++ "##{d}", lineArgs(e) ++ .{e.seq}));
}
