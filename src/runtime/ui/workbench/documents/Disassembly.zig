//! Disassembly document, this process's code as instructions.

const Disassembly = @This();

const std = @import("std");
const Names = @import("../../../Names.zig");

const devtools = @import("tuft_devtools");
const ui = @import("wraith_ui");

const Workbench = @import("../Workbench.zig");

const is64 = @sizeOf(usize) == 8;

window: ui.Window = .{ .title = "Disassembly", .size = .{ 900, 480 }, .min_size = .{ 480, 260 } },
wb: *Workbench,
bar: devtools.AddressBar = .{ .symbols = Names.global_symbols, .memory = .local },
code: devtools.AsmView = .{ .memory = .local, .symbols = Names.global_symbols, .claims = .local },

pub fn open(self: *Disassembly, address: usize) void {
    self.goTo(address);
    self.window.focus();
}

/// Without touching focus, for following a stepping thread.
pub fn follow(self: *Disassembly, address: usize) void {
    self.bar.visit(address);
    self.code.goTo(address);
}

pub fn draw(self: *Disassembly) void {
    if (self.bar.draw()) |address| {
        self.code.goTo(address);
        self.code.focus();
    }
    self.code.marks = .{ .ctx = self.wb, .func = Workbench.markAt };
    self.code.draw("code", .{ 0, 0 });

    const keys = &devtools.keys;
    var menu = ui.commands("code", .{});
    defer menu.end();
    const selected = self.code.selection();
    if (menu.item(.{ .label = "Toggle breakpoint", .chord = keys.toggle_breakpoint, .enabled = selected != null, .tooltip = "An int3 that stops the thread that runs it. Change what it stops in Breakpoints" })) {
        self.wb.toggleBreakpoint(selected.?.start) catch |err| {
            self.code.problem = .init("Couldn't set a breakpoint: {t}", .{err});
        };
    }
    if (menu.item(.{ .label = "Toggle hardware breakpoint", .chord = keys.toggle_hardware_breakpoint, .enabled = selected != null, .tooltip = "Uses one of the CPU's four debug registers and leaves the code alone, for games that check it" })) {
        self.wb.toggleHardwareBreakpoint(selected.?.start) catch |err| {
            self.code.problem = .init("Couldn't set a breakpoint: {t}", .{err});
        };
    }
    const on_breakpoint = if (selected) |s| self.wb.debugger.get(s.start) != null else false;
    if (menu.item(.{ .label = "Enable or disable breakpoint", .chord = keys.enable_breakpoint, .enabled = on_breakpoint, .tooltip = "A disabled one stays, but puts the code back or gives up its debug register" })) {
        self.wb.toggleBreakpointEnabled(selected.?.start) catch |err| {
            self.code.problem = .init("Couldn't enable it: {t}", .{err});
        };
    }
    const stopped = self.wb.stopped_len > 0;
    if (menu.item(.{ .label = "Continue", .chord = keys.continue_thread, .global = true, .enabled = stopped, .tooltip = "Let the stopped thread go (the one picked in Stopped)" })) self.wb.resumeFocused(.run);
    if (menu.item(.{ .label = "Step into", .chord = keys.step_into, .global = true, .enabled = stopped, .tooltip = "Run the stopped thread's next instruction" })) self.wb.resumeFocused(.step);
    if (menu.item(.{ .label = "Step over", .chord = keys.step_over, .global = true, .enabled = stopped, .tooltip = "Like step into, but a call runs through to where it returns" })) self.wb.resumeFocused(.step_over);
    if (menu.item(.{ .label = "Set next instruction", .chord = keys.set_next, .enabled = stopped and selected != null, .tooltip = "Moves the stopped thread here without running anything. The stack and registers stay as they are, so jumping out of the function usually crashes" })) {
        self.wb.setNextInstruction(selected.?.start) catch |err| {
            self.code.problem = .init("Couldn't move it there: {t}", .{err});
        };
    }
    menu.separator();
    if (menu.item(.{ .label = "Show in memory", .chord = keys.show_memory, .enabled = selected != null, .tooltip = "The selected instructions' bytes" })) {
        self.wb.openMemory(selected.?.start, selected.?.len, null);
    }
    if (self.wb.sig_maker.busy()) {
        if (menu.item(.{ .label = "Stop making signature", .chord = keys.make_sig })) self.wb.sig_maker.stop();
    } else if (menu.item(.{ .label = "Make signature", .chord = keys.make_sig, .enabled = selected != null, .tooltip = "The shortest pattern that only matches here, or at code that points here. Copied as a location" })) {
        self.wb.sig_maker.start(self.wb, selected.?.start);
    }
    if (menu.item(.{ .label = "Go to address", .chord = keys.go_to })) self.bar.focus();
    menu.separator();
    self.code.commands(&menu);
    if (is64) {
        menu.separator();
        const relative = self.code.addresses == .relative;
        if (menu.item(.{ .label = if (relative) "Show RIP targets only" else "Show RIP-relative", .tooltip = "[rip+0x10] with where it points as a comment, or just where it points" })) {
            self.code.addresses = if (relative) .absolute else .relative;
        }
    }
}

/// With keyboard focus on it, so the arrows move from there.
fn goTo(self: *Disassembly, address: usize) void {
    self.bar.visit(address);
    self.code.goTo(address);
    self.code.focus();
}
