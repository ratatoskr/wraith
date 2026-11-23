//! Loads plugins, one folder each, each run by a `PluginKind`. Finding them is in `plugins/discovery.zig`,
//! loading and unloading in `plugins/lifecycle.zig`, and the worker that runs jobs in `plugins/Jobs.zig`.

const PluginLoader = @This();

const std = @import("std");

const core = @import("wraith_core");
const tuft_sys = @import("tuft_sys");
const Atomic = @import("tuft_arch").atomic.Value;
const Text = @import("tuft_text").Text;
const memory = @import("tuft_mem");

const Known = @import("plugins/Known.zig");
const Jobs = @import("plugins/Jobs.zig");
const discovery = @import("plugins/discovery.zig");
const lifecycle = @import("plugins/lifecycle.zig");

const log = core.log.scoped(.wraith_runtime);

pub const Loaded = @import("plugins/Loaded.zig");
pub const State = Known.State;
pub const Info = Known.Info;
pub const About = Known.About;
pub const Op = Jobs.Op;
pub const Job = Jobs.Job;

allocator: std.mem.Allocator,
io: std.Io,
plugins_dir: []const u8,
/// Read on each scan. Its plugins win over installed ones.
dev_file: []const u8,
dev: std.ArrayList(discovery.Dev) = .empty,
/// How many dev plugins the last scan found. Any thread.
dev_count: Atomic(u32) = .init(0),
copies_dir: []const u8,
cache_dir: []const u8,
config_dir: []const u8,
game_config_dir: []const u8,
executable: Text(260) = .{},
game_id: Text(64) = .{},
/// Like `unity`, and its variant like `IL2CPP`. Empty if it's not one Wraith knows.
game_engine: Text(32) = .{},
game_engine_variant: Text(32) = .{},
known: Known.List = .{},
op_lock: tuft_sys.sync.RwLock = .{},
jobs: Jobs = .{},
/// Turned off by the user, while `start` runs. A plugin that needs one fails instead of loading it.
skipping: []const []const u8 = &.{},

/// The game, for which plugins and projects are for it.
pub fn here(self: *const PluginLoader) core.manifest.Here {
    const nonEmpty = struct {
        fn of(text: []const u8) ?[]const u8 {
            return if (text.len > 0) text else null;
        }
    }.of;
    return .{
        .id = nonEmpty(self.game_id.get()),
        .exe = self.executable.get(),
        .game_engine = nonEmpty(self.game_engine.get()),
        .game_engine_variant = nonEmpty(self.game_engine_variant.get()),
    };
}

pub const Paths = struct {
    plugins: []const u8,
    dev_plugins: []const u8,
    copies: []const u8,
    cache: []const u8,
    config: []const u8,
    game_config: []const u8,
};

/// Takes ownership of the paths.
pub fn init(allocator: std.mem.Allocator, io: std.Io, paths: Paths) PluginLoader {
    var self: PluginLoader = .{
        .allocator = allocator,
        .io = io,
        .plugins_dir = paths.plugins,
        .dev_file = paths.dev_plugins,
        .copies_dir = paths.copies,
        .cache_dir = paths.cache,
        .config_dir = paths.config,
        .game_config_dir = paths.game_config,
    };
    var buf: [260]u8 = undefined;
    if (memory.Module.main().name(&buf)) |exe| self.executable.set(exe);
    // Built-in kinds, found through the registry like any plugin's
    @import("plugins/native.zig").provide();
    @import("plugins/scripts.zig").provide();
    return self;
}

pub fn deinit(self: *PluginLoader) void {
    self.jobs.stop();
    self.op_lock.lock();
    defer self.op_lock.unlock();
    var i = self.known.items.items.len;
    while (i > 0) {
        i -= 1;
        if (self.known.items.items[i].loaded != null) lifecycle.unloadKnown(self, self.known.items.items[i]);
    }
    for (self.known.items.items) |k| k.destroy(self.allocator);
    self.known.items.deinit(self.allocator);
    discovery.clearDev(self);
    self.dev.deinit(self.allocator);
    self.allocator.free(self.dev_file);
    self.allocator.free(self.plugins_dir);
    self.allocator.free(self.copies_dir);
    self.allocator.free(self.cache_dir);
    self.allocator.free(self.config_dir);
    self.allocator.free(self.game_config_dir);
}

/// Finds and loads plugins, before anything else uses the loader.
pub fn start(self: *PluginLoader, skip: []const []const u8) !void {
    self.op_lock.lock();
    defer self.op_lock.unlock();
    try discovery.scan(self);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(self.allocator);
    {
        self.known.lock.lockShared();
        defer self.known.lock.unlockShared();
        for (self.known.items.items) |k| {
            if (k.state != .unloaded) continue;
            if (!k.auto_load) {
                log.info("Not loading plugin {s}: its wraith.json turns off autoLoad", .{k.name});
                continue;
            }
            try names.append(self.allocator, k.name);
        }
    }
    self.skipping = skip;
    defer self.skipping = &.{};
    for (names.items) |name| {
        if (discovery.isListed(skip, name)) {
            log.info("Skipping disabled plugin {s}", .{name});
            continue;
        }
        _ = lifecycle.loadNow(self, name) catch |err| switch (err) {
            // Something that needed it loaded it already
            error.AlreadyLoaded => {},
            // Already logged by `loadNow`
            error.UnsupportedGame, error.UnsupportedArch, error.NeedsNewerWraith, error.Revoked, error.OutdatedApi, error.KindNotFound => {},
            error.MissingDependency, error.DependencyOff, error.DependencyFailed, error.DependencyTooOld, error.DependencyCycle => {},
            else => log.err("Couldn't load plugin {s}: {t}", .{ name, err }),
        };
    }
}

pub fn load(self: *PluginLoader, name: []const u8) !Job {
    return self.job(.load, name);
}

pub fn unload(self: *PluginLoader, name: []const u8) !Job {
    return self.job(.unload, name);
}

pub fn reload(self: *PluginLoader, name: []const u8) !Job {
    return self.job(.reload, name);
}

pub fn devCount(self: *const PluginLoader) u32 {
    return self.dev_count.load(.acquire);
}

pub fn rescan(self: *PluginLoader) !Job {
    return self.job(.rescan, "");
}

/// Reloading a plugin reloads what its kinds run, and what depends on it, too.
pub fn job(self: *PluginLoader, op: Op, name: []const u8) !Job {
    return self.jobs.add(op, name);
}

/// Returns how many were copied.
pub fn list(self: *PluginLoader, out: []Info) usize {
    return @min(self.known.snapshotAs(Info, out, Known.infoOf), out.len);
}

pub fn count(self: *PluginLoader) usize {
    self.known.lock.lockShared();
    defer self.known.lock.unlockShared();
    var n: usize = 0;
    for (self.known.items.items) |k| {
        if (k.loaded != null) n += 1;
    }
    return n;
}

pub fn busy(self: *PluginLoader) bool {
    return self.jobs.busy();
}

/// Tests and startup only, a job could unload it right after.
pub fn find(self: *PluginLoader, name: []const u8) ?*Loaded {
    self.known.lock.lockShared();
    defer self.known.lock.unlockShared();
    const k = Known.find(&self.known, name) orelse return null;
    return k.loaded;
}

pub fn stateOf(self: *PluginLoader, name: []const u8) ?struct { state: State, last_error: ?anyerror } {
    self.known.lock.lockShared();
    defer self.known.lock.unlockShared();
    const k = Known.find(&self.known, name) orelse return null;
    return .{ .state = k.state, .last_error = k.last_error };
}

const tests = struct {
    const testing = std.testing;

    const Install = @import("testing/Install.zig");

    test "list shows every plugin" {
        const options = @import("test_options");
        var install: Install = undefined;
        try install.init(.{ .plugins = &.{.{ "fixture", options.fixture_plugin }} });
        defer install.deinit();
        const loader = &install.loader;
        try loader.start(&.{});

        const loaded = install.info("fixture").?;
        try testing.expectEqual(.loaded, loaded.state);
        try testing.expectEqualStrings(loader.find("fixture").?.copy_dir, loaded.copy_dir.get());
        try testing.expect(std.mem.endsWith(u8, loaded.source_dir.get(), "fixture"));
        try testing.expect(loaded.library != 0);

        // Jobs run in order, so waiting on the last waits for all
        _ = try loader.unload("fixture");
        const load_job = try loader.load("fixture");
        const unload_job = try loader.unload("fixture");
        try unload_job.wait();
        try load_job.wait();
        try testing.expect(!loader.busy());

        const unloaded = install.info("fixture").?;
        try testing.expectEqual(.unloaded, unloaded.state);
        try testing.expectEqual(0, unloaded.library);
        try (try loader.load("fixture")).wait();
        try testing.expectEqual(.loaded, install.info("fixture").?.state);
    }

    test "plugins share Salamander objects, which stop when the plugin unloads" {
        const options = @import("test_options");
        const sal = @import("salamander_runtime");
        // The fixture's own schema, so both sides agree on it
        const Counter = @import("wraith_test_fixture").FixtureCounter;
        var install: Install = undefined;
        try install.init(.{ .plugins = &.{.{ "fixture", options.fixture_plugin }} });
        defer install.deinit();
        const loader = &install.loader;
        try loader.start(&.{});

        const counter = sal.host().get(Counter, "fixture.counter", 1).?;
        try testing.expectEqual(1, counter.next());
        try testing.expectEqual(2, counter.next());

        // Its code's gone, but the table's the host's, so calls give zero rather than crash
        try (try loader.unload("fixture")).wait();
        try testing.expectEqual(0, counter.next());
        try testing.expectEqual(null, sal.host().get(Counter, "fixture.counter", 1));

        // Loaded again, it can provide the name again
        try (try loader.load("fixture")).wait();
        try testing.expectEqual(1, sal.host().get(Counter, "fixture.counter", 1).?.next());
    }

    test "plugins can run through a kind another plugin provides" {
        const options = @import("test_options");
        const sal = @import("salamander_runtime");
        const Stats = @import("wraith_test_fixture").FixtureKindStats;
        var install: Install = undefined;
        try install.init(.{ .plugins = &.{.{ "fixture", options.fixture_plugin }} });
        defer install.deinit();
        try install.addScript("guest", "fixture");
        try install.pluginManifest("guest", "\"provider\": \"fixture\", \"depends\": [\"fixture\"]");
        const loader = &install.loader;
        try loader.start(&.{});

        try testing.expectEqual(.loaded, install.info("guest").?.state);
        const stats = sal.host().get(Stats, "fixture.kind", 1).?;
        try testing.expectEqual(1, stats.starts());
        try testing.expect(stats.sawWraith());
        // Scripts and the like have no module
        try testing.expectEqual(0, install.info("guest").?.library);

        try (try loader.unload("guest")).wait();
        try testing.expectEqual(1, stats.stops());
        try testing.expectEqual(1, stats.unloads());

        // Its kind's maker can't go first, so unloading it takes the guest too
        try (try loader.load("guest")).wait();
        try testing.expectEqual(2, stats.starts());
        try (try loader.unload("fixture")).wait();
        try testing.expectEqual(.unloaded, install.info("guest").?.state);
    }

    test "script plugins run on Salamander, with Wraith's areas" {
        const host = @import("host/root.zig");
        const Registry = @import("settings/Registry.zig");
        const r = try Registry.create(testing.allocator, .{});
        defer r.destroy();
        host.settings.setRegistry(r);
        defer host.settings.setRegistry(null);
        host.wraith.setIo(testing.io);
        defer host.wraith.setIo(null);
        host.frame.setFrames(true);
        defer host.frame.setFrames(false);
        // Shared source that isn't in either plugin's folder, so require asks Wraith for it
        const Libraries = @import("Libraries.zig");
        Libraries.global = .init(testing.allocator);
        defer Libraries.global.deinit();
        try Libraries.global.add(.{ .name = "shared", .language = "js", .source = "export function double(x) { return x * 2; }" });
        try Libraries.global.add(.{ .name = "shared", .language = "lua", .source = "return { double = function(x) return x * 2 end }" });

        var install: Install = undefined;
        try install.init(.{});
        defer install.deinit();
        const files = [_]struct { []const u8, []const u8, []const u8, []const u8 }{
            .{
                "hello_js", "js", "main.js",
                \\import { settings, frame, log } from "wraith";
                \\import { double } from "shared";
                \\const fov = settings.add({ id: "fov", kind: "number", min: 60, max: 120, has_default: true, default_value: { number: 90 } }, null);
                \\let ticks = 0;
                \\frame.onFrame(() => { ticks++; fov.set({ number: double(30) + ticks }); });
                \\frame.post(() => log.info("posted"));
            },
            .{
                "hello_lua", "lua", "main.lua",
                \\local wraith = require("wraith")
                \\local shared = require("shared")
                \\wraith.settings:add({ id = "speed", kind = "toggle", has_default = true, default_value = { toggle = true } }, nil)
                \\local count = wraith.settings:add({ id = "count", kind = "number", min = 0, max = 100 }, nil)
                \\wraith.frame:post(function() count:set({ number = shared.double(21) }) end)
            },
            .{ "broken", "js", "main.js", "throw new Error('nope');" },
        };
        for (files) |f| {
            try install.addScript(f[0], f[1]);
            const path = try std.fmt.allocPrint(testing.allocator, "plugins/{s}/{s}", .{ f[0], f[2] });
            defer testing.allocator.free(path);
            try install.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = f[3] });
        }
        const loader = &install.loader;
        try loader.start(&.{});

        try testing.expectEqual(.loaded, install.info("hello_js").?.state);
        try testing.expectEqual(90, r.get(r.find("hello_js.fov").?).number);
        try testing.expectEqual(.loaded, install.info("hello_lua").?.state);
        try testing.expect(r.get(r.find("hello_lua.speed").?).toggle);
        try testing.expectEqual(.failed, install.info("broken").?.state);

        // A frame runs what they posted and their ticks
        host.frame.run();
        try testing.expectEqual(61, r.get(r.find("hello_js.fov").?).number);
        try testing.expectEqual(42, r.get(r.find("hello_lua.count").?).number);
        host.frame.run();
        try testing.expectEqual(62, r.get(r.find("hello_js.fov").?).number);

        // Its settings go with it, and come back with it
        try (try loader.unload("hello_js")).wait();
        try testing.expectEqual(null, r.find("hello_js.fov"));
        try (try loader.load("hello_js")).wait();
        try testing.expect(r.find("hello_js.fov") != null);
    }

    noinline fn jsTarget(a: i32, b: i32) callconv(.c) i32 {
        var x = a;
        asm volatile (""
            : [x] "+r" (x),
        );
        return x + b;
    }

    noinline fn luaTarget(a: i32, b: i32) callconv(.c) i32 {
        var x = a;
        asm volatile (""
            : [x] "+r" (x),
        );
        return x * b;
    }

    test "script plugins detour native functions and call on" {
        const host = @import("host/root.zig");
        try @import("tuft_hook").init(testing.allocator);
        defer @import("tuft_hook").deinit();
        host.wraith.setIo(testing.io);
        defer host.wraith.setIo(null);

        var install: Install = undefined;
        try install.init(.{});
        defer install.deinit();
        const js = try std.fmt.allocPrint(testing.allocator,
            \\import {{ hooks }} from "wraith";
            \\import {{ fn, native }} from "salamander";
            \\const sig = "fn i32 (i32 a, i32 b)";
            \\let original;
            \\const h = hooks.detour({d}, sig, fn(sig, (a, b) => original(a, b) * 10 + hooks.context()), {{ context: 7 }});
            \\original = native(sig, h.original());
        , .{@intFromPtr(&jsTarget)});
        defer testing.allocator.free(js);
        const lua = try std.fmt.allocPrint(testing.allocator,
            \\local wraith = require("wraith")
            \\local sal = require("salamander")
            \\local sig = "fn i32 (i32 a, i32 b)"
            \\local original
            \\local h = wraith.hooks:detour({d}, sig, sal.fn(sig, function(a, b) return original(a, b) + 1 end), {{}})
            \\original = sal.native(sig, h:original())
        , .{@intFromPtr(&luaTarget)});
        defer testing.allocator.free(lua);
        const files = [_]struct { []const u8, []const u8, []const u8, []const u8 }{
            .{ "hook_js", "js", "main.js", js },
            .{ "hook_lua", "lua", "main.lua", lua },
        };
        for (files) |f| {
            try install.addScript(f[0], f[1]);
            const path = try std.fmt.allocPrint(testing.allocator, "plugins/{s}/{s}", .{ f[0], f[2] });
            defer testing.allocator.free(path);
            try install.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = f[3] });
        }
        const loader = &install.loader;
        try loader.start(&.{});
        try testing.expectEqual(.loaded, install.info("hook_js").?.state);
        try testing.expectEqual(.loaded, install.info("hook_lua").?.state);

        try testing.expectEqual(57, jsTarget(2, 3));
        try testing.expectEqual(7, luaTarget(2, 3));

        // Gone with their plugins
        try (try loader.unload("hook_js")).wait();
        try (try loader.unload("hook_lua")).wait();
        try testing.expectEqual(5, jsTarget(2, 3));
        try testing.expectEqual(6, luaTarget(2, 3));
    }

    /// x times `n`, found by the named hook test's schema from the bytes it starts with. The nops leave
    /// room for a hook.
    fn Planted(comptime n: u8) type {
        const x64 = std.fmt.comptimePrint(
            \\.intel_syntax noprefix
            \\mov eax, 0x7E57F0{x:0>2}
            \\imul eax, ecx, {d}
            \\nop dword ptr [rax + rax * 1 + 0]
            \\nop dword ptr [rax + rax * 1 + 0]
            \\ret
            \\.att_syntax prefix
        , .{ n, n });
        const x86 = std.fmt.comptimePrint(
            \\.intel_syntax noprefix
            \\mov eax, 0x7E57F0{x:0>2}
            \\mov ecx, [esp + 4]
            \\imul eax, ecx, {d}
            \\nop dword ptr [eax + eax * 1 + 0]
            \\nop dword ptr [eax + eax * 1 + 0]
            \\ret
            \\.att_syntax prefix
        , .{ n, n });
        return struct {
            fn code() callconv(.naked) void {
                asm volatile (if (@sizeOf(usize) == 8) x64 else x86);
            }

            fn call(x: i32) i32 {
                const f: *const fn (i32) callconv(.c) i32 = @ptrCast(&code);
                return f(x);
            }
        };
    }

    /// Its code ends with 0x0BADC0DE, which the test's schema reads as a static.
    fn answerCode() callconv(.naked) void {
        asm volatile (
            \\.intel_syntax noprefix
            \\mov eax, 0x7E57F0AB
            \\ret
            \\.long 0x0BADC0DE
            \\.att_syntax prefix
        );
    }

    /// Laid out like the test schema's `Manager`.
    const Manager = extern struct {
        vt: *const [2]usize,
        health: f32 = 0,
        level: u32 = 0,

        fn bump(self: *Manager) callconv(.c) void {
            self.level += 1;
        }
    };

    test "script plugins use game code their schemas declare, live, and share them" {
        const host = @import("host/root.zig");
        try @import("tuft_hook").init(testing.allocator);
        defer @import("tuft_hook").deinit();
        host.wraith.setIo(testing.io);
        defer host.wraith.setIo(null);
        const four = Planted(4);
        const five = Planted(5);
        const six = Planted(6);
        try testing.expectEqual(8, four.call(2));
        try testing.expectEqual(10, five.call(2));
        try testing.expectEqual(12, six.call(2));
        std.mem.doNotOptimizeAway(&answerCode);
        const vtable: [2]usize = .{ 0, @intFromPtr(&Manager.bump) };
        var js_manager: Manager = .{ .vt = &vtable };
        var lua_manager: Manager = .{ .vt = &vtable };

        var install: Install = undefined;
        try install.init(.{});
        defer install.deinit();
        const io = testing.io;
        try install.addScript("named_js", "js");
        try install.tmp.dir.createDirPath(io, "plugins/named_js/schemas");
        try install.tmp.dir.writeFile(io, .{ .sub_path = "plugins/named_js/schemas/game.sal", .data =
            \\[Sig("B8 04 F0 57 7E")] i32 four(i32 x);
            \\[Sig("B8 05 F0 57 7E")] i32 five(i32 x);
            \\[Sig("B8 AB F0 57 7E C3", Offset(6))] static u32 answer;
            \\struct Entity { usize vt; [Virtual(1)] void bump(); }
            \\struct Manager : Entity {
            \\    f32 health;
            \\    u32 level;
            \\    [Sig("B8 06 F0 57 7E")] static i32 six(i32 x);
            \\}
        });
        const js = try std.fmt.allocPrint(testing.allocator,
            \\import {{ hooks, schema as declared }} from "wraith";
            \\import {{ fn, native }} from "salamander";
            \\import {{ Manager, default as game }} from "schema";
            \\let original;
            \\const h = hooks.named("four", fn("four", (x) => original(x) + 1), {{}});
            \\original = native("four", h.original());
            \\if (native("five", declared.address("five"))(3) !== 15) throw new Error("five");
            \\const m = Manager.at({d});
            \\m.level = game.answer;
            \\m.bump();
            \\m.health = Manager.six(2) + m.six(1);
        , .{@intFromPtr(&js_manager)});
        defer testing.allocator.free(js);
        try install.tmp.dir.writeFile(io, .{ .sub_path = "plugins/named_js/main.js", .data = js });
        // Its schemas come from the one it depends on
        try install.tmp.dir.createDirPath(io, "plugins/named_lua");
        try install.pluginManifest("named_lua", "\"provider\": \"lua\", \"depends\": [\"named_js\"]");
        const lua = try std.fmt.allocPrint(testing.allocator,
            \\local wraith = require("wraith")
            \\local sal = require("salamander")
            \\local game = require("schema")
            \\local original
            \\local h = wraith.hooks:named("five", sal.fn("five", function(x) return original(x) * 2 end), {{}})
            \\original = sal.native("five", h:original())
            \\local m = game.Manager.at({d})
            \\m.level = game.answer
            \\m:bump()
            \\m.health = game.Manager.six(2) + m:six(1)
        , .{@intFromPtr(&lua_manager)});
        defer testing.allocator.free(lua);
        try install.tmp.dir.writeFile(io, .{ .sub_path = "plugins/named_lua/main.lua", .data = lua });
        const loader = &install.loader;
        try loader.start(&.{});
        try testing.expectEqual(.loaded, install.info("named_js").?.state);
        try testing.expectEqual(.loaded, install.info("named_lua").?.state);

        try testing.expectEqual(9, four.call(2));
        try testing.expectEqual(20, five.call(2));
        for ([_]*Manager{ &js_manager, &lua_manager }) |m| {
            try testing.expectEqual(0x0BADC0DF, m.level);
            try testing.expectEqual(18, m.health);
        }

        try (try loader.unload("named_lua")).wait();
        try (try loader.unload("named_js")).wait();
        try testing.expectEqual(8, four.call(2));
        try testing.expectEqual(10, five.call(2));
    }

    test "plugins offer [Service] traits to the plugins that depend on them" {
        const host = @import("host/root.zig");
        host.wraith.setIo(testing.io);
        defer host.wraith.setIo(null);
        const Out = extern struct { total: u32 = 0, count: u32 = 0, later: u32 = 0, seen: u32 = 0 };
        var out: Out = .{};

        var install: Install = undefined;
        try install.init(.{});
        defer install.deinit();
        const io = testing.io;
        try install.addScript("tally", "js");
        try install.tmp.dir.createDirPath(io, "plugins/tally/schemas");
        try install.tmp.dir.writeFile(io, .{ .sub_path = "plugins/tally/schemas/tally.sal", .data =
            \\[Service] trait Tally { u32 add(u32 n); u32 count(); async u32 later(u32 n); void watch(keep Watcher w); }
            \\trait Watcher { void saw(u32 n); }
            \\struct Out { u32 total; u32 count; u32 later; u32 seen; }
        });
        try install.tmp.dir.writeFile(io, .{ .sub_path = "plugins/tally/main.js", .data =
            \\let total = 0, calls = 0, watcher = null;
            \\export const Tally = {
            \\    add(n) { calls++; total += n; if (watcher) watcher.saw(total); return total; },
            \\    count() { return calls; },
            \\    async later(n) { return n * 2; },
            \\    watch(w) { watcher = w; },
            \\};
        });
        try install.tmp.dir.createDirPath(io, "plugins/counter");
        try install.pluginManifest("counter", "\"provider\": \"lua\", \"depends\": [\"tally\"]");
        const lua = try std.fmt.allocPrint(testing.allocator,
            \\local tally = require("tally").Tally
            \\local out = require("schema").Out.at({d})
            \\tally:watch({{ saw = function(self, n) out.seen = n end }})
            \\out.total = tally:add(5) + tally:add(1)
            \\out.count = tally:count()
            \\out.later = tally:later(21):await()
        , .{@intFromPtr(&out)});
        defer testing.allocator.free(lua);
        try install.tmp.dir.writeFile(io, .{ .sub_path = "plugins/counter/main.lua", .data = lua });
        // Says it offers one, but doesn't export it
        try install.addScript("liar", "js");
        try install.tmp.dir.createDirPath(io, "plugins/liar/schemas");
        try install.tmp.dir.writeFile(io, .{ .sub_path = "plugins/liar/schemas/liar.sal", .data = "[Service] trait Liar { void say(); }" });
        try install.tmp.dir.writeFile(io, .{ .sub_path = "plugins/liar/main.js", .data = "export const Other = {};" });

        const loader = &install.loader;
        try loader.start(&.{});
        try testing.expectEqual(.loaded, install.info("tally").?.state);
        try testing.expectEqual(.loaded, install.info("counter").?.state);
        try testing.expectEqual(.failed, install.info("liar").?.state);
        try testing.expectEqual(5 + 6, out.total);
        try testing.expectEqual(2, out.count);
        try testing.expectEqual(6, out.seen);
        // Scripts get pumped once a frame, so the promise settles a few in
        for (0..20) |_| {
            if (out.later != 0) break;
            host.salamander.pollRender();
        }
        try testing.expectEqual(42, out.later);
        try testing.expectEqual(1, loader.find("tally").?.services.items.len);

        // What depends on it goes first
        try (try loader.unload("tally")).wait();
        try testing.expectEqual(.unloaded, install.info("counter").?.state);
    }

    test "native plugins offer [Service] traits too" {
        const options = @import("test_options");
        const host = @import("host/root.zig");
        const Service = @import("wraith_test_fixture").FixtureService;
        host.wraith.setIo(testing.io);
        defer host.wraith.setIo(null);
        const Out = extern struct { n: u32 = 0 };
        var out: Out = .{};

        var install: Install = undefined;
        try install.init(.{ .plugins = &.{.{ "fixture", options.fixture_plugin }} });
        defer install.deinit();
        const io = testing.io;
        try install.tmp.dir.createDirPath(io, "plugins/fixture/schemas");
        try install.tmp.dir.writeFile(io, .{ .sub_path = "plugins/fixture/schemas/fixture.sal", .data =
            \\[Service] trait FixtureService { u32 next(); }
            \\struct Out { u32 n; }
        });
        try install.tmp.dir.createDirPath(io, "plugins/user");
        try install.pluginManifest("user", "\"provider\": \"lua\", \"depends\": [\"fixture\"]");
        const lua = try std.fmt.allocPrint(testing.allocator,
            \\local s = require("fixture").FixtureService
            \\s:next()
            \\require("schema").Out.at({d}).n = s:next()
        , .{@intFromPtr(&out)});
        defer testing.allocator.free(lua);
        try install.tmp.dir.writeFile(io, .{ .sub_path = "plugins/user/main.lua", .data = lua });

        const loader = &install.loader;
        try loader.start(&.{});
        try testing.expectEqual(.loaded, install.info("user").?.state);
        try testing.expectEqual(2, out.n);
        const offered = loader.find("fixture").?.services.items;
        try testing.expectEqual(1, offered.len);
        try testing.expectEqual(3, offered[0].obj.as(Service).next());
    }

    test "script sessions get every loaded plugin's services, on the thread they ask for" {
        const options = @import("test_options");
        const host = @import("host/root.zig");
        const api = @import("wraith_api");
        const Sessions = @import("sessions/Sessions.zig");
        const Heard = @import("sessions/testing.zig").Heard;
        const protocol = api.script;
        host.wraith.setIo(testing.io);
        defer host.wraith.setIo(null);

        var install: Install = undefined;
        try install.init(.{ .plugins = &.{.{ "fixture", options.fixture_plugin }} });
        defer install.deinit();
        const io = testing.io;
        try install.tmp.dir.createDirPath(io, "plugins/fixture/schemas");
        try install.tmp.dir.writeFile(io, .{ .sub_path = "plugins/fixture/schemas/fixture.sal", .data = "[Service] trait FixtureService { u32 next(); }" });
        const loader = &install.loader;
        try loader.start(&.{});

        host.messages.setFrames(true);
        defer host.messages.setFrames(false);
        host.frame.setFrames(true);
        defer host.frame.setFrames(false);
        var heard: Heard = .{};
        defer heard.deinit();
        const sub = try host.messages.subscribeRuntime(&heard, Heard.on);
        defer sub.unsubscribe();
        const sessions = try Sessions.create(testing.allocator, "", "", loader);
        defer sessions.destroy();

        const Send = struct {
            fn runIn(thread: protocol.Thread) !void {
                return runAs(1, "lua", "return require('fixture').FixtureService:next()", thread);
            }

            fn runAs(session: u32, language: []const u8, code: []const u8, thread: protocol.Thread) !void {
                const json = try std.json.Stringify.valueAlloc(testing.allocator, protocol.Run{ .session = session, .language = language, .code = code, .thread = thread }, .{});
                defer testing.allocator.free(json);
                try host.messages.publishFromRuntime(protocol.topics.run, json);
                host.messages.deliver();
            }
        };
        const runIn = Send.runIn;

        // Game thread ones wait for a tick
        try runIn(.game);
        host.salamander.pollRender();
        host.messages.deliver();
        try testing.expectEqual(0, heard.lines.items.len);
        host.frame.tickForTests();
        host.messages.deliver();
        try testing.expectEqual(2, heard.lines.items.len);
        const first = try std.fmt.parseInt(u32, heard.line(1), 10);

        // And render thread ones for a frame, which starts it afresh
        try runIn(.render);
        host.frame.tickForTests();
        host.messages.deliver();
        try testing.expectEqual(2, heard.lines.items.len);
        host.salamander.pollRender();
        host.messages.deliver();
        try testing.expectEqual(4, heard.lines.items.len);
        try testing.expectEqual(first + 1, try std.fmt.parseInt(u32, heard.line(3), 10));

        // JS has them too
        try Send.runAs(2, "js", "require('fixture').FixtureService.next()", .game);
        host.frame.tickForTests();
        host.messages.deliver();
        try testing.expectEqual(6, heard.lines.items.len);
        try testing.expectEqual(first + 2, try std.fmt.parseInt(u32, heard.line(5), 10));
    }

    test "start skips disabled plugins" {
        const options = @import("test_options");
        var install: Install = undefined;
        try install.init(.{ .plugins = &.{.{ "fixture", options.fixture_plugin }} });
        defer install.deinit();
        const loader = &install.loader;

        try loader.start(&.{"FIXTURE"}); // case-insensitive, like Windows file names
        try testing.expectEqual(0, loader.count());
        try testing.expectEqual(.unloaded, install.info("fixture").?.state);
        try (try loader.load("fixture")).wait();
        try testing.expectEqual(1, loader.count());
    }
};

test {
    _ = tests;
    _ = discovery;
    _ = lifecycle;
    _ = Jobs;
}
