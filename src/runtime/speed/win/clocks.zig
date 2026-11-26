//! The Windows clocks games time frames with, hooked for `speed`.

const std = @import("std");

const core = @import("wraith_core");
const Hook = @import("tuft_hook").Hook;
const module = @import("tuft_sys").module;

const speed = @import("../root.zig");

const log = core.log.scoped(.wraith_runtime);

/// Returns BOOLEAN, but kernel32's callers read a BOOL, so the whole register passes through.
const Counter = fn (*i64) callconv(.winapi) u32;
const Ticks64 = fn () callconv(.winapi) u64;

/// Hook bookkeeping reads the clock too, which comes back here. Those calls get the real one.
threadlocal var inside: bool = false;

var counter: ?*Hook = null;
var real_counter: ?*const Counter = null;
var real_ticks: ?*const Ticks64 = null;
var multimedia: ?*Hook = null;
var winmm_watch: ?*module.WhenLoaded = null;

/// Scaled `T`; Wraith's own calls get the real one. `site` keeps each hooked copy apart.
fn Detour(comptime T: type, comptime clock: speed.Clock, comptime site: u8) type {
    return struct {
        comptime {
            _ = site;
        }
        var hook: ?*Hook = null;

        fn detour() callconv(.winapi) T {
            const from = @returnAddress();
            const h = hook.?;
            const original: *const fn () callconv(.winapi) T = @ptrFromInt(h.trampoline_addr);
            if (inside) return original();
            inside = true;
            defer inside = false;
            if (!h.enterCall()) return original();
            defer h.leaveCall();
            if (speed.own.contains(from)) return original();
            const real: u64 = if (clock == .ticks) real_ticks.?() else original();
            const v = speed.fake(clock, real);
            return if (T == u64) v else @truncate(v);
        }
    };
}

fn counterDetour(out: *i64) callconv(.winapi) u32 {
    const from = @returnAddress();
    const h = counter.?;
    const original: *const Counter = @ptrFromInt(h.trampoline_addr);
    if (inside) return original(out);
    inside = true;
    defer inside = false;
    if (!h.enterCall()) return original(out);
    defer h.leaveCall();
    const ok = original(out);
    if (!speed.own.contains(from)) out.* = @bitCast(speed.fake(.counter, @bitCast(out.*)));
    return ok;
}

const tick_dlls = [_][]const u8{ "kernelbase.dll", "kernel32.dll" };
const Tick64Sites = [_]type{ Detour(u64, .ticks, 0), Detour(u64, .ticks, 1) };
const TickSites = [_]type{ Detour(u32, .ticks, 0), Detour(u32, .ticks, 1) };
const Multimedia = Detour(u32, .multimedia, 0);

/// The clock's real time now, without the speed. Null if it isn't hooked.
pub fn now(clock: speed.Clock) ?u64 {
    switch (clock) {
        .counter => {
            var v: i64 = 0;
            _ = (real_counter orelse return null)(&v);
            return @bitCast(v);
        },
        .ticks => return (real_ticks orelse return null)(),
        .multimedia => {
            const h = multimedia orelse return null;
            const original: *const fn () callconv(.winapi) u32 = @ptrFromInt(h.trampoline_addr);
            return original();
        },
    }
}

/// Once, the first time the speed isn't 1.
pub fn install() !void {
    // Wraith's own code gets the real time
    const self_base = module.selfBase();
    speed.own.add(self_base, module.imageSize(self_base) catch 0);

    const ntdll = module.findBase("ntdll.dll") orelse return error.NoClock;
    const qpc = module.findExport(ntdll, "RtlQueryPerformanceCounter") orelse return error.NoClock;
    const h = try Hook.createFnRaw(qpc, @intFromPtr(&counterDetour), 0);
    counter = h;
    real_counter = @ptrFromInt(h.trampoline_addr);
    h.enable() catch |err| {
        h.destroy();
        counter = null;
        real_counter = null;
        return err;
    };
    speed.start(.counter, now(.counter).?);

    // The tick counts are worked out from one real GetTickCount64, so all of them hooked first
    var hooked: [4]usize = @splat(0);
    var n: usize = 0;
    inline for (tick_dlls, Tick64Sites, TickSites) |dll, Wide, Narrow| {
        if (module.findBase(dll)) |base| {
            inline for (.{ .{ "GetTickCount64", Wide }, .{ "GetTickCount", Narrow } }) |site| {
                if (hookSite(base, site[0], &site[1].detour, &hooked, &n)) |hk| {
                    site[1].hook = hk;
                    if (real_ticks == null and std.mem.eql(u8, site[0], "GetTickCount64")) real_ticks = @ptrFromInt(hk.trampoline_addr);
                }
            }
        }
    }
    if (real_ticks) |_| {
        speed.start(.ticks, now(.ticks).?);
        inline for (Tick64Sites ++ TickSites) |S| if (S.hook) |hk| hk.enable() catch |err| log.warn("Game speed can't change a tick count: {t}", .{err});
    } else log.warn("Game speed can't change GetTickCount", .{});

    winmm_watch = module.WhenLoaded.create(std.heap.page_allocator, "winmm.dll", .{ .ctx = null, .ready = winmmLoaded }) catch |err| blk: {
        log.warn("Game speed can't change timeGetTime: {t}", .{err});
        break :blk null;
    };
}

/// Puts the clocks back, waiting for calls in flight.
pub fn uninstall() void {
    if (winmm_watch) |w| w.destroy();
    winmm_watch = null;
    inline for (Tick64Sites ++ TickSites ++ .{Multimedia}) |S| if (S.hook) |hk| {
        hk.destroy();
        S.hook = null;
    };
    multimedia = null;
    real_ticks = null;
    if (counter) |h| h.destroy();
    counter = null;
    real_counter = null;
}

/// Made but not on yet. Null if it's not there, or hooked already under another name.
fn hookSite(base: usize, name: []const u8, detour: anytype, hooked: *[4]usize, n: *usize) ?*Hook {
    const at = module.findExport(base, name) orelse return null;
    for (hooked[0..n.*]) |seen| if (seen == at) return null;
    const hk = Hook.createFnRaw(at, @intFromPtr(detour), 0) catch |err| {
        log.warn("Game speed can't change {s}: {t}", .{ name, err });
        return null;
    };
    hooked[n.*] = at;
    n.* += 1;
    return hk;
}

fn winmmLoaded(_: ?*anyopaque, base: usize) void {
    const at = module.findExport(base, "timeGetTime") orelse return;
    const hk = Hook.createFnRaw(at, @intFromPtr(&Multimedia.detour), 0) catch |err| {
        log.warn("Game speed can't change timeGetTime: {t}", .{err});
        return;
    };
    Multimedia.hook = hk;
    multimedia = hk;
    speed.start(.multimedia, now(.multimedia).?);
    hk.enable() catch |err| log.warn("Game speed can't change timeGetTime: {t}", .{err});
}
