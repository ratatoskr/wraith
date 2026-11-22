//! The picked stopped thread's registers, to read and change.

const Registers = @This();

const std = @import("std");

const arch = @import("tuft_arch");
const devtools = @import("tuft_devtools");
const Debugger = @import("tuft_hook").Debugger;
const ui = @import("wraith_ui");

const Workbench = @import("../Workbench.zig");
const Clip = @import("wraith_ui").Clip;

const Paused = Debugger.Paused;

window: ui.Window = .{ .title = "Registers", .size = .{ 400, 400 }, .min_size = .{ 240, 160 } },
wb: *Workbench,
/// By their index in `names`.
picked: ui.Selection = .{},
/// The register being typed into, and whose thread it is.
editing: ?usize = null,
editing_thread: u32 = 0,
edit: [32:0]u8 = @splat(0),
focus_edit: bool = false,
/// Why the last change didn't go in.
problem: ?devtools.Problem = null,

pub fn deinit(self: *Registers) void {
    self.picked.deinit();
}

/// The plain integer registers in `CpuContext`, flags and ip too.
pub const names = blk: {
    var out: []const [:0]const u8 = &.{};
    const info = @typeInfo(arch.CpuContext).@"struct";
    for (info.field_names, info.field_types) |name, T| {
        if ((T == u64 or T == u32) and name[0] != '_') out = out ++ .{name};
    }
    break :blk out;
};

const digits = std.fmt.comptimePrint("{d}", .{@sizeOf(usize) * 2});

pub fn value(cpu: *const arch.CpuContext, i: usize) usize {
    inline for (names, 0..) |name, n| if (n == i) return @intCast(@field(cpu.*, name));
    unreachable;
}

pub fn set(cpu: *arch.CpuContext, i: usize, v: usize) void {
    inline for (names, 0..) |name, n| if (n == i) {
        @field(cpu.*, name) = @intCast(v);
        return;
    };
    unreachable;
}

pub fn index(name: []const u8) ?usize {
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    return null;
}

/// Hex, with or without `0x`.
pub fn parseHex(text: []const u8) ?usize {
    var t = std.mem.trim(u8, text, " \t");
    if (std.ascii.startsWithIgnoreCase(t, "0x")) t = t[2..];
    if (t.len == 0) return null;
    return std.fmt.parseInt(usize, t, 16) catch null;
}

pub fn draw(self: *Registers) void {
    const p = self.wb.focusedStop() orelse {
        self.editing = null;
        ui.textDisabled("Nothing's stopped. These are the stopped thread picked in Threads", .{});
        return;
    };
    // Another thread picked, or this one went
    if (self.editing != null and self.editing_thread != p.thread_id) self.editing = null;
    ui.textDisabled("Thread {d}", .{p.thread_id});
    if (self.problem) |*problem| ui.textColored(.{ 1, 0.45, 0.45, 1 }, "{s}", .{problem.message()});
    if (ui.table("registers", 2, .{ .borders = true, .row_background = true, .sizing = .stretch_prop, .scroll_y = true })) |table| {
        defer table.end();
        ui.tableColumnWith("Register", .{ .fixed = true, .width = 70 });
        ui.tableColumnWith("Value", .{ .stretch = true, .width = 1 });
        ui.tableHeaders();
        var picking = self.picked.begin(names.len, ui.Selection.Indices{}, .{});
        for (names, 0..) |name, i| {
            ui.tableNextRow();
            _ = ui.tableNextColumn();
            _ = picking.row(i, name);
            _ = ui.tableNextColumn();
            if (self.editing == i) {
                self.drawEdit(&p, i);
            } else {
                ui.text("{x:0>" ++ digits ++ "}", .{value(&p.cpu, i)});
            }
        }
        picking.end();
    }
    // After the table, not in it, or its items can't be clicked
    self.commands(&p);
}

fn drawEdit(self: *Registers, p: *const Paused, i: usize) void {
    if (self.focus_edit) {
        ui.focusNext();
        self.focus_edit = false;
    }
    ui.setNextItemWidth(ui.fill);
    const entered = ui.inputTextWith("##edit", &self.edit, .{ .flags = .{ .enter_returns_true = true, .auto_select_all = true }, .tight = true });
    if (entered) {
        self.commit(p, i, std.mem.sliceTo(&self.edit, 0));
        self.editing = null;
    } else if (ui.isItemDeactivated()) {
        self.editing = null;
    }
}

pub fn startEdit(self: *Registers, p: *const Paused, i: usize) void {
    _ = std.fmt.bufPrintSentinel(&self.edit, "{x:0>" ++ digits ++ "}", .{value(&p.cpu, i)}, 0) catch return;
    self.editing = i;
    self.editing_thread = p.thread_id;
    self.focus_edit = true;
}

/// Goes into the thread when it carries on, however that is.
pub fn commit(self: *Registers, p: *const Paused, i: usize, text: []const u8) void {
    const v = parseHex(text) orelse {
        self.problem = .init("\"{s}\" isn't a hex number", .{text});
        return;
    };
    var cpu = p.cpu;
    set(&cpu, i, v);
    self.wb.debugger.setCpu(p.id, cpu) catch |err| {
        self.problem = .init("Couldn't change {s}: {t}", .{ names[i], err });
        return;
    };
    self.problem = null;
}

fn commands(self: *Registers, p: *const Paused) void {
    const keys = &devtools.keys;
    var menu = ui.commands("registers", .{ .activated = self.picked.activated });
    defer menu.end();
    const one: ?usize = if (self.picked.focused()) |id| @intCast(id) else null;
    const v: usize = if (one) |i| value(&p.cpu, i) else 0;
    if (menu.item(.{ .label = "Change value", .chord = keys.edit, .enabled = one != null, .default = true, .tooltip = "Type a new one in hex (Enter or a double-click does too). It goes in when the thread carries on" })) {
        self.startEdit(p, one.?);
    }
    if (menu.item(.{ .label = "Copy value", .chord = keys.copy, .enabled = one != null })) {
        var clip: Clip = .{};
        clip.line("0x{x}", .{v});
        clip.copy();
    }
    menu.separator();
    if (menu.item(.{ .label = "Show as code", .chord = keys.show_code, .enabled = one != null, .tooltip = "Where it points, as instructions" })) self.wb.openCode(v);
    if (menu.item(.{ .label = "Show in memory", .chord = keys.show_memory, .enabled = one != null, .tooltip = "Where it points, as bytes" })) self.wb.openMemory(v, @sizeOf(usize), null);
}

test "register values in hex" {
    try std.testing.expectEqual(0x2A, parseHex("2a"));
    try std.testing.expectEqual(0x2A, parseHex(" 0X2A "));
    try std.testing.expectEqual(null, parseHex("0x"));
    try std.testing.expectEqual(null, parseHex("zz"));
    const flags = index("eflags") orelse index("rflags").?;
    var cpu = std.mem.zeroes(arch.CpuContext);
    set(&cpu, flags, 0x246);
    try std.testing.expectEqual(0x246, value(&cpu, flags));
    // The ip's one of them
    try std.testing.expect(index("rip") != null or index("eip") != null);
}
