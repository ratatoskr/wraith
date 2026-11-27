//! Every claim the runtime keeps, so who holds which bytes.

const ClaimsWindow = @This();

const std = @import("std");
const Names = @import("../../../Names.zig");

const devtools = @import("tuft_devtools");
const memory = @import("tuft_mem");
const ui = @import("wraith_ui");

const Navigator = @import("../Navigator.zig");
const Clip = @import("wraith_ui").Clip;

const Claim = memory.Claims.Claim;

nav: Navigator,
claims: [1024]Claim = undefined,
/// `claims` holds as many as fit.
total: usize = 0,
picked: ui.Selection = .{},

pub fn deinit(self: *ClaimsWindow) void {
    self.picked.deinit();
}

pub fn draw(self: *ClaimsWindow) void {
    self.total = memory.Claims.snapshot(&self.claims);
    const shown = self.claims[0..@min(self.total, self.claims.len)];
    if (shown.len < self.total) {
        ui.textDisabled("{d} claim(s), the first {d} shown", .{ self.total, shown.len });
    } else {
        ui.textDisabled("{d} claim(s)", .{self.total});
    }

    const table = ui.table("claims", 5, .{
        .borders = true,
        .row_background = true,
        .resizable = true,
        .sortable = true,
        .sizing = .fixed_fit,
        .scroll_x = true,
        .scroll_y = true,
        .frozen_columns = 1,
    }) orelse return;
    inline for (.{ "Owner", "Kind", "Id", "Where", "Size" }) |label| ui.tableColumn(label);
    ui.tableHeaders();
    table.sort(Column, Claim, shown, {}, order);

    var picking = self.picked.begin(shown.len, ui.Selection.Rows(Claim, idOf){ .rows = shown }, .{});
    var clipper = ui.clip(shown.len);
    clipper.include(picking.keep());
    while (clipper.next()) |i| {
        const claim = &shown[i];
        const scope = ui.id(@as(i32, @intCast(i)));
        defer scope.end();
        ui.tableNextRow();
        _ = ui.tableNextColumn();
        _ = picking.row(i, ui.format("{s}", .{if (claim.ownerName().len == 0) "wraith" else claim.ownerName()}));
        _ = ui.tableNextColumn();
        ui.text("{s}", .{std.enums.tagName(memory.Claims.Kind, claim.kind) orelse "other"});
        _ = ui.tableNextColumn();
        ui.text("{d}", .{claim.id});
        _ = ui.tableNextColumn();
        where(claim.start);
        _ = ui.tableNextColumn();
        ui.text("{d}", .{claim.len});
    }
    picking.end();
    // The menu after the table, not in it, or its items can't be clicked
    table.end();
    self.commands(shown);
}

fn commands(self: *ClaimsWindow, shown: []const Claim) void {
    const keys = &devtools.keys;
    var menu = ui.commands("claims", .{ .activated = self.picked.activated });
    defer menu.end();
    const one = self.focused(shown);
    const any = self.picked.count() > 0;
    if (menu.item(.{ .label = "Show in memory", .chord = keys.show_memory, .enabled = one != null, .default = true, .tooltip = "The claimed bytes, marked" })) {
        const claim = one.?;
        self.nav.openMemory(claim.start, @min(claim.len, 64), .{ .start = claim.start, .len = claim.len });
    }
    if (menu.item(.{ .label = "Show as code", .chord = keys.show_code, .enabled = one != null })) self.nav.openCode(one.?.start);
    menu.separator();
    if (menu.item(.{ .label = "Copy", .chord = keys.copy, .enabled = any, .tooltip = "Owner, kind, where and size, one claim per line" })) {
        var clip: Clip = .{};
        for (shown) |*claim| if (self.picked.contains(claim.id)) {
            var buf: [300]u8 = undefined;
            clip.line("{s}\t{s}\t{s}\t{d}", .{
                if (claim.ownerName().len == 0) "wraith" else claim.ownerName(),
                std.enums.tagName(memory.Claims.Kind, claim.kind) orelse "other",
                Names.global.describe(claim.start, &buf) orelse ui.format("0x{x}", .{claim.start}),
                claim.len,
            });
        };
        clip.copy();
    }
    if (menu.item(.{ .label = "Copy address", .chord = keys.copy_address, .enabled = any })) {
        var clip: Clip = .{};
        for (shown) |*claim| if (self.picked.contains(claim.id)) clip.line("0x{x}", .{claim.start});
        clip.copy();
    }
}

fn focused(self: *const ClaimsWindow, shown: []const Claim) ?*const Claim {
    const id = self.picked.focused() orelse return null;
    for (shown) |*claim| if (claim.id == id) return claim;
    return null;
}

fn idOf(claim: *const Claim) u64 {
    return claim.id;
}

const Column = enum { owner, kind, id, where, size };

fn order(_: void, column: ?Column, a: Claim, b: Claim) std.math.Order {
    return switch (column orelse return .eq) {
        .owner => std.mem.order(u8, a.ownerName(), b.ownerName()),
        .kind => std.math.order(@backingInt(a.kind), @backingInt(b.kind)),
        .id => std.math.order(a.id, b.id),
        .where => std.math.order(a.start, b.start),
        .size => std.math.order(a.len, b.len),
    };
}

fn where(address: usize) void {
    var buf: [300]u8 = undefined;
    const name = Names.global.describe(address, &buf) orelse return ui.text("0x{x}", .{address});
    ui.text("{s}", .{name});
    if (ui.isItemHovered()) ui.tooltip("0x{x:0>16}", .{address});
}
