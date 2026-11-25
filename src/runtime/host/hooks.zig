//! Hooks service. Every owner's hooks share one engine, so overlapping ones get refused.

const std = @import("std");

const core = @import("wraith_core");
const Hook = @import("tuft_hook").Hook;
const Patch = @import("tuft_hook").Patch;
const api = @import("wraith_api");

const host = @import("root.zig");
const code = @import("code.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;

const log = core.log.scoped(.wraith_runtime);

/// From `hooks.sal`, kept till the hook's destroyed.
pub const MidHandler = api.wraith.Hooks.MidHandler;
const cpu_regs = @import("cpu.zig");
const schemas = @import("schemas.zig");
const bind = @import("salamander_bind");
const sync = @import("tuft_sys").sync;
const sal = api.salamander;

// Function hooks typed by a signature, written while running or declared in the plugin's schemas

pub const Typed = schemas.Typed;

/// A typed hook's handler and what it was given.
const FnHandler = struct {
    record: bind.FnRecord,
    handler: sal.AnyObject,
    trait: *const bind.Trait,
    context: usize,
};

/// What `hooks.sal`'s `context` gives while a handler runs on this thread.
threadlocal var running_context: usize = 0;

pub fn runningContext() usize {
    return running_context;
}

/// Every typed hook's detour. The stub before it set the current hook, whose record says the rest.
const typed_detour = bind.Detour(findTyped);

fn findTyped() *const bind.FnRecord {
    const engine = Hook.current();
    const record: *Record = @ptrFromInt(engine.user_data);
    return &record.fn_handler.?.record;
}

fn typedDispatch(ctx: usize, _: u32, args: []const [*]u8, value: [*]u8) u32 {
    const record: *Record = @ptrFromInt(ctx);
    const h = &record.fn_handler.?;
    const engine = record.engine;
    const const_args: []const [*]const u8 = @ptrCast(args);
    // Going away, so the game gets what it would have
    if (!engine.enterCall()) return bind.callAt(h.record.function, engine.trampoline_addr, const_args, value);
    defer engine.leaveCall();
    const was = running_context;
    running_context = h.context;
    defer running_context = was;
    return bind.call(h.trait, h.handler, 0, const_args, value);
}

/// Through `hooks.sal`. `handler` is still the caller's if it fails.
pub fn createTyped(loaded: *Loaded, target: usize, slot: bool, t: Typed, handler: sal.AnyObject, context: usize) api.HookError!*api.Hook {
    const allocator = loaded.allocator;
    const record = try allocator.create(Record);
    record.* = .{ .engine = undefined, .loaded = loaded, .user_data = 0 };
    record.fn_handler = .{
        .record = .{ .function = t.function, .ctx = @intFromPtr(record), .dispatch = typedDispatch },
        .handler = handler,
        .trait = t.trait,
        .context = context,
    };
    const detour = typed_detour.address();
    record.engine = (if (slot) Hook.createSlotRaw(target, detour, @intFromPtr(record)) else Hook.createFnRaw(target, detour, @intFromPtr(record))) catch |err| {
        allocator.destroy(record);
        return errorFor(err, target);
    };
    return finish(record);
}

pub const Record = struct {
    engine: *Hook,
    loaded: *Loaded,
    user_data: usize,
    mid_handler: ?MidHandler = null,
    fn_handler: ?FnHandler = null,
    destroyed: bool = false,

    fn handle(self: *Record) *api.Hook {
        return @ptrCast(self);
    }

    fn of(h: *api.Hook) *Record {
        return @ptrCast(@alignCast(h));
    }

    pub fn going(self: *Record) bool {
        return !self.destroyed;
    }

    pub fn stop(self: *Record) void {
        if (self.destroyed) return;
        self.engine.destroy();
        self.destroyed = true;
        // Calls in flight are done, so it won't be called again
        if (self.mid_handler) |f| f.release();
        if (self.fn_handler) |h| sal.host().release(h.handler);
    }

    pub fn free(self: *Record) void {
        self.stop();
        self.loaded.allocator.destroy(self);
    }
};

var records: host.Owned(Record) = .{};

/// Its hooks that aren't destroyed.
pub fn countOf(loaded: *Loaded) u32 {
    return records.count(&loaded.owner);
}

pub fn createFn(loaded: *Loaded, target: usize, detour: usize, user_data: usize) api.HookError!*api.Hook {
    return create(loaded, target, .{ .detour = detour }, user_data);
}

pub fn createSlot(loaded: *Loaded, slot: usize, detour: usize, user_data: usize) api.HookError!*api.Hook {
    return create(loaded, slot, .{ .slot = detour }, user_data);
}

/// Before the instruction at `target`, or in place of the code `options` says it replaces. Through
/// `hooks.sal`, and `handler`'s released if it fails.
pub fn createMid(loaded: *Loaded, target: usize, handler: MidHandler, options: api.MidOptions) api.HookError!*api.Hook {
    return midWith(loaded, target, handler, options) catch |err| {
        handler.release();
        return err;
    };
}

fn midWith(loaded: *Loaded, target: usize, handler: MidHandler, options: api.MidOptions) api.HookError!*api.Hook {
    var replace: u8 = 0;
    var names: code.Names = .{ .loaded = loaded, .scope = options.names };
    if (options.replace) {
        const expect: ?[]const u8 = if (options.expect.len > 0) options.expect else null;
        var found: Patch.ExpectProblem = .{};
        const size = Patch.replaceSize(target, .{ .size = options.size, .expect = expect, .problem = &found, .resolver = names.resolver() }) catch |err| {
            if (options.problem) |p| code.describeExpect(err, &found, p);
            return errorFor(err, target);
        };
        replace = std.math.cast(u8, size) orelse return error.HookFailed;
    } else if (options.expect.len > 0) {
        var found: Patch.ExpectProblem = .{};
        _ = Patch.expected(target, options.expect, .{ .problem = &found, .resolver = names.resolver() }) catch |err| {
            if (options.problem) |p| code.describeExpect(err, &found, p);
            return errorFor(err, target);
        };
    }
    return create(loaded, target, .{ .mid = .{ .handler = handler, .replace = replace } }, 0);
}

/// Code before the instruction at `target`, which runs after it.
pub fn createInject(loaded: *Loaded, target: usize, source: []const u8, options: api.InjectOptions, problem: *api.AsmProblem) api.InjectError!*api.Hook {
    const allocator = loaded.allocator;
    const record = try allocator.create(Record);
    record.* = .{ .engine = undefined, .loaded = loaded, .user_data = 0 };
    var build: code.Build = .{ .gpa = allocator, .source = source, .problem = problem, .loaded = loaded, .scope = options.names };
    var reach: [16]usize = undefined;
    record.engine = Hook.createInjectRaw(target, build.of(), .{ .reach = code.reachOf(options.names, &reach) }) catch |err| {
        allocator.destroy(record);
        if (build.failed) |failed| return failed;
        return errorFor(err, target);
    };
    return finish(record);
}

fn create(loaded: *Loaded, target: usize, kind: union(enum) { detour: usize, slot: usize, mid: struct { handler: MidHandler, replace: u8 } }, user_data: usize) api.HookError!*api.Hook {
    const allocator = loaded.allocator;
    const record = try allocator.create(Record);
    record.* = .{ .engine = undefined, .loaded = loaded, .user_data = user_data };
    record.engine = switch (kind) {
        .detour => |detour| Hook.createFnRaw(target, detour, @intFromPtr(record)),
        .slot => |detour| Hook.createSlotRaw(target, detour, @intFromPtr(record)),
        .mid => |mid| blk: {
            record.mid_handler = mid.handler;
            break :blk Hook.createMidRaw(target, midEntry, @intFromPtr(record), .{ .replace = mid.replace });
        },
    } catch |err| {
        allocator.destroy(record);
        return errorFor(err, target);
    };
    return finish(record);
}

fn finish(record: *Record) api.HookError!*api.Hook {
    record.engine.setOwner(&record.loaded.owner);
    records.add(record) catch |err| {
        // The handler's still the caller's
        record.mid_handler = null;
        record.fn_handler = null;
        record.free();
        return if (err == error.OutOfMemory) error.OutOfMemory else error.HookFailed;
    };
    return record.handle();
}

pub fn enable(_: *Loaded, h: *api.Hook) api.HookError!void {
    const record = Record.of(h);
    if (record.destroyed) return error.InvalidHandle;
    record.engine.enable() catch |err| return errorFor(err, record.engine.target_addr);
}

pub fn disable(_: *Loaded, h: *api.Hook) api.HookError!void {
    const record = Record.of(h);
    if (record.destroyed) return error.InvalidHandle;
    record.engine.disable() catch |err| return errorFor(err, record.engine.target_addr);
}

pub fn destroy(_: *Loaded, h: *api.Hook) void {
    Record.of(h).stop();
}

pub fn trampoline(_: *Loaded, h: *api.Hook) usize {
    return Record.of(h).engine.trampoline_addr;
}

pub fn resumeAt(_: *Loaded, h: *api.Hook) usize {
    return Record.of(h).engine.resume_addr;
}

pub fn enter(_: *Loaded) api.HookCall {
    // Must be the first thing on this thread since the stub ran
    const engine = Hook.current();
    const record: *Record = @ptrFromInt(engine.user_data);
    return .{
        .hook = record.handle(),
        .trampoline = engine.trampoline_addr,
        .user_data = record.user_data,
        .entered = engine.enterCall(),
    };
}

pub fn leave(_: *Loaded, h: *api.Hook) void {
    Record.of(h).engine.leaveCall();
}

fn midEntry(engine: *Hook, ctx: *Hook.CpuContext) callconv(.c) void {
    if (!engine.enterCall()) return;
    defer engine.leaveCall();
    const record: *Record = @ptrFromInt(engine.user_data);
    record.mid_handler.?.invoke(.{cpu_regs.of(ctx)});
}

fn errorFor(err: anyerror, target: usize) api.HookError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.AlreadyHooked => error.AlreadyHooked,
        error.FunctionTooSmall => error.FunctionTooSmall,
        error.TargetModified => error.TargetModified,
        error.UnexpectedBytes => error.UnexpectedBytes,
        error.InvalidPattern, error.InvalidExpect => error.InvalidPattern,
        error.SplitsInstruction => error.SplitsInstruction,
        else => {
            log.warn("Hook on 0x{x} failed: {t}", .{ target, err });
            return error.HookFailed;
        },
    };
}

const tests = struct {
    const testing = std.testing;
    const hook_engine = @import("tuft_hook");
    const sdk = @import("wraith_sdk");
    const arch = @import("tuft_arch");

    // `noinline` plus an asm barrier so calls really go through the patched code

    noinline fn add(a: i32, b: i32) callconv(.c) i32 {
        var x = a;
        var y = b;
        asm volatile (""
            : [x] "+r" (x),
              [y] "+r" (y),
        );
        return x + y;
    }

    noinline fn sub(a: i32, b: i32) callconv(.c) i32 {
        var x = a;
        var y = b;
        asm volatile (""
            : [x] "+r" (x),
              [y] "+r" (y),
        );
        return x - y;
    }

    noinline fn increment(a: usize) callconv(.c) usize {
        var x = a;
        asm volatile (""
            : [x] "+r" (x),
        );
        return x + 1;
    }

    const AddFn = fn (i32, i32) callconv(.c) i32;

    const FakePlugin = struct {
        loaded: Loaded,

        fn init(self: *FakePlugin) void {
            self.initNamed("test");
        }

        fn initNamed(self: *FakePlugin, name: []const u8) void {
            self.loaded.initForTest(testing.allocator, name);
            self.attach();
        }

        fn attach(self: *FakePlugin) void {
            sdk.Owner.attach(self.loaded.root());
        }

        fn unload(self: *FakePlugin) void {
            self.loaded.deinitForTest();
            sdk.Owner.detach();
        }
    };

    const State = struct {
        calls: u32 = 0,
        bonus: i32 = 1000,
    };

    fn addDetour(state: *State, hook: sdk.hooks.FnHook(AddFn), a: i32, b: i32) i32 {
        state.calls += 1;
        return hook.original()(a, b) + state.bonus;
    }

    test "fn hook" {
        try hook_engine.init(testing.allocator);
        defer hook_engine.deinit();
        var fake: FakePlugin = undefined;
        fake.init();
        defer fake.unload();

        var state: State = .{};
        const hook = try sdk.hooks.createFn(AddFn, &add, addDetour, &state);
        try testing.expectEqual(5, add(2, 3)); // created disabled

        try hook.enable();
        try testing.expectEqual(1005, add(2, 3));
        try testing.expectEqual(1, state.calls);

        try hook.disable();
        try testing.expectEqual(5, add(2, 3));
        try testing.expectEqual(1, state.calls);

        hook.destroy();
        hook.destroy(); // a stale handle is harmless
        try testing.expectError(error.HookFailed, hook.enable());
    }

    test "hook claims its bytes" {
        const Claims = @import("tuft_mem").Claims;
        Claims.enable(testing.allocator);
        defer Claims.disable();
        try hook_engine.init(testing.allocator);
        defer hook_engine.deinit();
        var fake: FakePlugin = undefined;
        fake.init();
        defer fake.unload();

        var state: State = .{};
        const hook = try sdk.hooks.createFn(AddFn, &add, addDetour, &state);
        const claim = Claims.local.first(@intFromPtr(&add), 1).?;
        try testing.expectEqual(Claims.Kind.hook, claim.kind);
        try testing.expectEqual(&fake.loaded.owner, claim.owner.?);
        try testing.expectEqualStrings("test", claim.ownerName());
        hook.destroy();
        try testing.expectEqual(null, Claims.local.first(@intFromPtr(&add), 1));
    }

    test "slot hook" {
        try hook_engine.init(testing.allocator);
        defer hook_engine.deinit();
        var fake: FakePlugin = undefined;
        fake.init();

        var methods: [2]usize = .{ @intFromPtr(&sub), @intFromPtr(&add) };
        const object: *const [2]usize = &methods;
        const Virtual = struct {
            fn call(slot: *volatile usize, a: i32, b: i32) i32 {
                const f: *const AddFn = @ptrFromInt(slot.*);
                return f(a, b);
            }
        };

        var state: State = .{};
        const hook = try sdk.Address.from(&object).vtableSlot(1).createSlot(AddFn, addDetour, &state);
        try hook.enable();
        try testing.expectEqual(1005, Virtual.call(&methods[1], 2, 3));
        try testing.expectEqual(5, add(2, 3)); // direct calls aren't hooked
        try testing.expectEqual(1, state.calls);

        fake.unload();
        try testing.expectEqual(@intFromPtr(&add), methods[1]);
        try testing.expectEqual(5, Virtual.call(&methods[1], 2, 3));
    }

    test "mid hook registers" {
        try hook_engine.init(testing.allocator);
        defer hook_engine.deinit();
        var fake: FakePlugin = undefined;
        fake.init();
        defer fake.unload();

        var seen: usize = 0;
        const hook = try sdk.Address.from(&increment).createMid(struct {
            fn cb(out: *usize, cpu: *sdk.CpuContext) void {
                out.* = arch.testing.firstArg(cpu);
                arch.testing.changeFirstArg(cpu);
            }
        }.cb, &seen);

        try hook.enable();
        try testing.expectEqual(arch.testing.changed_arg + 1, increment(5));
        try testing.expectEqual(5, seen);

        try hook.disable();
        try testing.expectEqual(6, increment(5));
    }

    test "mid hook through hooks.sal, changing registers" {
        try hook_engine.init(testing.allocator);
        defer hook_engine.deinit();
        var fake: FakePlugin = undefined;
        fake.init();
        const hooks = sdk.wraith.root().?.hooks();

        const H = struct {
            fn handle(out: *usize, regs: *cpu_regs.Cpu) void {
                // Copied for tuft's helpers, which want a context's alignment
                var ctx: Hook.CpuContext = undefined;
                @memcpy(std.mem.asBytes(&ctx), std.mem.asBytes(regs));
                out.* = arch.testing.firstArg(&ctx);
                arch.testing.changeFirstArg(&ctx);
                @memcpy(std.mem.asBytes(regs), std.mem.asBytes(&ctx));
            }
        };
        var seen: usize = 0;
        const h = try hooks.mid(@intFromPtr(&increment), .{}, MidHandler.init(&seen, H.handle));
        try testing.expectEqual(arch.testing.changed_arg + 1, increment(5));
        try testing.expectEqual(5, seen);
        try h.disable();
        try testing.expectEqual(6, increment(5));
        try h.enable();
        try testing.expectError(error.InvalidPattern, hooks.mid(@intFromPtr(&increment) + 1, .{ .expect = "zz" }, MidHandler.init(&seen, H.handle)));

        fake.unload();
        host.wraith.forget(&fake.loaded);
        try testing.expectEqual(6, increment(5));
        try testing.expectError(error.Gone, h.enable());
    }

    noinline fn addTwo(a: i32, b: i32) callconv(.c) i32 {
        var x = a;
        asm volatile (""
            : [x] "+r" (x),
        );
        return x + b;
    }

    const Typed10 = struct {
        var function: *const bind.Function = undefined;
        var original: usize = 0;
        var context: usize = 0;

        /// The original's answer times ten.
        fn dispatch(_: usize, _: u32, args: []const [*]u8, value: [*]u8) u32 {
            context = runningContext();
            var out: i32 = 0;
            _ = bind.callAt(function, original, @ptrCast(args), std.mem.asBytes(&out));
            const ten = out * 10;
            @memcpy(value[0..4], std.mem.asBytes(&ten));
            return 0;
        }
    };

    test "function hooks typed by a signature, calling on with a context" {
        try hook_engine.init(testing.allocator);
        defer hook_engine.deinit();
        var fake: FakePlugin = undefined;
        fake.init();
        const hooks = sdk.wraith.root().?.hooks();

        const sig = "fn i32 (i32 a, i32 b)";
        const ty = try (try schemas.wraithOnly()).typedOf(sig);
        Typed10.function = ty.function;
        const handler = try bind.implement(sal.host(), ty.trait, 0, Typed10.dispatch, null);
        const h = try hooks.detour(@intFromPtr(&addTwo), sig, handler, .{ .context = 77 });
        Typed10.original = h.original();
        try testing.expectEqual(50, addTwo(2, 3));
        try testing.expectEqual(77, Typed10.context);
        try testing.expectEqual(0, hooks.context());

        const other = try (try schemas.wraithOnly()).typedOf("fn i32 (i32 a)");
        const wrong = try bind.implement(sal.host(), other.trait, 0, Typed10.dispatch, null);
        try testing.expectError(error.WrongHandler, hooks.detour(@intFromPtr(&increment), sig, wrong, .{}));
        try testing.expectError(error.InvalidSignature, hooks.detour(@intFromPtr(&increment), "fn Nope (u32 a)", wrong, .{}));
        try testing.expect(std.mem.indexOf(u8, sal.host().explanation("InvalidSignature"), "Nope") != null);

        try h.disable();
        try testing.expectEqual(5, addTwo(2, 3));
        try h.enable();
        fake.unload();
        host.wraith.forget(&fake.loaded);
        try testing.expectEqual(5, addTwo(2, 3));
        try testing.expectError(error.Gone, h.enable());
    }

    /// What the named hook test's [Sig] finds, x times 3. It starts with bytes nothing else has, and the
    /// nops leave room for a hook.
    fn tripled() callconv(.naked) void {
        if (@sizeOf(usize) == 8) asm volatile (
            \\.intel_syntax noprefix
            \\mov eax, 0x7E57F00D
            \\lea eax, [rcx + rcx * 2]
            \\nop dword ptr [rax + rax * 1 + 0]
            \\nop dword ptr [rax + rax * 1 + 0]
            \\ret
            \\.att_syntax prefix
        ) else asm volatile (
            \\.intel_syntax noprefix
            \\mov eax, 0x7E57F00D
            \\mov ecx, [esp + 4]
            \\lea eax, [ecx + ecx * 2]
            \\nop dword ptr [eax + eax * 1 + 0]
            \\nop dword ptr [eax + eax * 1 + 0]
            \\ret
            \\.att_syntax prefix
        );
    }

    test "named hooks and game code from the plugin's schemas" {
        try hook_engine.init(testing.allocator);
        defer hook_engine.deinit();
        var fake: FakePlugin = undefined;
        fake.init();
        fake.loaded.schemas = try schemas.fromFiles(&.{.{ .name = "test/game.sal", .text =
            \\[Sig("B8 0D F0 57 7E")] i32 tripled(i32 x);
            \\struct Thing {
            \\    usize vt;
            \\    [Virtual(1)] i32 second(i32 x);
            \\    [Sig("B8 0D F0 57 7E")] static i32 alsoTripled(i32 x);
            \\}
            \\[Instance("B8 0D F0 57 7E")]
            \\struct Spot { u32 x; }
        }});
        fake.loaded.schemas.?.setHome("test");
        defer {
            fake.loaded.schemas.?.destroy();
            fake.loaded.schemas = null;
        }
        const root = sdk.wraith.root().?;
        const g = root.schema();
        const at = @intFromPtr(&tripled);
        try testing.expectEqual(at, try g.address("tripled"));
        try testing.expectEqual(at, try g.address("Thing.alsoTripled"));
        // A struct tagged as a global is found like a [Sig] static
        try testing.expectEqual(at, try g.address("Spot.instance"));
        // Through an object's own vtable
        const table = [_]usize{ 0, at };
        const thing = [_]usize{@intFromPtr(&table)};
        try testing.expectEqual(at, try g.method(@intFromPtr(&thing), "Thing.second"));
        try testing.expectError(error.Unknown, g.address("nope"));
        try testing.expectError(error.NeedsObject, g.address("Thing.second"));

        const hooks = root.hooks();
        const ty = try (try schemas.of(&fake.loaded)).typedOf("tripled");
        Typed10.function = ty.function;
        const handler = try bind.implement(sal.host(), ty.trait, 0, Typed10.dispatch, null);
        const h = try hooks.named("tripled", handler, .{});
        Typed10.original = h.original();
        const call: *const fn (i32) callconv(.c) i32 = @ptrCast(&tripled);
        try testing.expectEqual(60, call(2));
        const other = try bind.implement(sal.host(), ty.trait, 0, Typed10.dispatch, null);
        try testing.expectError(error.NotFound, hooks.named("nope", other, .{}));
        try testing.expect(std.mem.indexOf(u8, sal.host().explanation("NotFound"), "nope") != null);

        fake.unload();
        host.wraith.forget(&fake.loaded);
        try testing.expectEqual(6, call(2));
    }

    test "unload destroys leftover hooks" {
        try hook_engine.init(testing.allocator);
        defer hook_engine.deinit();
        var fake: FakePlugin = undefined;
        fake.init();

        var state: State = .{};
        const kept = try sdk.hooks.createFn(AddFn, &add, addDetour, &state);
        try kept.enable();
        const early = try sdk.hooks.createFn(AddFn, &sub, struct {
            fn detour(a: i32, b: i32) i32 {
                return a * b;
            }
        }.detour, {});
        try early.enable();
        early.destroy(); // so unload mustn't destroy it again

        try testing.expectEqual(1005, add(2, 3));
        fake.unload();
        try testing.expectEqual(5, add(2, 3));
        try testing.expectEqual(-1, sub(2, 3));
    }

    test "hooks stop before stop" {
        try hook_engine.init(testing.allocator);
        defer hook_engine.deinit();
        var fake: FakePlugin = undefined;
        fake.init();

        var state: State = .{};
        const hook = try sdk.hooks.createFn(AddFn, &add, addDetour, &state);
        try hook.enable();
        try testing.expectEqual(1005, add(2, 3));

        fake.loaded.owner.close();
        try testing.expectEqual(5, add(2, 3)); // unhooked before `stop` runs
        // `stop` can't hook anything new
        try testing.expectError(error.HooksUnavailable, hook.disable());
        hook.destroy();
        try testing.expectError(error.HooksUnavailable, sdk.hooks.createFn(AddFn, &sub, addDetour, &state));
        fake.unload();
    }

    test "no shared targets" {
        try hook_engine.init(testing.allocator);
        defer hook_engine.deinit();
        var first: FakePlugin = undefined;
        first.init();
        defer first.unload();
        var second: FakePlugin = undefined;
        second.init();
        defer second.unload();

        var state: State = .{};
        first.attach();
        _ = try sdk.hooks.createFn(AddFn, &add, addDetour, &state);
        second.attach();
        try testing.expectError(error.AlreadyHooked, sdk.hooks.createFn(AddFn, &add, addDetour, &state));
    }
};

test {
    _ = tests;
}
