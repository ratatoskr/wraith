//! The game's C# runtime, Mono, IL2CPP or CoreCLR, for Unity games, .NET games and mod loaders like
//! Dalamud. Calling in from a thread the runtime doesn't know can crash it, so one thread of ours
//! makes every call, attached while it does. Others hand it work with `call` and wait.

const Managed = @This();

const std = @import("std");

const core = @import("wraith_core");
const tuft_managed = @import("tuft_managed");
const sys = @import("tuft_sys");
const Atomic = @import("tuft_arch").atomic.Value;

pub const Runtime = tuft_managed.Runtime;
pub const Kind = tuft_managed.Kind;
pub const Class = tuft_managed.Class;
pub const Image = tuft_managed.Image;
pub const Method = tuft_managed.Method;
pub const Field = tuft_managed.Field;
pub const Type = tuft_managed.Type;
pub const Object = tuft_managed.Object;
pub const ElementType = tuft_managed.ElementType;

const log = core.log.scoped(.wraith_runtime);
/// For work on the attached thread. Not the render thread's.
const gpa = std.heap.smp_allocator;

pub var global: Managed = .{};

pub const State = enum(u8) {
    /// Not watching, or stopped
    off,
    /// For the game to load or start its runtime
    waiting,
    running,
    /// Its DLL's missing exports we need, so there's nothing to do
    failed,
};

pub const Error = error{NotRunning};

/// How long the runtime has to have been started before we attach, so we don't race the game
/// still setting it up.
const settle_ms = 1000;

/// How long CoreCLR's host can keep refusing to be joined, while it's still starting, before we
/// give up.
const join_timeout_ms = 30_000;

state: Atomic(State) = .init(.off),
/// The runtime's DLL, once it's loaded. 0 till then.
found: Atomic(usize) = .init(0),
found_kind: Atomic(u8) = .init(0),
/// Good once `state` is `running`, and only used on the attached thread after that.
rt: Runtime = undefined,
watch_ctx: [watched.len]Watch = undefined,
watches: [watched.len]?*sys.module.WhenLoaded = @splat(null),
wake: ?sys.sync.Signal = null,
thread: ?*anyopaque = null,
thread_id: Atomic(u32) = .init(0),
stopping: Atomic(bool) = .init(false),
lock: sys.sync.RwLock = .{},
head: ?*Job = null,
tail: ?*Job = null,
/// Off in tests, which have no runtime to attach to.
attaches: bool = true,
/// `Class:Method` names to their code, which stays put once compiled. Under `lock`.
methods: std.StringHashMapUnmanaged(usize) = .empty,
/// The runtime's `changes` when `methods` was last known good.
methods_seen: Atomic(u32) = .init(0),
/// For joining CoreCLR, which writes a small config file to `clr_dir` first.
io: ?std.Io = null,
clr_dir: ?[]const u8 = null,

const Watched = struct { name: []const u8, kind: Kind };
const watched = blk: {
    const il2cpp = tuft_managed.il2cpp_modules;
    const mono = tuft_managed.mono_modules;
    const coreclr = tuft_managed.coreclr_modules;
    var list: [il2cpp.len + mono.len + coreclr.len]Watched = undefined;
    for (il2cpp, 0..) |n, i| list[i] = .{ .name = n, .kind = .il2cpp };
    for (mono, 0..) |n, i| list[il2cpp.len + i] = .{ .name = n, .kind = .mono };
    for (coreclr, 0..) |n, i| list[il2cpp.len + mono.len + i] = .{ .name = n, .kind = .coreclr };
    break :blk list;
};

const Watch = struct {
    managed: *Managed,
    kind: Kind,

    fn ready(ctx: ?*anyopaque, base: usize) void {
        const w: *Watch = @ptrCast(@alignCast(ctx.?));
        const self = w.managed;
        if (self.found.cmpxchgStrong(0, base, .acq_rel, .acquire) != null) return;
        self.found_kind.store(@backingInt(w.kind), .release);
        if (self.wake) |s| s.set();
    }
};

const Job = struct {
    run: *const fn (ctx: *anyopaque, rt: *const Runtime) void,
    ctx: *anyopaque,
    done: sys.sync.Signal,
    /// The thread stopped before getting to it
    dropped: bool = false,
    next: ?*Job = null,
};

/// Watches for the runtime's DLL and starts the attached thread. Does nothing if it can't. `io` and
/// `clr_dir`, a folder Wraith can write to, are for joining CoreCLR. The folder's copied.
pub fn start(self: *Managed, io: std.Io, clr_dir: []const u8) void {
    self.useCoreClr(io, clr_dir);
    if (!self.begin()) return;
    // After the thread, since a DLL that's already loaded fires straight away
    for (watched, &self.watch_ctx, &self.watches) |m, *ctx, *w| {
        ctx.* = .{ .managed = self, .kind = m.kind };
        w.* = sys.module.WhenLoaded.create(gpa, m.name, .{ .ctx = ctx, .ready = Watch.ready }) catch null;
    }
}

/// Like `start`, for a runtime that's already loaded at `base`, without watching for others. Call
/// `useCoreClr` first for CoreCLR.
pub fn startOn(self: *Managed, k: Kind, base: usize) void {
    self.found_kind.store(@backingInt(k), .release);
    self.found.store(base, .release);
    _ = self.begin();
}

/// What joining CoreCLR needs. The folder's copied.
pub fn useCoreClr(self: *Managed, io: std.Io, clr_dir: []const u8) void {
    self.io = io;
    if (self.clr_dir) |d| gpa.free(d);
    self.clr_dir = gpa.dupe(u8, clr_dir) catch null;
}

fn begin(self: *Managed) bool {
    if (self.state.load(.acquire) != .off) return false;
    self.stopping.store(false, .release);
    self.attaches = true;
    self.wake = sys.sync.Signal.init() catch |err| {
        log.warn("Can't watch for a C# runtime: {t}", .{err});
        return false;
    };
    self.state.store(.waiting, .release);
    self.thread = sys.thread.spawn(*Managed, work, self) catch |err| {
        log.warn("Can't watch for a C# runtime: {t}", .{err});
        self.state.store(.off, .release);
        self.wake.?.deinit();
        self.wake = null;
        return false;
    };
    return true;
}

/// Detaches and stops the thread. Calls waiting on it fail with `NotRunning`.
pub fn stop(self: *Managed) void {
    for (&self.watches) |*w| if (w.*) |one| {
        one.destroy();
        w.* = null;
    };
    const thread = self.thread orelse return;
    self.stopping.store(true, .release);
    self.wake.?.set();
    sys.thread.join(thread);
    self.thread = null;
    self.wake.?.deinit();
    self.wake = null;
    self.lock.lock();
    var it = self.methods.iterator();
    while (it.next()) |e| gpa.free(e.key_ptr.*);
    self.methods.deinit(gpa);
    self.methods = .empty;
    self.lock.unlock();
    if (self.clr_dir) |d| gpa.free(d);
    self.clr_dir = null;
    self.found.store(0, .release);
    self.state.store(.off, .release);
}

pub fn running(self: *const Managed) bool {
    return self.state.load(.acquire) == .running;
}

/// Which runtime the game has, once it's running.
pub fn kind(self: *const Managed) ?Kind {
    if (!self.running()) return null;
    return self.rt;
}

/// Runs `func(rt, args...)` on the attached thread and waits for what it returns. Straight away if
/// this thread can call in already, like it being that thread or Unity's main one, which some of
/// Unity's own methods need.
pub fn call(self: *Managed, comptime func: anytype, args: anytype) Error!ReturnOf(func) {
    const R = ReturnOf(func);
    const Ctx = struct {
        args: @TypeOf(args),
        result: R = undefined,

        fn run(p: *anyopaque, rt: *const Runtime) void {
            const c: *@This() = @ptrCast(@alignCast(p));
            c.result = @call(.auto, func, .{rt} ++ c.args);
        }
    };
    if (!self.running()) return error.NotRunning;
    var ctx: Ctx = .{ .args = args };
    if (self.thread_id.load(.acquire) == std.Thread.getCurrentId() or (self.attaches and self.rt.attachedHere())) {
        Ctx.run(&ctx, &self.rt);
        return ctx.result;
    }
    var job: Job = .{ .run = Ctx.run, .ctx = &ctx, .done = sys.sync.Signal.init() catch return error.NotRunning };
    defer job.done.deinit();
    {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.stopping.load(.acquire)) return error.NotRunning;
        if (self.tail) |t| t.next = &job else self.head = &job;
        self.tail = &job;
    }
    self.wake.?.set();
    _ = job.done.wait(null);
    if (job.dropped) return error.NotRunning;
    return ctx.result;
}

fn ReturnOf(comptime func: anytype) type {
    return @typeInfo(@TypeOf(func)).@"fn".return_type.?;
}

fn work(self: *Managed) void {
    self.thread_id.store(std.Thread.getCurrentId(), .release);
    var loaded = false;
    var started_at: ?u64 = null;
    while (!self.stopping.load(.acquire)) {
        const state = self.state.load(.acquire);
        const polling = state == .waiting and self.found.load(.acquire) != 0;
        _ = self.wake.?.wait(if (polling) 100 else null);
        if (self.stopping.load(.acquire)) break;
        if (state == .waiting) self.tryStart(&loaded, &started_at);
        self.drain(false);
    }
    self.drain(true);
}

fn tryStart(self: *Managed, loaded: *bool, started_at: *?u64) void {
    const base = self.found.load(.acquire);
    if (base == 0) return;
    const k: Kind = @fromBackingInt(@intCast(self.found_kind.load(.acquire)));
    if (k == .coreclr) return self.tryJoin(started_at);
    if (!loaded.*) {
        var missing: []const u8 = "";
        self.rt = Runtime.fromModule(k, base, &missing) catch {
            log.warn("The game's {s} has no {s}, so Wraith can't read its C#", .{ label(k), missing });
            self.state.store(.failed, .release);
            return;
        };
        loaded.* = true;
    }
    if (!self.rt.started()) return;
    if (sinceSeen(started_at) < settle_ms) return;
    // Only to see it works. Calls attach for as long as they take
    self.rt.detach(self.rt.attach() orelse return);
    self.state.store(.running, .release);
    log.info("The game's {s} is running", .{label(k)});
}

/// CoreCLR has no exports to read, so we join it through the game's own host and load tuft's
/// helper into it. Its host can refuse while it's still starting the runtime, so this tries again
/// each poll for a while.
fn tryJoin(self: *Managed, started_at: *?u64) void {
    const so_far = sinceSeen(started_at);
    if (so_far < settle_ms) return;
    const io = self.io orelse return self.fail("Wraith can't join the game's CoreCLR without a folder for its config", .{});
    const dir = self.clr_dir orelse return self.fail("Wraith can't join the game's CoreCLR without a folder for its config", .{});
    var messages: std.Io.Writer.Allocating = .init(gpa);
    defer messages.deinit();
    const cc = tuft_managed.CoreClr.open(gpa, io, .{ .dir = dir, .messages = &messages.writer }) catch |err| {
        const clr = tuft_managed.coreclr.clr;
        const status = clr.lastStatus();
        return switch (err) {
            error.NotHostedByFxr => self.fail("The game started its CoreCLR without hostfxr, so Wraith can't join it", .{}),
            error.InitFailed => if (status == clr.fxr.status.host_incompatible_config or status == clr.fxr.status.framework_missing)
                self.fail("The game's .NET is older than 10, which Wraith needs to read it: {s}", .{messages.written()})
            else if (so_far < join_timeout_ms) {} else self.fail("Wraith couldn't join the game's CoreCLR (hostfxr 0x{x}): {s}", .{ @as(u32, @bitCast(status)), messages.written() }),
            // Its DLL's loaded, but it hasn't started a runtime yet
            error.NotRunning => if (so_far < join_timeout_ms) {} else self.fail("The game loaded CoreCLR but never started it", .{}),
            else => self.fail("Wraith couldn't read the game's CoreCLR: {t}", .{err}),
        };
    };
    self.rt = .{ .coreclr = cc };
    self.state.store(.running, .release);
    log.info("The game's CoreCLR is running", .{});
}

/// How long since the runtime was first seen, which is now the first time.
fn sinceSeen(started_at: *?u64) u64 {
    const now = sys.thread.tickMs();
    const first = started_at.* orelse blk: {
        started_at.* = now;
        break :blk now;
    };
    return now - first;
}

fn fail(self: *Managed, comptime message: []const u8, args: anytype) void {
    log.warn(message, args);
    self.state.store(.failed, .release);
}

/// Attached only while it has calls, since the game closing waits for every thread its runtime
/// knows, and this one would never end by itself.
fn drain(self: *Managed, drop: bool) void {
    var attached: ?*tuft_managed.Thread = null;
    defer if (attached) |t| self.rt.detach(t);
    while (true) {
        const job = blk: {
            self.lock.lock();
            defer self.lock.unlock();
            const j = self.head orelse return;
            self.head = j.next;
            if (self.head == null) self.tail = null;
            break :blk j;
        };
        if (!drop and attached == null and self.attaches) attached = self.rt.attach();
        if (drop) job.dropped = true else job.run(job.ctx, &self.rt);
        job.done.set();
    }
}

pub fn label(k: Kind) []const u8 {
    return switch (k) {
        .il2cpp => "IL2CPP",
        .mono => "Mono",
        .coreclr => "CoreCLR",
    };
}

/// For tests: `rt` as if the game had started it, with no watching or attaching.
pub fn startForTest(self: *Managed, rt: Runtime) !void {
    self.stopping.store(false, .release);
    self.wake = try sys.sync.Signal.init();
    self.rt = rt;
    self.attaches = false;
    self.state.store(.running, .release);
    self.thread = try sys.thread.spawn(*Managed, work, self);
    // `work` only drains while it's running, so nothing attaches
    while (self.thread_id.load(.acquire) == 0) sys.thread.sleepMs(1);
}

// Lookups, for the attached thread

/// Like `Game.Player`, `Player`, or `Game.Player/Inner` for a nested class. The first image with
/// it wins.
pub fn findClass(rt: *const Runtime, name: []const u8) ?*Class {
    const slash = std.mem.indexOfScalar(u8, name, '/');
    const outer_name = name[0 .. slash orelse name.len];
    const dot = std.mem.lastIndexOfScalar(u8, outer_name, '.');
    var ns_buf: [256:0]u8 = undefined;
    var name_buf: [256:0]u8 = undefined;
    const ns = terminate(&ns_buf, if (dot) |d| outer_name[0..d] else "") orelse return null;
    const short = terminate(&name_buf, if (dot) |d| outer_name[d + 1 ..] else outer_name) orelse return null;
    const list = rt.assemblies(gpa) catch return null;
    defer gpa.free(list);
    for (list) |a| {
        const image = rt.assemblyImage(a) orelse continue;
        const outer = rt.findClass(image, ns, short) orelse continue;
        const rest = if (slash) |s| name[s + 1 ..] else return outer;
        return findNested(rt, image, outer, rest) orelse continue;
    }
    return null;
}

fn findNested(rt: *const Runtime, image: *Image, outer: *Class, path: []const u8) ?*Class {
    var it = std.mem.splitScalar(u8, path, '/');
    var here = outer;
    while (it.next()) |part| {
        here = for (0..rt.classCount(image)) |i| {
            const c = rt.classAt(image, i) orelse continue;
            if (rt.classOuter(c) == here and std.mem.eql(u8, rt.className(c), part)) break c;
        } else return null;
    }
    return here;
}

fn terminate(buf: *[256:0]u8, text: []const u8) ?[:0]const u8 {
    if (text.len > buf.len) return null;
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;
    return buf[0..text.len :0];
}

/// Like `Game.Player/Stats`: the outermost class's namespace, then each class out to in.
pub fn fullName(rt: *const Runtime, a: std.mem.Allocator, c: *Class) std.mem.Allocator.Error![]u8 {
    var chain: [16]*Class = undefined;
    var n: usize = 0;
    var here: ?*Class = c;
    while (here) |h| : (here = rt.classOuter(h)) {
        if (n == chain.len) break;
        chain[n] = h;
        n += 1;
    }
    var out: std.ArrayList(u8) = .empty;
    const ns = rt.classNamespace(chain[n - 1]);
    if (ns.len > 0) {
        try out.appendSlice(a, ns);
        try out.append(a, '.');
    }
    var i = n;
    while (i > 0) {
        i -= 1;
        try out.appendSlice(a, rt.className(chain[i]));
        if (i > 0) try out.append(a, '/');
    }
    return out.items;
}

/// The first method called `name` with `params` parameters, or any number if it's null. Looks in
/// parents too.
pub fn findMethod(rt: *const Runtime, class: *Class, name: []const u8, params: ?u32) ?*Method {
    var here: ?*Class = class;
    while (here) |c| : (here = rt.classParent(c)) {
        var it = rt.methods(c);
        while (it.next()) |m| {
            if (!std.mem.eql(u8, rt.methodName(m), name)) continue;
            if (params) |n| if (rt.paramCount(m) != n) continue;
            return m;
        }
    }
    return null;
}

/// Looks in parents too.
pub fn findField(rt: *const Runtime, class: *Class, name: []const u8) ?*Field {
    var here: ?*Class = class;
    while (here) |c| : (here = rt.classParent(c)) {
        if (rt.findField(c, name)) |f| return f;
    }
    return null;
}

/// `Class:Method` splits into its class and method, else null.
pub fn splitMethodName(name: []const u8) ?struct { class: []const u8, method: []const u8 } {
    const colon = std.mem.lastIndexOfScalar(u8, name, ':') orelse return null;
    if (colon == 0 or colon + 1 == name.len) return null;
    return .{ .class = name[0..colon], .method = name[colon + 1 ..] };
}

fn methodCode(rt: *const Runtime, class_name: []const u8, method: []const u8) ?usize {
    const c = findClass(rt, class_name) orelse return null;
    const m = findMethod(rt, c, method, null) orelse return null;
    return rt.methodPointer(m);
}

/// Where `Class:Method` or `Namespace.Class:Method`'s code is, for names in addresses, compiling it
/// first under Mono. Null if it's not a name like that, isn't there, or the runtime isn't running.
pub fn methodAddress(self: *Managed, name: []const u8) ?usize {
    const parts = splitMethodName(name) orelse return null;
    if (!self.running()) return null;
    self.forgetStale();
    {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        if (self.methods.get(name)) |at| return at;
    }
    const seen = self.rt.changes();
    const at = (self.call(methodCode, .{ parts.class, parts.method }) catch return null) orelse return null;
    self.lock.lock();
    defer self.lock.unlock();
    // Something unloaded while it looked, so it may be gone already
    if (self.rt.changes() != seen or self.methods_seen.load(.acquire) != seen) return at;
    const key = gpa.dupe(u8, name) catch return at;
    const entry = self.methods.getOrPut(gpa, key) catch {
        gpa.free(key);
        return at;
    };
    if (entry.found_existing) gpa.free(key);
    entry.value_ptr.* = at;
    return at;
}

/// Like `methodAddress`, but only ones it's already found, so it never waits.
pub fn cachedMethodAddress(self: *Managed, name: []const u8) ?usize {
    _ = splitMethodName(name) orelse return null;
    if (!self.running()) return null;
    self.forgetStale();
    self.lock.lockShared();
    defer self.lock.unlockShared();
    return self.methods.get(name);
}

/// Drops methods' code once the runtime says it could be gone, like a plugin a mod loader unloaded.
fn forgetStale(self: *Managed) void {
    const now = self.rt.changes();
    if (self.methods_seen.load(.acquire) == now) return;
    self.lock.lock();
    defer self.lock.unlock();
    var it = self.methods.iterator();
    while (it.next()) |e| gpa.free(e.key_ptr.*);
    self.methods.clearRetainingCapacity();
    self.methods_seen.store(now, .release);
}

/// Why a `Class:Method` name wasn't found, for address problems. Null if it's not one.
pub fn whyMissing(self: *Managed, name: []const u8) ?[]const u8 {
    _ = splitMethodName(name) orelse return null;
    return switch (self.state.load(.acquire)) {
        .off, .waiting => "the game's C# runtime isn't running",
        .failed => "Wraith can't read this game's C#",
        .running => "there's no class with that method",
    };
}

const testing = std.testing;

test "calls run on the attached thread, one after another" {
    var m: Managed = .{};
    try testing.expectError(error.NotRunning, m.call(struct {
        fn f(_: *const Runtime) void {}
    }.f, .{}));

    try m.startForTest(.{ .mono = .{ .api = undefined } });
    defer m.stop();
    const Work = struct {
        fn threadOf(_: *const Runtime) u32 {
            return std.Thread.getCurrentId();
        }

        fn add(_: *const Runtime, a: u32, b: u32) u32 {
            return a + b;
        }

        fn nested(rt: *const Runtime, self: *Managed) u32 {
            _ = rt;
            // Already on the thread, so this mustn't wait on itself
            return self.call(add, .{ 2, 3 }) catch 0;
        }
    };
    const id = try m.call(Work.threadOf, .{});
    try testing.expect(id != std.Thread.getCurrentId());
    try testing.expectEqual(m.thread_id.load(.acquire), id);
    try testing.expectEqual(7, try m.call(Work.add, .{ 3, 4 }));
    try testing.expectEqual(5, try m.call(Work.nested, .{&m}));
}

test "Class:Method names" {
    const p = splitMethodName("Game.Player:Update").?;
    try testing.expectEqualStrings("Game.Player", p.class);
    try testing.expectEqualStrings("Update", p.method);
    try testing.expectEqual(null, splitMethodName("kernel32.dll!Sleep"));
    try testing.expectEqual(null, splitMethodName("Player:"));
    var m: Managed = .{};
    try testing.expectEqual(null, m.methodAddress("Player:Update"));
    try testing.expectEqualStrings("the game's C# runtime isn't running", m.whyMissing("Player:Update").?);
    try testing.expectEqual(null, m.whyMissing("kernel32.dll"));
}

test "joins a CoreCLR and finds its methods by name" {
    // Started here like a .NET game would, then found the way the game's is
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    _ = tuft_managed.CoreClr.open(gpa, testing.io, .{ .dir = dir, .start = true }) catch |err| switch (err) {
        error.NoDotnet => return error.SkipZigTest,
        else => return err,
    };
    const base = sys.module.findBase(tuft_managed.coreclr_modules[0]) orelse return error.NoCoreClr;

    var m: Managed = .{};
    m.useCoreClr(testing.io, dir);
    m.startOn(.coreclr, base);
    defer m.stop();
    var waited: u32 = 0;
    while (!m.running() and waited < 10_000) : (waited += 10) sys.thread.sleepMs(10);
    try testing.expect(m.running());
    try testing.expectEqual(.coreclr, m.kind().?);
    try testing.expectEqualStrings("CoreCLR", label(m.kind().?));

    const at = m.methodAddress("System.String:IsNullOrEmpty") orelse return error.NoMethod;
    try testing.expectEqual(at, m.cachedMethodAddress("System.String:IsNullOrEmpty").?);
    try testing.expectEqual(null, m.methodAddress("System.String:NoSuchMethod"));
}
