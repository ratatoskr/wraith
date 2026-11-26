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
const values = @import("managed_values.zig");
const wraith = @import("wraith.zig");
const threads = @import("threads.zig");
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
        if (g.running()) g.call(Runtime.freeHandle, .{kv.key_ptr.*}) catch {};
        held.removeByPtr(kv.key_ptr);
    };
}

/// Runs `func` where the runtime can take it, which fails the same way as it not running.
fn run(comptime func: anytype, args: anytype) @typeInfo(@TypeOf(func)).@"fn".return_type.? {
    return global().call(func, args) catch error.NotRunning;
}

pub const Impl = struct {
    pub fn runtimeKind(_: *Loaded) W.Managed.Kind {
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
        job.* = .{ .owner = t.owner, .resolver = .of(pair.resolver, loaded) };
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

    pub fn findMethod(_: *Loaded, class_name: []const u8, name: []const u8, params: i32) sal.Plain(Managed, "findMethod") {
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

    pub fn invoke(_: *Loaded, class_name: []const u8, method_name: []const u8, target: usize, args: []const W.Managed.Value) sal.Plain(Managed, "invoke") {
        return switch (try run(invokeOn, .{ scratch.begin(), class_name, method_name, target, args })) {
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
        const handle = g.call(Runtime.newHandle, .{ @as(*ManagedRuntime.Object, @ptrFromInt(object)), false }) catch 0;
        if (handle == 0) return error.Failed;
        held_lock.lock();
        defer held_lock.unlock();
        held.put(std.heap.smp_allocator, handle, &loaded.owner) catch {
            g.call(Runtime.freeHandle, .{handle}) catch {};
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
        global().call(Runtime.freeHandle, .{handle}) catch {};
    }

    pub fn heldAt(loaded: *Loaded, handle: u32) sal.Plain(Managed, "heldAt") {
        const g = global();
        if (!g.running()) return error.NotRunning;
        held_lock.lock();
        defer held_lock.unlock();
        // Only its own
        const owner = held.get(handle) orelse return error.NotFound;
        if (owner != &loaded.owner) return error.NotFound;
        const at = g.call(Runtime.handleTarget, .{handle}) catch null;
        return @intFromPtr(at orelse return error.NotFound);
    }

    pub fn classOf(_: *Loaded, object: usize) sal.Plain(Managed, "classOf") {
        return run(classNameOf, .{ scratch.begin(), object });
    }

    pub fn readString(_: *Loaded, address: usize) sal.Plain(Managed, "readString") {
        return run(stringAt, .{ scratch.begin(), address });
    }

    pub fn getField(_: *Loaded, object: usize, field: []const u8) sal.Plain(Managed, "getField") {
        return run(fieldOf, .{ scratch.begin(), object, field });
    }

    pub fn setField(_: *Loaded, object: usize, field: []const u8, value: W.Managed.Value) sal.Plain(Managed, "setField") {
        return run(setFieldOn, .{ scratch.begin(), object, field, value });
    }
};

// On the attached thread from here down

const RunningPromise = sal.Plain(Managed, "running");

/// Waits off the caller's thread till the runtime's running. Gives up once the plugin's gone, or if
/// the runtime can't be used, or Wraith stopped watching.
const RunningWait = struct {
    owner: *sal.Owner,
    resolver: threads.Back(wraith.ResolverOf(RunningPromise)),

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

fn classInfo(rt: *const Runtime, a: Allocator, name: []const u8) E!W.Managed.Class {
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

fn listFields(rt: *const Runtime, a: Allocator, name: []const u8) E![]const W.Managed.Field {
    const c = try classCalled(rt, name);
    var out: std.ArrayList(W.Managed.Field) = .empty;
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

fn listMethods(rt: *const Runtime, a: Allocator, name: []const u8) E![]const W.Managed.Method {
    const c = try classCalled(rt, name);
    var out: std.ArrayList(W.Managed.Method) = .empty;
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

/// What a schema's `[Managed]` static or `[Icall]` is in the game's C#. Methods are called through
/// `managed_calls` instead.
pub const Member = enum { static, icall };

/// Where a schema's `[Managed]` static or `[Icall]` is, through the attached thread.
pub fn memberAddress(class_name: []const u8, name: []const u8, member: Member) sal.Plain(Managed, "staticAddress") {
    return switch (member) {
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

const Value = values.Value;
const Outcome = values.Outcome;

fn invokeOn(rt: *const Runtime, a: Allocator, class_name: []const u8, method_name: []const u8, target: usize, args: []const Value) E!Outcome {
    if (args.len > values.max_args) return error.Failed;
    const c = try classCalled(rt, class_name);
    var kinds: [values.max_args]W.Managed.ValueKind = undefined;
    for (args, kinds[0..args.len]) |arg, *k| k.* = arg.kind;
    const m = values.pickMethod(rt, c, method_name, kinds[0..args.len]) orelse return error.NotFound;
    // A constructor with no object makes one, and gives it back
    if (target == 0 and std.mem.eql(u8, method_name, ".ctor")) return values.construct(rt, a, c, m, args);
    return values.call(rt, a, m, target, args);
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
    // CoreCLR's runtime takes a MethodTable as it is, and garbage kills the game
    if (rt.* == .coreclr) {
        const object = ManagedRuntime.findClass(rt, "System.Object") orelse return error.Failed;
        if (!likeMethodTable(class_at, @intFromPtr(object))) return error.Unreadable;
    }
    const image = rt.classImage(@ptrFromInt(class_at)) orelse return error.Unreadable;
    const list = rt.assemblies(gpa) catch return error.Failed;
    defer gpa.free(list);
    for (list) |asm_entry| {
        if (rt.assemblyImage(asm_entry) == image) return rt.objectClass(@ptrFromInt(address)) orelse error.Unreadable;
    }
    return error.Unreadable;
}

/// Whether `at` looks like an object's CoreCLR MethodTable. Its size is at +4 and its parent's at
/// +16, on 64 and 32-bit, and every object's parents end at `object`, System.Object's own. Only
/// checking the size there let garbage through now and then.
fn likeMethodTable(at: usize, object: usize) bool {
    const word = @sizeOf(usize);
    var mt = at;
    for (0..64) |_| {
        if (mt == object) return true;
        if (!mem.isReadable(mt, 16 + word)) return false;
        const size = mem.Memory.local.load(u32, mt + 4) catch return false;
        if (size < 2 * word or size > 1 << 24) return false;
        mt = mem.Memory.local.load(usize, mt + 16) catch return false;
        if (mt == 0) return false;
    }
    return false;
}

test "a MethodTable's parents have to end at System.Object's own" {
    const word = @sizeOf(usize);
    // Like the real ones, a size at +4 and a parent at +16
    const Mt = extern struct { flags: u32 = 0, size: u32, pad: [8]u8 = @splat(0), parent: usize, rest: [8]usize = @splat(0) };
    const object: Mt = .{ .size = 3 * word, .parent = 0 };
    const player: Mt = .{ .size = 8 * word, .parent = @intFromPtr(&object) };
    try std.testing.expect(likeMethodTable(@intFromPtr(&player), @intFromPtr(&object)));
    // Shaped right, with an object-sized root, but not the runtime's
    // Vars, so they're apart from the consts above, which can share one address
    var lookalike: Mt = .{ .size = 3 * word, .parent = 0 };
    var fake: Mt = .{ .size = 8 * word, .parent = @intFromPtr(&lookalike) };
    try std.testing.expect(!likeMethodTable(@intFromPtr(&fake), @intFromPtr(&object)));
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
    if (values.primitive(kind, at)) |v| return v;
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
    const p = try values.argument(rt, a, rt.fieldType(f) orelse return error.Failed, value, &slot);
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
    try testing.expectEqual(.none, Impl.runtimeKind(&loaded));
    try testing.expectError(error.NotRunning, Impl.images(&loaded));
    try testing.expectError(error.NotRunning, Impl.findMethod(&loaded, "Game.Player", "Update", -1));
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

    try testing.expectEqual(if (il2cpp) W.Managed.Kind.il2cpp else .mono, m.runtimeKind());
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
    const code = try m.findMethod("System.String", "Concat", -1);
    try testing.expect(code != 0);
    var problem: api.LocationProblem = .{};
    try testing.expectEqual(code, try addresses.resolve(&loaded, "System.String:Concat", &.{}, &problem));
    try testing.expectEqual(code + 4, try addresses.resolve(&loaded, "System.String:Concat+4", &.{}, &problem));
    try testing.expectError(error.NotFound, m.findMethod("System.String", "NoSuchMethod", -1));
    try m.running().wait();

    // Schemas name C# members, and they're found by name. Methods are called through Wraith, which
    // converts strings
    const srt = @import("salamander_runtime");
    const schemas = try @import("schemas.zig").fromFiles(&.{.{ .name = "kai/cs.sal", .text =
        \\[Managed("System.String")]
        \\struct CsString {
        \\    [Managed] static usize Empty;
        \\    [Managed("Concat")] static string concat(string a, string b);
        \\}
        \\[Managed("System.String:Concat")] string concatOf(string a, string b);
        \\[Managed("UnityEngine.Transform")]
        \\struct UnityTransform {
        \\    [Icall("get_position_Injected")] void position(inout Vec3 at);
        \\}
    }});
    defer schemas.destroy();
    try testing.expectEqual(try m.staticAddress("System.String", "Empty"), try schemas.address("CsString.Empty"));
    const Concat = *const fn (srt.String, srt.String) callconv(.c) srt.String;
    const concat_of: Concat = @ptrFromInt(try schemas.address("CsString.concat"));
    try testing.expectEqualStrings("Velvet Crowe", concat_of(.init("Velvet "), .init("Crowe")).get());
    const top: Concat = @ptrFromInt(try schemas.address("concatOf"));
    try testing.expectEqualStrings("ab", top(.init("a"), .init("b")).get());
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

    try testing.expectEqual(W.Managed.Kind.coreclr, m.runtimeKind());
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
    const code = try m.findMethod("System.String", "IsNullOrEmpty", 1);
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

    // A constructor with no object makes one, all in one go here, as the collector moves things
    const built = try m.invoke("System.Version", ".ctor", 0, &.{.{ .kind = .text, .text = "5.6" }});
    try testing.expectEqual(W.Managed.ValueKind.object, built.kind);
    try testing.expectEqualStrings("System.Version", try m.classOf(built.object));
    try testing.expectEqual(5, (try m.invoke("System.Version", "get_Major", built.object, &.{})).integer);
    try testing.expectError(error.Threw, m.invoke("System.Version", ".ctor", 0, &.{.{ .kind = .text, .text = "nope" }}));
    // And made without constructing, zeroed
    const blank = try global().call(struct {
        fn f(rt: *const Runtime) usize {
            const c = ManagedRuntime.findClass(rt, "System.Version") orelse return 0;
            return @intFromPtr(rt.newObject(c) orelse return 0);
        }
    }.f, .{});
    try testing.expect(blank != 0);
    try testing.expectEqualStrings("System.Version", try m.classOf(blank));

    // Calling C#, picking the overload that fits
    try testing.expectEqual(42, (try m.invoke("System.Int32", "Parse", 0, &.{.{ .kind = .text, .text = "42" }})).integer);
    const joined = try m.invoke("System.String", "Concat", 0, &.{ .{ .kind = .text, .text = "Velvet " }, .{ .kind = .text, .text = "Crowe" } });
    try testing.expectEqualStrings("Velvet Crowe", joined.text);
    try testing.expect((try m.invoke("System.String", "IsNullOrEmpty", 0, &.{.{ .kind = .text, .text = "" }})).flag);
    try testing.expectEqual(3.0, (try m.invoke("System.Math", "Sqrt", 0, &.{.{ .kind = .integer, .integer = 9 }})).number);
    try testing.expectError(error.Threw, m.invoke("System.Int32", "Parse", 0, &.{.{ .kind = .text, .text = "nope" }}));

    // Schemas' [Managed] methods, called like any other declared function, with strings and objects
    // converted, and overloads told apart by what they take
    const srt = @import("salamander_runtime");
    const schemas = try @import("schemas.zig").fromFiles(&.{.{ .name = "ffxiv/cs.sal", .text =
        \\[Managed("System.String")]
        \\struct CsString {
        \\    [Managed("Concat")] static string concat(string a, string b);
        \\    [Managed("Concat")] static string concat3(string a, string b, string c);
        \\    [Managed("get_Length")] i32 length();
        \\}
        \\[Managed("System.Int32:Parse")] i32 parse(string s);
        \\[Managed("System.Math:Max")] i64 maxLong(i64 a, i64 b);
        \\[Managed("System.Math:Max")] f64 maxDouble(f64 a, f64 b);
        \\[Managed("System.Math:Max")] usize maxWord(usize a, usize b);
    }});
    defer schemas.destroy();
    schemas.setHome("ffxiv");
    const Concat = *const fn (srt.String, srt.String) callconv(.c) srt.String;
    const concat_of: Concat = @ptrFromInt(try schemas.address("CsString.concat"));
    try testing.expectEqualStrings("Velvet Crowe", concat_of(.init("Velvet "), .init("Crowe")).get());
    const concat3: *const fn (srt.String, srt.String, srt.String) callconv(.c) srt.String = @ptrFromInt(try schemas.address("CsString.concat3"));
    try testing.expectEqualStrings("abc", concat3(.init("a"), .init("b"), .init("c")).get());
    const kept = try m.hold(made);
    defer m.release(kept);
    const length: *const fn (usize) callconv(.c) i32 = @ptrFromInt(try schemas.address("CsString.length"));
    try testing.expectEqual(8, length(try m.heldAt(kept)));
    const parse: *const fn (srt.String) callconv(.c) i32 = @ptrFromInt(try schemas.address("parse"));
    try testing.expectEqual(42, parse(.init("42")));
    // What throws gives zero, and says so in the log
    {
        const saved = @import("wraith_core").log.mute(&.{.runtime});
        defer @import("wraith_core").log.setFilter(saved);
        try testing.expectEqual(0, parse(.init("nope")));
    }
    const max_long: *const fn (i64, i64) callconv(.c) i64 = @ptrFromInt(try schemas.address("maxLong"));
    try testing.expectEqual(1 << 40, max_long(1 << 40, -3));
    const max_double: *const fn (f64, f64) callconv(.c) f64 = @ptrFromInt(try schemas.address("maxDouble"));
    try testing.expectEqual(2.5, max_double(2.5, -1));
    // nint and nuint both take an address, so it can't say which
    try testing.expectError(error.NotFound, schemas.address("maxWord"));
    // The same one, declared again, is the same function
    try testing.expectEqual(@intFromPtr(concat_of), try schemas.address("CsString.concat"));

    // From a fiber, like a plugin's task, a call goes through Wraith's thread, since one from there
    // has CoreCLR end the thread once the fiber's deleted
    const InFiber = struct {
        fiber: sys.fiber.Fiber = undefined,
        parse: *const fn (srt.String) callconv(.c) i32,
        got: i32 = 0,

        fn run(f: *sys.fiber.Fiber) void {
            const self: *@This() = @alignCast(@fieldParentPtr("fiber", f));
            self.got = self.parse(.init("7"));
        }
    };
    var in_fiber: InFiber = .{ .parse = parse };
    try in_fiber.fiber.init(InFiber.run, .{});
    in_fiber.fiber.resumeHere();
    in_fiber.fiber.deinit();
    try testing.expectEqual(7, in_fiber.got);
    try testing.expectEqual(9, parse(.init("9")));

    // Garbage isn't an object, and doesn't crash
    var not_object: [4]usize = @splat(0);
    not_object[0] = @intFromPtr(&not_object);
    try testing.expectError(error.Unreadable, m.classOf(@intFromPtr(&not_object)));
    // Nor one whose class points nowhere, which CoreCLR itself would follow and crash on
    const nowhere: [0x80]usize = @splat(std.math.maxInt(usize) - 0xfff);
    const fake: [2]usize = .{ @intFromPtr(&nowhere), 0 };
    try testing.expectError(error.Unreadable, m.classOf(@intFromPtr(&fake)));
    // Nor one shaped like a MethodTable whose root is object-sized but isn't System.Object's
    var lookalike: [8]usize = @splat(0);
    std.mem.writeInt(u32, std.mem.asBytes(&lookalike)[4..8], 3 * @sizeOf(usize), .little);
    const posing: [2]usize = .{ @intFromPtr(&lookalike), 0 };
    try testing.expectError(error.Unreadable, m.classOf(@intFromPtr(&posing)));
    try testing.expectError(error.Unreadable, m.readString(code));
}
