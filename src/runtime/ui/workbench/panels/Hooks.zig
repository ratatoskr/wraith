//! Every hook the engine holds. A fn hook's time includes the original if the detour calls it.

const Hooks = @This();

const std = @import("std");
const Names = @import("../../../Names.zig");

const core = @import("wraith_core");
const devtools = @import("tuft_devtools");
const hook = @import("tuft_hook");
const Symbols = @import("tuft_mem").Symbols;
const ui = @import("wraith_ui");

const Rates = @import("../Rates.zig");
const Navigator = @import("../Navigator.zig");
const Clip = @import("../Clip.zig");

const Info = hook.registry.Info;

window: ui.Window = .{ .title = "Hooks", .size = .{ 820, 340 }, .min_size = .{ 420, 180 } },
nav: Navigator,
infos: [Rates.max]Info = undefined,
rates: Rates = .{},
picked: ui.Selection = .{},

pub fn deinit(self: *Hooks) void {
    self.picked.deinit();
}

pub fn draw(self: *Hooks) void {
    const n = hook.registry.snapshot(&self.infos);
    const hooks = self.infos[0..n];

    var samples: [Rates.max]Rates.Sample = undefined;
    for (hooks, 0..) |*info, i| samples[i] = sample(info);

    self.rates.tick(samples[0..n]);

    ui.textDisabled("{d} hook(s)", .{n});

    // Too many columns to fit, so they scroll with the owner pinned
    const table = ui.table("hooks", 6 + Rates.columns(.ms).len, .{
        .borders = true,
        .row_background = true,
        .resizable = true,
        .sortable = true,
        .sizing = .fixed_fit,
        .scroll_x = true,
        .scroll_y = true,
        .frozen_columns = 1,
    }) orelse return;
    inline for (.{
        "Owner",
        "Kind",
        "Target",
        "Patch",
        "State",
    }) |label| ui.tableColumn(label);
    Rates.setupColumns(.ms);
    ui.tableColumn("Running");
    ui.tableHeaders();
    table.sort(Column, Info, hooks, &self.rates, order);

    var picking = self.picked.begin(n, ui.Selection.Rows(Info, idOf){ .rows = hooks }, .{});
    for (hooks, 0..) |*info, i| {
        const scope = ui.id(@as(i32, @truncate(@as(i64, @bitCast(info.id)))));
        defer scope.end();
        ui.tableNextRow();
        _ = ui.tableNextColumn();
        _ = picking.row(i, ui.format("{s}", .{if (info.ownerName().len == 0) "wraith" else info.ownerName()}));
        _ = ui.tableNextColumn();
        ui.text("{t}", .{info.kind});
        _ = ui.tableNextColumn();
        target(info.target);
        _ = ui.tableNextColumn();
        ui.text("{t}", .{info.mode});
        _ = ui.tableNextColumn();
        switch (info.state) {
            .enabled => ui.textColored(.{ 0.4, 0.9, 0.4, 1 }, "enabled", .{}),
            .disabled => ui.textDisabled("disabled", .{}),
            .orphaned => ui.textColored(.{ 1, 0.7, 0.2, 1 }, "orphaned", .{}),
        }
        self.rates.row(info.id, figuresOf(info));
        _ = ui.tableNextColumn();
        ui.text("{d}", .{info.active});
    }
    picking.end();
    // The menu after the table, not in it, or its items can't be clicked
    table.end();
    self.commands(hooks);
}

fn commands(self: *Hooks, hooks: []const Info) void {
    const keys = &devtools.keys;
    var menu = ui.commands("hooks", .{ .activated = self.picked.activated });
    defer menu.end();
    const one = self.focused(hooks);
    const any = self.picked.count() > 0;
    if (menu.item(.{ .label = "Show as code", .chord = keys.show_code, .enabled = one != null, .default = true })) self.nav.openCode(one.?.target);
    if (menu.item(.{ .label = "Show in memory", .chord = keys.show_memory, .enabled = one != null, .tooltip = "The patched bytes, marked" })) {
        const info = one.?;
        self.nav.openMemory(info.target, info.patch_len, .{ .start = info.target, .len = info.patch_len });
    }
    menu.separator();
    if (menu.item(.{ .label = "Copy", .chord = keys.copy, .enabled = any, .tooltip = "Owner, kind, target and patch, one hook per line" })) {
        var clip: Clip = .{};
        for (hooks) |*info| if (self.picked.contains(info.id)) {
            var buf: [300]u8 = undefined;
            clip.line("{s}\t{t}\t{s}\t{t}", .{ if (info.ownerName().len == 0) "wraith" else info.ownerName(), info.kind, Names.global.describe(info.target, &buf) orelse ui.format("0x{x}", .{info.target}), info.mode });
        };
        clip.copy();
    }
    if (menu.item(.{ .label = "Copy address", .chord = keys.copy_address, .enabled = any })) {
        var clip: Clip = .{};
        for (hooks) |*info| if (self.picked.contains(info.id)) clip.line("0x{x}", .{info.target});
        clip.copy();
    }
    menu.separator();
    if (menu.item(.{ .label = "Reset timings", .tooltip = "Clears every hook's counts and maximum" })) hook.registry.resetTimings();
}

fn focused(self: *const Hooks, hooks: []const Info) ?*const Info {
    const id = self.picked.focused() orelse return null;
    for (hooks) |*info| if (info.id == id) return info;
    return null;
}

fn idOf(info: *const Info) u64 {
    return info.id;
}

/// For a slot hook, the pointer's address.
fn target(addr: usize) void {
    var buf: [300]u8 = undefined;
    const where = Names.global.describe(addr, &buf) orelse return ui.text("0x{x}", .{addr});
    ui.text("{s}", .{where});
    if (ui.isItemHovered()) ui.tooltip("0x{x:0>16}", .{addr});
}

fn figuresOf(info: *const Info) core.timing.Figures {
    return .{ .calls = info.timing.calls, .total_ns = info.timing.total_ns, .max_ns = info.timing.max_ns, .last_ns = info.timing.last_ns };
}

fn sample(info: *const Info) Rates.Sample {
    return .{ .id = info.id, .figures = figuresOf(info) };
}

const Column = enum { owner, kind, target, patch, state, per_second, avg, max, last, calls, running };

fn order(rates: *const Rates, column: ?Column, a: Info, b: Info) std.math.Order {
    return switch (column orelse return .eq) {
        .owner => std.mem.order(u8, a.ownerName(), b.ownerName()),
        .kind => std.math.order(@backingInt(a.kind), @backingInt(b.kind)),
        .target => std.math.order(a.target, b.target),
        .patch => std.math.order(@backingInt(a.mode), @backingInt(b.mode)),
        .state => std.math.order(@backingInt(a.state), @backingInt(b.state)),
        inline .per_second, .avg, .max, .last, .calls => |figure| rates.order(@field(Rates.Figure, @tagName(figure)), sample(&a), sample(&b)),
        .running => std.math.order(a.active, b.active),
    };
}
