//! The built-in `js` and `lua` kinds, on Salamander's hosts. A script plugin's folder has `main.js` or
//! `main.lua`, and imports Wraith's areas from the `wraith` module, like
//! `import { settings } from "wraith"` or `require("wraith").settings`.
//!
//! Each runs its main file as it starts, then gets pumped once a frame on the render thread, which
//! never waits for it. Other threads calling in wait their turn.

const std = @import("std");

const core = @import("wraith_core");
const api = @import("wraith_api");
const hosts = @import("salamander_hosts");
const mem = @import("tuft_mem");

const host = @import("../host/root.zig");
const Libraries = @import("../Libraries.zig");

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
    /// Finds what its schemas declare, for the `schema` module.
    schema: sal.Object(host.wraith.SchemaArea) = .{},
    /// Its schemas as the script sees them, for taking its services.
    types: ?*const engine.Module = null,

    fn create(language: hosts.Language, guest: host.wraith.Guest) !*Running {
        const r = try allocator.create(Running);
        errdefer allocator.destroy(r);
        r.* = .{ .language = language, .name = try allocator.dupe(u8, guest.name), .dir = undefined, .owner = undefined };
        errdefer allocator.free(r.name);
        r.dir = try allocator.dupe(u8, guest.dir);
        errdefer allocator.free(r.dir);
        r.owner = try sal.host().owner(r.name);
        errdefer r.owner.drain();

        r.script = try hosts.create(language, .{
            .gpa = allocator,
            .resolver = .{ .ctx = r, .resolve = resolve, .read = read },
            .report = .{ .ctx = r, .f = report },
            .policy = .{ .how = policy },
            .schema_options = api.sal_options,
            .locator = .{ .ctx = r, .address = locate, .read = readMemory, .write = writeMemory },
        });
        errdefer r.script.deinit();
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

    /// Wraith's areas, as the `wraith` module. Its schemas are in scope too, so it can type things like
    /// `salamander.fn("Player.heal", f)` by what they declare. Each plugin it depends on is a module
    /// too, by its name, with what it offers, like `import { Freecam } from "freecam"`.
    fn expose(r: *Running, guest: host.wraith.Guest) !void {
        const text = guest.schema;
        const types = try r.script.schema(if (text.len > 0) text else api.wraith_sal);
        r.types = types;
        r.schema = sal.invoke(host.wraith.Wraith, "schema", guest.wraith, .{});
        const methods = host.wraith.Wraith.salamander.methods;
        var exports: [methods.len]engine.Export = undefined;
        inline for (methods, 0..) |m, i| {
            const area = sal.invoke(host.wraith.Wraith, m.name, guest.wraith, .{});
            exports[i] = .{ .name = m.name, .schema = types, .trait = @TypeOf(area).salamander.name, .obj = .of(area) };
        }
        try r.script.module("wraith", &exports);

        // The loader lists each plugin's services together
        var services: std.ArrayList(engine.Export) = .empty;
        defer services.deinit(allocator);
        var i: usize = 0;
        while (i < guest.services.len) {
            const plugin = guest.services[i].plugin;
            services.clearRetainingCapacity();
            while (i < guest.services.len and std.mem.eql(u8, guest.services[i].plugin, plugin)) : (i += 1) {
                const s = guest.services[i];
                try services.append(allocator, .{ .name = s.trait, .schema = types, .trait = s.trait, .obj = s.obj });
            }
            try r.script.module(plugin, services.items);
        }
    }

    fn locate(ctx: ?*anyopaque, name: []const u8) anyerror!usize {
        const r: *Running = @ptrCast(@alignCast(ctx.?));
        return r.schema.address(name);
    }

    fn readMemory(_: ?*anyopaque, address: usize, out: []u8) bool {
        mem.Memory.local.read(address, out) catch return false;
        return true;
    }

    fn writeMemory(_: ?*anyopaque, address: usize, bytes: []const u8) bool {
        mem.Memory.local.write(address, bytes) catch return false;
        return true;
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

    /// Salamander's native modules, like `wraith`, come first. Then the plugin's own files, then
    /// libraries shared through `Libraries`, like the runtime's `ce`.
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

/// The render thread never waits on a script. Others do.
pub fn policy(_: ?*anyopaque) engine.Gate.How {
    return if (host.frame.onRenderThread()) .try_ else .block;
}

const RunningImpl = struct {
    pub fn stop(r: *Running) void {
        // Out of anything it's stuck in, and its pump's done for good
        r.script.interrupt();
        r.owner.drain();
        r.script.deinit();
    }

    pub fn unload(r: *Running) void {
        allocator.free(r.name);
        allocator.free(r.dir);
        allocator.destroy(r);
    }

    pub fn module(_: *Running) usize {
        return 0;
    }

    pub fn service(r: *Running, trait: []const u8) sal.Plain(host.wraith.Plugin, "service") {
        const types = r.types orelse return .{};
        return r.script.take(trait, types, trait) catch {
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
