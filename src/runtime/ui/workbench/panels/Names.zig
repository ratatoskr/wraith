//! Every name there is: addresses with ids, schema statics, plugins' and tweaks' names, and
//! signature scans, with where each is now or why it isn't anywhere.

const NamesPanel = @This();

const std = @import("std");

const core = @import("wraith_core");
const devtools = @import("tuft_devtools");
const Schema = @import("salamander_schema").Schema;
const memory = @import("tuft_mem");
const values = memory.values;
const Kind = values.Kind;
const ui = @import("wraith_ui");
const Atomic = @import("tuft_arch").atomic.Value;

const Names = @import("../../../Names.zig");
const Navigator = @import("../Navigator.zig");
const Clip = @import("wraith_ui").Clip;
const Workbench = @import("../Workbench.zig");

const AddressList = devtools.AddressList;
const Info = Names.Info;

/// More are left out, so a runaway plugin can't make it crawl.
const max_listed = 16384;
/// User entries and where things are change without a new generation, so it looks again anyway.
const refresh_ns = std.time.ns_per_s / 2;

const red: [4]f32 = .{ 1, 0.4, 0.4, 1 };
const orange: [4]f32 = .{ 1, 0.7, 0.2, 1 };
const green: [4]f32 = .{ 0.4, 0.9, 0.4, 1 };

nav: Navigator,
allocator: std.mem.Allocator,
/// Where Add to addresses goes. Null in the overlay, which can't reach the workbench's list.
wb: ?*Workbench = null,
infos: std.ArrayList(Info) = .empty,
/// What the filters let through, in the table's order.
shown: std.ArrayList(*const Info) = .empty,
/// How many there were, listed or not.
total: usize = 0,
generation: u32 = 0,
refreshed_ns: u64 = 0,
picked: ui.Selection = .{},
filter: Filter = .all,
kind: KindFilter = .any,
/// Only this plugin's, or the like. Empty for everyone's.
group: [64:0]u8 = @splat(0),
/// Each group once, pointing into `infos`, with "Any plugin" first.
groups: std.ArrayList([:0]const u8) = .empty,
search: [128:0]u8 = @splat(0),
// The scan box
module: [64:0]u8 = @splat(0),
section: [16:0]u8 = blk: {
    var s: [16:0]u8 = @splat(0);
    @memcpy(s[0..5], ".text");
    break :blk s;
},
name: [64:0]u8 = @splat(0),
pattern: [256:0]u8 = @splat(0),
last_scan: ?(anyerror!Names.Result) = null,
/// Which copies of the game's code rescans and new scans read.
scan_from: ScanFrom = .fallback,
/// Rescan all, which runs on a thread of its own.
worker: ?std.Thread = null,
progress: Names.Progress = .{},
running: Atomic(bool) = .init(false),

pub const Filter = enum {
    all,
    user,
    schemas,
    plugins,
    tweaks,
    scans,

    const labels: []const [:0]const u8 = &.{ "All", "User", "Schemas", "Plugins", "Tweaks", "Scans" };

    fn lets(self: Filter, source: Names.Origin) bool {
        return switch (self) {
            .all => true,
            .user => source == .user,
            .schemas => source == .schema,
            .plugins => source == .plugin,
            .tweaks => source == .tweak,
            .scans => source == .scan,
        };
    }
};

pub const ScanFrom = enum {
    fallback,
    live,
    snapshot,
    disk,

    const labels: []const [:0]const u8 = &.{ "Fall through", "Live", "Snapshot", "Disk" };

    fn sources(self: ScanFrom) memory.Sources {
        return switch (self) {
            .fallback => .all,
            .live => .only(.live),
            .snapshot => .only(.snapshot),
            .disk => .only(.disk),
        };
    }
};

pub const KindFilter = enum {
    any,
    data,
    functions,
    other,

    const labels: []const [:0]const u8 = &.{ "Any kind", "Data", "Functions", "Other" };

    fn lets(self: KindFilter, kind: Names.Kind) bool {
        return switch (self) {
            .any => true,
            .data => kind == .data,
            .functions => kind == .function,
            .other => kind == .other,
        };
    }
};

pub fn deinit(self: *NamesPanel) void {
    self.progress.cancel.store(true, .release);
    if (self.worker) |w| w.join();
    self.worker = null;
    self.picked.deinit();
    self.infos.deinit(self.allocator);
    self.shown.deinit(self.allocator);
    self.groups.deinit(self.allocator);
}

/// Copies them all again, then filters.
pub fn refresh(self: *NamesPanel) void {
    self.refreshed_ns = core.timing.now();
    self.generation = Names.global.generation();
    self.total = Names.global.count();
    self.shown.clearRetainingCapacity();
    self.groups.clearRetainingCapacity();
    self.infos.resize(self.allocator, @min(self.total, max_listed)) catch return;
    self.infos.shrinkRetainingCapacity(Names.global.list(self.infos.items));
    self.listGroups();
    self.refilter();
}

fn listGroups(self: *NamesPanel) void {
    self.groups.append(self.allocator, "Any plugin") catch return;
    for (self.infos.items) |*info| {
        const g = info.group.get();
        if (g.len == 0) continue;
        const seen = for (self.groups.items[1..]) |had| {
            if (std.mem.eql(u8, had, g)) break true;
        } else false;
        if (!seen) self.groups.append(self.allocator, g) catch return;
    }
    std.mem.sort([:0]const u8, self.groups.items[1..], {}, struct {
        fn less(_: void, a: [:0]const u8, b: [:0]const u8) bool {
            return std.ascii.lessThanIgnoreCase(a, b);
        }
    }.less);
}

/// Next frame, since rows point into what it copied.
fn refreshSoon(self: *NamesPanel) void {
    self.refreshed_ns = 0;
}

fn refilter(self: *NamesPanel) void {
    self.shown.clearRetainingCapacity();
    const text = std.mem.trim(u8, std.mem.sliceTo(&self.search, 0), " \t");
    const group = std.mem.sliceTo(&self.group, 0);
    for (self.infos.items) |*info| {
        if (!self.filter.lets(info.origin) or !self.kind.lets(info.kind) or !matches(info, text)) continue;
        if (group.len > 0 and !std.mem.eql(u8, info.group.get(), group)) continue;
        self.shown.append(self.allocator, info) catch return;
    }
}

fn matches(info: *const Info, text: []const u8) bool {
    if (text.len == 0) return true;
    const scan_pattern = if (info.scan) |*s| s.pattern.get() else "";
    for ([_][]const u8{ info.name.get(), info.label.get(), info.group.get(), info.text.get(), info.type.get(), scan_pattern }) |field| {
        if (std.ascii.findIgnoreCase(field, text) != null) return true;
    }
    return false;
}

pub fn draw(self: *NamesPanel) void {
    const now = core.timing.now();
    if (Names.global.generation() != self.generation or now -| self.refreshed_ns >= refresh_ns) self.refresh();

    var which: usize = @backingInt(self.filter);
    ui.setNextItemWidth(110);
    if (ui.combo("##source", &which, Filter.labels)) {
        self.filter = @fromBackingInt(@intCast(which));
        self.refilter();
    }
    ui.sameLine();
    var kind: usize = @backingInt(self.kind);
    ui.setNextItemWidth(100);
    if (ui.combo("##kind", &kind, KindFilter.labels)) {
        self.kind = @fromBackingInt(@intCast(kind));
        self.refilter();
    }
    ui.sameLine();
    self.groupCombo();
    ui.sameLine();
    ui.setNextItemWidth(220);
    if (ui.inputTextHint("##filter", "Filter by name, type or text", &self.search)) self.refilter();
    ui.sameLine();
    if (self.total > self.infos.items.len) {
        ui.textDisabled("{d} of {d} shown, the first {d} listed", .{ self.shown.items.len, self.total, self.infos.items.len });
    } else {
        ui.textDisabled("{d} of {d} shown", .{ self.shown.items.len, self.total });
    }
    ui.sameLine();
    var from: usize = @backingInt(self.scan_from);
    ui.setNextItemWidth(150);
    if (ui.combo("##scan_from", &from, ScanFrom.labels)) self.scan_from = @fromBackingInt(@intCast(from));
    ui.tooltip("What rescans and new scans read: the game's code as it is now, the snapshot taken as Wraith started, or the game's exe on disk. Falling through tries each till one has it, for code something hooked", .{});
    if (self.rescanning()) {
        ui.sameLine();
        ui.textColored(orange, "Rescanning, {d} of {d}", .{ self.progress.done.load(.acquire), self.progress.total.load(.acquire) });
    }

    if (ui.collapsingHeader("New scan", false)) self.scanBox();

    const table = ui.table("names", 7, .{
        .borders = true,
        .row_background = true,
        .resizable = true,
        .sortable = true,
        .sizing = .stretch_prop,
        .scroll_y = true,
    }) orelse return;
    ui.tableColumnWith("Name", .{ .stretch = true, .width = 2 });
    ui.tableColumnWith("Kind", .{ .stretch = true, .width = 0.6 });
    ui.tableColumnWith("Source", .{ .stretch = true, .width = 1 });
    ui.tableColumnWith("Location", .{ .stretch = true, .width = 3 });
    ui.tableColumnWith("Address", .{ .stretch = true, .width = 1.5 });
    ui.tableColumnWith("Type", .{ .stretch = true, .width = 1 });
    ui.tableColumnWith("Status", .{ .stretch = true, .width = 2 });
    ui.tableHeaders();
    const rows = self.shown.items;
    table.sort(Column, *const Info, rows, {}, order);

    var picking = self.picked.begin(rows.len, ui.Selection.Rows(*const Info, idOf){ .rows = rows }, .{});
    var clipper = ui.clip(rows.len);
    clipper.include(picking.keep());
    while (clipper.next()) |i| {
        const info = rows[i];
        const scope = ui.id(@as(i32, @truncate(@as(i64, @bitCast(info.id)))));
        defer scope.end();
        ui.tableNextRow();
        _ = ui.tableNextColumn();
        _ = picking.row(i, ui.format("{s}", .{info.name.get()}));
        if (info.label.len() > 0 and !std.mem.eql(u8, info.label.get(), info.name.get()) and ui.isItemHovered()) ui.tooltip("{s}", .{info.label.get()});
        _ = ui.tableNextColumn();
        switch (info.kind) {
            .data => ui.textDisabled("data", .{}),
            .function => ui.textDisabled("function", .{}),
            .other => {},
        }
        _ = ui.tableNextColumn();
        drawSource(info);
        _ = ui.tableNextColumn();
        drawLocation(info);
        _ = ui.tableNextColumn();
        if (info.address) |at| ui.text("0x{x}", .{at}) else ui.textDisabled("-", .{});
        _ = ui.tableNextColumn();
        drawType(info);
        _ = ui.tableNextColumn();
        drawStatus(info);
    }
    picking.end();
    // The menu after the table, not in it, or its items can't be clicked
    table.end();
    self.commands(rows);
}

fn groupCombo(self: *NamesPanel) void {
    if (self.groups.items.len == 0) return;
    const group = std.mem.sliceTo(&self.group, 0);
    var which: usize = 0;
    if (group.len > 0) {
        for (self.groups.items[1..], 1..) |g, i| if (std.mem.eql(u8, g, group)) {
            which = i;
        };
    }
    ui.setNextItemWidth(140);
    if (!ui.combo("##group", &which, self.groups.items)) return;
    self.group = @splat(0);
    if (which > 0) {
        const g = self.groups.items[which];
        const n = @min(g.len, self.group.len);
        @memcpy(self.group[0..n], g[0..n]);
    }
    self.refilter();
}

fn drawSource(info: *const Info) void {
    ui.text("{s}", .{sourceName(info.origin)});
    const group = groupOf(info);
    if (group.len == 0) return;
    ui.sameLine();
    ui.textDisabled("{s}", .{group});
}

fn sourceName(source: Names.Origin) []const u8 {
    return switch (source) {
        .user => "user",
        .schema => "schema",
        .plugin => "plugin",
        .tweak => "tweak",
        .scan => "scan",
    };
}

/// Its plugin, tweak or scanner. The open project's own schemas have none.
fn groupOf(info: *const Info) []const u8 {
    return switch (info.origin) {
        .user => "",
        else => info.group.get(),
    };
}

fn drawLocation(info: *const Info) void {
    if (info.scan) |*s| {
        ui.text("sig(\"{s}\")", .{s.pattern.get()});
        if (ui.isItemHovered()) ui.tooltip("{s}\n0x{x} .. 0x{x} ({Bi:.1})", .{ s.pattern.get(), s.start, s.start + s.len, s.len });
        ui.sameLine();
        if (s.section.len() != 0) {
            ui.textDisabled("{s} {s}", .{ s.module.get(), s.section.get() });
        } else {
            ui.textDisabled("{s}", .{if (s.module.len() != 0) s.module.get() else "?"});
        }
        return;
    }
    if (info.text.len() == 0) {
        if (info.address) |at| ui.text("0x{x}", .{at});
        return;
    }
    ui.text("{s}", .{info.text.get()});
    if (ui.isItemHovered()) ui.tooltip("{s}", .{info.text.get()});
    for (info.offsets[0..info.offsets_len]) |o| {
        ui.sameLine();
        if (o < 0) ui.textDisabled("[-0x{x}]", .{@abs(o)}) else ui.textDisabled("[0x{x}]", .{o});
    }
}

fn drawType(info: *const Info) void {
    if (info.type.len() > 0) {
        ui.text("{s}", .{info.type.get()});
        if (info.size == 0) return;
        ui.sameLine();
    }
    if (info.size > 0) ui.textDisabled("{d} B", .{info.size});
}

fn drawStatus(info: *const Info) void {
    if (info.scan) |*s| return drawScanStatus(s);
    if (info.failed) |*f| {
        ui.textColored(red, "{s}", .{f.message.message()});
        if (ui.isItemHovered()) ui.tooltip("{s}", .{f.message.message()});
        return;
    }
    if (info.address != null) {
        ui.textColored(green, "found", .{});
    } else {
        ui.textDisabled("not looked for yet", .{});
    }
}

/// What it found when its owner scanned, and what it finds now if it was rescanned.
fn drawScanStatus(s: *const Names.ScanInfo) void {
    const now = s.rescanned orelse s.scanned;
    if (s.rescanned) |again| {
        if (again.outcome == .found and s.scanned.outcome == .found and again.address != s.scanned.address) {
            ui.textColored(orange, "moved", .{});
            ui.tooltip("Found somewhere else than when its owner scanned it", .{});
            ui.sameLine();
        }
    }
    switch (now.source) {
        .live => {},
        .snapshot => {
            ui.textDisabled("[snapshot]", .{});
            ui.tooltip("Found in the snapshot of the game's code taken as Wraith started. Something's hooked it since", .{});
            ui.sameLine();
        },
        .disk => {
            ui.textDisabled("[disk]", .{});
            ui.tooltip("Found in the game's exe on disk. Something hooked it before Wraith started", .{});
            ui.sameLine();
        },
    }
    if (now.err) |err| {
        ui.textColored(red, "{t}", .{err});
    } else switch (now.outcome) {
        .found => ui.textColored(green, "found", .{}),
        .not_found => ui.textColored(red, "not found", .{}),
        .not_unique => ui.textColored(orange, "not unique", .{}),
    }
    if (!ui.isItemHovered()) return;
    if (s.rescanned) |again| {
        ui.tooltip("First scan: {s} in {d:.2} ms\nRescanned: {d} match(es) in {d:.2} ms", .{ outcomeName(s.scanned), ms(s.scanned.ns), again.matches orelse 0, ms(again.ns) });
    } else {
        ui.tooltip("Scanned in {d:.2} ms. Rescan to count its matches", .{ms(s.scanned.ns)});
    }
}

fn outcomeName(r: Names.Result) []const u8 {
    if (r.err != null) return "failed";
    return switch (r.outcome) {
        .found => "found",
        .not_found => "not found",
        .not_unique => "not unique",
    };
}

fn commands(self: *NamesPanel, rows: []const *const Info) void {
    const keys = &devtools.keys;
    var menu = ui.commands("names", .{ .activated = self.picked.activated });
    defer menu.end();
    const one = self.focused(rows);
    const any = self.picked.count() > 0;
    var scans = false;
    var unfound = false;
    for (rows) |info| if (self.picked.contains(info.id)) {
        if (info.scan != null) scans = true;
        if (lookable(info)) unfound = true;
    };

    if (menu.item(.{ .label = "Show in memory", .chord = keys.show_memory, .enabled = one != null, .default = true, .tooltip = "Looks for it first if it hasn't been. A scan's bytes are marked" })) {
        const len = lengthOf(one.?);
        if (self.whereIs(one.?)) |at| self.nav.openMemory(at, len, .{ .start = at, .len = len });
    }
    if (menu.item(.{ .label = "Show as code", .chord = keys.show_code, .enabled = one != null })) {
        if (self.whereIs(one.?)) |at| self.nav.openCode(at);
    }
    if (menu.item(.{ .label = "Add to addresses", .chord = keys.add_to_list, .enabled = any and self.wb != null, .tooltip = if (self.wb == null) "From the workbench's Names" else "An entry of your own that points at it by name, typed when the type's known" })) {
        for (rows) |info| if (self.picked.contains(info.id)) self.addToAddresses(info);
    }
    if (menu.item(.{ .label = "Rescan", .enabled = scans or unfound, .tooltip = "Scan the picked ones again, to see what they find now. Ones not looked for yet get looked for" })) {
        for (rows) |info| if (self.picked.contains(info.id)) {
            if (info.scan != null) {
                _ = Names.global.rescan(info.id, self.scan_from.sources());
            } else if (lookable(info)) {
                _ = Names.global.get(info.name.get()) catch {};
            }
        };
        self.refreshSoon();
    }
    menu.separator();
    if (menu.item(.{ .label = "Copy name", .chord = keys.copy, .enabled = any })) {
        var clip: Clip = .{};
        for (rows) |info| if (self.picked.contains(info.id)) clip.line("{s}", .{info.name.get()});
        clip.copy();
    }
    if (menu.item(.{ .label = "Copy address", .chord = keys.copy_address, .enabled = any, .tooltip = "Where each is now, if it was found" })) {
        var clip: Clip = .{};
        for (rows) |info| if (self.picked.contains(info.id)) {
            if (info.address) |at| clip.line("0x{x}", .{at});
        };
        clip.copy();
    }
    if (menu.item(.{ .label = "Copy pattern", .enabled = scans })) {
        var clip: Clip = .{};
        for (rows) |info| if (self.picked.contains(info.id)) {
            if (info.scan) |*s| clip.line("{s}", .{s.pattern.get()});
        };
        clip.copy();
    }
    if (menu.item(.{ .label = "Copy rows", .enabled = any, .tooltip = "Name, kind, source, address and status, one per line" })) {
        var clip: Clip = .{};
        for (rows) |info| if (self.picked.contains(info.id)) {
            var status_buf: [600]u8 = undefined;
            clip.line("{s}\t{s}\t{s}\t{s}\t{s}", .{ info.name.get(), @tagName(info.kind), sourceName(info.origin), if (info.address) |at| ui.format("0x{x}", .{at}) else "-", statusText(info, &status_buf) });
        };
        clip.copy();
    }
    menu.separator();
    if (self.rescanning()) {
        if (menu.item(.{ .label = "Stop rescanning" })) self.progress.cancel.store(true, .release);
    } else if (menu.item(.{ .label = "Rescan all", .tooltip = "Scan every signature again, and look for every name that isn't anywhere yet, so signatures nothing's used get scanned too" })) {
        self.rescanAll();
    }
}

/// A name with location text that isn't anywhere yet, so looking for it might scan.
fn lookable(info: *const Info) bool {
    return info.scan == null and info.text.len() > 0 and info.address == null;
}

fn rescanning(self: *NamesPanel) bool {
    return self.running.load(.acquire);
}

/// On a thread, since there can be thousands of signatures.
pub fn rescanAll(self: *NamesPanel) void {
    if (self.rescanning()) return;
    // The last one's done, so this doesn't wait
    if (self.worker) |w| w.join();
    self.worker = null;
    self.progress = .{};
    self.running.store(true, .release);
    self.worker = std.Thread.spawn(.{}, rescanWork, .{ self, self.scan_from.sources() }) catch {
        Names.global.scanEverything(self.scan_from.sources(), &self.progress);
        self.running.store(false, .release);
        self.refreshSoon();
        return;
    };
}

fn rescanWork(self: *NamesPanel, sources: memory.Sources) void {
    Names.global.scanEverything(sources, &self.progress);
    self.running.store(false, .release);
}

fn statusText(info: *const Info, buf: []u8) []const u8 {
    if (info.failed) |*f| {
        const m = f.message.message();
        const n = @min(m.len, buf.len);
        @memcpy(buf[0..n], m[0..n]);
        return buf[0..n];
    }
    return if (info.address != null) "found" else "not looked for yet";
}

/// Where it is now. Looks for it, maybe scanning, if that's not known yet.
fn whereIs(self: *NamesPanel, info: *const Info) ?usize {
    if (info.address) |at| return at;
    const at = Names.global.get(info.name.get()) catch null;
    self.refreshSoon();
    return at;
}

fn lengthOf(info: *const Info) usize {
    if (info.scan) |*s| return (s.pattern.len() + 1) / 3;
    return if (info.size > 0) @min(info.size, 4096) else 16;
}

fn addToAddresses(self: *NamesPanel, info: *const Info) void {
    const wb = self.wb orelse return;
    var buf: [256]u8 = undefined;
    const item = itemFor(info, wb.panels.addresses.schemas.items, &buf) orelse return;
    wb.panels.addresses.addItem(item);
}

/// An entry at `(name)`, or `[name]` for a pointer to a struct like `Player*`, typed like the name.
/// Null if the name doesn't fit in `buf`.
pub fn itemFor(info: *const Info, schemas: []const *const Schema, buf: []u8) ?AddressList.Item {
    const name = info.name.get();
    var t = std.mem.trim(u8, info.type.get(), " ");
    var count: []const u8 = "";
    if (std.mem.indexOfScalar(u8, t, '[')) |open| if (t.len > open + 1 and t[t.len - 1] == ']') {
        count = t[open + 1 .. t.len - 1];
        t = t[0..open];
    };
    const through = t.len > 1 and t[t.len - 1] == '*' and count.len == 0 and isStruct(schemas, t[0 .. t.len - 1]);
    if (through) t = t[0 .. t.len - 1];
    const plain = isPlain(name);
    const address = (if (through)
        (if (plain) std.fmt.bufPrint(buf, "[{s}]", .{name}) else std.fmt.bufPrint(buf, "[\"{s}\"]", .{name}))
    else if (plain)
        std.fmt.bufPrint(buf, "({s})", .{name})
    else
        std.fmt.bufPrint(buf, "(\"{s}\")", .{name})) catch return null;

    var item: AddressList.Item = .{
        .name = if (info.label.len() > 0) info.label.get() else name,
        .address = address,
        .count = count,
    };
    if (t.len > 0 and isSchemaType(schemas, t)) {
        item.type = t;
    } else if (kindOf(t)) |kind| {
        item.kind = kind;
    } else if (info.scan) |*s| {
        item.kind = .bytes;
        item.length = @intCast(@min((s.pattern.len() + 1) / 3, values.max_len));
    } else if (info.size > 0 and count.len == 0) {
        item.kind = AddressList.kindForLength(info.size);
        if (item.kind == .bytes) item.length = @intCast(@min(info.size, values.max_len));
    }
    return item;
}

/// Location text can name it without quotes.
fn isPlain(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '.' and ch != '!') return false;
    return !std.mem.eql(u8, name, "sig");
}

fn isStruct(schemas: []const *const Schema, name: []const u8) bool {
    for (schemas) |s| if (s.findType(name)) |t| return t.kind == .@"struct";
    return false;
}

fn isSchemaType(schemas: []const *const Schema, name: []const u8) bool {
    for (schemas) |s| if (s.findType(name) != null) return true;
    return false;
}

/// Plain values, by the names schemas use or the address list's own.
fn kindOf(t: []const u8) ?Kind {
    if (std.meta.stringToEnum(Kind, t)) |k| return k;
    const pointer: Kind = if (@sizeOf(usize) == 8) .eight_bytes else .four_bytes;
    if (t.len > 0 and t[0] == '*') return pointer;
    const Plain = struct { []const u8, Kind };
    const plain = [_]Plain{
        .{ "u8", .byte },        .{ "i8", .byte },         .{ "bool", .byte },
        .{ "u16", .two_bytes },  .{ "i16", .two_bytes },   .{ "u32", .four_bytes },
        .{ "i32", .four_bytes }, .{ "u64", .eight_bytes }, .{ "i64", .eight_bytes },
        .{ "f32", .float },      .{ "f64", .double },      .{ "usize", pointer },
        .{ "isize", pointer },
    };
    for (plain) |p| if (std.mem.eql(u8, p[0], t)) return p[1];
    return null;
}

fn focused(self: *const NamesPanel, rows: []const *const Info) ?*const Info {
    const id = self.picked.focused() orelse return null;
    for (rows) |info| if (info.id == id) return info;
    return null;
}

fn idOf(info: *const *const Info) u64 {
    return info.*.id;
}

const Column = enum { name, kind, source, location, address, type, status };

fn order(_: void, column: ?Column, a: *const Info, b: *const Info) std.math.Order {
    return switch (column orelse return std.math.order(a.id, b.id)) {
        .name => std.mem.order(u8, a.name.get(), b.name.get()),
        .kind => std.math.order(@backingInt(a.kind), @backingInt(b.kind)),
        .source => switch (std.math.order(@backingInt(a.origin), @backingInt(b.origin))) {
            .eq => std.mem.order(u8, a.group.get(), b.group.get()),
            else => |o| o,
        },
        .location => std.mem.order(u8, a.text.get(), b.text.get()),
        // Not found goes last
        .address => if (a.address) |x|
            (if (b.address) |y| std.math.order(x, y) else .lt)
        else if (b.address != null) .gt else .eq,
        .type => std.mem.order(u8, a.type.get(), b.type.get()),
        .status => std.math.order(@intFromBool(a.failed != null), @intFromBool(b.failed != null)),
    };
}

fn scanBox(self: *NamesPanel) void {
    ui.setNextItemWidth(160);
    _ = ui.inputTextHint("##module", "module (the game)", &self.module);
    ui.tooltip("A loaded module's file name, like kernel32.dll. Empty for the game's executable", .{});
    ui.sameLine();
    ui.setNextItemWidth(90);
    _ = ui.inputTextHint("##section", "whole image", &self.section);
    ui.tooltip("A section, like .text. Empty for the whole image", .{});
    ui.sameLine();
    ui.setNextItemWidth(160);
    _ = ui.inputTextHint("##name", "name", &self.name);
    ui.setNextItemWidth(ui.fill);
    const entered = ui.inputTextWith("##pattern", &self.pattern, .{ .hint = "48 8B 05 ?? ?? ?? ?? C3, then Enter to scan", .flags = .{ .enter_returns_true = true } });
    const pattern = std.mem.sliceTo(&self.pattern, 0);
    if (entered and pattern.len > 0) self.scanNow();
    if (self.last_scan) |last| {
        if (last) |r| {
            switch (r.outcome) {
                .found => ui.textColored(green, "found at 0x{x}", .{r.address}),
                .not_found => ui.textColored(red, "not found", .{}),
                .not_unique => ui.textColored(orange, "not unique", .{}),
            }
            ui.sameLine();
            ui.textDisabled("{d} match(es) in {d:.2} ms{s}", .{ r.matches orelse 0, ms(r.ns), switch (r.source) {
                .live => "",
                .snapshot => ", in the snapshot",
                .disk => ", in the exe on disk",
            } });
        } else |err| {
            ui.textColored(red, "{t}", .{err});
        }
    }
    ui.spacing();
}

/// Scans for what's in the scan box, and lists it under the user's scans.
pub fn scanNow(self: *NamesPanel) void {
    const pattern = std.mem.sliceTo(&self.pattern, 0);
    const name = std.mem.sliceTo(&self.name, 0);
    self.last_scan = Names.global.scanManual(
        if (name.len == 0) pattern else name,
        std.mem.sliceTo(&self.module, 0),
        std.mem.sliceTo(&self.section, 0),
        pattern,
        self.scan_from.sources(),
    );
    self.refresh();
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}
