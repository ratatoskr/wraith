//! The `managed` area: the game's Mono or IL2CPP, through `Managed`'s attached thread. Each call
//! does its work there and builds what it gives back in the caller's scratch, which is safe since
//! the caller waits.

const std = @import("std");

const api = @import("wraith_api");
const mem = @import("tuft_mem");

const ManagedRuntime = @import("../Managed.zig");
const Owner = @import("tuft_event").Owner;
const RwLock = @import("tuft_sys").sync.RwLock;
const OnGone = @import("Owned.zig").OnGone;
const scratch = @import("scratch.zig");
const wraith = @import("wraith.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;

const sal = api.salamander;
const W = api.wraith;
const Runtime = ManagedRuntime.Runtime;
const Class = ManagedRuntime.Class;
const Image = ManagedRuntime.Image;
const Object = ManagedRuntime.Object;
const E = W.ManagedError;
const Allocator = std.mem.Allocator;

pub const Managed = W.Managed;

fn global() *ManagedRuntime {
    return &ManagedRuntime.global;
}

/// Handles from `hold`, and whose they are, so they're released when their plugin goes.
var held_lock: RwLock = .{};
var held: std.AutoHashMapUnmanaged(u32, *Owner) = .empty;
var held_cleanup: OnGone(.closing, heldGone) = .{};

fn heldGone(owner: *Owner) void {
    held_lock.lock();
    defer held_lock.unlock();
    const g = global();
    var it = held.iterator();
    while (it.next()) |kv| if (kv.value_ptr.* == owner) {
        if (g.running()) g.rt.freeHandle(kv.key_ptr.*);
        held.removeByPtr(kv.key_ptr);
    };
}

/// Runs `func` on the attached thread, which fails the same way as it not running.
fn run(comptime func: anytype, args: anytype) @typeInfo(@TypeOf(func)).@"fn".return_type.? {
    return global().call(func, args) catch error.NotRunning;
}

pub const Impl = struct {
    pub fn kind(_: *Loaded) W.ManagedKind {
        const k = global().kind() orelse return .none;
        return switch (k) {
            .mono => .mono,
            .il2cpp => .il2cpp,
            .coreclr => .coreclr,
        };
    }

    pub fn running(loaded: *Loaded) RunningPromise {
        const pair = RunningPromise.make() catch return .{};
        if (global().running()) {
            pair.resolver.settle({});
            return pair.promise;
        }
        const t = wraith.tablesOf(loaded) orelse {
            pair.resolver.drop();
            return pair.promise;
        };
        const job = std.heap.page_allocator.create(RunningWait) catch {
            pair.resolver.fail(error.Failed);
            return pair.promise;
        };
        job.* = .{ .owner = t.owner, .resolver = pair.resolver };
        const thread = std.Thread.spawn(.{}, RunningWait.run, .{job}) catch {
            std.heap.page_allocator.destroy(job);
            pair.resolver.fail(error.Failed);
            return pair.promise;
        };
        thread.detach();
        return pair.promise;
    }

    pub fn images(_: *Loaded) sal.Plain(Managed, "images") {
        return run(listImages, .{scratch.begin()});
    }

    pub fn classes(_: *Loaded, image: []const u8) sal.Plain(Managed, "classes") {
        return run(listClasses, .{ scratch.begin(), image });
    }

    pub fn find(_: *Loaded, class_name: []const u8) sal.Plain(Managed, "find") {
        return run(classInfo, .{ scratch.begin(), class_name });
    }

    pub fn fields(_: *Loaded, class_name: []const u8) sal.Plain(Managed, "fields") {
        return run(listFields, .{ scratch.begin(), class_name });
    }

    pub fn methods(_: *Loaded, class_name: []const u8) sal.Plain(Managed, "methods") {
        return run(listMethods, .{ scratch.begin(), class_name });
    }

    pub fn fieldOffset(_: *Loaded, class_name: []const u8, field: []const u8) sal.Plain(Managed, "fieldOffset") {
        return run(offsetOf, .{ class_name, field });
    }

    pub fn staticAddress(_: *Loaded, class_name: []const u8, field: []const u8) sal.Plain(Managed, "staticAddress") {
        return run(staticOf, .{ class_name, field });
    }

    pub fn method(_: *Loaded, class_name: []const u8, name: []const u8, params: i32) sal.Plain(Managed, "method") {
        return run(codeOf, .{ class_name, name, params });
    }

    pub fn icall(_: *Loaded, class_name: []const u8, method_name: []const u8) sal.Plain(Managed, "icall") {
        return run(icallOf, .{ class_name, method_name });
    }

    pub fn typeObject(_: *Loaded, class_name: []const u8) sal.Plain(Managed, "typeObject") {
        return run(typeObjectOf, .{class_name});
    }

    pub fn callNative(_: *Loaded, function: usize) sal.Plain(Managed, "callNative") {
        if (function == 0) return error.NotFound;
        return run(callOn, .{function});
    }

    pub fn invoke(_: *Loaded, class_name: []const u8, method_name: []const u8, target: usize, args: []const W.ManagedValue) sal.Plain(Managed, "invoke") {
        const g = global();
        if (!g.running()) return error.NotRunning;
        const a = scratch.begin();
        // Unity's own methods only work on its main thread, which the runtime knows
        const outcome = if (g.rt.attachedHere())
            invokeOn(&g.rt, a, class_name, method_name, target, args)
        else
            run(invokeOn, .{ a, class_name, method_name, target, args });
        return switch (try outcome) {
            .value => |v| v,
            .threw => |why| sal.host().explain(error.Threw, "{s}", .{why}),
        };
    }

    pub fn hold(loaded: *Loaded, object: usize) sal.Plain(Managed, "hold") {
        if (object == 0) return error.NotFound;
        const g = global();
        if (!g.running()) return error.NotRunning;
        const lease = held_cleanup.lease(&loaded.owner) orelse return error.Failed;
        defer lease.end();
        const handle = g.rt.newHandle(@ptrFromInt(object), false);
        if (handle == 0) return error.Failed;
        held_lock.lock();
        defer held_lock.unlock();
        held.put(std.heap.smp_allocator, handle, &loaded.owner) catch {
            g.rt.freeHandle(handle);
            return error.Failed;
        };
        return handle;
    }

    pub fn release(loaded: *Loaded, handle: u32) void {
        held_lock.lock();
        defer held_lock.unlock();
        const owner = held.get(handle) orelse return;
        // Only its own
        if (owner != &loaded.owner) return;
        _ = held.remove(handle);
        global().rt.freeHandle(handle);
    }

    pub fn heldAt(loaded: *Loaded, handle: u32) sal.Plain(Managed, "heldAt") {
        const g = global();
        if (!g.running()) return error.NotRunning;
        held_lock.lock();
        defer held_lock.unlock();
        // Only its own
        const owner = held.get(handle) orelse return error.NotFound;
        if (owner != &loaded.owner) return error.NotFound;
        return @intFromPtr(g.rt.handleTarget(handle) orelse return error.NotFound);
    }

    pub fn classOf(_: *Loaded, object: usize) sal.Plain(Managed, "classOf") {
        return run(classNameOf, .{ scratch.begin(), object });
    }

    pub fn readString(_: *Loaded, address: usize) sal.Plain(Managed, "readString") {
        return run(stringAt, .{ scratch.begin(), address });
    }

    pub fn getField(_: *Loaded, object: usize, field: []const u8) sal.Plain(Managed, "getField") {
        const g = global();
        if (!g.running()) return error.NotRunning;
        const a = scratch.begin();
        return if (g.rt.attachedHere()) fieldOf(&g.rt, a, object, field) else run(fieldOf, .{ a, object, field });
    }

    pub fn setField(_: *Loaded, object: usize, field: []const u8, value: W.ManagedValue) sal.Plain(Managed, "setField") {
        const g = global();
        if (!g.running()) return error.NotRunning;
        const a = scratch.begin();
        // A Unity object's own fields want its main thread, which the runtime knows
        return if (g.rt.attachedHere()) setFieldOn(&g.rt, a, object, field, value) else run(setFieldOn, .{ a, object, field, value });
    }
};

// On the attached thread from here down

const RunningPromise = sal.Plain(Managed, "running");

/// Waits off the caller's thread till the runtime's running. Gives up once the plugin's gone, or if
/// the runtime can't be used, or Wraith stopped watching.
const RunningWait = struct {
    owner: *sal.Owner,
    resolver: wraith.ResolverOf(RunningPromise),

    fn run(job: *RunningWait) void {
        defer std.heap.page_allocator.destroy(job);
        while (true) {
            if (!job.owner.enter()) return job.resolver.drop();
            const state = global().state.load(.acquire);
            switch (state) {
                .running => {
                    defer job.owner.leave();
                    return job.resolver.settle({});
                },
                .failed, .off => {
                    defer job.owner.leave();
                    return job.resolver.fail(error.NotRunning);
                },
                .waiting => job.owner.leave(),
            }
            @import("tuft_sys").thread.sleepMs(50);
        }
    }
};

const gpa = std.heap.smp_allocator;

fn listImages(rt: *const Runtime, a: Allocator) E![]const []const u8 {
    const list = rt.assemblies(gpa) catch return error.Failed;
    defer gpa.free(list);
    var out: std.ArrayList([]const u8) = .empty;
    for (list) |asm_entry| {
        const image = rt.assemblyImage(asm_entry) orelse continue;
        out.append(a, a.dupe(u8, rt.imageName(image)) catch return error.Failed) catch return error.Failed;
    }
    return out.items;
}

fn imageCalled(rt: *const Runtime, name: []const u8) ?*Image {
    return rt.findImage(gpa, name) catch null;
}

fn listClasses(rt: *const Runtime, a: Allocator, image_name: []const u8) E![]const []const u8 {
    const image = imageCalled(rt, image_name) orelse return error.NotFound;
    const n = rt.classCount(image);
    const out = a.alloc([]const u8, n) catch return error.Failed;
    var count: usize = 0;
    for (0..n) |i| {
        const c = rt.classAt(image, i) orelse continue;
        out[count] = ManagedRuntime.fullName(rt, a, c) catch return error.Failed;
        count += 1;
    }
    return out[0..count];
}

fn classCalled(rt: *const Runtime, name: []const u8) E!*Class {
    return ManagedRuntime.findClass(rt, name) orelse error.NotFound;
}

fn classInfo(rt: *const Runtime, a: Allocator, name: []const u8) E!W.ManagedClass {
    const c = try classCalled(rt, name);
    return .{
        .full_name = ManagedRuntime.fullName(rt, a, c) catch return error.Failed,
        .name = rt.className(c),
        .image = if (rt.classImage(c)) |i| rt.imageName(i) else "",
        .parent = if (rt.classParent(c)) |p| ManagedRuntime.fullName(rt, a, p) catch return error.Failed else "",
        .size = @intCast(@max(0, rt.instanceSize(c))),
        .value_type = rt.isValueType(c),
    };
}

fn typeName(rt: *const Runtime, a: Allocator, t: ?*ManagedRuntime.Type) E![]const u8 {
    return rt.typeName(a, t orelse return "") catch error.Failed;
}

fn listFields(rt: *const Runtime, a: Allocator, name: []const u8) E![]const W.ManagedField {
    const c = try classCalled(rt, name);
    var out: std.ArrayList(W.ManagedField) = .empty;
    var it = rt.fields(c);
    while (it.next()) |f| {
        out.append(a, .{
            .name = rt.fieldName(f),
            .type = try typeName(rt, a, rt.fieldType(f)),
            .offset = rt.fieldOffset(f),
            .is_static = rt.isStatic(f),
            .literal = rt.isLiteral(f),
        }) catch return error.Failed;
    }
    return out.items;
}

fn listMethods(rt: *const Runtime, a: Allocator, name: []const u8) E![]const W.ManagedMethod {
    const c = try classCalled(rt, name);
    var out: std.ArrayList(W.ManagedMethod) = .empty;
    var it = rt.methods(c);
    while (it.next()) |m| {
        const params = a.alloc([]const u8, rt.paramCount(m)) catch return error.Failed;
        for (params, 0..) |*p, i| p.* = try typeName(rt, a, rt.paramType(m, @intCast(i)));
        out.append(a, .{
            .name = rt.methodName(m),
            .return_type = try typeName(rt, a, rt.returnType(m)),
            .params = params,
            .is_static = rt.isStaticMethod(m),
        }) catch return error.Failed;
    }
    return out.items;
}

fn offsetOf(rt: *const Runtime, class_name: []const u8, field: []const u8) E!usize {
    const f = ManagedRuntime.findField(rt, try classCalled(rt, class_name), field) orelse return error.NotFound;
    return rt.fieldOffset(f);
}

fn staticOf(rt: *const Runtime, class_name: []const u8, field: []const u8) sal.Plain(Managed, "staticAddress") {
    const f = ManagedRuntime.findField(rt, try classCalled(rt, class_name), field) orelse return error.NotFound;
    return rt.staticAddress(f) catch |err| switch (err) {
        error.NotStatic => error.NotFound,
        error.ThreadStatic, error.Unsupported => error.Unsupported,
    };
}

fn codeOf(rt: *const Runtime, class_name: []const u8, name: []const u8, params: i32) E!usize {
    const c = try classCalled(rt, class_name);
    const m = ManagedRuntime.findMethod(rt, c, name, if (params < 0) null else @intCast(params)) orelse return error.NotFound;
    return rt.methodPointer(m) orelse error.NotFound;
}

fn icallOf(rt: *const Runtime, class_name: []const u8, method_name: []const u8) E!usize {
    return (rt.icall(gpa, class_name, method_name) catch return error.Failed) orelse error.NotFound;
}

/// What a schema's `[Managed]` or `[Icall]` member is in the game's C#.
pub const Member = union(enum) {
    /// The one with this many parameters, else the first by its name
    method: ?u32,
    static,
    icall,
};

/// Where a schema's `[Managed]` or `[Icall]` member is, through the attached thread.
pub fn memberAddress(class_name: []const u8, name: []const u8, member: Member) sal.Plain(Managed, "staticAddress") {
    return switch (member) {
        .method => |params| {
            if (params) |n| if (run(codeOf, .{ class_name, name, @as(i32, @intCast(n)) })) |at| return at else |err| switch (err) {
                error.NotFound => {},
                else => return err,
            };
            return run(codeOf, .{ class_name, name, -1 });
        },
        .static => run(staticOf, .{ class_name, name }),
        .icall => run(icallOf, .{ class_name, name }),
    };
}

fn typeObjectOf(rt: *const Runtime, class_name: []const u8) E!usize {
    const c = try classCalled(rt, class_name);
    const object = rt.typeObject(rt.classType(c) orelse return error.NotFound) orelse return error.NotFound;
    return @intFromPtr(object);
}

fn callOn(_: *const Runtime, function: usize) E!usize {
    const f: *const fn () callconv(.c) usize = @ptrFromInt(function);
    return f();
}

const Kind = ManagedRuntime.ElementType;
const Value = W.ManagedValue;

/// What `invoke` got, worked out where it ran, so the error's message is said on the caller's thread.
const Outcome = union(enum) {
    value: Value,
    /// Like `System.FormatException: Input string was not in a correct format.`
    threw: []const u8,
};

/// Most arguments a call takes.
const max_args = 16;

fn invokeOn(rt: *const Runtime, a: Allocator, class_name: []const u8, method_name: []const u8, target: usize, args: []const Value) E!Outcome {
    if (args.len > max_args) return error.Failed;
    const c = try classCalled(rt, class_name);
    const m = pickMethod(rt, c, method_name, args) orelse return error.NotFound;
    var slots: [max_args]u64 = undefined;
    var pointers: [max_args]?*anyopaque = undefined;
    for (args, 0..) |arg, i| pointers[i] = try argument(rt, a, rt.paramType(m, @intCast(i)) orelse return error.Failed, arg, &slots[i]);
    var exception: ?*Object = null;
    const result = rt.invoke(m, if (target == 0) null else @ptrFromInt(target), &pointers, &exception);
    if (exception) |e| return .{ .threw = describe(rt, a, e) };
    return .{ .value = try fromResult(rt, a, rt.returnType(m), result) };
}

/// The overload of `name` with as many parameters as `args`, where each fits, else the first with
/// that many. Looks in parents too.
fn pickMethod(rt: *const Runtime, class: *Class, name: []const u8, args: []const Value) ?*ManagedRuntime.Method {
    var first: ?*ManagedRuntime.Method = null;
    var here: ?*Class = class;
    while (here) |c| : (here = rt.classParent(c)) {
        var it = rt.methods(c);
        while (it.next()) |m| {
            if (!std.mem.eql(u8, rt.methodName(m), name) or rt.paramCount(m) != args.len) continue;
            if (first == null) first = m;
            const fits = for (args, 0..) |arg, i| {
                const t = rt.paramType(m, @intCast(i)) orelse break false;
                if (!fitsType(rt, t, arg.kind)) break false;
            } else true;
            if (fits) return m;
        }
    }
    return first;
}

fn fitsType(rt: *const Runtime, t: *ManagedRuntime.Type, kind: W.ManagedValueKind) bool {
    return switch (rt.typeKind(t)) {
        .boolean => kind == .flag or kind == .integer,
        .char, .i1, .u1, .i2, .u2, .i4, .u4, .i8, .u8, .i, .u => kind == .integer,
        .r4, .r8 => kind == .number or kind == .integer,
        .string => kind == .text or kind == .none,
        .valuetype => if (rt.typeClass(t)) |c| (if (rt.isEnum(c)) kind == .integer else kind == .object) else false,
        .byref, .ptr => kind == .object,
        else => kind == .object or kind == .none,
    };
}

/// What `invoke` takes for one argument: a pointer to its value for value types, the object itself
/// for the rest.
fn argument(rt: *const Runtime, a: Allocator, t: *ManagedRuntime.Type, arg: Value, slot: *u64) E!?*anyopaque {
    const whole: i64 = switch (arg.kind) {
        .integer => arg.integer,
        .flag => @intFromBool(arg.flag),
        .number => @intFromFloat(std.math.clamp(arg.number, -9.2e18, 9.2e18)),
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

fn fromResult(rt: *const Runtime, a: Allocator, t: ?*ManagedRuntime.Type, result: ?*Object) E!Value {
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
fn primitive(kind: Kind, at: [*]const u8) ?Value {
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
fn describe(rt: *const Runtime, a: Allocator, e: *Object) []const u8 {
    const c = rt.objectClass(e) orelse return "it threw";
    const name = ManagedRuntime.fullName(rt, a, c) catch return "it threw";
    const get = ManagedRuntime.findMethod(rt, c, "get_Message", 0) orelse return name;
    var again: ?*Object = null;
    const message = rt.invoke(get, e, null, &again) orelse return name;
    if (again != null) return name;
    const text = rt.readString(a, @ptrCast(message)) catch return name;
    return std.fmt.allocPrint(a, "{s}: {s}", .{ name, text }) catch name;
}

/// What the runtime's class struct reads at most, comfortably, before we trust it.
const class_bytes = 0x200;

/// The class of the object at `address`, if it really is one. The runtime would crash on garbage,
/// so the header and class have to be readable and the class has to be in a loaded image.
fn objectClass(rt: *const Runtime, address: usize) E!*Class {
    const word = @sizeOf(usize);
    if (address == 0 or !mem.isReadable(address, 2 * word)) return error.Unreadable;
    const header = mem.Memory.local.load(usize, address) catch return error.Unreadable;
    // IL2CPP's and CoreCLR's header is the class. Mono's is a vtable, whose first word is the class
    const class_at = switch (rt.*) {
        .il2cpp, .coreclr => header,
        .mono => if (header != 0 and mem.isReadable(header, word)) mem.Memory.local.load(usize, header) catch return error.Unreadable else return error.Unreadable,
    };
    if (class_at == 0 or !mem.isReadable(class_at, class_bytes)) return error.Unreadable;
    const image = rt.classImage(@ptrFromInt(class_at)) orelse return error.Unreadable;
    const list = rt.assemblies(gpa) catch return error.Failed;
    defer gpa.free(list);
    for (list) |asm_entry| {
        if (rt.assemblyImage(asm_entry) == image) return rt.objectClass(@ptrFromInt(address)) orelse error.Unreadable;
    }
    return error.Unreadable;
}

fn classNameOf(rt: *const Runtime, a: Allocator, object: usize) E![]const u8 {
    return ManagedRuntime.fullName(rt, a, try objectClass(rt, object)) catch error.Failed;
}

/// An instance field by name, looking in parents too.
fn instanceField(rt: *const Runtime, object: usize, name: []const u8) E!*ManagedRuntime.Field {
    const f = ManagedRuntime.findField(rt, try objectClass(rt, object), name) orelse return error.NotFound;
    if (rt.isStatic(f) or rt.isLiteral(f)) return error.NotFound;
    return f;
}

fn fieldOf(rt: *const Runtime, a: Allocator, object: usize, name: []const u8) E!Value {
    const f = try instanceField(rt, object, name);
    const t = rt.fieldType(f) orelse return error.Failed;
    var kind = rt.typeKind(t);
    if (kind == .valuetype) {
        const c = rt.typeClass(t) orelse return error.Failed;
        if (!rt.isEnum(c)) return .{ .kind = .object, .object = object + rt.fieldOffset(f) };
        kind = rt.typeKind(rt.enumBase(c) orelse return error.Failed);
    }
    var slot: u64 align(8) = 0;
    rt.fieldValue(@ptrFromInt(object), f, &slot);
    const at: [*]const u8 = @ptrCast(&slot);
    if (primitive(kind, at)) |v| return v;
    const pointer: usize = @truncate(slot);
    if (kind == .string) {
        if (pointer == 0) return .{ .kind = .text, .text = "" };
        return .{ .kind = .text, .text = rt.readString(a, @ptrFromInt(pointer)) catch return error.Failed };
    }
    return .{ .kind = .object, .object = pointer };
}

fn setFieldOn(rt: *const Runtime, a: Allocator, object: usize, name: []const u8, value: Value) E!void {
    const f = try instanceField(rt, object, name);
    var slot: u64 = undefined;
    const p = try argument(rt, a, rt.fieldType(f) orelse return error.Failed, value, &slot);
    rt.setFieldValue(@ptrFromInt(object), f, p);
}

fn stringAt(rt: *const Runtime, a: Allocator, address: usize) E![]const u8 {
    const c = try objectClass(rt, address);
    if (!std.mem.eql(u8, rt.className(c), "String") or !std.mem.eql(u8, rt.classNamespace(c), "System")) return error.Unreadable;
    return rt.readString(a, @ptrFromInt(address)) catch error.Failed;
}

test "nothing's running outside a game" {
    const testing = std.testing;
    var loaded: Loaded = undefined;
    try testing.expectEqual(.none, Impl.kind(&loaded));
    try testing.expectError(error.NotRunning, Impl.images(&loaded));
    try testing.expectError(error.NotRunning, Impl.method(&loaded, "Game.Player", "Update", -1));
    try testing.expectError(error.NotRunning, Impl.getField(&loaded, 0x1000, "health"));
    try testing.expectError(error.NotRunning, Impl.setField(&loaded, 0x1000, "health", .{ .kind = .integer, .integer = 1 }));
}

// Off unless `WRAITH_MANAGED_GAME` names a Unity game's folder. See testing/managed_game.zig.
test "a real game's C#, through the API" {
    const testing = std.testing;
    const sdk = @import("wraith_sdk");
    const Names = @import("../Names.zig");
    const addresses = @import("addresses.zig");

    const k = try @import("../testing/managed_game.zig").start();
    defer global().stop();
    const il2cpp = k == .il2cpp;

    Names.global = .init(testing.allocator);
    defer Names.global.deinit();
    var loaded: Loaded = undefined;
    loaded.initForTest(testing.allocator, "kai");
    sdk.Owner.attach(loaded.root());
    defer sdk.Owner.detach();
    defer {
        loaded.deinitForTest();
        wraith.forget(&loaded);
    }
    const m = sdk.wraith.root().?.managed();

    try testing.expectEqual(if (il2cpp) W.ManagedKind.il2cpp else .mono, m.kind());
    const images_list = try m.images();
    try testing.expect(for (images_list) |i| {
        if (std.mem.startsWith(u8, i, "mscorlib")) break true;
    } else false);
    try testing.expect((try m.classes("mscorlib.dll")).len > 100);

    const string = try m.find("System.String");
    try testing.expectEqualStrings("System.String", string.full_name);
    try testing.expectEqualStrings("System.Object", string.parent);
    try testing.expect(!string.value_type);
    const nested = try m.find("System.Environment/SpecialFolder");
    try testing.expectEqualStrings("System.Environment/SpecialFolder", nested.full_name);
    try testing.expect(nested.value_type);
    try testing.expectError(error.NotFound, m.find("No.Such.Class"));

    const empty = for (try m.fields("System.String")) |f| {
        if (std.mem.eql(u8, f.name, "Empty")) break f;
    } else return error.NoEmpty;
    try testing.expect(empty.is_static);
    try testing.expectEqualStrings("System.String", empty.type);
    const concat = for (try m.methods("System.String")) |one| {
        if (std.mem.eql(u8, one.name, "Concat") and one.params.len == 2 and std.mem.eql(u8, one.params[0], "System.String")) break one;
    } else return error.NoConcat;
    try testing.expect(concat.is_static);
    try testing.expectEqualStrings("System.String", concat.return_type);

    // `Class:Method` in address text finds the same code
    const code = try m.method("System.String", "Concat", -1);
    try testing.expect(code != 0);
    var problem: api.LocationProblem = .{};
    try testing.expectEqual(code, try addresses.resolve(&loaded, "System.String:Concat", &.{}, &problem));
    try testing.expectEqual(code + 4, try addresses.resolve(&loaded, "System.String:Concat+4", &.{}, &problem));
    try testing.expectError(error.NotFound, m.method("System.String", "NoSuchMethod", -1));
    try m.running().wait();

    // Schemas name C# members, and they're found by name
    const schemas = try @import("schemas.zig").fromFiles(&.{.{ .name = "kai/cs.sal", .text =
        \\[Managed("System.String")]
        \\struct CsString {
        \\    [Managed] static usize Empty;
        \\    [Managed("Concat")] static usize concat(usize a, usize b);
        \\}
        \\[Managed("System.String:Concat")] usize concatOf(usize a, usize b);
        \\[Managed("UnityEngine.Transform")]
        \\struct UnityTransform {
        \\    [Icall("get_position_Injected")] void position(inout Vec3 at);
        \\}
    }});
    defer schemas.destroy();
    try testing.expectEqual(try m.staticAddress("System.String", "Empty"), try schemas.address("CsString.Empty"));
    try testing.expectEqual(try m.method("System.String", "Concat", 2), try schemas.address("CsString.concat"));
    try testing.expectEqual(try m.method("System.String", "Concat", 2), try schemas.address("concatOf"));
    // An engine call, registered the way Unity does as it starts
    const Fake = struct {
        fn position(_: ?*anyopaque, out: *[3]f32) callconv(.c) void {
            out.* = .{ 1, 2, 3 };
        }
    };
    const sys = @import("tuft_sys");
    const runtime_dll = for (@import("tuft_managed").il2cpp_modules ++ @import("tuft_managed").mono_modules) |name| {
        if (sys.module.findBase(name)) |base| break base;
    } else return error.NoRuntime;
    const add_name = if (il2cpp) "il2cpp_add_internal_call" else "mono_add_internal_call";
    const add: *const fn ([*:0]const u8, *const anyopaque) callconv(.c) void = @ptrFromInt(sys.module.findExport(runtime_dll, add_name).?);
    add("UnityEngine.Transform::get_position_Injected", &Fake.position);
    try testing.expectEqual(@intFromPtr(&Fake.position), try schemas.address("UnityTransform.position"));
    try testing.expectEqual(@intFromPtr(&Fake.position), try m.icall("UnityEngine.Transform", "get_position_Injected"));
    try testing.expect(std.mem.endsWith(u8, try m.classOf(try m.typeObject("System.String")), "Type"));
    try testing.expectError(error.NotFound, m.icall("System.String", "Concat"));

    const at = try m.staticAddress("System.String", "Empty");
    const object = try mem.Memory.local.load(usize, at);
    try testing.expectEqualStrings("System.String", try m.classOf(object));
    try testing.expectEqualStrings("", try m.readString(object));
    const instance_field = for (try m.fields("System.String")) |f| {
        if (!f.is_static) break f.name;
    } else return error.NoInstanceField;
    try testing.expectError(error.NotFound, m.staticAddress("System.String", instance_field));
    const made = try global().call(struct {
        fn f(rt: *const Runtime) usize {
            return @intFromPtr(rt.newString("Velvet ✦") orelse return 0);
        }
    }.f, .{});
    try testing.expectEqualStrings("System.String", try m.classOf(made));
    try testing.expectEqualStrings("Velvet ✦", try m.readString(made));

    // Fields of a live object, read and set by name
    const version = try m.invoke("System.Version", "Parse", 0, &.{.{ .kind = .text, .text = "1.2.3.4" }});
    try testing.expectEqual(1, (try m.getField(version.object, "_Major")).integer);
    try m.setField(version.object, "_Major", .{ .kind = .integer, .integer = 7 });
    try testing.expectEqual(7, (try m.invoke("System.Version", "get_Major", version.object, &.{})).integer);
    try testing.expectError(error.NotFound, m.getField(version.object, "nope"));

    // Held past where it came from, and let go, which is fine twice
    const handle = try m.hold(made);
    try testing.expect(handle != 0);
    try testing.expectEqualStrings("Velvet ✦", try m.readString(made));
    m.release(handle);
    m.release(handle);
    try testing.expectError(error.NotFound, m.hold(0));

    // Calling C#, picking the overload that fits
    const parsed = try m.invoke("System.Int32", "Parse", 0, &.{.{ .kind = .text, .text = "42" }});
    try testing.expectEqual(.integer, parsed.kind);
    try testing.expectEqual(42, parsed.integer);
    const joined = try m.invoke("System.String", "Concat", 0, &.{ .{ .kind = .text, .text = "Velvet " }, .{ .kind = .text, .text = "Crowe" } });
    try testing.expectEqualStrings("Velvet Crowe", joined.text);
    try testing.expect((try m.invoke("System.String", "IsNullOrEmpty", 0, &.{.{ .kind = .text, .text = "" }})).flag);
    try testing.expectEqual(3.0, (try m.invoke("System.Math", "Sqrt", 0, &.{.{ .kind = .integer, .integer = 9 }})).number);
    // An instance method, on the string from before
    try testing.expectEqual(8, (try m.invoke("System.String", "get_Length", made, &.{})).integer);
    try testing.expectError(error.Threw, m.invoke("System.Int32", "Parse", 0, &.{.{ .kind = .text, .text = "nope" }}));
    try testing.expectError(error.NotFound, m.invoke("System.Int32", "Parse", 0, &.{}));
    // From a thread the runtime doesn't know, it runs on Wraith's own
    const Elsewhere = struct {
        fn parse(area: W.Managed, out: *i64) void {
            out.* = (area.invoke("System.Int32", "Parse", 0, &.{.{ .kind = .text, .text = "7" }}) catch return).integer;
        }
    };
    var elsewhere: i64 = 0;
    const thread = try std.Thread.spawn(.{}, Elsewhere.parse, .{ m, &elsewhere });
    thread.join();
    try testing.expectEqual(7, elsewhere);
    const OnWorker = struct {
        fn threadId() callconv(.c) usize {
            return std.Thread.getCurrentId();
        }
    };
    try testing.expectEqual(@as(usize, global().thread_id.load(.acquire)), try m.callNative(@intFromPtr(&OnWorker.threadId)));
    try testing.expectError(error.NotFound, m.callNative(0));

    // Garbage isn't an object, and doesn't crash
    var not_object: [4]usize = @splat(0);
    not_object[0] = @intFromPtr(&not_object);
    try testing.expectError(error.Unreadable, m.classOf(@intFromPtr(&not_object)));
    try testing.expectError(error.Unreadable, m.classOf(0x10));
    try testing.expectError(error.Unreadable, m.readString(code));
}

// Starts a CoreCLR here, like a .NET game would, then joins it like the game's. Skipped without .NET 10.
test "CoreCLR's C#, through the API" {
    const testing = std.testing;
    const sdk = @import("wraith_sdk");
    const Names = @import("../Names.zig");
    const addresses = @import("addresses.zig");
    const tuft_managed = @import("tuft_managed");
    const sys = @import("tuft_sys");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    _ = tuft_managed.CoreClr.open(std.heap.smp_allocator, testing.io, .{ .dir = dir, .start = true }) catch |err| switch (err) {
        error.NoDotnet => return error.SkipZigTest,
        else => return err,
    };
    global().useCoreClr(testing.io, dir);
    global().startOn(.coreclr, sys.module.findBase(tuft_managed.coreclr_modules[0]) orelse return error.NoCoreClr);
    defer global().stop();
    var waited: u32 = 0;
    while (!global().running() and waited < 10_000) : (waited += 10) sys.thread.sleepMs(10);

    Names.global = .init(testing.allocator);
    defer Names.global.deinit();
    var loaded: Loaded = undefined;
    loaded.initForTest(testing.allocator, "ffxiv");
    sdk.Owner.attach(loaded.root());
    defer sdk.Owner.detach();
    defer {
        loaded.deinitForTest();
        wraith.forget(&loaded);
    }
    const m = sdk.wraith.root().?.managed();
    try m.running().wait();

    try testing.expectEqual(W.ManagedKind.coreclr, m.kind());
    try testing.expect(for (try m.images()) |i| {
        if (std.mem.eql(u8, i, "System.Private.CoreLib.dll")) break true;
    } else false);
    try testing.expect((try m.classes("System.Private.CoreLib.dll")).len > 1000);

    const string = try m.find("System.String");
    try testing.expectEqualStrings("System.Object", string.parent);
    try testing.expect(!string.value_type);
    try testing.expect((try m.find("System.Environment/SpecialFolder")).value_type);
    try testing.expectError(error.NotFound, m.find("No.Such.Class"));
    const concat = for (try m.methods("System.String")) |one| {
        if (std.mem.eql(u8, one.name, "Concat") and one.params.len == 2 and std.mem.eql(u8, one.params[0], "System.String")) break one;
    } else return error.NoConcat;
    try testing.expect(concat.is_static);
    try testing.expectEqualStrings("System.String", concat.return_type);

    // `Class:Method` in address text finds the same code
    const code = try m.method("System.String", "IsNullOrEmpty", 1);
    var problem: api.LocationProblem = .{};
    try testing.expectEqual(code, try addresses.resolve(&loaded, "System.String:IsNullOrEmpty", &.{}, &problem));

    // Statics, strings and System.Type
    const object = try mem.Memory.local.load(usize, try m.staticAddress("System.String", "Empty"));
    try testing.expectEqualStrings("System.String", try m.classOf(object));
    try testing.expectEqualStrings("", try m.readString(object));
    try testing.expect(std.mem.endsWith(u8, try m.classOf(try m.typeObject("System.String")), "Type"));
    const made = try global().call(struct {
        fn f(rt: *const Runtime) usize {
            return @intFromPtr(rt.newString("Velvet ✦") orelse return 0);
        }
    }.f, .{});

    // Held, and found again where the garbage collector's put it
    const handle = try m.hold(made);
    const now = try m.heldAt(handle);
    try testing.expectEqualStrings("System.String", try m.classOf(now));
    try testing.expectEqualStrings("Velvet ✦", try m.readString(now));
    try testing.expectEqual(8, (try m.invoke("System.String", "get_Length", now, &.{})).integer);
    m.release(handle);
    try testing.expectError(error.NotFound, m.heldAt(handle));

    // Fields of a live object, read and set by name
    const version = try m.invoke("System.Version", "Parse", 0, &.{.{ .kind = .text, .text = "1.2.3.4" }});
    try testing.expectEqual(1, (try m.getField(version.object, "_Major")).integer);
    try m.setField(version.object, "_Major", .{ .kind = .integer, .integer = 7 });
    try testing.expectEqual(7, (try m.invoke("System.Version", "get_Major", version.object, &.{})).integer);

    // Calling C#, picking the overload that fits
    try testing.expectEqual(42, (try m.invoke("System.Int32", "Parse", 0, &.{.{ .kind = .text, .text = "42" }})).integer);
    const joined = try m.invoke("System.String", "Concat", 0, &.{ .{ .kind = .text, .text = "Velvet " }, .{ .kind = .text, .text = "Crowe" } });
    try testing.expectEqualStrings("Velvet Crowe", joined.text);
    try testing.expect((try m.invoke("System.String", "IsNullOrEmpty", 0, &.{.{ .kind = .text, .text = "" }})).flag);
    try testing.expectEqual(3.0, (try m.invoke("System.Math", "Sqrt", 0, &.{.{ .kind = .integer, .integer = 9 }})).number);
    try testing.expectError(error.Threw, m.invoke("System.Int32", "Parse", 0, &.{.{ .kind = .text, .text = "nope" }}));

    // Garbage isn't an object, and doesn't crash
    var not_object: [4]usize = @splat(0);
    not_object[0] = @intFromPtr(&not_object);
    try testing.expectError(error.Unreadable, m.classOf(@intFromPtr(&not_object)));
    try testing.expectError(error.Unreadable, m.readString(code));
}
