//! The game's file I/O. What it opens, reads, writes and closes, what's open now, and the virtual
//! files plugins serve.

const FileIo = @This();

const std = @import("std");

const core = @import("wraith_core");
const devtools = @import("tuft_devtools");
const ui = @import("wraith_ui");

const Files = @import("../../../Files.zig");
const Clip = @import("wraith_ui").Clip;
const Vfs = Files.Vfs;
const Entry = Files.Entry;
const Op = Files.Op;

/// How often the open file list is copied again.
const refresh_ns = 250 * std.time.ns_per_ms;

window: ui.Window = .{ .title = "IO", .size = .{ 900, 380 }, .min_size = .{ 480, 200 } },
allocator: std.mem.Allocator,

/// Render thread only, oldest at `head`.
entries: [Files.capacity]Entry = undefined,
head: usize = 0,
len: usize = 0,
next_seq: u64 = 0,
shown: [Files.capacity]u16 = undefined,
ops: std.EnumArray(Op, bool) = .initFill(true),
filter: [128:0]u8 = @splat(0),
follow: bool = true,
picked: ui.Selection = .{},

open: []Vfs.Snapshot = &.{},
open_at: u64 = 0,
open_picked: ui.Selection = .{},

virtual: []Vfs.Store.Info = &.{},
virtual_at: u64 = 0,
virtual_picked: ui.Selection = .{},

pub fn deinit(self: *FileIo) void {
    self.picked.deinit();
    self.open_picked.deinit();
    self.virtual_picked.deinit();
    Vfs.freeSnapshots(self.allocator, self.open);
    Vfs.Store.freeInfos(self.allocator, self.virtual);
    self.open = &.{};
    self.virtual = &.{};
}

pub fn draw(self: *FileIo) void {
    const vfs = Files.global.vfs orelse {
        ui.textDisabled("The game's file I/O isn't being watched. Turn on file_io in the settings and restart.", .{});
        return;
    };
    const added = self.pull();
    self.refresh(vfs);

    const bar = ui.tabBar("io") orelse return;
    defer bar.end();
    if (ui.tabItem(ui.format("Activity###activity", .{}), .{})) |tab| {
        defer tab.end();
        self.drawActivity(added);
    }
    if (ui.tabItem(ui.format("Open files ({d})###open", .{self.open.len}), .{})) |tab| {
        defer tab.end();
        self.drawOpen();
    }
    if (ui.tabItem(ui.format("Virtual files ({d})###virtual", .{self.virtual.len}), .{})) |tab| {
        defer tab.end();
        self.drawVirtual(vfs);
    }
}

// Activity

fn drawActivity(self: *FileIo, added: bool) void {
    inline for (.{ .{ .open, "Opens" }, .{ .read, "Reads" }, .{ .write, "Writes" }, .{ .close, "Closes" }, .{ .fail, "Failures" } }) |pair| {
        _ = ui.checkbox(pair[1], self.ops.getPtr(pair[0]));
        ui.sameLine();
    }
    self.ops.set(.refused, self.ops.get(.write));
    var recording = Files.global.recording.load(.monotonic);
    if (ui.checkbox("Record", &recording)) Files.global.recording.store(recording, .monotonic);
    ui.sameLine();
    _ = ui.checkbox("Follow", &self.follow);
    ui.setNextItemWidth(ui.fill);
    _ = ui.inputTextHint("##filter", "Filter paths", &self.filter);

    const count = self.select();
    const table = ui.table("activity", 7, .{
        .borders = true,
        .row_background = true,
        .resizable = true,
        .sizing = .fixed_fit,
        .scroll_y = true,
    }) orelse return;
    inline for (.{ "Time", "Op", "Path", "Bytes", "Times", "Thread", "Info" }) |label| ui.tableColumn(label);
    ui.tableHeaders();
    var picking = self.picked.begin(count, Shown{ .io = self }, .{});
    var rows = ui.clip(count);
    rows.include(picking.keep());
    while (rows.next()) |row| self.activityRow(&picking, row, self.at(self.shown[row]));
    picking.end();
    if (self.follow and added and ui.getScrollY() >= ui.getScrollMaxY()) ui.setScrollHereY(1);
    table.end();

    var menu = ui.commands("activity", .{});
    defer menu.end();
    const any = self.picked.count() > 0;
    if (menu.item(.{ .label = "Copy", .chord = devtools.keys.copy, .enabled = any, .tooltip = "The picked lines as shown" })) {
        var clip: Clip = .{};
        for (self.shown[0..count]) |i| {
            const e = self.at(i);
            if (self.picked.contains(e.seq)) clip.line("{d:.3}\t{s}\t{s}\t{d}\t{d}\t{d}", .{ seconds(e.time_ns), opName(e.op), e.path.message(), e.bytes, e.count, e.thread });
        }
        clip.copy();
    }
    if (menu.item(.{ .label = "Copy path", .chord = devtools.keys.copy_address, .enabled = any })) {
        var clip: Clip = .{};
        for (self.shown[0..count]) |i| {
            const e = self.at(i);
            if (self.picked.contains(e.seq)) clip.line("{s}", .{e.path.message()});
        }
        clip.copy();
    }
    menu.separator();
    if (menu.item(.{ .label = "Clear", .tooltip = "Forget what's shown so far. New activity still comes in" })) {
        self.head = 0;
        self.len = 0;
        self.picked.clear();
    }
}

fn activityRow(_: *FileIo, picking: anytype, row: usize, e: *const Entry) void {
    const scope = ui.id(@as(i32, @truncate(@as(i64, @bitCast(e.seq)))));
    defer scope.end();
    ui.tableNextRow();
    _ = ui.tableNextColumn();
    _ = picking.row(row, ui.format("{d:.3}", .{seconds(e.time_ns)}));
    _ = ui.tableNextColumn();
    switch (e.op) {
        .fail, .refused => ui.textColored(.{ 1, 0.45, 0.4, 1 }, "{s}", .{opName(e.op)}),
        .write => ui.textColored(.{ 1, 0.75, 0.3, 1 }, "{s}", .{opName(e.op)}),
        else => ui.text("{s}", .{opName(e.op)}),
    }
    _ = ui.tableNextColumn();
    ui.text("{s}", .{e.path.message()});
    _ = ui.tableNextColumn();
    if (e.op == .read or e.op == .write or e.op == .refused or e.op == .close) bytesText(e.bytes) else ui.textDisabled("-", .{});
    _ = ui.tableNextColumn();
    if (e.count > 1) ui.text("{d}", .{e.count}) else ui.textDisabled("1", .{});
    _ = ui.tableNextColumn();
    ui.text("{d}", .{e.thread});
    _ = ui.tableNextColumn();
    if (e.op == .fail) {
        ui.textColored(.{ 1, 0.45, 0.4, 1 }, "{s}", .{statusName(e.status)});
        if (ui.isItemHovered()) ui.tooltip("NTSTATUS 0x{x:0>8}", .{e.status});
    } else if (e.virtual) {
        ui.textColored(.{ 0.55, 0.75, 1, 1 }, "virtual", .{});
    } else if (e.redirected) {
        ui.textColored(.{ 0.55, 0.75, 1, 1 }, "redirected", .{});
    }
}

const Shown = struct {
    io: *const FileIo,

    pub fn id(self: Shown, row: usize) u64 {
        return self.io.at(self.io.shown[row]).seq;
    }
};

/// Takes what's new, and the newest again since back to back reads grow it.
fn pull(self: *FileIo) bool {
    var added = false;
    var batch: [64]Entry = undefined;
    var from = if (self.len > 0) self.next_seq -| 1 else self.next_seq;
    while (true) {
        const got = Files.global.readSince(from, &batch);
        if (got.len == 0) return added;
        for (got) |e| {
            if (self.len > 0 and self.atMut(self.len - 1).seq == e.seq) {
                self.atMut(self.len - 1).* = e;
            } else if (e.seq >= self.next_seq) {
                self.push(e);
                added = true;
            }
        }
        self.next_seq = got[got.len - 1].seq + 1;
        from = self.next_seq;
        if (got.len < batch.len) return added;
    }
}

fn push(self: *FileIo, e: Entry) void {
    if (self.len < self.entries.len) {
        self.entries[(self.head + self.len) % self.entries.len] = e;
        self.len += 1;
    } else {
        self.entries[self.head] = e;
        self.head = (self.head + 1) % self.entries.len;
    }
}

fn at(self: *const FileIo, i: usize) *const Entry {
    return &self.entries[(self.head + i) % self.entries.len];
}

fn atMut(self: *FileIo, i: usize) *Entry {
    return &self.entries[(self.head + i) % self.entries.len];
}

fn select(self: *FileIo) usize {
    const text = std.mem.sliceTo(&self.filter, 0);
    var n: usize = 0;
    for (0..self.len) |i| {
        const e = self.at(i);
        if (!self.ops.get(e.op)) continue;
        if (text.len != 0 and std.ascii.findIgnoreCase(e.path.message(), text) == null) continue;
        self.shown[n] = @intCast(i);
        n += 1;
    }
    return n;
}

// Open files

fn refresh(self: *FileIo, vfs: *Vfs) void {
    const now = core.timing.now();
    if (now -| self.open_at < refresh_ns and self.open_at != 0) return;
    self.open_at = now;
    if (vfs.openFiles(self.allocator)) |files| {
        Vfs.freeSnapshots(self.allocator, self.open);
        self.open = files;
    } else |_| {}
    if (vfs.store.files(self.allocator)) |files| {
        Vfs.Store.freeInfos(self.allocator, self.virtual);
        self.virtual = files;
    } else |_| {}
}

const OpenColumn = enum { path, access, kind, handles, reads, read, writes, written, thread, age };

fn drawOpen(self: *FileIo) void {
    const table = ui.table("open", 10, .{
        .borders = true,
        .row_background = true,
        .resizable = true,
        .sortable = true,
        .sizing = .fixed_fit,
        .scroll_x = true,
        .scroll_y = true,
        .frozen_columns = 1,
    }) orelse return;
    inline for (.{ "Path", "Access", "Kind", "Handles", "Reads", "Read", "Writes", "Written", "Thread", "Open for" }) |label| ui.tableColumn(label);
    ui.tableHeaders();
    table.sort(OpenColumn, Vfs.Snapshot, self.open, {}, openOrder);

    var picking = self.open_picked.begin(self.open.len, ui.Selection.Rows(Vfs.Snapshot, openId){ .rows = self.open }, .{});
    var rows = ui.clip(self.open.len);
    rows.include(picking.keep());
    while (rows.next()) |i| {
        const f = &self.open[i];
        const scope = ui.id(@as(i32, @truncate(@as(i64, @bitCast(f.id)))));
        defer scope.end();
        ui.tableNextRow();
        _ = ui.tableNextColumn();
        _ = picking.row(i, ui.format("{s}", .{f.path}));
        if (ui.isItemHovered()) if (f.requested) |r| ui.tooltip("The game asked for {s}", .{r});
        _ = ui.tableNextColumn();
        ui.text("{s}", .{accessText(f.access)});
        _ = ui.tableNextColumn();
        if (f.kind == .virtual) ui.textColored(.{ 0.55, 0.75, 1, 1 }, "virtual", .{}) else if (f.requested != null) ui.textColored(.{ 0.55, 0.75, 1, 1 }, "redirected", .{}) else ui.text("{s}", .{if (f.directory) "folder" else "file"});
        _ = ui.tableNextColumn();
        ui.text("{d}", .{f.handles});
        _ = ui.tableNextColumn();
        ui.text("{d}", .{f.reads});
        _ = ui.tableNextColumn();
        bytesText(f.bytes_read);
        if (f.pending > 0 and ui.isItemHovered()) ui.tooltip("Plus {d} read(s) that finished later", .{f.pending});
        _ = ui.tableNextColumn();
        ui.text("{d}", .{f.writes});
        _ = ui.tableNextColumn();
        bytesText(f.bytes_written);
        _ = ui.tableNextColumn();
        ui.text("{d}", .{f.thread});
        _ = ui.tableNextColumn();
        ui.text("{d:.1}s", .{seconds(sys_clock.now() -| f.opened_ns)});
    }
    picking.end();
    table.end();

    var menu = ui.commands("open", .{});
    defer menu.end();
    const any = self.open_picked.count() > 0;
    if (menu.item(.{ .label = "Copy path", .chord = devtools.keys.copy, .enabled = any })) {
        var clip: Clip = .{};
        for (self.open) |*f| if (self.open_picked.contains(f.id)) clip.line("{s}", .{f.path});
        clip.copy();
    }
}

/// `Snapshot.opened_ns` is on tuft's clock.
const sys_clock = struct {
    fn now() u64 {
        return @import("tuft_sys").clock.nanos();
    }
};

fn openId(f: *const Vfs.Snapshot) u64 {
    return f.id;
}

fn openOrder(_: void, column: ?OpenColumn, a: Vfs.Snapshot, b: Vfs.Snapshot) std.math.Order {
    return switch (column orelse return std.math.order(a.id, b.id)) {
        .path => std.ascii.orderIgnoreCase(a.path, b.path),
        .access => std.math.order(@as(u8, @bitCast(a.access)), @as(u8, @bitCast(b.access))),
        .kind => std.math.order(@backingInt(a.kind), @backingInt(b.kind)),
        .handles => std.math.order(a.handles, b.handles),
        .reads => std.math.order(a.reads, b.reads),
        .read => std.math.order(a.bytes_read, b.bytes_read),
        .writes => std.math.order(a.writes, b.writes),
        .written => std.math.order(a.bytes_written, b.bytes_written),
        .thread => std.math.order(a.thread, b.thread),
        .age => std.math.order(b.opened_ns, a.opened_ns),
    };
}

// Virtual files

fn drawVirtual(self: *FileIo, vfs: *Vfs) void {
    if (self.virtual.len == 0) {
        ui.textDisabled("None. Plugins and scripts serve them with vfs.put.", .{});
        return;
    }
    const table = ui.table("virtual", 2, .{ .borders = true, .row_background = true, .resizable = true, .sizing = .fixed_fit, .scroll_y = true }) orelse return;
    ui.tableColumn("Path");
    ui.tableColumn("Size");
    ui.tableHeaders();
    var picking = self.virtual_picked.begin(self.virtual.len, ui.Selection.Indices{}, .{});
    for (self.virtual, 0..) |*f, i| {
        const scope = ui.id(@as(i32, @intCast(i)));
        defer scope.end();
        ui.tableNextRow();
        _ = ui.tableNextColumn();
        _ = picking.row(i, ui.format("{s}", .{f.path}));
        _ = ui.tableNextColumn();
        bytesText(f.size);
    }
    picking.end();
    table.end();

    var menu = ui.commands("virtual", .{});
    defer menu.end();
    const any = self.virtual_picked.count() > 0;
    if (menu.item(.{ .label = "Copy path", .chord = devtools.keys.copy, .enabled = any })) {
        var clip: Clip = .{};
        for (self.virtual, 0..) |*f, i| if (self.virtual_picked.contains(i)) clip.line("{s}", .{f.path});
        clip.copy();
    }
    menu.separator();
    if (menu.item(.{ .label = "Remove", .chord = devtools.keys.delete, .enabled = any, .tooltip = "The game can't open them anymore. Handles it has keep working" })) {
        for (self.virtual, 0..) |*f, i| if (self.virtual_picked.contains(i)) {
            _ = vfs.remove(f.path);
        };
        self.virtual_picked.clear();
        self.open_at = 0;
    }
}

// Text

fn seconds(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
}

fn opName(op: Op) []const u8 {
    return switch (op) {
        .open => "open",
        .fail => "failed",
        .read => "read",
        .write => "write",
        .refused => "refused",
        .close => "close",
    };
}

fn accessText(a: Vfs.Access) []const u8 {
    if (a.write and a.read) return "read/write";
    if (a.write) return "write";
    if (a.append) return "append";
    if (a.read) return "read";
    if (a.execute) return "execute";
    if (a.delete) return "delete";
    return "-";
}

fn statusName(status: u32) []const u8 {
    return switch (status) {
        0xC0000034, 0xC000003A => "not found",
        0xC0000022 => "access denied",
        0xC0000043 => "in use",
        0xC0000035 => "already exists",
        0xC00000BA => "is a folder",
        0xC0000103 => "not a folder",
        0xC00000A2 => "write protected",
        0xC0000033 => "bad name",
        else => "failed",
    };
}

fn bytesText(n: u64) void {
    const f: f64 = @floatFromInt(n);
    if (n < 1024) return ui.text("{d} B", .{n});
    if (n < 1024 * 1024) return ui.text("{d:.1} KB", .{f / 1024});
    if (n < 1024 * 1024 * 1024) return ui.text("{d:.1} MB", .{f / (1024 * 1024)});
    ui.text("{d:.2} GB", .{f / (1024 * 1024 * 1024)});
}
