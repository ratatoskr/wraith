//! Typed hooks. The runtime does the patching.

const std = @import("std");

const meta = @import("tuft_hook").meta;
const Address = @import("tuft_mem").Address;

const api = @import("wraith_api");
const Owner = @import("Owner.zig");

pub const CpuContext = api.CpuContext;

const W = api.wraith;
const HookObject = W.Hook;

pub const Error = error{
    OutOfMemory,
    AlreadyHooked,
    FunctionTooSmall,
    TargetModified,
    UnexpectedBytes,
    InvalidPattern,
    SplitsInstruction,
    NotFound,
    HookFailed,
    HooksUnavailable,
};

fn hookError(err: anyerror) Error {
    return switch (err) {
        inline error.AlreadyHooked, error.FunctionTooSmall, error.TargetModified, error.UnexpectedBytes, error.InvalidPattern, error.SplitsInstruction, error.NotFound => |e| e,
        error.Gone => error.HooksUnavailable,
        else => error.HookFailed,
    };
}

/// Detours only run while the DLL is loaded, so its own owner works for all.
fn host() Owner {
    return Owner.own().?;
}

fn Common(comptime Self: type) type {
    return struct {
        pub fn enable(self: Self) Error!void {
            return self.object.enable() catch |err| hookError(err);
        }

        pub fn disable(self: Self) Error!void {
            return self.object.disable() catch |err| hookError(err);
        }

        /// Waits for calls in flight. Safe to call twice.
        pub fn destroy(self: Self) void {
            self.object.destroy();
        }
    };
}

pub fn FnHook(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Original = *const meta.FnType(T);

        object: HookObject,
        /// Kept from when it was made, since asking the hook stops working once the plugin's
        /// going, while a game thread can still be in the detour.
        original_address: usize = 0,

        pub const enable = Common(Self).enable;
        pub const disable = Common(Self).disable;
        pub const destroy = Common(Self).destroy;

        pub fn original(self: Self) Original {
            return @ptrFromInt(if (self.original_address != 0) self.original_address else self.object.original());
        }
    };
}

pub const MidHook = struct {
    object: HookObject,

    pub const enable = Common(MidHook).enable;
    pub const disable = Common(MidHook).disable;
    pub const destroy = Common(MidHook).destroy;

    /// Setting the ip here in the callback runs the original instruction, or the code it
    /// replaces, then carries on.
    pub fn originalAddress(self: MidHook) usize {
        return self.object.original();
    }

    /// Setting the ip here in the callback skips the instruction, or the code it replaces.
    pub fn resumeAddress(self: MidHook) usize {
        return self.object.@"resume"();
    }
};

/// Like `Hooks.MidOptions` in hooks.sal.
pub const MidOptions = struct {
    /// The callback replaces code there, so returning carries on after it. Else it goes before
    /// the instruction there, which runs after it.
    replace: bool = false,
    /// Bytes it replaces, ending between instructions. 0 is what `expect` covers, or else the
    /// instruction there.
    size: u32 = 0,
    /// What has to be there, a byte pattern like `89 83 ?? ??` or asm like `cmp ecx, eax`.
    expect: []const u8 = "",
    /// Starts on. Otherwise call `enable`.
    enabled: bool = false,
};

pub const Options = struct {
    /// Starts on. Otherwise call `enable`.
    enabled: bool = false,
};

/// The runtime's way into native detours, made once and fine from any thread.
var calls: ?W.Hooks.NativeCalls = null;
var hook_table: ?*const anyopaque = null;

const HookCall = W.Hook.Call;

/// What `hook(In, name, ...)` gives, like `Hook(GameStateManager, .spendMira)`.
pub fn Hook(comptime In: type, comptime name: @EnumLiteral()) type {
    return FnHook(@field(In.Fns, @tagName(name)));
}

/// Hooks a function the schemas declare, like `hook(GameStateManager, .spendMira, cb, self)`. `In` is
/// the struct or namespace it's in. A [Virtual(n)] one swaps its vtable slot. `callback` takes the
/// function's arguments, after the hook and the context if it wants them. `createFn` and
/// `createSlot` do the same at an address of your own.
pub fn hook(comptime In: type, comptime name: @EnumLiteral(), comptime callback: anytype, context: anytype) !Hook(In, name) {
    return hookWith(In, name, callback, context, .{});
}

pub fn hookWith(comptime In: type, comptime name: @EnumLiteral(), comptime callback: anytype, context: anytype, options: Options) !Hook(In, name) {
    const n = @tagName(name);
    const at = try @field(In.addresses, n)();
    const slot = comptime @hasDecl(In, "slots") and @hasDecl(In.slots, n);
    return hookTyped(In, name, slot, at, callback, context, options);
}

/// The same at an address of your own, typed like the declared one, like `createFn`.
pub fn hookAt(comptime In: type, comptime name: @EnumLiteral(), target: anytype, comptime callback: anytype, context: anytype) !Hook(In, name) {
    return hookAtWith(In, name, target, callback, context, .{});
}

pub fn hookAtWith(comptime In: type, comptime name: @EnumLiteral(), target: anytype, comptime callback: anytype, context: anytype, options: Options) !Hook(In, name) {
    return hookTyped(In, name, false, try Address.from(target).unwrap(), callback, context, options);
}

fn hookTyped(comptime In: type, comptime name: @EnumLiteral(), slot: bool, at: usize, comptime callback: anytype, context: anytype, options: Options) !Hook(In, name) {
    const T = @field(In.Fns, @tagName(name));
    const Bridge = FnBridge(T, callback, @TypeOf(context));
    const h = try native(slot, at, @intFromPtr(&Bridge.detour), meta.addressFromAny(context), options);
    return .{ .object = h, .original_address = h.original() };
}

pub fn createFn(comptime T: type, target: anytype, comptime callback: anytype, context: anytype) !FnHook(T) {
    return createFnWith(T, target, callback, context, .{});
}

pub fn createFnWith(comptime T: type, target: anytype, comptime callback: anytype, context: anytype, options: Options) !FnHook(T) {
    const Bridge = FnBridge(T, callback, @TypeOf(context));
    const h = try native(false, try Address.from(target).unwrap(), @intFromPtr(&Bridge.detour), meta.addressFromAny(context), options);
    return .{ .object = h, .original_address = h.original() };
}

pub fn createSlot(comptime T: type, slot: anytype, comptime callback: anytype, context: anytype) !FnHook(T) {
    return createSlotWith(T, slot, callback, context, .{});
}

pub fn createSlotWith(comptime T: type, slot: anytype, comptime callback: anytype, context: anytype, options: Options) !FnHook(T) {
    const Bridge = FnBridge(T, callback, @TypeOf(context));
    const h = try native(true, try Address.from(slot).unwrap(), @intFromPtr(&Bridge.detour), meta.addressFromAny(context), options);
    return .{ .object = h, .original_address = h.original() };
}

fn native(slot: bool, target: usize, detour: usize, context: usize, options: Options) Error!HookObject {
    const owner = Owner.current() orelse return error.HooksUnavailable;
    const hooks = owner.root.hooks();
    if (calls == null) {
        const c = hooks.nativeHookCalls();
        if (c.enter == 0 or c.leave == 0) return error.HooksUnavailable;
        calls = c;
    }
    const hook_options: W.Hook.Options = .{ .context = context, .disabled = !options.enabled };
    const h = (if (slot) hooks.detourSlotNative(target, detour, hook_options) else hooks.detourNative(target, detour, hook_options)) catch |err| return hookError(err);
    hook_table = h.table;
    return h;
}

/// `callback` gets the registers before the instruction at `target`, which runs after it.
pub fn createMid(target: anytype, comptime callback: anytype, context: anytype) !MidHook {
    return createMidWith(target, callback, context, .{});
}

/// Like `createMid`, but `options` can make it replace code instead, see `MidOptions`.
pub fn createMidWith(target: anytype, comptime callback: anytype, context: anytype, options: MidOptions) !MidHook {
    const owner = Owner.current() orelse return error.HooksUnavailable;
    const at = try Address.from(target).unwrap();
    const Context = @TypeOf(context);
    const cb_params = meta.fnInfo(@TypeOf(callback)).param_types;
    const Bridge = struct {
        fn run(ctx: ?*anyopaque, cpu: *W.Cpu) void {
            const user_data = if (ctx) |p| @intFromPtr(p) else 0;
            // Laid out the same, but tuft's wants more alignment
            var regs: CpuContext = undefined;
            @memcpy(std.mem.asBytes(&regs), std.mem.asBytes(cpu));
            defer @memcpy(std.mem.asBytes(cpu), std.mem.asBytes(&regs));
            var cb_args: CallbackArgs(callback) = undefined;
            inline for (cb_params, 0..) |P, i| {
                cb_args[i] = if (P.? == *CpuContext) &regs else if (comptime hasContext(Context) and P.? == Context) @ptrFromInt(user_data) else @compileError("A mid hook callback takes *CpuContext and the context, not " ++ @typeName(P.?));
            }
            @call(.auto, callback, cb_args);
        }
    };
    const handler = W.Hooks.MidHandler.init(meta.addressFromAny(context), Bridge.run);
    const h = owner.root.hooks().mid(at, .{
        .replace = options.replace,
        .size = options.size,
        .expect = options.expect,
        .disabled = !options.enabled,
        .names = &.{},
    }, handler) catch |err| return hookError(err);
    return .{ .object = h };
}

fn hasContext(comptime Context: type) bool {
    return Context != void and Context != @TypeOf(null) and Context != type;
}

fn CallbackArgs(comptime callback: anytype) type {
    return std.meta.ArgsTuple(meta.FnType(@TypeOf(callback)));
}

inline fn inject(comptime P: type, comptime Context: type, comptime Handle: type, call: HookCall) P {
    if (comptime hasContext(Context) and P == Context) return @ptrFromInt(call.context);
    if (P == Handle) return .{ .object = .{ .data = call.hook, .table = hook_table }, .original_address = call.original };
    @compileError("Callback parameter of type '" ++ @typeName(P) ++ "' can't be injected; expected " ++ @typeName(Handle) ++
        (if (hasContext(Context)) " or the context type '" ++ @typeName(Context) ++ "'" else " (no context was provided)"));
}

fn FnBridge(comptime T: type, comptime callback: anytype, comptime Context: type) type {
    const params = meta.fnInfo(T).param_types;
    const R = meta.fnInfo(T).return_type.?;
    const cb_params = meta.fnInfo(@TypeOf(callback)).param_types;

    if (cb_params.len < params.len) @compileError("The callback has fewer parameters than the hooked function");
    const extra = cb_params.len - params.len;

    return meta.Forwarder(T, struct {
        pub inline fn invoke(args: anytype) R {
            // First thing, since `enter` reads which hook was hit
            const c = calls.?;
            const enter: *const fn () callconv(.c) HookCall = @ptrFromInt(c.enter);
            const call = enter();
            if (!call.entered) {
                // Being destroyed, act like we're not hooked
                const original: *const meta.FnType(T) = @ptrFromInt(call.original);
                return @call(.auto, original, args);
            }
            const leave: *const fn (usize) callconv(.c) void = @ptrFromInt(c.leave);
            defer leave(call.hook);

            var cb_args: CallbackArgs(callback) = undefined;
            inline for (0..extra) |i| cb_args[i] = inject(cb_params[i].?, Context, FnHook(T), call);
            inline for (0..params.len) |i| cb_args[extra + i] = args[i];
            return @call(.auto, callback, cb_args);
        }
    });
}

const tests = struct {
    const Fake = @import("testing.zig").Fake;

    test "failed address chain" {
        var fake: Fake = .{};
        fake.attach();
        defer fake.detach();

        try std.testing.expectError(error.PatternNotFound, createMid(Address.fail(error.PatternNotFound), struct {
            fn cb(_: *CpuContext) void {}
        }.cb, {}));
    }

    test "without hooks" {
        var fake: Fake = .{};
        fake.attach();
        defer fake.detach();

        const Fn = fn () callconv(.c) void;
        try std.testing.expectError(error.HooksUnavailable, createFn(Fn, 0x1000, struct {
            fn d() void {}
        }.d, {}));
    }

    test "without an owner" {
        Owner.detach();
        try std.testing.expectError(error.HooksUnavailable, createMid(0x1000, struct {
            fn cb(_: *CpuContext) void {}
        }.cb, {}));
    }
};

test {
    _ = tests;
}
