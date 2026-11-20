//! Memory viewer document, this process's memory as hex.

const MemoryViewer = @This();

const std = @import("std");
const Names = @import("../../../Names.zig");

const devtools = @import("tuft_devtools");
const ui = @import("wraith_ui");

const Workbench = @import("../Workbench.zig");

window: ui.Window = .{ .title = "Memory viewer", .size = .{ 900, 480 }, .min_size = .{ 560, 260 } },
wb: *Workbench,
bar: devtools.AddressBar = .{ .symbols = Names.global_symbols, .memory = .local },
hex: devtools.HexView = .{ .memory = .local, .claims = .local },
inspector: devtools.Inspector = .{ .memory = .local, .symbols = Names.global_symbols, .claims = .local },

pub fn open(self: *MemoryViewer, address: usize, len: usize, highlight: ?@import("tuft_mem").Range) void {
    self.goTo(address, len);
    self.hex.highlight = highlight;
    self.window.focus();
}

pub fn draw(self: *MemoryViewer) void {
    if (self.bar.draw()) |address| {
        self.hex.highlight = null;
        self.hex.goTo(address, 1);
        self.hex.focus();
    }

    const inspector_w = ui.scaled(280);
    self.hex.draw("bytes", .{ -inspector_w, 0 });
    ui.sameLine();
    if (ui.child("inspector", .{ 0, 0 }, .{ .border = true })) |panel| {
        defer panel.end();
        if (self.inspector.draw(self.hex.selection())) |pointer| {
            self.hex.highlight = null;
            self.goTo(pointer, @sizeOf(usize));
        }
    }
    self.commands();
}

fn commands(self: *MemoryViewer) void {
    const keys = &devtools.keys;
    var menu = ui.commands("memory", .{});
    defer menu.end();
    const selected = self.hex.selection();
    if (menu.item(.{ .label = "Show as code", .chord = keys.show_code, .enabled = selected != null })) self.wb.openCode(selected.?.start);
    if (menu.item(.{ .label = "Add to address list", .chord = keys.add_to_list, .enabled = selected != null, .tooltip = "Watch the selection in the Addresses window" })) {
        self.wb.panels.addresses.add(selected.?.start, devtools.AddressList.kindForLength(selected.?.len), selected.?.len);
    }
    if (menu.item(.{ .label = "Find what writes this", .chord = keys.what_writes, .enabled = selected != null, .tooltip = "Adds it to the address list, where every instruction that writes it shows" })) {
        self.wb.panels.addresses.watch(selected.?.start, devtools.AddressList.kindForLength(selected.?.len), selected.?.len, .writes);
    }
    if (menu.item(.{ .label = "Find what reads this", .chord = keys.what_reads, .enabled = selected != null, .tooltip = "Adds it to the address list, where every instruction that reads it shows" })) {
        self.wb.panels.addresses.watch(selected.?.start, devtools.AddressList.kindForLength(selected.?.len), selected.?.len, .reads);
    }
    if (self.wb.sig_maker.busy()) {
        if (menu.item(.{ .label = "Stop making signature", .chord = keys.make_sig })) self.wb.sig_maker.stop();
    } else if (menu.item(.{ .label = "Make signature", .chord = keys.make_sig, .enabled = selected != null, .tooltip = "The shortest pattern that only matches here, or at code that points here. Copied as a location" })) {
        self.wb.sig_maker.start(self.wb, selected.?.start);
    }
    if (menu.item(.{ .label = "Go to address", .chord = keys.go_to })) self.bar.focus();
    menu.separator();
    self.hex.commands(&menu);
}

/// With keyboard focus on it, so the arrows move from there.
fn goTo(self: *MemoryViewer, address: usize, len: usize) void {
    self.bar.visit(address);
    self.hex.goTo(address, len);
    self.hex.focus();
}
