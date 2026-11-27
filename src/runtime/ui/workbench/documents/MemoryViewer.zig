//! Memory viewer document, this process's memory as hex.

const MemoryViewer = @This();

const std = @import("std");
const Names = @import("../../../Names.zig");

const devtools = @import("tuft_devtools");
const memory = @import("tuft_mem");
const ui = @import("wraith_ui");

const Workbench = @import("../Workbench.zig");
const Versions = @import("Versions.zig");

/// Its tab's, which the Workbench's tabs keep.
window: *ui.Window = undefined,
wb: *Workbench,
bar: devtools.AddressBar = .{ .symbols = Names.global_symbols, .memory = .local },
hex: devtools.HexView = .{ .memory = .local, .claims = .local },
inspector: devtools.Inspector = .{ .memory = .local, .symbols = Names.global_symbols, .claims = .local },
/// Which copy of the game's code `hex` shows.
source: memory.AddressSource = .live,
/// What `hex` read when it was made, for showing live memory again.
live: ?memory.Memory = null,
/// A second pane next to `hex`, kept where it is.
split: bool = false,
other: devtools.HexView = undefined,
other_source: memory.AddressSource = .snapshot,
synced: Versions.Synced(devtools.HexView) = .{},
panes: ui.Split = .{ .ratio = 0.5 },

pub fn open(self: *MemoryViewer, address: usize, len: usize, highlight: ?@import("tuft_mem").Range) void {
    self.goTo(address, len);
    self.hex.highlight = highlight;
    self.window.focus();
}

pub fn draw(self: *MemoryViewer) void {
    const live = self.live orelse blk: {
        self.live = self.hex.memory;
        break :blk self.hex.memory;
    };
    if (Versions.picker("##source", &self.source)) {
        self.hex.memory = Versions.memoryOf(self.source, live);
        self.inspector.memory = self.hex.memory;
    }
    ui.sameLine();
    self.bar.trailing = if (self.split) Versions.picker_width + 8 else 0;
    if (self.bar.draw()) |address| {
        self.hex.highlight = null;
        self.hex.goTo(address, 1);
        self.hex.focus();
    }
    if (self.split) {
        ui.sameLine();
        if (Versions.picker("##other_source", &self.other_source)) self.other.memory = Versions.memoryOf(self.other_source, live);
    }

    const inspector_w = ui.scaled(280);
    if (self.split) {
        if (self.panes.first("bytes")) |pane| {
            defer pane.end();
            self.hex.draw("bytes", .{ 0, 0 });
        }
        if (self.panes.second("other")) |pane| {
            defer pane.end();
            self.other.highlight = self.hex.highlight;
            self.other.draw("other", .{ -inspector_w, 0 });
            ui.sameLine();
            self.drawInspector();
        }
        self.synced.sync(&self.hex, &self.other);
    } else {
        self.hex.draw("bytes", .{ -inspector_w, 0 });
        ui.sameLine();
        self.drawInspector();
    }
    self.commands();
}

fn drawInspector(self: *MemoryViewer) void {
    const panel = ui.child("inspector", .{ 0, 0 }, .{ .border = true }) orelse return;
    defer panel.end();
    if (self.inspector.draw(self.hex.selection())) |pointer| {
        self.hex.highlight = null;
        self.goTo(pointer, @sizeOf(usize));
    }
}

/// The second pane starts where the first is, showing another copy.
pub fn toggleSplit(self: *MemoryViewer) void {
    self.split = !self.split;
    if (!self.split) return;
    const live = self.live orelse self.hex.memory;
    if (self.other_source == self.source) self.other_source = if (self.source == .live) .snapshot else .live;
    self.other = self.hex;
    self.other.take_focus = false;
    self.other.memory = Versions.memoryOf(self.other_source, live);
    self.synced.reset();
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
    if (menu.item(.{ .label = if (self.split) "Close second pane" else "Split view", .tooltip = "Another pane next to this one, kept at the same place, to compare copies of the code side by side" })) self.toggleSplit();
    if (menu.item(.{ .label = "View as type", .enabled = selected != null, .tooltip = "Lays a schema's struct over the selection, in the Schemas panel. Pick the type there" })) {
        self.wb.panels.schemas.viewAt(selected.?.start);
    }
    menu.separator();
    self.hex.commands(&menu);
}

/// With keyboard focus on it, so the arrows move from there.
fn goTo(self: *MemoryViewer, address: usize, len: usize) void {
    self.bar.visit(address);
    self.hex.goTo(address, len);
    self.hex.focus();
}
