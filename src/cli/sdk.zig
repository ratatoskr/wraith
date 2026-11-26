//! `wraith sdk`: what a plugin build needs from its wraith.

const std = @import("std");

const core = @import("wraith_core");
const api = @import("wraith_api");
const salamander_schema = @import("salamander_schema");
const salamander_cs = @import("salamander_cs");
const types = @import("salamander_types");
const build_info = @import("build_info");

const ops = @import("ops.zig");
const deps = @import("deps.zig");

const log = core.log.scoped(.wraith_cli);

pub const usage =
    \\  sdk js types [--out <folder>] [--pointer-size 4|8] [--namespace NS] [<file.sal | folder> ...]
    \\                                       TypeScript typings for a JavaScript plugin (run from
    \\                                       its folder), in <folder> (default .wraith/types):
    \\                                       wraith.d.ts and salamander.d.ts. Each namespace at the
    \\                                       top is in the wraith module, like Wraith.tweaks() and
    \\                                       Wraith.Window, and its own schemas folder and any .sal given are in NS
    \\                                       (default its id in PascalCase, like Kai). Each plugin
    \\                                       its wraith.json depends on is in its own, with its
    \\                                       [Service] traits like Freecam.camera(), found like
    \\                                       sdk deps does. --offline doesn't download them
    \\  sdk lua types [--out <folder>] [--pointer-size 4|8] [--namespace NS] [<file.sal | folder> ...]
    \\                                       LuaLS annotations for a Lua plugin, like sdk js types:
    \\                                       wraith.lua, wraith_hooks.lua and salamander.lua. Writes
    \\                                       .luarc.json
    \\                                       pointing there if there isn't one
    \\  sdk cs types [--out <folder>] [--pointer-size 4|8] [--namespace NS] [<file.sal | folder> ...]
    \\                                       C# for a C# plugin, for its .csproj to compile, in
    \\                                       <folder> (default .wraith/cs): Wraith's API in
    \\                                       Wraith, the SDK's WraithPlugin, Salamander's runtime,
    \\                                       and Schema.cs for its schemas in NS and those of
    \\                                       plugins it depends on in theirs
    \\  sdk deps [--json] [--offline]       where the plugins wraith.json here depends on are: a
    \\                                       dev plugin, a folder by its name next to this one,
    \\                                       installed, or downloaded from the hub into the cache
    \\                                       (not with --offline)
    \\  sdk js info, sdk lua info, sdk cs info
    \\                                       this wraith, as JSON, for a plugin's build or editor:
    \\                                       its version, folder (dir), mods_dir (where
    \\                                       installed mods go), and the apiVersion range it loads
    \\                                       (api_version, min_api_version)
;

const Language = enum { js, lua, cs };

pub fn run(ctx: ops.Context, args: anytype) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const first = args.next() orelse "";
    if (std.mem.eql(u8, first, "deps")) return depsCommand(ctx, arena, args);
    const language = std.meta.stringToEnum(Language, first) orelse return usageError();
    const sub = args.next() orelse "";
    if (std.mem.eql(u8, sub, "info")) return info(ctx, arena);
    if (!std.mem.eql(u8, sub, "types")) return usageError();

    var options: Options = .{};
    var inputs: std.ArrayList([]const u8) = .empty;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--out")) {
            options.out = args.next() orelse return usageError();
        } else if (std.mem.eql(u8, arg, "--namespace")) {
            options.namespace = args.next() orelse return usageError();
        } else if (std.mem.eql(u8, arg, "--offline")) {
            options.offline = true;
        } else if (std.mem.eql(u8, arg, "--pointer-size")) {
            const n = args.next() orelse return usageError();
            options.pointer_size = if (std.mem.eql(u8, n, "4")) 4 else if (std.mem.eql(u8, n, "8")) 8 else return usageError();
        } else {
            try inputs.append(arena, try arena.dupe(u8, arg));
        }
    }
    return writeTypes(ctx, arena, language, options, inputs.items);
}

fn usageError() u8 {
    log.err("Usage:\n{s}", .{usage});
    return 1;
}

fn depsCommand(ctx: ops.Context, arena: std.mem.Allocator, args: anytype) !u8 {
    var json = false;
    var offline = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--offline")) {
            offline = true;
        } else return usageError();
    }
    const listed = try deps.listed(arena, ctx.io);
    const found = try deps.resolve(ctx, arena, listed, !offline);
    if (json) {
        var buf: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(ctx.io, &buf);
        try std.json.Stringify.value(found, .{}, &stdout.interface);
        try stdout.interface.writeByte('\n');
        try stdout.interface.flush();
    } else {
        for (found) |f| log.printLn("{s} {s} ({t}): {s}", .{ f.name, f.version, f.from, f.dir });
    }
    return if (found.len == listed.depends.len) 0 else 1;
}

fn info(ctx: ops.Context, arena: std.mem.Allocator) !u8 {
    const locations = try ops.locations(arena);
    var buf: [2048]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(ctx.io, &buf);
    try std.json.Stringify.value(.{
        .version = build_info.version,
        .dir = ctx.dir,
        .mods_dir = locations.mods,
        .api_version = core.manifest.api_version,
        .min_api_version = core.manifest.min_api_version,
    }, .{}, &stdout.interface);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
    return 0;
}

const Options = struct {
    const default_out = ".wraith/types";

    out: []const u8 = default_out,
    pointer_size: u8 = 8,
    /// Don't download dependencies from the hub.
    offline: bool = false,
    /// Manifest dependencies. Their schemas get their own namespaces, services like `Freecam.camera()`.
    depends: []const []const u8 = &.{},
    /// Its schemas', and C#'s home for anything without one. Its id in PascalCase if empty.
    namespace: []const u8 = "",
};

/// Wraith's schema with the plugin's as globals, each in its namespace.
fn writeTypes(ctx: ops.Context, arena: std.mem.Allocator, language: Language, options_in: Options, inputs: []const []const u8) !u8 {
    const io = ctx.io;
    const cwd = std.Io.Dir.cwd();
    var options = options_in;

    var files: std.ArrayList(salamander_schema.File) = .empty;
    collect(arena, io, "schemas", &files) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    for (inputs) |input| collect(arena, io, input, &files) catch |err| {
        log.err("{s}: {t}", .{ input, err });
        return 1;
    };
    const found = try deps.resolve(ctx, arena, try deps.listed(arena, io), !options.offline);
    const names = try arena.alloc([]const u8, found.len);
    for (found, names) |f, *n| {
        n.* = f.name;
        try collectDependency(arena, io, f, &files);
    }
    options.depends = names;
    if (language == .cs and std.mem.eql(u8, options.out, Options.default_out)) options.out = ".wraith/cs";
    if (options.namespace.len == 0) options.namespace = try namespaceOf(arena, io);
    const made = generate(arena, language, options, files.items) catch |err| switch (err) {
        error.InvalidSchema => return 1,
        else => return err,
    };

    try cwd.createDirPath(io, options.out);
    for (made) |m| {
        const path = try std.mem.concat(arena, u8, &.{ options.out, "/", m.name });
        try cwd.writeFile(io, .{ .sub_path = path, .data = m.text });
        log.printLn("{s}", .{path});
    }
    if (language == .lua) try writeLuarc(ctx, arena, options);
    return 0;
}

const Made = struct { name: []const u8, text: []const u8 };

/// What scripts import Wraith's and the plugins' namespaces from.
const script_module = "wraith";

/// The typed hooks every script's `Wraith.Hooks` gets, see runtime/plugins/hooks.js.
const ts_hooks =
    \\
    \\declare module "wraith" {
    \\  namespace Wraith {
    \\    /** What a typed hook's handler gets for a parameter named `hook`. */
    \\    interface TypedHook<F extends (...args: any[]) => any> {
    \\      /** The function as it was, to call on. */
    \\      original(): F;
    \\      /** What its options said. */
    \\      readonly context: number;
    \\      enable(): void;
    \\      disable(): void;
    \\      destroy(): void;
    \\    }
    \\    interface Hooks {
    \\      /**
    \\       * Hooks a function the schemas declare, like `GameStateManager.spendMira`. The handler gets its
    \\       * arguments, and a parameter named `hook` or `context` gets that instead, wherever it is. They're
    \\       * typed after the arguments, like `(self, amount, hook) => hook.original()(self, 0)`.
    \\       */
    \\      hook<F extends (...args: any[]) => any>(target: F, handler: (...args: [...Parameters<F>, hook: TypedHook<F>, context: number]) => ReturnType<F>, options?: import("salamander").Given<Wraith.Hook.Options>): Wraith.Hook;
    \\      /** The same at an address of your own, typed like `target`. */
    \\      hookAt<F extends (...args: any[]) => any>(address: number | bigint, target: F, handler: (...args: [...Parameters<F>, hook: TypedHook<F>, context: number]) => ReturnType<F>, options?: import("salamander").Given<Wraith.Hook.Options>): Wraith.Hook;
    \\    }
    \\  }
    \\}
    \\
;

const lua_hooks =
    \\---@meta
    \\-- Made by Wraith. Don't change it, since it's made again.
    \\
    \\---What a typed hook's handler gets for a parameter named `hook`.
    \\---@class Wraith.TypedHook
    \\---@field context integer What its options said
    \\local typed = {}
    \\
    \\---The function as it was, to call on.
    \\---@return function
    \\function typed.original() end
    \\
    \\function typed.enable() end
    \\
    \\function typed.disable() end
    \\
    \\function typed.destroy() end
    \\
    \\---@class Wraith.Hooks
    \\local hooks = {}
    \\
    \\---Hooks a function the schemas declare, like `GameStateManager.spendMira`. The handler gets its
    \\---arguments, and a parameter named `hook` or `context` gets that instead.
    \\---@param target function
    \\---@param handler function
    \\---@param options? Wraith.Hook.Options
    \\---@return Wraith.Hook
    \\function hooks:hook(target, handler, options) end
    \\
    \\---The same at an address of your own, typed like `target`.
    \\---@param address integer
    \\---@param target function
    \\---@param handler function
    \\---@param options? Wraith.Hook.Options
    \\---@return Wraith.Hook
    \\function hooks:hookAt(address, target, handler, options) end
    \\
;

/// Each package's schemas parse in its own namespace; every file sees Wraith's and deps' without `use`.
fn parseOptions(arena: std.mem.Allocator, options: Options) !salamander_schema.Options {
    var o = api.sal_options;
    o.pointer_size = options.pointer_size;
    o.namespace = options.namespace;
    const base = api.sal_options.global_uses;
    const uses = try arena.alloc([]const u8, base.len + options.depends.len);
    @memcpy(uses[0..base.len], base);
    const files = try arena.alloc(salamander_schema.FileNamespace, options.depends.len);
    for (options.depends, files, uses[base.len..]) |d, *f, *u| {
        const ns = try pascal(arena, d);
        f.* = .{ .prefix = try std.fmt.allocPrint(arena, "{s}/", .{d}), .namespace = ns };
        u.* = ns;
    }
    o.global_uses = uses;
    o.file_namespaces = files;
    return o;
}

/// Each file's name and text, in `arena`. Says what's wrong with a schema that doesn't parse.
fn generate(arena: std.mem.Allocator, language: Language, options: Options, files: []const salamander_schema.File) ![]const Made {
    const parse_options = try parseOptions(arena, options);
    var diag: salamander_schema.Schema.Diagnostic = .{};
    var wraith = salamander_schema.parse(arena, api.wraith_sal, parse_options, &diag) catch |err| {
        if (err == error.InvalidSchema) log.err("Wraith's own schema: {s}", .{diag.message()});
        return err;
    };
    defer wraith.deinit();
    const own = salamander_schema.bundle(arena, files) catch |err| {
        if (err == error.InvalidFileName) log.err("A schema's file name can't be used: {t}", .{err});
        return if (err == error.InvalidFileName) error.InvalidSchema else err;
    };
    var all = salamander_schema.parse(arena, try std.mem.concat(arena, u8, &.{ api.wraith_sal, "\n", own }), parse_options, &diag) catch |err| {
        if (err == error.InvalidSchema) log.err("{s}", .{diag.message()});
        return err;
    };
    defer all.deinit();

    // What its dependencies give it, like `Freecam.camera()`
    var services: std.ArrayList([]const u8) = .empty;
    for (options.depends) |d| for (all.schema.traits) |*t| if (isServiceOf(all, t, d)) try services.append(arena, t.name);

    var list: std.ArrayList(Made) = .empty;
    switch (language) {
        .js => {
            var w: std.Io.Writer.Allocating = .init(arena);
            try types.ts.globals(&w.writer, all.schema, all.source, services.items, script_module);
            try w.writer.writeAll(ts_hooks);
            try list.append(arena, .{ .name = "wraith.d.ts", .text = w.written() });
            w = .init(arena);
            try types.ts.builtins(&w.writer);
            try list.append(arena, .{ .name = "salamander.d.ts", .text = w.written() });
        },
        .lua => {
            var w: std.Io.Writer.Allocating = .init(arena);
            try types.luals.globals(&w.writer, all.schema, all.source, services.items, script_module);
            try list.append(arena, .{ .name = "wraith.lua", .text = w.written() });
            w = .init(arena);
            try w.writer.writeAll(lua_hooks);
            try list.append(arena, .{ .name = "wraith_hooks.lua", .text = w.written() });
            w = .init(arena);
            try types.luals.builtins(&w.writer);
            try list.append(arena, .{ .name = "salamander.lua", .text = w.written() });
        },
        .cs => {
            try list.append(arena, .{ .name = "Salamander.cs", .text = salamander_cs.base_file });
            try list.append(arena, .{ .name = "WraithPlugin.cs", .text = @embedFile("WraithPlugin.cs") });
            var w: std.Io.Writer.Allocating = .init(arena);
            try salamander_cs.writeCore(arena, &w.writer, options.pointer_size);
            try list.append(arena, .{ .name = "SalamanderCore.cs", .text = w.written() });
            w = .init(arena);
            try salamander_cs.write(arena, wraith.schema, &w.writer, .{ .label = "wraith.sal", .namespace = cs_namespace, .class = cs_class }, &diag);
            try list.append(arena, .{ .name = "Wraith.cs", .text = w.written() });
            // Its own, with Wraith's files named like plugin builds name them, so they're used from Wraith.cs
            const renamed = try std.mem.replaceOwned(u8, arena, api.wraith_sal, "\n" ++ salamander_schema.Schema.bundle_marker, "\n" ++ salamander_schema.Schema.bundle_marker ++ "wraith/");
            const text = try std.mem.concat(arena, u8, &.{ salamander_schema.Schema.bundle_marker ++ "wraith/", renamed[salamander_schema.Schema.bundle_marker.len..], "\n", own });
            var mine = salamander_schema.parse(arena, text, parse_options, &diag) catch |err| {
                if (err == error.InvalidSchema) log.err("{s}", .{diag.message()});
                return err;
            };
            defer mine.deinit();
            w = .init(arena);
            salamander_cs.write(arena, mine.schema, &w.writer, .{
                .label = "its schemas",
                .namespace = options.namespace,
                .class = "Schema",
                .source = mine.source,
                .aliases = &.{.{ .prefix = "wraith/", .namespace = cs_namespace }},
                .singletons = services.items,
            }, &diag) catch |err| {
                if (err == error.NameClash) log.err("{s}", .{diag.message()});
                return if (err == error.NameClash) error.InvalidSchema else err;
            };
            try list.append(arena, .{ .name = "Schema.cs", .text = w.written() });
        },
    }
    return list.items;
}

/// Wraith's API, `Raw` and constants live in `Wraith`. Constants can't be `Api` or `Schema` (traits).
const cs_namespace = "Wraith";
const cs_class = "Constants";

/// The plugin's id from its wraith.json in PascalCase, like `TrailsHorizon`, or `Plugin` without one.
fn namespaceOf(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(io, core.manifest.file_name, arena, .limited(1 << 20)) catch return "Plugin";
    const m = std.json.parseFromSliceLeaky(struct { id: []const u8 = "" }, arena, text, .{ .ignore_unknown_fields = true }) catch return "Plugin";
    return pascal(arena, m.id);
}

/// The namespace for a plugin's id, like `TrailsHorizon`.
pub fn pascal(arena: std.mem.Allocator, id: []const u8) ![]const u8 {
    var buf: [core.manifest.namespace_max]u8 = undefined;
    return arena.dupe(u8, core.manifest.namespaceOf(&buf, id));
}

/// A [Service] trait in one of `plugin`'s files.
fn isServiceOf(parsed: salamander_schema.Parsed, t: *const salamander_schema.Schema.Trait, plugin: []const u8) bool {
    if (salamander_schema.Schema.findAnnotation(t.annotations, "wraith", "Service") == null) return false;
    const file = salamander_schema.Schema.fileOf(parsed.source, t.at);
    return file.len > plugin.len and std.mem.startsWith(u8, file, plugin) and file[plugin.len] == '/';
}

/// A `.luarc.json` so LuaLS finds them, unless they have one.
fn writeLuarc(ctx: ops.Context, arena: std.mem.Allocator, options: Options) !void {
    const io = ctx.io;
    const cwd = std.Io.Dir.cwd();
    if (cwd.access(io, ".luarc.json", .{})) |_| return else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    try cwd.writeFile(io, .{ .sub_path = ".luarc.json", .data = try luarc(arena, options.out) });
    log.printLn(".luarc.json", .{});
}

/// LuaLS settings for wraith's Lua: the annotations, and none of the libraries it leaves out.
fn luarc(arena: std.mem.Allocator, out: []const u8) ![]const u8 {
    var text: std.Io.Writer.Allocating = .init(arena);
    const w = &text.writer;
    try w.writeAll("{\n  \"$schema\": \"https://raw.githubusercontent.com/LuaLS/vscode-lua/master/setting/schema.json\",\n");
    try w.writeAll("  \"runtime.version\": \"Lua 5.5\",\n  \"runtime.builtin\": { \"io\": \"disable\" },\n");
    try w.writeAll("  \"workspace.library\": [");
    try std.json.Stringify.value(out, .{}, w);
    // Just a library, not more files to check
    try w.writeAll("],\n  \"workspace.ignoreDir\": [");
    try std.json.Stringify.value(out, .{}, w);
    try w.writeAll("]\n}\n");
    return text.written();
}

/// A dependency's schemas, named like `name/path.sal` the way Wraith names them.
fn collectDependency(arena: std.mem.Allocator, io: std.Io, dep: deps.Found, files: *std.ArrayList(salamander_schema.File)) !void {
    const dir = try std.fs.path.join(arena, &.{ dep.dir, "schemas" });
    const start = files.items.len;
    collect(arena, io, dir, files) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    const prefix = (try slashed(arena, dir)).len + 1;
    for (files.items[start..]) |*f| f.name = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dep.name, f.name[prefix..] });
}

/// `input`'s `.sal` files, a folder's in order, named by their path from here.
fn collect(arena: std.mem.Allocator, io: std.Io, input: []const u8, files: *std.ArrayList(salamander_schema.File)) !void {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, input, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return files.append(arena, .{ .name = try slashed(arena, input), .text = try cwd.readFileAlloc(io, input, arena, .limited(16 << 20)) }),
        else => return err,
    };
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit(io);
    var found: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".sal")) continue;
        try found.append(arena, try std.fs.path.join(arena, &.{ input, entry.path }));
    }
    std.mem.sort([]const u8, found.items, {}, lessThan);
    for (found.items) |path| try files.append(arena, .{ .name = try slashed(arena, path), .text = try cwd.readFileAlloc(io, path, arena, .limited(16 << 20)) });
}

fn slashed(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, path);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "typings for Wraith's whole schema and a plugin's" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const game: salamander_schema.File = .{ .name = "schemas/game.sal", .text =
        \\// The one playing
        \\struct Player {
        \\    u32 health;
        \\    [Sig("48 8B 05")] static Player* instance;
        \\    [Sig("48 89 5C")] void heal(u32 amount);
        \\}
    };
    const want = [_]struct { Language, []const u8, []const u8 }{
        .{ .js, "wraith.d.ts", "declare module \"wraith\" {\nnamespace Wraith {" },
        .{ .js, "wraith.d.ts", "    threads(): Wraith.Threads;" },
        .{ .js, "wraith.d.ts", "Given<Wraith.Tweaks.Definition>" },
        .{ .js, "salamander.d.ts", "declare const salamander: typeof import(\"salamander\");" },
        .{ .js, "wraith.d.ts", "\nnamespace Kai {" },
        .{ .js, "wraith.d.ts", "hook<F extends (...args: any[]) => any>(target: F, handler: (...args: [...Parameters<F>, hook: TypedHook<F>, context: number])" },
        .{ .lua, "wraith.lua", "---@meta wraith\n" },
        .{ .lua, "wraith.lua", "---@class wraith\n" },
        .{ .lua, "wraith_hooks.lua", "function hooks:hook(target, handler, options) end" },
        .{ .cs, "Schema.cs", "        public static readonly HealFn Heal = new();" },
        .{ .cs, "WraithPlugin.cs", "public Hook Hook<H, W>(DeclaredFunction<H, W> target, W handler" },
        .{ .js, "wraith.d.ts", "The one playing" },
        .{ .lua, "wraith.lua", "---@class Wraith.Tweaks.Definition" },
        .{ .lua, "wraith.lua", "---@class Kai.Player" },
        .{ .lua, "wraith.lua", "function c:heal(amount) end" },
        .{ .cs, "Wraith.cs", "namespace Wraith\n" },
        .{ .cs, "WraithPlugin.cs", "public abstract class WraithPlugin" },
        .{ .cs, "SalamanderCore.cs", "namespace Salamander.Raw\n" },
        .{ .cs, "Schema.cs", "namespace Kai\n" },
        .{ .cs, "Schema.cs", "Declared.Address(\"Kai.Player.instance\")" },
        .{ .cs, "Schema.cs", "    public void Heal(uint amount)" },
    };
    for (std.enums.values(Language)) |language| {
        const made = try generate(arena, language, .{ .namespace = "Kai" }, &.{game});
        for (want) |w| {
            if (w[0] != language) continue;
            const text = for (made) |m| {
                if (std.mem.eql(u8, m.name, w[1])) break m.text;
            } else return error.TestUnexpectedResult;
            if (std.mem.indexOf(u8, text, w[2]) == null) {
                std.debug.print("{s} is missing:\n{s}\n", .{ w[1], w[2] });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "each dependency's in its namespace, with its [Service] traits as functions" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const files = [_]salamander_schema.File{
        .{ .name = "tally/tally.sal", .text = "[Service] trait Tally { u32 add(u32 n); }\ntrait Helper { void help(); }" },
        .{ .name = "schemas/own.sal", .text = "[Service] trait Mine { void go(); }\nstruct Uses { Helper* h; }" },
    };
    const options: Options = .{ .depends = &.{"tally"}, .namespace = "Mod" };
    const want = [_]struct { Language, []const u8, []const u8 }{
        .{ .js, "wraith.d.ts", "tally(): Tally.Tally;" },
        .{ .js, "wraith.d.ts", "instance(): Tally.Tally" },
        .{ .lua, "wraith.lua", "function c.tally() end" },
        .{ .lua, "wraith.lua", "---@field Tally Tally\n" },
        .{ .lua, "wraith.lua", "---@class Mod.Mine" },
        .{ .cs, "Schema.cs", "public static Tally Instance => global::Salamander.Singletons.Get<Tally>();" },
    };
    for (std.enums.values(Language)) |language| {
        const made = try generate(arena, language, options, &files);
        for (want) |w| {
            if (w[0] != language) continue;
            const text = for (made) |m| {
                if (std.mem.eql(u8, m.name, w[1])) break m.text;
            } else return error.TestUnexpectedResult;
            if (std.mem.indexOf(u8, text, w[2]) == null) {
                std.debug.print("{s} is missing:\n{s}\nin:\n{s}\n", .{ w[1], w[2], text });
                return error.TestUnexpectedResult;
            }
        }
    }
}
