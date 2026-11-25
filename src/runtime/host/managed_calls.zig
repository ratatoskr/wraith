//! Schemas' `[Managed]` methods, called like any other function a schema declares. Each is a native
//! function of its schema type, from salamander's `bind.function`, that converts what it's given, calls
//! the C# method on a thread that can, and converts what comes back. The same for Mono, IL2CPP and
//! CoreCLR, and for every language, since they all call it like native code.
//!
//! Strings it gives back are good till the thread's next call. Objects go both ways as their
//! addresses, which the garbage collector can move, so `hold` ones to keep. A method that throws, or
//! a call before the game's C# is running, says so in the log and gives zero.

const std = @import("std");

const api = @import("wraith_api");
const core = @import("wraith_core");
const salamander_schema = @import("salamander_schema");
const bind = @import("salamander_bind");
const srt = @import("salamander_runtime");
const sync = @import("tuft_sys").sync;
const Atomic = @import("tuft_arch").atomic.Value;

const ManagedRuntime = @import("../Managed.zig");
const values = @import("managed_values.zig");

const Schema = salamander_schema.Schema;
const Runtime = ManagedRuntime.Runtime;
const Method = ManagedRuntime.Method;
const Value = values.Value;
const W = api.wraith;
const sal = api.salamander;
const log = core.log.scoped(.wraith_runtime);
const gpa = std.heap.smp_allocator;

fn global() *ManagedRuntime {
    return &ManagedRuntime.global;
}

/// A parameter or the result, as far as converting goes.
const Kind = union(enum) {
    none,
    flag,
    int: struct { size: u8, signed: bool },
    float: u8,
    /// `string`, UTF-8 by pointer and length
    string,
    /// `cstring`, UTF-8 up to a zero
    cstring,
    /// `usize`, `isize` or a pointer: an object's address, or an `IntPtr`
    word,

    fn of(s: Schema, r: Schema.Ref) ?Kind {
        return switch (r) {
            .prim => |p| prim(p, s.pointer_size),
            .pointer => .word,
            .optional => |c| if (c.* == .pointer) .word else null,
            .named => |n| switch ((s.findType(n) orelse return null).kind) {
                .@"enum" => |e| prim(e.backing, s.pointer_size),
                else => null,
            },
            else => null,
        };
    }

    fn prim(p: Schema.Prim, pointer_size: u8) ?Kind {
        return switch (p) {
            .void => .none,
            .bool => .flag,
            .u8, .u16, .u32, .u64 => .{ .int = .{ .size = @intCast(p.size(pointer_size)), .signed = false } },
            .i8, .i16, .i32, .i64 => .{ .int = .{ .size = @intCast(p.size(pointer_size)), .signed = true } },
            .f32 => .{ .float = 4 },
            .f64 => .{ .float = 8 },
            .usize, .isize => .word,
            .string => .string,
            .cstring => .cstring,
            else => null,
        };
    }

    /// What `invoke` calls it, for picking an overload.
    fn valueKind(k: Kind) W.ManagedValueKind {
        return switch (k) {
            .none => .none,
            .flag => .flag,
            .int => .integer,
            .float => .number,
            .string, .cstring => .text,
            .word => .object,
        };
    }

    /// Whether a C# type of `kind` is exactly this, to choose between overloads that both fit.
    fn exactly(k: Kind, kind: values.Kind) bool {
        return switch (k) {
            .int => |i| switch (kind) {
                .i1 => i.size == 1 and i.signed,
                .u1 => i.size == 1 and !i.signed,
                .i2 => i.size == 2 and i.signed,
                .u2, .char => i.size == 2 and !i.signed,
                .i4 => i.size == 4 and i.signed,
                .u4 => i.size == 4 and !i.signed,
                .i8 => i.size == 8 and i.signed,
                .u8 => i.size == 8 and !i.signed,
                else => false,
            },
            .float => |n| (kind == .r4 and n == 4) or (kind == .r8 and n == 8),
            .flag => kind == .boolean,
            .string, .cstring => kind == .string,
            .word => kind != .valuetype and kind != .r4 and kind != .r8,
            .none => true,
        };
    }
};

/// One `[Managed]` method, kept for good, since its function is.
const Binding = struct {
    /// What the schema calls it, like `Versioning.scmVersion`, for the log
    name: []const u8,
    class: []const u8,
    member: []const u8,
    this: bool,
    params: []const Kind,
    ret: Kind,
    /// Found on first use, and again once the runtime says what was found could be gone
    method: Atomic(usize) = .init(0),
    seen: Atomic(u32) = .init(0),
    warned: Atomic(bool) = .init(false),

    fn warnOnce(b: *Binding, comptime message: []const u8, args: anytype) void {
        if (b.warned.swap(true, .acq_rel)) return;
        log.warn("{s}: " ++ message, .{b.name} ++ args);
    }
};

var lock: sync.Mutex = .{};
/// By class, member and signature, so plugins that declare the same one share it.
var made: std.StringHashMapUnmanaged(usize) = .empty;

pub const Error = error{ NotFound, OutOfMemory };

/// The native function for `name`, a `[Managed]` method `class` has as `member`, of type `function`.
/// If the game's C# is running, it has to have the method now. Else it's looked for on first call.
pub fn entry(name: []const u8, class: []const u8, member: []const u8, s: Schema, f: Schema.Function, function: *const bind.Function) Error!usize {
    const key = try std.fmt.allocPrint(gpa, "{s}:{s}#{x}", .{ class, member, function.hash });
    lock.lock();
    defer lock.unlock();
    if (made.get(key)) |at| {
        gpa.free(key);
        return at;
    }
    errdefer gpa.free(key);
    const sig = f.method.signature;
    const params = try gpa.alloc(Kind, sig.params.len);
    errdefer gpa.free(params);
    if (params.len > values.max_args) return sal.host().explain(error.NotFound, "{s} takes more than {d} things, which C# methods can't here", .{ name, values.max_args });
    for (sig.params, params) |p, *k| k.* = Kind.of(s, p.type) orelse return sal.host().explain(error.NotFound, "{s}'s {s} can't go to C#, which takes numbers, flags, enums, strings and addresses", .{ name, p.name });
    const ret = Kind.of(s, sig.ret) orelse return sal.host().explain(error.NotFound, "what {s} gives back can't come from C#, which gives numbers, flags, enums, strings and addresses", .{name});
    const b = try gpa.create(Binding);
    errdefer gpa.destroy(b);
    b.* = .{
        .name = try gpa.dupe(u8, name),
        .class = try gpa.dupe(u8, class),
        .member = try gpa.dupe(u8, member),
        .this = f.hasThis(),
        .params = params,
        .ret = ret,
    };
    if (global().call(resolve, .{b})) |found| {
        _ = found catch |err| return explainMissing(b, err);
    } else |_| {}
    const at = bind.function(function, @intFromPtr(b), dispatch) catch return sal.host().explain(error.NotFound, "{s} is one more C# method than Wraith can call from schemas", .{name});
    try made.put(gpa, key, at);
    return at;
}

fn explainMissing(b: *const Binding, err: PickError) Error {
    return switch (err) {
        error.Ambiguous => sal.host().explain(error.NotFound, "{s} could be more than one of {s}'s {s} overloads, so give it a name of its own with parameters only one takes", .{ b.name, b.class, b.member }),
        else => sal.host().explain(error.NotFound, "{s} is {s}:{s} in the game's C#, which doesn't have it with those parameters", .{ b.name, b.class, b.member }),
    };
}

const PickError = error{ NotFound, Ambiguous };

/// On a thread that can call in.
fn resolve(rt: *const Runtime, b: *Binding) PickError!*Method {
    const now = rt.changes();
    const have = b.method.load(.acquire);
    if (have != 0 and b.seen.load(.acquire) == now) return @ptrFromInt(have);
    const c = ManagedRuntime.findClass(rt, b.class) orelse return error.NotFound;
    const m = try pick(rt, c, b);
    b.method.store(@intFromPtr(m), .release);
    b.seen.store(now, .release);
    return m;
}

/// The most derived class's overload that fits, or the one that fits exactly if more than one does.
fn pick(rt: *const Runtime, class: *ManagedRuntime.Class, b: *const Binding) PickError!*Method {
    var kinds: [values.max_args]W.ManagedValueKind = undefined;
    for (b.params, kinds[0..b.params.len]) |k, *v| v.* = k.valueKind();
    var here: ?*ManagedRuntime.Class = class;
    while (here) |c| : (here = rt.classParent(c)) {
        var fits: ?*Method = null;
        var exact: ?*Method = null;
        var count: usize = 0;
        var exact_count: usize = 0;
        var it = rt.methods(c);
        while (it.next()) |m| {
            if (!std.mem.eql(u8, rt.methodName(m), b.member) or rt.paramCount(m) != b.params.len) continue;
            if (rt.isStaticMethod(m) == b.this) continue;
            if (!values.fitsAll(rt, m, kinds[0..b.params.len])) continue;
            fits = m;
            count += 1;
            if (fitsExactly(rt, m, b.params)) {
                exact = m;
                exact_count += 1;
            }
        }
        if (count == 1) return fits.?;
        if (count > 1) return if (exact_count == 1) exact.? else error.Ambiguous;
    }
    return error.NotFound;
}

fn fitsExactly(rt: *const Runtime, m: *Method, params: []const Kind) bool {
    for (params, 0..) |k, i| {
        const t = rt.paramType(m, @intCast(i)) orelse return false;
        if (!k.exactly(rt.typeKind(t))) return false;
    }
    return true;
}

const CallError = PickError || values.E;

fn callOn(rt: *const Runtime, b: *Binding, a: std.mem.Allocator, target: usize, args: []const Value) CallError!values.Outcome {
    return values.call(rt, a, try resolve(rt, b), target, args);
}

threadlocal var depth: u32 = 0;
threadlocal var results: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

fn dispatch(ctx: usize, _: u32, args: []const [*]u8, value: [*]u8) u32 {
    const b: *Binding = @ptrFromInt(ctx);
    // A call from C# that this one made can come back in, and mustn't free what the first is using
    if (depth == 0) _ = results.reset(.{ .retain_with_limit = 64 << 10 });
    depth += 1;
    defer depth -= 1;
    const a = results.allocator();
    var target: usize = 0;
    var first: usize = 0;
    if (b.this) {
        target = readWord(args[0]);
        first = 1;
    }
    var in: [values.max_args]Value = undefined;
    for (b.params, args[first..][0..b.params.len], in[0..b.params.len]) |k, at, *v| v.* = toValue(k, at);
    const outcome = (global().call(callOn, .{ b, a, target, in[0..b.params.len] }) catch {
        b.warnOnce("the game's C# isn't running yet", .{});
        return 0;
    }) catch |err| {
        switch (err) {
            error.NotFound, error.Ambiguous => b.warnOnce("{s}:{s} isn't in the game's C# with those parameters ({t})", .{ b.class, b.member, err }),
            else => log.warn("{s}: calling {s}:{s} failed ({t})", .{ b.name, b.class, b.member, err }),
        }
        return 0;
    };
    switch (outcome) {
        .value => |v| put(b.ret, v, value, a),
        .threw => |why| log.warn("{s}: {s}:{s} threw {s}", .{ b.name, b.class, b.member, why }),
    }
    return 0;
}

fn readWord(at: [*]const u8) usize {
    return std.mem.bytesToValue(usize, at[0..@sizeOf(usize)]);
}

fn toValue(k: Kind, at: [*]const u8) Value {
    return switch (k) {
        .none => .{ .kind = .none },
        .flag => .{ .kind = .flag, .flag = at[0] != 0 },
        .int => |i| blk: {
            var bits: u64 = 0;
            @memcpy(std.mem.asBytes(&bits)[0..i.size], at[0..i.size]);
            if (i.signed and i.size < 8) {
                const shift: u6 = @intCast(64 - @as(u32, i.size) * 8);
                bits = @bitCast(@as(i64, @bitCast(bits << shift)) >> shift);
            }
            break :blk .{ .kind = .integer, .integer = @bitCast(bits) };
        },
        .float => |n| .{ .kind = .number, .number = if (n == 4) std.mem.bytesToValue(f32, at[0..4]) else std.mem.bytesToValue(f64, at[0..8]) },
        .string => .{ .kind = .text, .text = std.mem.bytesToValue(srt.String, at[0..@sizeOf(srt.String)]).get() },
        .cstring => blk: {
            const p = std.mem.bytesToValue(?[*:0]const u8, at[0..@sizeOf(usize)]) orelse break :blk .{ .kind = .none };
            break :blk .{ .kind = .text, .text = std.mem.span(p) };
        },
        .word => .{ .kind = .object, .object = readWord(at) },
    };
}

fn put(k: Kind, v: Value, out: [*]u8, a: std.mem.Allocator) void {
    const whole: i64 = switch (v.kind) {
        .integer => v.integer,
        .flag => @intFromBool(v.flag),
        .number => @intFromFloat(std.math.clamp(v.number, -9.2e18, 9.2e18)),
        .object => @bitCast(@as(u64, v.object)),
        else => 0,
    };
    switch (k) {
        .none => {},
        .flag => out[0] = @intFromBool(whole != 0),
        .int => |i| @memcpy(out[0..i.size], std.mem.asBytes(&whole)[0..i.size]),
        .float => |n| {
            const real: f64 = if (v.kind == .number) v.number else @floatFromInt(whole);
            if (n == 4) @memcpy(out[0..4], std.mem.asBytes(&@as(f32, @floatCast(real)))) else @memcpy(out[0..8], std.mem.asBytes(&real));
        },
        .string => {
            const s: srt.String = if (v.kind == .text) .init(v.text) else .{};
            @memcpy(out[0..@sizeOf(srt.String)], std.mem.asBytes(&s));
        },
        .cstring => {
            const p: ?[*:0]const u8 = if (v.kind == .text) (a.dupeSentinel(u8, v.text, 0) catch null) else null;
            @memcpy(out[0..@sizeOf(usize)], std.mem.asBytes(&p));
        },
        .word => @memcpy(out[0..@sizeOf(usize)], std.mem.asBytes(&@as(usize, @truncate(@as(u64, @bitCast(whole)))))),
    }
}
