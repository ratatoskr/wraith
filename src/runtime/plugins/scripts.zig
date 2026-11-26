//! The built-in `js` and `lua` kinds, on Salamander's hosts. Pumped once a frame on the render thread,
//! which never waits: a busy tick is skipped. After an await it resumes per `Lanes`.

const std = @import("std");

const core = @import("wraith_core");
const api = @import("wraith_api");
const hosts = @import("salamander_hosts");

const host = @import("../host/root.zig");
const Libraries = @import("../Libraries.zig");
const threads = host.threads;
const Atomic = @import("tuft_arch").atomic.Value;

const sal = api.salamander;
const engine = hosts.engine;
const log = core.log.scoped(.wraith_plugin);
const allocator = std.heap.page_allocator;

const Kind = struct {
    language: hosts.Language,

    pub fn start(self: *Kind, guest: host.wraith.Guest) sal.Plain(host.wraith.PluginKind, "start") {
        const r = Running.create(self.language, guest) catch return error.Failed;
        return sal.Object(host.wraith.Plugin).init(r, running_table);
    }
};

/// One script plugin.
const Running = struct {
    language: hosts.Language,
    name: []u8,
    dir: []u8,
    script: hosts.Script = undefined,
    /// Guards its pump, so stopping waits for one that's running and stops the rest.
    owner: *sal.Owner,
    pump: sal.Task = .{},
    exposed: Exposed = .{},
    /// Where it carries on after an await, kept after it's gone.
    lanes: *Lanes = undefined,

    fn create(language: hosts.Language, guest: host.wraith.Guest) !*Running {
        const r = try allocator.create(Running);
        errdefer allocator.destroy(r);
        r.* = .{ .language = language, .name = try allocator.dupe(u8, guest.name), .dir = undefined, .owner = undefined };
        errdefer allocator.free(r.name);
        r.dir = try allocator.dupe(u8, guest.dir);
        errdefer allocator.free(r.dir);
        r.owner = try sal.host().owner(r.name);
        errdefer r.owner.drain();

        r.lanes = try Lanes.create();
        const schema = if (guest.schema.len > 0) guest.schema else api.wraith_sal;
        var home: [core.manifest.namespace_max]u8 = undefined;
        errdefer r.exposed.deinit();
        r.script = try r.exposed.create(language, allocator, .{ .ctx = r, .resolve = resolve, .read = read }, .{ .ctx = r, .f = report }, r.lanes, schema, core.manifest.namespaceOf(&home, guest.name));
        errdefer r.script.deinit();
        // Before main, which can await too
        try r.lanes.start(r.script, r.owner);
        try r.expose(guest);

        const main = switch (language) {
            .js => "main.js",
            .lua => "main.lua",
        };
        const source = read(r, allocator, main) orelse {
            log.err("{s} has no {s}", .{ r.name, main });
            return error.NoMain;
        };
        defer allocator.free(source);
        r.script.run(source, main) catch |err| {
            r.script.enter();
            defer r.script.leave();
            log.err("{s}: {s}", .{ r.name, r.script.lastError() });
            return err;
        };

        r.pump = try sal.Task.owned(r.owner, r, pumpNow);
        r.schedule();
        return r;
    }

    /// Puts Wraith's areas and what each dependency offers in the `wraith` module.
    fn expose(r: *Running, guest: host.wraith.Guest) !void {
        var services: std.ArrayList(Exposed.Service) = .empty;
        defer services.deinit(allocator);
        for (guest.services) |s| try services.append(allocator, .{ .trait = s.trait, .obj = s.obj });
        try r.exposed.expose(r.script, guest.wraith, guest.schema, false, services.items);
    }

    fn schedule(r: *Running) void {
        host.salamander.renderQueueOf().postTask(r.pump) catch {};
    }

    /// Once a frame. Skipped while another thread's in, since the render thread never waits.
    fn pumpNow(r: *Running) void {
        if (r.script.tryEnter()) {
            defer r.script.leave();
            r.script.pump();
        }
        r.schedule();
    }

    /// Salamander's native modules first, then the plugin's own files, then `Libraries`.
    fn resolve(ctx: ?*anyopaque, buf: []u8, from: []const u8, name: []const u8) ?[]const u8 {
        const r: *Running = @ptrCast(@alignCast(ctx.?));
        if (r.ownFile(buf, from, name)) |own| {
            if (r.exists(own)) return own;
        }
        return resolveLibrary(buf, name, r.languageName()) orelse r.ownFile(buf, from, name);
    }

    fn languageName(r: *const Running) []const u8 {
        return switch (r.language) {
            .js => "js",
            .lua => "lua",
        };
    }

    fn exists(r: *const Running, name: []const u8) bool {
        const io = host.wraith.ioOf() orelse return false;
        var dir = std.Io.Dir.cwd().openDir(io, r.dir, .{}) catch return false;
        defer dir.close(io);
        _ = dir.statFile(io, name, .{}) catch return false;
        return true;
    }

    /// `name` as a file under the plugin's folder.
    fn ownFile(r: *const Running, buf: []u8, from: []const u8, name: []const u8) ?[]const u8 {
        if (r.language == .lua and !std.mem.endsWith(u8, name, ".lua")) {
            // `require("lib.util")` is `lib/util.lua`
            var dotted: [256]u8 = undefined;
            if (name.len + 4 > dotted.len) return null;
            @memcpy(dotted[0..name.len], name);
            std.mem.replaceScalar(u8, dotted[0..name.len], '.', '/');
            @memcpy(dotted[name.len..][0..4], ".lua");
            return hosts.relative(buf, "", dotted[0 .. name.len + 4]);
        }
        return hosts.relative(buf, from, name);
    }

    /// `name` resolved, so it's a library or under the plugin's folder.
    fn read(ctx: ?*anyopaque, gpa: std.mem.Allocator, name: []const u8) ?[]u8 {
        const r: *Running = @ptrCast(@alignCast(ctx.?));
        if (readLibrary(gpa, name, r.languageName())) |text| return text;
        const io = host.wraith.ioOf() orelse return null;
        const path = std.fs.path.join(gpa, &.{ r.dir, name }) catch return null;
        defer gpa.free(path);
        return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20)) catch null;
    }

    fn report(ctx: ?*anyopaque, message: []const u8) void {
        const r: *Running = @ptrCast(@alignCast(ctx.?));
        log.err("{s}: {s}", .{ r.name, message });
    }
};

/// Wraith as a script sees it, a plugin's or a session's.
pub const Exposed = struct {
    /// Finds what its schemas declare, for the `schema` module.
    schema: sal.Object(host.wraith.SchemaArea) = .{},
    /// Its schemas as the script sees them.
    types: ?*const engine.Module = null,
    /// What its schema options point into, kept till `deinit`, after the script's gone.
    arena: ?std.heap.ArenaAllocator = null,
    language: hosts.Language = .js,

    /// A script whose memory and names go through Wraith. `self` has to stay put, `lanes` outlives it.
    /// Text names are looked for in namespace `home` first.
    pub fn create(self: *Exposed, language: hosts.Language, gpa: std.mem.Allocator, resolver: hosts.Resolver, report: hosts.Report, lanes: ?*Lanes, schema: []const u8, home: []const u8) !hosts.Script {
        self.arena = .init(allocator);
        self.language = language;
        const options = try host.schemas.scriptOptions(self.arena.?.allocator(), schema, home);
        return hosts.create(language, .{
            .gpa = gpa,
            .resolver = resolver,
            .report = report,
            .policy = .{ .how = policy },
            .resume_on = if (lanes) |l| .{ .ctx = l, .run = Lanes.resumeHere } else null,
            .schema_options = options,
            .locator = @import("wraith_sdk").salamander.locator(self, locate),
        });
    }

    /// Once its script's gone.
    pub fn deinit(self: *Exposed) void {
        if (self.arena) |*a| a.deinit();
        self.arena = null;
    }

    /// Puts its namespaces, Wraith's areas and `services` in the `wraith` module. With `bare`, like in
    /// Workbench scripts, they're globals instead.
    pub fn expose(self: *Exposed, script: hosts.Script, wraith: @FieldType(host.wraith.Guest, "wraith"), schema: []const u8, bare: bool, services: []const Service) !void {
        const types = try script.schema(if (schema.len > 0) schema else api.wraith_sal);
        self.types = types;
        self.schema = sal.invoke(host.wraith.Wraith, "schema", wraith, .{});
        if (bare) inline for (host.wraith.Wraith.salamander.methods) |m| {
            const area = sal.invoke(host.wraith.Wraith, m.name, wraith, .{});
            try script.expose(m.name, .{ .name = m.name, .schema = types, .trait = @TypeOf(area).salamander.name, .obj = .of(area) });
        };
        var roots: std.ArrayList(engine.Export) = .empty;
        defer roots.deinit(allocator);
        try roots.append(allocator, .{ .name = "", .schema = types, .trait = host.wraith.Wraith.salamander.name, .obj = .of(wraith) });
        for (services) |s| try roots.append(allocator, .{ .name = "", .schema = types, .trait = s.trait, .obj = s.obj });
        try script.namespaces(module_name, roots.items, bare);
        try script.extend(types, host.wraith.Hooks.salamander.name, switch (self.language) {
            .js => @embedFile("hooks.js"),
            .lua => @embedFile("hooks.lua"),
        });
    }

    /// What scripts import, like `import { Wraith } from "wraith"`.
    pub const module_name = "wraith";

    /// A plugin's [Service] object, by its trait's full name.
    pub const Service = struct { trait: []const u8, obj: sal.AnyObject };

    fn locate(ctx: ?*anyopaque, name: []const u8) anyerror!usize {
        const self: *Exposed = @ptrCast(@alignCast(ctx.?));
        return self.schema.address(name);
    }
};

/// Where shared libraries resolve to. Not a path, since `relative` never starts one with `@`.
const library_prefix = "@library/";

/// A library shared through `Libraries`, like the runtime's `ce`, by what `readLibrary` takes.
pub fn resolveLibrary(buf: []u8, name: []const u8, language: []const u8) ?[]const u8 {
    if (!api.validLibraryName(name)) return null;
    _ = Libraries.global.get(name, language, &.{}) catch return null;
    return std.fmt.bufPrint(buf, library_prefix ++ "{s}", .{name}) catch null;
}

/// Its text, if `name` is what `resolveLibrary` gave.
pub fn readLibrary(gpa: std.mem.Allocator, name: []const u8, language: []const u8) ?[]u8 {
    if (!std.mem.startsWith(u8, name, library_prefix)) return null;
    const lib = name[library_prefix.len..];
    // Asked for its size first, and again if it grew in between
    var len = Libraries.global.get(lib, language, &.{}) catch return null;
    while (true) {
        const buf = gpa.alloc(u8, len) catch return null;
        const got = Libraries.global.get(lib, language, buf) catch {
            gpa.free(buf);
            return null;
        };
        if (got == len) return buf;
        gpa.free(buf);
        len = got;
    }
}

/// Neither frame thread waits on a script, so a script never holds up the game. Others do.
pub fn policy(_: ?*anyopaque) engine.Gate.How {
    return if (host.frame.onRenderThread() or host.frame.onGameThread()) .try_ else .block;
}

/// Where a script resumes after an awaited native promise: one queue per thread, pumped there.
/// Kept for good, since a promise can settle after its script's gone.
pub const Lanes = struct {
    lanes: [3]Lane,

    const Lane = struct {
        queue: sal.Queue,
        thread: threads.Thread,
        script: ?hosts.Script = null,
        /// Owned by the script's owner, so it does nothing once the script's going.
        pump: sal.Task = .{},
        scheduled: Atomic(bool) = .init(false),

        fn schedule(lane: *Lane) void {
            if (lane.pump.table == null) return;
            if (lane.scheduled.swap(true, .acq_rel)) return;
            // Nothing polls a thread without frames, so a worker does it then
            const where: threads.Thread = if (threads.reachable(lane.thread)) lane.thread else .worker;
            threads.post(where, lane.pump) catch lane.scheduled.store(false, .release);
        }

        fn pumpNow(lane: *Lane) void {
            lane.scheduled.store(false, .release);
            const script = lane.script orelse return;
            // The frame threads never wait on a script, so they try again at the next frame or tick
            if (!script.pumpQueue(lane.queue, lane.thread == .worker or !threads.reachable(lane.thread))) lane.schedule();
        }
    };

    pub fn create() !*Lanes {
        const self = try std.heap.page_allocator.create(Lanes);
        errdefer std.heap.page_allocator.destroy(self);
        inline for (&self.lanes, .{ threads.Thread.render, .game, .worker }) |*l, t| {
            l.* = .{ .queue = sal.host().queue() catch return error.OutOfMemory, .thread = t };
        }
        return self;
    }

    /// Once it's running, so it can be pumped. Its pumps go with `owner`.
    pub fn start(self: *Lanes, script: hosts.Script, owner: *sal.Owner) !void {
        for (&self.lanes) |*l| {
            l.script = script;
            l.pump = try sal.Task.owned(owner, l, Lane.pumpNow);
        }
    }

    fn resumeHere(ctx: ?*anyopaque, task: sal.Task) void {
        const self: *Lanes = @ptrCast(@alignCast(ctx.?));
        const lane = &self.lanes[@backingInt(threads.here())];
        lane.queue.postTask(task) catch return log.err("A script couldn't carry on after an await: out of memory", .{});
        lane.schedule();
    }
};

const RunningImpl = struct {
    pub fn stop(r: *Running) void {
        // Out of anything it's stuck in, and its pump's done for good
        r.script.interrupt();
        r.owner.drain();
        r.script.deinit();
        r.exposed.deinit();
    }

    pub fn unload(r: *Running) void {
        allocator.free(r.name);
        allocator.free(r.dir);
        allocator.destroy(r);
    }

    pub fn module(_: *Running) usize {
        return 0;
    }

    pub fn serviceFor(r: *Running, trait: []const u8) sal.Plain(host.wraith.Plugin, "serviceFor") {
        const types = r.exposed.types orelse return .{};
        // Exported by its own name, like `Tally` for `Tally.Tally`
        const export_name = trait[if (std.mem.lastIndexOfScalar(u8, trait, '.')) |d| d + 1 else 0..];
        return r.script.take(export_name, types, trait) catch {
            log.err("{s}: {s}", .{ r.name, r.script.lastError() });
            return .{};
        };
    }
};

var js: Kind = .{ .language = .js };
var lua: Kind = .{ .language = .lua };
var running_table: *const sal.Table(host.wraith.Plugin) = undefined;
var provided = std.atomic.Value(bool).init(false);

/// Provides both kinds, once for the process, owned by the runtime.
pub fn provide() void {
    if (provided.swap(true, .acq_rel)) return;
    const h = sal.host();
    const owner = h.owner("wraith.scripts") catch return provided.store(false, .release);
    running_table = h.adopt(host.wraith.Plugin, sal.implement(host.wraith.Plugin, RunningImpl), owner) catch return provided.store(false, .release);
    inline for (.{ .{ "js", &js }, .{ "lua", &lua } }) |k| provideKind(k[0], k[1], owner);
}

fn provideKind(comptime name: []const u8, kind: *Kind, owner: *sal.Owner) void {
    const h = sal.host();
    const obj = sal.Object(host.wraith.PluginKind).init(kind, sal.implement(host.wraith.PluginKind, Kind));
    const owned = h.own(obj, owner) catch return;
    h.provide("wraith.kind." ++ name, 1, owned) catch |err| {
        log.err("Couldn't provide the {s} plugin kind: {t}", .{ name, err });
    };
}
