//! What writes or reads an address, like Cheat Engine's, using the CPU's debug registers.

const Accesses = @This();

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;
const Names = @import("../../../Names.zig");

const core = @import("wraith_core");
const devtools = @import("tuft_devtools");
const disasm = @import("tuft_asm").disasm;
const hook = @import("tuft_hook");
const Memory = @import("tuft_mem").Memory;
const Symbols = @import("tuft_mem").Symbols;
const tuft_event = @import("tuft_event");
const sys = @import("tuft_sys");
const ui = @import("wraith_ui");
const Text = @import("tuft_text").Text;

const Workbench = @import("../Workbench.zig");
const Clip = @import("wraith_ui").Clip;

const watch = hook.watch;
const CpuContext = hook.CpuContext;
const log = core.log.scoped(.wraith_ui);

pub const Mode = enum { writes, reads };

const max_watches = 8;
/// How often running watches get put on threads started since.
const refresh_ns = std.time.ns_per_s;
const red: ui.Color = .{ 1, 0.4, 0.4, 1 };
const Inbox = tuft_event.Mailbox(watch.Hit, 128);

wb: *Workbench,
inbox: Inbox = .{},
/// Too big for a game thread's stack.
drained: [Inbox.capacity]watch.Hit = undefined,
dropped: Atomic(u32) = .init(0),
/// `watch` is initialized while it's set.
scope: ?tuft_event.Scope = null,
/// Hits from it are us.
own: sys.thread.CodeRange = .{ .start = 0, .len = 0 },
watches: std.ArrayList(Watching) = .empty,
next_key: u64 = 1,
shown_key: u64 = 0,
pick_key: ?u64 = null,
picked_rows: ui.Selection = .{},
last_refresh_ns: u64 = 0,
problem: ?devtools.Problem = null,

const Watching = struct {
    key: u64 = 0,
    name: Text(64) = .{},
    address: usize,
    len: u8,
    mode: Mode,
    slot: ?watch.Slot,
    rows: std.ArrayList(Row) = .empty,

    fn condition(self: *const Watching) watch.Condition {
        return switch (self.mode) {
            .writes => .write,
            .reads => .access,
        };
    }

    pub fn shown(self: *const Watching) usize {
        var n: usize = 0;
        for (self.rows.items) |*r| n += @intFromBool(!r.hidden);
        return n;
    }
};

const Row = struct {
    /// The instruction after it, which is what the CPU reports.
    after: usize,
    /// `after` if we couldn't tell.
    at: usize,
    text: Text(96) = .{},
    /// Not a load, so a "what reads" watch skips it.
    hidden: bool = false,
    count: u64 = 0,
    cpu: CpuContext = undefined,
    thread_id: u32 = 0,
};

/// The CPU watches up to 8 aligned bytes, so a longer value only has its start watched.
pub fn start(self: *Accesses, address: usize, len: usize, mode: Mode, name: []const u8) void {
    self.problem = null;
    self.begin() catch |err| {
        self.problem = .init("Couldn't start watching: {t}", .{err});
        return;
    };
    if (self.watches.items.len == max_watches and !self.dropOldestStopped()) {
        self.problem = .init("That's {d} watches. Remove one first", .{max_watches});
        return;
    }
    const w: watch.Watch = .{ .address = address, .len = watch.lengthFor(address, len), .on = switch (mode) {
        .writes => .write,
        .reads => .access,
    } };
    const slot = watch.add(w) catch |err| {
        self.problem = switch (err) {
            error.NoFreeSlot => .init("All four watches are running. Stop one first", .{}),
            else => .init("Couldn't watch 0x{x}: {t}", .{ address, err }),
        };
        return;
    };
    var watching: Watching = .{ .key = self.next_key, .address = address, .len = w.len, .mode = mode, .slot = slot };
    self.next_key += 1;
    const label = if (name.len > 0) name else "(no description)";
    watching.name.set(label);
    self.watches.append(self.wb.allocator, watching) catch {
        watch.remove(slot);
        self.problem = .init("Out of memory", .{});
        return;
    };
    self.pick_key = watching.key;
    self.wb.panels.addresses.window.focus();
}

fn begin(self: *Accesses) !void {
    if (self.scope != null) return;
    const base = sys.module.selfBase();
    self.own = .{ .start = base, .len = sys.module.imageSize(base) catch 0 };
    try watch.init(self.wb.allocator);
    errdefer watch.deinit();
    self.scope = .init(self.wb.allocator);
    errdefer {
        self.scope.?.deinit();
        self.scope = null;
    }
    try watch.subscribe(&self.scope.?, self, onHit);
}

/// False if they're all running.
fn dropOldestStopped(self: *Accesses) bool {
    for (self.watches.items, 0..) |*w, i| {
        if (w.slot == null) {
            self.removeWatch(i);
            return true;
        }
    }
    return false;
}

pub fn stop(self: *Accesses, i: usize) void {
    const w = &self.watches.items[i];
    const slot = w.slot orelse return;
    watch.remove(slot);
    w.slot = null;
}

fn removeWatch(self: *Accesses, i: usize) void {
    self.stop(i);
    self.watches.items[i].rows.deinit(self.wb.allocator);
    _ = self.watches.orderedRemove(i);
}

pub fn stopAll(self: *Accesses) void {
    for (0..self.watches.items.len) |i| self.stop(i);
}

pub fn running(self: *const Accesses) usize {
    var n: usize = 0;
    for (self.watches.items) |*w| n += @intFromBool(w.slot != null);
    return n;
}

/// Call before the workbench goes, once nothing's drawing.
pub fn deinit(self: *Accesses) void {
    while (self.watches.items.len > 0) self.removeWatch(self.watches.items.len - 1);
    self.watches.deinit(self.wb.allocator);
    self.picked_rows.deinit();
    if (self.scope) |*scope| {
        scope.deinit();
        self.scope = null;
        watch.deinit();
    }
    _ = self.inbox.close();
}

/// On whichever game thread hit, inside the exception. Just queue it.
fn onHit(self: *Accesses, hit: *const watch.Hit) void {
    self.inbox.push(hit.*) catch {
        _ = self.dropped.fetchAdd(1, .monotonic);
    };
}

/// Every workbench tick, open or not.
pub fn tick(self: *Accesses) void {
    if (self.scope == null) return;
    for (self.inbox.drain(&self.drained)) |*hit| self.record(hit);

    const now = core.timing.now();
    if (now -% self.last_refresh_ns < refresh_ns) return;
    self.last_refresh_ns = now;
    for (self.watches.items) |*w| {
        if (w.slot != null) break;
    } else return;
    watch.refresh();
}

fn record(self: *Accesses, hit: *const watch.Hit) void {
    if (self.own.contains(hit.cpu.ip())) return;
    const w = for (self.watches.items) |*w| {
        if (w.slot == hit.slot and w.address == hit.watch.address and w.condition() == hit.watch.on) break w;
    } else return;

    const row = for (w.rows.items) |*r| {
        if (r.after == hit.cpu.ip()) break r;
    } else blk: {
        var row: Row = .{ .after = hit.cpu.ip(), .at = hit.cpu.ip() };
        if (instructionBefore(hit.cpu.ip())) |insn| {
            row.at = hit.cpu.ip() - insn.len;
            row.text.set(insn.text());
            row.hidden = w.mode == .reads and !insn.reads_memory;
        } else {
            row.text.set("??");
        }
        w.rows.append(self.wb.allocator, row) catch return;
        break :blk &w.rows.items[w.rows.items.len - 1];
    };
    row.count += 1;
    row.cpu = hit.cpu;
    row.thread_id = hit.thread_id;
}

/// Reads less if the page before isn't there.
fn instructionBefore(ip: usize) ?disasm.Instruction {
    var buf: [64]u8 = undefined;
    for ([_]usize{ 64, 32, 16 }) |len| {
        const code = buf[0..len];
        Memory.local.read(ip -% len, code) catch continue;
        return disasm.before(code, ip);
    }
    return null;
}

// Drawing

pub fn drawFor(self: *Accesses, address: usize, name: []const u8) void {
    if (self.problem) |*p| ui.textColored(red, "{s}", .{p.message()});
    const dropped = self.dropped.load(.monotonic);
    if (dropped > 0) {
        ui.textDisabled("{d} hit(s) came too fast to count", .{dropped});
        ui.tooltip("Counts are low, but every instruction still shows up the next time it hits", .{});
    }
    var any = false;
    for (self.watches.items) |*w| any = any or w.address == address;
    if (!any) {
        ui.textDisabled("Find what writes {s} or reads it from its right-click menu", .{if (name.len > 0) name else "it"});
        return;
    }
    const bar = ui.tabBar("watches") orelse return;
    defer bar.end();
    for (self.watches.items) |*w| {
        if (w.address != address) continue;
        const scope = ui.id(@as(i32, @truncate(@as(i64, @bitCast(w.key)))));
        defer scope.end();
        const label = ui.format("{s} ({d}){s}###watch", .{ switch (w.mode) {
            .writes => "Writes",
            .reads => "Reads",
        }, w.shown(), if (w.slot != null) "" else ", stopped" });
        const tab = ui.tabItem(label, .{ .select = self.pick_key == w.key }) orelse continue;
        defer tab.end();
        // Switching takes a frame, so it's asked for until it's showing
        if (self.pick_key == w.key) self.pick_key = null;
        if (self.shown_key != w.key) {
            self.shown_key = w.key;
            self.picked_rows.clear();
        }
        // Every tab's submitted each frame or a switch to a later one never happens
        if (self.drawRows(w)) return;
    }
}

/// True if its menu removed it.
fn drawRows(self: *Accesses, w: *Watching) bool {
    if (w.slot != null) {
        ui.textColored(.{ 0.65, 0.89, 0.63, 1 }, "Watching", .{});
        ui.sameLine();
        ui.textDisabled("every instruction that {s} it, as the game runs", .{switch (w.mode) {
            .writes => "writes",
            .reads => "reads",
        }});
    } else {
        ui.textDisabled("Stopped. What it found stays until removed", .{});
    }

    // Ones a "what reads" watch skips stay in `rows` but aren't listed
    var indices: [256]u32 = undefined;
    var n: usize = 0;
    for (w.rows.items, 0..) |*row, i| {
        if (row.hidden or n == indices.len) continue;
        indices[n] = @intCast(i);
        n += 1;
    }
    const shown: Shown = .{ .rows = w.rows.items, .indices = indices[0..n] };

    const registers_height = 130;
    var gone = false;
    // A region of its own, so its menu and keys are apart from the entry's
    if (ui.child("found_list", .{ 0, @max(ui.getContentRegionAvailPixels()[1] - ui.scaled(registers_height), ui.scaled(80)) }, .{})) |region| {
        defer region.end();
        if (ui.table("found", 3, .{ .borders = true, .row_background = true, .resizable = true, .sizing = .stretch_prop, .scroll_y = true })) |table| {
            defer table.end();
            ui.tableColumnWith("Count", .{ .fixed = true, .width = 70 });
            ui.tableColumnWith("Address", .{ .fixed = true, .width = 200 });
            ui.tableColumnWith("Instruction", .{ .stretch = true, .width = 3 });
            ui.tableHeaders();
            var picking = self.picked_rows.begin(n, shown, .{});
            for (0..n) |r| {
                const row = shown.at(r);
                const scope = ui.id(@as(i32, @intCast(r)));
                defer scope.end();
                ui.tableNextRow();
                _ = ui.tableNextColumn();
                _ = picking.row(r, ui.format("{d}", .{row.count}));
                _ = ui.tableNextColumn();
                var buf: [300]u8 = undefined;
                ui.text("{s}", .{Names.global.describe(row.at, &buf) orelse ui.format("0x{x}", .{row.at})});
                _ = ui.tableNextColumn();
                ui.text("{s}", .{row.text.get()});
            }
            picking.end();
        }
        // After the table, not in it, or its items can't be clicked
        gone = self.rowCommands(w, shown);
    }
    if (gone) return true;
    const key = self.picked_rows.focused() orelse return false;
    for (w.rows.items) |*row| if (row.after == key) {
        drawRegisters(row);
        break;
    };
    return false;
}

const Shown = struct {
    rows: []const Row,
    indices: []const u32,

    fn at(self: Shown, r: usize) *const Row {
        return &self.rows[self.indices[r]];
    }

    pub fn id(self: Shown, r: usize) u64 {
        return self.at(r).after;
    }
};

/// True if it removed the watch.
fn rowCommands(self: *Accesses, w: *Watching, shown: Shown) bool {
    const keys = &devtools.keys;
    var menu = ui.commands("found", .{ .activated = self.picked_rows.activated });
    defer menu.end();
    const one: ?*const Row = blk: {
        const key = self.picked_rows.focused() orelse break :blk null;
        for (0..shown.indices.len) |r| if (shown.at(r).after == key) break :blk shown.at(r);
        break :blk null;
    };
    const any = self.picked_rows.count() > 0;
    if (menu.item(.{ .label = "Show as code", .chord = keys.show_code, .enabled = one != null, .default = true, .tooltip = "The instruction with the code around it" })) self.wb.openCode(one.?.at);
    menu.separator();
    if (menu.item(.{ .label = "Copy", .chord = keys.copy, .enabled = any, .tooltip = "Count, address and instruction, one per line" })) {
        var clip: Clip = .{};
        for (0..shown.indices.len) |r| {
            const row = shown.at(r);
            if (!self.picked_rows.contains(row.after)) continue;
            var buf: [300]u8 = undefined;
            clip.line("{d}\t{s}\t{s}", .{ row.count, Names.global.describe(row.at, &buf) orelse ui.format("0x{x}", .{row.at}), row.text.get() });
        }
        clip.copy();
    }
    if (menu.item(.{ .label = "Copy address", .chord = keys.copy_address, .enabled = any })) {
        var clip: Clip = .{};
        for (0..shown.indices.len) |r| {
            const row = shown.at(r);
            if (self.picked_rows.contains(row.after)) clip.line("0x{x}", .{row.at});
        }
        clip.copy();
    }
    menu.separator();
    if (menu.item(.{ .label = "Clear found", .tooltip = "Forget what's been found so far" })) {
        w.rows.clearRetainingCapacity();
        self.picked_rows.clear();
    }
    if (menu.item(.{ .label = "Stop watching", .enabled = w.slot != null, .tooltip = "Frees its debug register. What it found stays" })) {
        for (self.watches.items, 0..) |*other, i| if (other == w) self.stop(i);
    }
    if (menu.item(.{ .label = "Remove watch", .tooltip = "Stops it and forgets what it found" })) {
        for (self.watches.items, 0..) |*other, i| if (other == w) {
            self.removeWatch(i);
            return true;
        };
    }
    return false;
}

fn drawRegisters(row: *const Row) void {
    const panel = ui.child("registers", .{ 0, 0 }, .{ .border = true }) orelse return;
    defer panel.end();
    ui.textDisabled("After its last hit, on thread {d}", .{row.thread_id});
    const table = ui.table("registers", 4, .{ .sizing = .stretch_same }) orelse return;
    defer table.end();
    const digits = @sizeOf(usize) * 2;
    const info = @typeInfo(CpuContext).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        if (comptime (T == u64 or T == u32) and !std.mem.startsWith(u8, name, "_")) {
            _ = ui.tableNextColumn();
            ui.text("{s:<6} {x:0>" ++ std.fmt.comptimePrint("{d}", .{digits}) ++ "}", .{ name, @as(usize, @intCast(@field(row.cpu, name))) });
        }
    }
    _ = ui.tableNextColumn();
    ui.text("{s:<6} {x:0>" ++ std.fmt.comptimePrint("{d}", .{digits}) ++ "}", .{ if (digits == 16) "rip" else "eip", row.after });
}
