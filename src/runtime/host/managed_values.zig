//! Values going into and coming out of the game's C#, the same for Mono, IL2CPP and CoreCLR. The
//! `managed` area's `invoke` and fields use these, and so do schemas' `[Managed]` functions. Only on
//! a thread that can call in, like through `Managed.call`.

const std = @import("std");

const api = @import("wraith_api");

const ManagedRuntime = @import("../Managed.zig");

const W = api.wraith;
const Runtime = ManagedRuntime.Runtime;
const Class = ManagedRuntime.Class;
const Object = ManagedRuntime.Object;
const Method = ManagedRuntime.Method;
const Type = ManagedRuntime.Type;
const Allocator = std.mem.Allocator;

pub const Kind = ManagedRuntime.ElementType;
pub const Value = W.ManagedValue;
pub const E = W.ManagedError;

/// Most arguments a call takes.
pub const max_args = 16;

/// The overload of `name` with as many parameters as `kinds`, where each fits, else the first with
/// that many. Looks in parents too.
pub fn pickMethod(rt: *const Runtime, class: *Class, name: []const u8, kinds: []const W.ManagedValueKind) ?*Method {
    var first: ?*Method = null;
    var here: ?*Class = class;
    while (here) |c| : (here = rt.classParent(c)) {
        var it = rt.methods(c);
        while (it.next()) |m| {
            if (!std.mem.eql(u8, rt.methodName(m), name) or rt.paramCount(m) != kinds.len) continue;
            if (first == null) first = m;
            if (fitsAll(rt, m, kinds)) return m;
        }
    }
    return first;
}

pub fn fitsAll(rt: *const Runtime, m: *Method, kinds: []const W.ManagedValueKind) bool {
    for (kinds, 0..) |kind, i| {
        const t = rt.paramType(m, @intCast(i)) orelse return false;
        if (!fitsType(rt, t, kind)) return false;
    }
    return true;
}

pub fn fitsType(rt: *const Runtime, t: *Type, kind: W.ManagedValueKind) bool {
    return switch (rt.typeKind(t)) {
        .boolean => kind == .flag or kind == .integer,
        .char, .i1, .u1, .i2, .u2, .i4, .u4, .i8, .u8 => kind == .integer,
        // IntPtr, which an address is too
        .i, .u => kind == .integer or kind == .object,
        .r4, .r8 => kind == .number or kind == .integer,
        .string => kind == .text or kind == .none,
        .valuetype => if (rt.typeClass(t)) |c| (if (rt.isEnum(c)) kind == .integer else kind == .object) else false,
        .byref, .ptr => kind == .object,
        else => kind == .object or kind == .none,
    };
}

/// What `invoke` takes for one argument: a pointer to its value for value types, the object itself
/// for the rest.
pub fn argument(rt: *const Runtime, a: Allocator, t: *Type, arg: Value, slot: *u64) E!?*anyopaque {
    const whole: i64 = switch (arg.kind) {
        .integer => arg.integer,
        .flag => @intFromBool(arg.flag),
        .number => @intFromFloat(std.math.clamp(arg.number, -9.2e18, 9.2e18)),
        .object => @bitCast(@as(u64, arg.object)),
        else => 0,
    };
    const real: f64 = switch (arg.kind) {
        .number => arg.number,
        .integer => @floatFromInt(arg.integer),
        else => 0,
    };
    // Little-endian, so a narrower value's in the slot's first bytes
    slot.* = 0;
    switch (rt.typeKind(t)) {
        .boolean => slot.* = @intFromBool(whole != 0),
        .char, .i1, .u1, .i2, .u2, .i4, .u4, .i8, .u8, .i, .u => slot.* = @bitCast(whole),
        .r4 => slot.* = @as(u32, @bitCast(@as(f32, @floatCast(real)))),
        .r8 => slot.* = @bitCast(real),
        .string => {
            if (arg.kind != .text) return if (arg.object == 0) null else @ptrFromInt(arg.object);
            const text = a.dupeSentinel(u8, arg.text, 0) catch return error.Failed;
            return @ptrCast(rt.newString(text) orelse return error.Failed);
        },
        .valuetype => {
            const c = rt.typeClass(t) orelse return error.Failed;
            if (!rt.isEnum(c)) return if (arg.object == 0) error.Failed else @ptrFromInt(arg.object);
            slot.* = @bitCast(whole);
        },
        else => return if (arg.object == 0) null else @ptrFromInt(arg.object),
    }
    return @ptrCast(slot);
}

pub fn fromResult(rt: *const Runtime, a: Allocator, t: ?*Type, result: ?*Object) E!Value {
    const ret = t orelse return .{ .kind = .none };
    var kind = rt.typeKind(ret);
    if (kind == .void) return .{ .kind = .none };
    const o = result orelse return .{ .kind = .none };
    if (kind == .valuetype) {
        const c = rt.typeClass(ret) orelse return error.Failed;
        if (!rt.isEnum(c)) return .{ .kind = .object, .object = @intFromPtr(o) };
        kind = rt.typeKind(rt.enumBase(c) orelse return error.Failed);
    }
    const at: [*]const u8 = switch (kind) {
        .boolean, .char, .i1, .u1, .i2, .u2, .i4, .u4, .i8, .u8, .i, .u, .r4, .r8 => @ptrCast(rt.unbox(o) orelse return error.Failed),
        .string => return .{ .kind = .text, .text = rt.readString(a, @ptrCast(o)) catch return error.Failed },
        else => return .{ .kind = .object, .object = @intFromPtr(o) },
    };
    return primitive(kind, at).?;
}

/// A number or flag of `kind` from its bytes at `at`, or null for other kinds.
pub fn primitive(kind: Kind, at: [*]const u8) ?Value {
    return switch (kind) {
        .boolean => .{ .kind = .flag, .flag = at[0] != 0 },
        .i1 => .{ .kind = .integer, .integer = std.mem.bytesToValue(i8, at[0..1]) },
        .u1 => .{ .kind = .integer, .integer = at[0] },
        .i2 => .{ .kind = .integer, .integer = std.mem.bytesToValue(i16, at[0..2]) },
        .u2, .char => .{ .kind = .integer, .integer = std.mem.bytesToValue(u16, at[0..2]) },
        .i4 => .{ .kind = .integer, .integer = std.mem.bytesToValue(i32, at[0..4]) },
        .u4 => .{ .kind = .integer, .integer = std.mem.bytesToValue(u32, at[0..4]) },
        .i8, .u8 => .{ .kind = .integer, .integer = std.mem.bytesToValue(i64, at[0..8]) },
        .i, .u => .{ .kind = .integer, .integer = std.mem.bytesToValue(isize, at[0..@sizeOf(isize)]) },
        .r4 => .{ .kind = .number, .number = std.mem.bytesToValue(f32, at[0..4]) },
        .r8 => .{ .kind = .number, .number = std.mem.bytesToValue(f64, at[0..8]) },
        else => null,
    };
}

/// `Type: Message`, from the exception's own `Message`.
pub fn describe(rt: *const Runtime, a: Allocator, e: *Object) []const u8 {
    const c = rt.objectClass(e) orelse return "it threw";
    const name = ManagedRuntime.fullName(rt, a, c) catch return "it threw";
    const get = ManagedRuntime.findMethod(rt, c, "get_Message", 0) orelse return name;
    var again: ?*Object = null;
    const message = rt.invoke(get, e, null, &again) orelse return name;
    if (again != null) return name;
    const text = rt.readString(a, @ptrCast(message)) catch return name;
    return std.fmt.allocPrint(a, "{s}: {s}", .{ name, text }) catch name;
}

/// Calls `m` with `args` converted for its parameters. `target` is the object, or 0 for statics.
pub fn call(rt: *const Runtime, a: Allocator, m: *Method, target: usize, args: []const Value) E!Outcome {
    if (args.len > max_args) return error.Failed;
    var slots: [max_args]u64 = undefined;
    var pointers: [max_args]?*anyopaque = undefined;
    for (args, 0..) |arg, i| pointers[i] = try argument(rt, a, rt.paramType(m, @intCast(i)) orelse return error.Failed, arg, &slots[i]);
    var exception: ?*Object = null;
    const result = rt.invoke(m, if (target == 0) null else @ptrFromInt(target), &pointers, &exception);
    if (exception) |e| return .{ .threw = describe(rt, a, e) };
    return .{ .value = try fromResult(rt, a, rt.returnType(m), result) };
}

/// What a call got, worked out where it ran, so what's wrong is said on the caller's thread.
pub const Outcome = union(enum) {
    value: Value,
    /// Like `System.FormatException: Input string was not in a correct format.`
    threw: []const u8,
};
