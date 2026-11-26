//! The workbench's side of the debugger: stops, stepping, breakpoints and taking over crashes.
//! Its thread, unless it says otherwise.

const std = @import("std");

const core = @import("wraith_core");
const devtools = @import("tuft_devtools");
const ui = @import("wraith_ui");
const crash = @import("../../crash/root.zig");

const c = @import("../imgui.zig").c;
const Workbench = @import("Workbench.zig");
const Debugger = Workbench.Debugger;
const pressed = @import("keys.zig").pressed;

const log = core.log.scoped(.wraith_ui);

/// So the crash window's "Open in workbench" opens it.
pub fn hookCrashes(self: *Workbench) void {
    crash.setOpener(.{ .ctx = self, .open = openForCrash });
}

pub fn unhookCrashes() void {
    crash.setOpener(null);
}

/// From the crash window's thread. The render thread's usually the one stopped, so nothing else is opening it.
fn openForCrash(ctx: *anyopaque) void {
    const self: *Workbench = @ptrCast(@alignCast(ctx));
    self.open();
}

/// Lets stopped threads go, a crash too.
pub fn deinit(self: *Workbench) void {
    self.debugger.deinit();
    crash.setDebugger(null);
}

pub fn tick(self: *Workbench) void {
    const d = &self.debugger;
    if (!self.ticked) {
        self.ticked = true;
        // Stopping the thread that would show it can't end well
        d.ignoreThread(std.Thread.getCurrentId());
    }
    d.beat();
    catchCrashes(self, self.isOpen());
    const now = core.timing.now();
    if (now -% self.last_refresh_ns >= std.time.ns_per_s) {
        self.last_refresh_ns = now;
        d.refresh();
    }
    // Something stopped. Show where
    const stops = d.stopCount();
    if (stops == self.seen_stops) return;
    self.seen_stops = stops;
    var newest: [Debugger.max_paused]Debugger.Paused = undefined;
    const n = d.paused(&newest);
    if (n == 0) return;
    var latest = &newest[0];
    for (newest[1..n]) |*p| if (p.id > latest.id) {
        latest = p;
    };
    self.panels.stopped.picked.only(latest.thread_id);
    // A step goes on quietly where it is, so the keys keep working wherever you are
    if (latest.reason == .step) if (self.active_code) |doc| {
        self.groups.debug.show(&self.panels.stopped);
        doc.body.code.follow(latest.cpu.ip());
        return;
    };
    // A breakpoint or crash takes over, even if you were busy in here
    if (self.app) |app| app.show();
    self.go(.{ .code = latest.cpu.ip() });
    self.focus_when_active = self.active_code;
    self.focus_applied = false;
    self.focus_for_stop = true;
    // Registers stay up if you were watching them
    const debug = &self.groups.debug;
    if (!debug.showing(&self.panels.registers) and !debug.showing(&self.panels.stopped)) debug.select(&self.panels.stopped) else debug.window.show();
    self.debug_to_front = true;
}

/// Only on a change, since it waits for a crash already stopped here to go.
fn catchCrashes(self: *Workbench, on: bool) void {
    if (on == self.catching_crashes) return;
    if (on) self.debugger.prepare() catch |err| {
        log.warn("Crashes won't stop in the debugger: {t}", .{err});
        return;
    };
    crash.setDebugger(if (on) &self.debugger else null);
    self.catching_crashes = on;
}

/// Where the stopped threads are, for this frame's markers.
pub fn readStops(self: *Workbench) void {
    var threads: [Debugger.max_paused]Debugger.Paused = undefined;
    self.stopped_len = self.debugger.paused(&threads);
    for (threads[0..self.stopped_len], 0..) |p, i| self.stopped_at[i] = p.cpu.ip();
}

/// The one picked in Stopped, else any.
pub fn focusedStop(self: *Workbench) ?Debugger.Paused {
    var threads: [Debugger.max_paused]Debugger.Paused = undefined;
    const n = self.debugger.paused(&threads);
    if (n == 0) return null;
    if (self.panels.stopped.picked.focused()) |id| {
        for (threads[0..n]) |p| if (p.thread_id == id) return p;
    }
    return threads[0];
}

pub fn resumeFocused(self: *Workbench, how: Debugger.How) void {
    const p = focusedStop(self) orelse return;
    _ = self.debugger.resumeThread(p.id, how);
}

/// Moves the thread picked in Stopped to `address`, without running anything.
pub fn setNextInstruction(self: *Workbench, address: usize) Debugger.SetCpuError!void {
    const p = focusedStop(self) orelse return error.NotStopped;
    try self.debugger.setIp(p.id, address);
    // So the marker moves now, not at the next refresh
    for (self.stopped_at[0..self.stopped_len]) |*at| if (at.* == p.cpu.ip()) {
        at.* = address;
    };
}

pub fn markAt(ctx: *anyopaque, address: usize) devtools.AsmView.Mark {
    const self: *Workbench = @ptrCast(@alignCast(ctx));
    var mark: devtools.AsmView.Mark = .{};
    if (self.debugger.get(address)) |b| mark.breakpoint = b.enabled;
    for (self.stopped_at[0..self.stopped_len]) |at| if (at == address) {
        mark.current = true;
    };
    return mark;
}

/// A software one if there's none there, else takes away whatever's there.
pub fn toggleBreakpoint(self: *Workbench, address: usize) !void {
    return toggleBreakpointOf(self, address, .software);
}

pub fn toggleHardwareBreakpoint(self: *Workbench, address: usize) !void {
    return toggleBreakpointOf(self, address, .hardware);
}

fn toggleBreakpointOf(self: *Workbench, address: usize, kind: Debugger.Kind) !void {
    if (self.debugger.get(address) != null) return self.debugger.remove(address);
    try self.debugger.add(address, kind, .thread);
    self.groups.debug.show(&self.panels.breakpoints);
}

/// Keeps how it stops and whether it's on.
pub fn setBreakpointKind(self: *Workbench, address: usize, kind: Debugger.Kind) !void {
    const b = self.debugger.get(address) orelse return;
    if (b.kind == kind) return;
    self.debugger.remove(address);
    self.debugger.add(address, kind, b.stop) catch |err| {
        // Put back what was there
        self.debugger.add(address, b.kind, b.stop) catch {};
        return err;
    };
    if (!b.enabled) try self.debugger.setEnabled(address, false);
}

pub fn toggleBreakpointEnabled(self: *Workbench, address: usize) !void {
    const b = self.debugger.get(address) orelse return;
    try self.debugger.setEnabled(address, !b.enabled);
}

pub fn deleteAllBreakpoints(self: *Workbench) void {
    var all: [Debugger.max_breakpoints]Debugger.Breakpoint = undefined;
    const n = self.debugger.list(&all);
    for (all[0..n]) |b| self.debugger.remove(b.address);
}

/// Debugging keys work anywhere in it, like in Visual Studio.
pub fn debugKeys(self: *Workbench) void {
    const chords = &devtools.keys;
    if (pressed(chords.continue_thread)) resumeFocused(self, .run);
    if (pressed(chords.step_into)) resumeFocused(self, .step);
    if (pressed(chords.step_over)) resumeFocused(self, .step_over);
    if (pressed(chords.delete_all_breakpoints)) deleteAllBreakpoints(self);
}

pub fn drawMenu(self: *Workbench) void {
    const chords = &devtools.keys;
    const stopped = self.stopped_len > 0;
    if (ui.menuItem("Continue", .{ .shortcut = shortcut(chords.continue_thread), .enabled = stopped })) resumeFocused(self, .run);
    ui.tooltip("Let the stopped thread go, the one picked in Stopped", .{});
    if (ui.menuItem("Step into", .{ .shortcut = shortcut(chords.step_into), .enabled = stopped })) resumeFocused(self, .step);
    ui.tooltip("Run the stopped thread's next instruction", .{});
    if (ui.menuItem("Step over", .{ .shortcut = shortcut(chords.step_over), .enabled = stopped })) resumeFocused(self, .step_over);
    ui.tooltip("Like step into, but a call runs through to where it returns", .{});
    if (ui.menuItem("Continue all", .{ .enabled = stopped })) self.debugger.resumeAll();
    ui.separator();
    var any: [1]Debugger.Breakpoint = undefined;
    const has_breakpoints = self.debugger.list(&any) > 0;
    if (ui.menuItem("Delete all breakpoints", .{ .shortcut = shortcut(chords.delete_all_breakpoints), .enabled = has_breakpoints })) deleteAllBreakpoints(self);
    const accesses = &self.panels.accesses;
    if (ui.menuItem("Stop all watches", .{ .enabled = accesses.running() > 0 })) accesses.stopAll();
    ui.tooltip("Stop finding what writes or reads addresses. Frees the CPU's four debug registers", .{});
    ui.separator();
    if (ui.menuItem("Breakpoints", .{})) self.groups.debug.focus(&self.panels.breakpoints);
    if (ui.menuItem("Stopped threads", .{})) self.groups.debug.focus(&self.panels.stopped);
    if (ui.menuItem("Registers", .{})) self.groups.debug.focus(&self.panels.registers);
}

fn shortcut(chord: ?ui.Chord) ?[:0]const u8 {
    return ui.format("{f}", .{chord orelse return null});
}

/// Focuses a stop's code after `show`'s raise, and again once Windows gives the window focus. Inside that window.
pub fn applyPendingFocus(self: *Workbench) void {
    const doc = self.focus_when_active orelse return;
    // Let go meanwhile, so it's not about this stop anymore
    if (self.focus_for_stop and self.stopped_len == 0) {
        self.focus_when_active = null;
        return;
    }
    const app = self.app orelse {
        self.focus_when_active = null;
        return doc.window().focus();
    };
    if (app.raising()) return;
    if (!self.focus_applied) {
        self.focus_applied = true;
        doc.window().focus();
    }
    if (!hasOsFocus()) return;
    self.focus_when_active = null;
    // ImGui leaves focus alone when it came with a click, so a click wins here too
    if (!c.ImGui_IsAnyMouseDown()) doc.window().focus();
}

/// As ImGui saw it this frame. Inside the window.
fn hasOsFocus() bool {
    // No way to tell
    if (c.ImGui_GetPlatformIO().*.Platform_GetWindowFocus == null) return true;
    return c.ImGui_GetWindowViewport().*.Flags & c.ImGuiViewportFlags_IsFocused != 0;
}
