//! Keeps our last-chance filter first; filters games set become the one ours passes crashes on to.

const std = @import("std");

const core = @import("wraith_core");
const hook = @import("tuft_hook");

const log = core.log.scoped(.wraith_runtime);

const SetFilter = fn (filter: ?*const anyopaque) callconv(.winapi) ?*const anyopaque;

const State = struct {
    ours: usize,
    set_next: *const fn (address: usize) usize,
};

var state: State = undefined;
var installed: ?*hook.TypedHook(SetFilter) = null;

pub fn start(ours: usize, set_next: *const fn (address: usize) usize) void {
    if (installed != null) return;
    state = .{ .ours = ours, .set_next = set_next };
    const kernel32 = hook.memory.Module.find("kernel32.dll") catch return;
    const h = kernel32.symbol("SetUnhandledExceptionFilter").createFn(SetFilter, detour, &state) catch |err| {
        log.warn("Crashes may skip Wraith if the game sets its own handler: {t}", .{err});
        return;
    };
    h.enable() catch |err| {
        log.warn("Crashes may skip Wraith if the game sets its own handler: {t}", .{err});
        h.destroy();
        return;
    };
    installed = h;
}

/// Before taking ours out, which goes through the real one.
pub fn stop() void {
    const h = installed orelse return;
    h.destroy();
    installed = null;
}

fn detour(s: *State, h: *hook.TypedHook(SetFilter), filter: ?*const anyopaque) ?*const anyopaque {
    if (@intFromPtr(filter) == s.ours) return h.original()(filter);
    return @ptrFromInt(s.set_next(@intFromPtr(filter)));
}
