//! The `Hooks` and `Watches` areas, from `hooks.sal` and `watches.sal`. Handlers get the registers as
//! `cpu.sal`'s `Cpu`, see `cpu.zig`.

const std = @import("std");

const api = @import("wraith_api");

const host = @import("root.zig");
const wraith = @import("wraith.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;

const sal = api.salamander;
const W = api.wraith;
pub const Hooks = W.Hooks;
pub const Hook = W.Hook;
pub const Watches = W.Watches;
pub const Watch = W.Watch;

const allocator = std.heap.page_allocator;

/// Hook functions take a `Loaded` they never look at.
const nobody: *Loaded = undefined;

const HookError = error{ AlreadyHooked, FunctionTooSmall, TargetModified, UnexpectedBytes, InvalidPattern, SplitsInstruction, InvalidSignature, WrongHandler, NotFound, Failed };

fn hookError(err: anyerror) HookError {
    return switch (err) {
        error.AlreadyHooked => error.AlreadyHooked,
        error.FunctionTooSmall => error.FunctionTooSmall,
        error.TargetModified => error.TargetModified,
        error.UnexpectedBytes => error.UnexpectedBytes,
        error.InvalidPattern => error.InvalidPattern,
        error.SplitsInstruction => error.SplitsInstruction,
        error.InvalidSignature => error.InvalidSignature,
        error.Unknown, error.NotFound, error.NeedsObject => error.NotFound,
        else => error.Failed,
    };
}

pub const HooksImpl = struct {
    pub fn detour(loaded: *Loaded, target: usize, signature: []const u8, handler: sal.AnyObject, options: W.HookOptions) sal.Plain(Hooks, "detour") {
        return typed(loaded, target, false, signature, handler, options);
    }

    pub fn detourSlot(loaded: *Loaded, at: usize, signature: []const u8, handler: sal.AnyObject, options: W.HookOptions) sal.Plain(Hooks, "detourSlot") {
        return typed(loaded, at, true, signature, handler, options);
    }

    pub fn named(loaded: *Loaded, name: []const u8, handler: sal.AnyObject, options: W.HookOptions) sal.Plain(Hooks, "named") {
        const schemas = host.schemas.of(loaded) catch {
            sal.host().release(handler);
            return error.Failed;
        };
        const f = schemas.schema().findFunction(name) orelse {
            sal.host().release(handler);
            return sal.host().explain(error.NotFound, "the plugin's schemas don't declare a function or method {s}", .{name});
        };
        const slot = f.method.virtual != null;
        const target = (if (slot) schemas.slot(name) else schemas.address(name)) catch |err| {
            sal.host().release(handler);
            // Keeps what went wrong as NotFound's
            return sal.host().explain(error.NotFound, "{s}", .{sal.host().explanation(@errorName(err))});
        };
        return typed(loaded, target, slot, name, handler, options);
    }

    pub fn context(_: *Loaded) usize {
        return host.hooks.runningContext();
    }

    pub fn detourNative(loaded: *Loaded, target: usize, to: usize, options: W.HookOptions) sal.Plain(Hooks, "detourNative") {
        return native(loaded, target, false, to, options);
    }

    pub fn detourSlotNative(loaded: *Loaded, at: usize, to: usize, options: W.HookOptions) sal.Plain(Hooks, "detourSlotNative") {
        return native(loaded, at, true, to, options);
    }

    pub fn nativeCalls(_: *Loaded) W.NativeHookCalls {
        return .{ .enter = @intFromPtr(&nativeEnter), .leave = @intFromPtr(&nativeLeave) };
    }

    pub fn mid(loaded: *Loaded, target: usize, options: W.MidOptions, handler: host.hooks.MidHandler) sal.Plain(Hooks, "mid") {
        const t = wraith.tablesOf(loaded) orelse {
            handler.release();
            return error.Failed;
        };
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const names = a.alloc(api.Name, options.names.len) catch {
            handler.release();
            return error.Failed;
        };
        for (options.names, names) |n, *o| o.* = .of(n.name, n.address);
        var problem: api.AsmProblem = .{};
        const h = host.hooks.createMid(loaded, target, handler, .{
            .replace = options.replace,
            .size = options.size,
            .expect = options.expect,
            .problem = &problem,
            .names = names,
        }) catch |err| {
            const e = hookError(err);
            if (problem.message().len == 0) return e;
            return sal.host().explain(e, "{s}", .{problem.message()});
        };
        if (!options.disabled) host.hooks.enable(nobody, h) catch |err| {
            host.hooks.destroy(nobody, h);
            return hookError(err);
        };
        return .init(h, t.hook);
    }
};

fn native(loaded: *Loaded, target: usize, slot: bool, to: usize, options: W.HookOptions) sal.Plain(Hooks, "detourNative") {
    const t = wraith.tablesOf(loaded) orelse return error.Failed;
    const h = (if (slot) host.hooks.createSlot(loaded, target, to, options.context) else host.hooks.createFn(loaded, target, to, options.context)) catch |err| return hookError(err);
    if (!options.disabled) host.hooks.enable(nobody, h) catch |err| {
        host.hooks.destroy(nobody, h);
        return hookError(err);
    };
    return .init(h, t.hook);
}

fn nativeEnter() callconv(.c) W.HookCall {
    const call = host.hooks.enter(nobody);
    return .{ .hook = @intFromPtr(call.hook), .original = call.trampoline, .context = call.user_data, .entered = call.entered };
}

fn nativeLeave(h: usize) callconv(.c) void {
    host.hooks.leave(nobody, @ptrFromInt(h));
}

/// A function hook on `target`, or the pointer at it for `slot`. Takes `handler` either way.
fn typed(loaded: *Loaded, target: usize, slot: bool, signature: []const u8, handler: sal.AnyObject, options: W.HookOptions) sal.Plain(Hooks, "detour") {
    const t = wraith.tablesOf(loaded) orelse {
        sal.host().release(handler);
        return error.Failed;
    };
    const schemas = host.schemas.of(loaded) catch {
        sal.host().release(handler);
        return error.Failed;
    };
    const ty = schemas.typedOf(signature) catch |err| {
        sal.host().release(handler);
        return hookError(err);
    };
    const table = handler.table orelse return sal.host().explain(error.WrongHandler, "there's no handler", .{});
    if (sal.headerOf(table).info.hash != ty.trait.info.hash) {
        sal.host().release(handler);
        return sal.host().explain(error.WrongHandler, "the handler isn't a fn value of `{s}`, like what salamander.fn makes with it", .{signature});
    }
    const h = host.hooks.createTyped(loaded, target, slot, ty, handler, options.context) catch |err| {
        sal.host().release(handler);
        return hookError(err);
    };
    if (!options.disabled) host.hooks.enable(nobody, h) catch |err| {
        host.hooks.destroy(nobody, h);
        return hookError(err);
    };
    return .init(h, t.hook);
}

pub const HookImpl = struct {
    pub fn original(h: *api.Hook) usize {
        return host.hooks.trampoline(nobody, h);
    }

    pub fn @"resume"(h: *api.Hook) usize {
        return host.hooks.resumeAt(nobody, h);
    }

    pub fn enable(h: *api.Hook) sal.Plain(Hook, "enable") {
        host.hooks.enable(nobody, h) catch |err| return hookError(err);
    }

    pub fn disable(h: *api.Hook) sal.Plain(Hook, "disable") {
        host.hooks.disable(nobody, h) catch |err| return hookError(err);
    }

    pub fn destroy(h: *api.Hook) void {
        host.hooks.destroy(nobody, h);
    }
};

pub const WatchesImpl = struct {
    pub fn add(loaded: *Loaded, address: usize, length: u8, kind: W.WatchKind, handler: host.watches.Handler) sal.Plain(Watches, "add") {
        const t = wraith.tablesOf(loaded) orelse {
            handler.release();
            return error.Failed;
        };
        const k: api.WatchKind = switch (kind) {
            inline .write, .access, .execute => |x| @field(api.WatchKind, @tagName(x)),
            else => {
                handler.release();
                return error.Failed;
            },
        };
        const record = host.watches.add(loaded, address, length, k, handler) catch |err| return switch (err) {
            error.WatchesUnavailable => error.Unavailable,
            error.NoFreeSlot => error.NoFreeSlot,
            error.Misaligned => error.Misaligned,
            error.InvalidLength => error.InvalidLength,
            else => error.Failed,
        };
        return .init(record, t.watch);
    }
};

pub const WatchImpl = struct {
    pub fn remove(record: *host.watches.Record) void {
        record.stop();
    }
};
