//! `wraith sdk`: what a plugin's build needs from its wraith. `sdk <language> types` makes Wraith's API and
//! the plugin's schemas as that language's types, every language the same way: the project's loaded once
//! (sdk/project.zig), its language makes files from it (sdk/<language>.zig), and they're written if they
//! changed, with what they're made from (sdk/output.zig).

const std = @import("std");

const core = @import("wraith_core");
const build_info = @import("build_info");

const ops = @import("ops.zig");
const deps = @import("deps.zig");
const languages = @import("languages.zig");
const Project = @import("sdk/project.zig");
const output = @import("sdk/output.zig");
const rust = @import("sdk/rust.zig");

const log = core.log.scoped(.wraith_cli);
const Sdk = languages.Sdk;

pub const usage =
    \\  sdk <language> types [--out <folder>] [--pointer-size 4|8] [--namespace NS] [--offline] [<file.sal | folder> ...]
    \\                                       Wraith's API and the plugin's schemas as <language>'s
    \\                                       types, run from its folder: js (TypeScript typings, in
    \\                                       .wraith/types), lua (LuaLS annotations, in .wraith/types,
    \\                                       and .luarc.json), cs (C#, in .wraith/cs), rust (the
    \\                                       salamander and wraith crates and schema.rs, for 32 and
    \\                                       64-bit both, in .wraith/rust), c or cpp (headers, in
    \\                                       .wraith/c or .wraith/cpp). Its schemas are in NS (default
    \\                                       its id in PascalCase), and each plugin its wraith.json
    \\                                       depends on in its own, found like sdk deps does, which
    \\                                       --offline doesn't download. Only files that changed are
    \\                                       written, with inputs.txt saying what they're made from,
    \\                                       so a build can make them again when any of it changes
    \\
++ rust.build_usage ++
    \\
    \\  sdk cmake <file>                     wraith.cmake, which a C or C++ plugin's CMakeLists.txt
    \\                                       includes for wraith_plugin(<id> <C|CXX> <sources>...)
    \\  sdk deps [--json] [--offline]       where the plugins wraith.json here depends on are: a
    \\                                       dev plugin, a folder by its name next to this one,
    \\                                       installed, or downloaded from the hub into the cache
    \\                                       (not with --offline)
    \\  sdk <language> info                 this wraith, as JSON, for a plugin's build or editor:
    \\                                       its version, folder (dir), mods_dir (where
    \\                                       installed mods go), and the apiVersion range it loads
    \\                                       (api_version, min_api_version)
;

pub fn run(ctx: ops.Context, args: anytype) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const first = args.next() orelse "";
    if (std.mem.eql(u8, first, "deps")) return depsCommand(ctx, arena, args);
    if (std.mem.eql(u8, first, "cmake")) {
        const file = args.next() orelse return usageError();
        _ = try output.writeIfChanged(ctx, arena, std.fs.path.dirname(file) orelse ".", std.fs.path.basename(file), @embedFile("wraith.cmake"));
        return 0;
    }
    // TypeScript's are JavaScript's
    const language: Sdk = if (std.mem.eql(u8, first, "ts")) .js else std.meta.stringToEnum(Sdk, first) orelse return usageError();
    const sub = args.next() orelse "";
    if (std.mem.eql(u8, sub, "info")) return info(ctx, arena);
    if (std.mem.eql(u8, sub, "build") and language == .rust) return rust.build(ctx, arena, args, rustTypes) catch |err| switch (err) {
        error.Usage => usageError(),
        else => err,
    };
    if (!std.mem.eql(u8, sub, "types")) return usageError();

    var options: Options = .{};
    var extra: std.ArrayList([]const u8) = .empty;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--out")) {
            options.out = args.next() orelse return usageError();
        } else if (std.mem.eql(u8, arg, "--namespace")) {
            options.project.namespace = args.next() orelse return usageError();
        } else if (std.mem.eql(u8, arg, "--offline")) {
            options.project.offline = true;
        } else if (std.mem.eql(u8, arg, "--pointer-size")) {
            const n = args.next() orelse return usageError();
            options.project.pointer_size = if (std.mem.eql(u8, n, "4")) 4 else if (std.mem.eql(u8, n, "8")) 8 else return usageError();
        } else {
            try extra.append(arena, try arena.dupe(u8, arg));
        }
    }
    options.project.extra = extra.items;
    return types(ctx, arena, language, options);
}

pub const Options = struct {
    /// The language's own folder if null.
    out: ?[]const u8 = null,
    project: Project.Options = .{},
};

/// Makes `language`'s types for the plugin here and writes what changed. 1 once it's said what's wrong.
pub fn types(ctx: ops.Context, arena: std.mem.Allocator, language: Sdk, options: Options) !u8 {
    var p = Project.load(ctx, arena, options.project) catch |err| switch (err) {
        error.InvalidSchema => return 1,
        else => return err,
    };
    const made = generate(&p, language) catch |err| switch (err) {
        error.InvalidSchema => return 1,
        else => return err,
    };
    const out = options.out orelse defaultOut(language);
    try output.write(ctx, arena, out, made, p.inputs);
    if (language == .lua) try @import("sdk/lua.zig").after(ctx, arena, out);
    return 0;
}

fn rustTypes(ctx: ops.Context, arena: std.mem.Allocator) anyerror!u8 {
    return types(ctx, arena, .rust, .{});
}

fn generator(comptime language: Sdk) type {
    return switch (language) {
        .js => @import("sdk/js.zig"),
        .lua => @import("sdk/lua.zig"),
        .cs => @import("sdk/cs.zig"),
        .rust => @import("sdk/rust.zig"),
        .c => @import("sdk/c.zig"),
        .cpp => @import("sdk/cpp.zig"),
    };
}

pub fn generate(p: *Project, language: Sdk) ![]const output.Made {
    return switch (language) {
        inline else => |l| generator(l).generate(p),
    };
}

pub fn defaultOut(language: Sdk) []const u8 {
    return switch (language) {
        inline else => |l| generator(l).default_out,
    };
}

/// The namespace for a plugin's id, like `TrailsHorizon`.
pub const pascal = Project.pascal;

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

test {
    _ = rust;
}

const testing = std.testing;

fn expectMade(language: Sdk, p: *Project, want: []const [2][]const u8) !void {
    const made = try generate(p, language);
    for (want) |w| {
        const text = for (made) |m| {
            if (std.mem.eql(u8, m.name, w[0])) break m.text;
        } else {
            std.debug.print("{t} made no {s}\n", .{ language, w[0] });
            return error.TestUnexpectedResult;
        };
        if (std.mem.indexOf(u8, text, w[1]) == null) {
            std.debug.print("{t}'s {s} is missing:\n{s}\n", .{ language, w[0], w[1] });
            return error.TestUnexpectedResult;
        }
    }
}

test "every language's types for Wraith's whole schema and a plugin's" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const game: Project.File = .{ .name = "schemas/game.sal", .text =
        \\// The one playing
        \\struct Player {
        \\    u32 health;
        \\    Vec3 at;
        \\    [Sig("48 8B 05")] static Player* instance;
        \\    [Sig("48 89 5C")] void heal(u32 amount);
        \\}
    };
    var p = Project.forTest(arena, &.{game}, &.{}, "Kai");
    try expectMade(.js, &p, &.{
        .{ "wraith.d.ts", "declare module \"wraith\" {\nnamespace Wraith {" },
        .{ "wraith.d.ts", "    threads(): Wraith.Threads;" },
        .{ "wraith.d.ts", "Given<Wraith.Tweaks.Definition>" },
        .{ "wraith.d.ts", "\nnamespace Kai {" },
        .{ "wraith.d.ts", "The one playing" },
        .{ "wraith.d.ts", "hook<F extends (...args: any[]) => any>(target: F, handler: (...args: [...Parameters<F>, hook: TypedHook<F>, context: number])" },
        .{ "salamander.d.ts", "declare const salamander: typeof import(\"salamander\");" },
    });
    try expectMade(.lua, &p, &.{
        .{ "wraith.lua", "---@meta wraith\n" },
        .{ "wraith.lua", "---@class wraith\n" },
        .{ "wraith.lua", "---@class Wraith.Tweaks.Definition" },
        .{ "wraith.lua", "---@class Kai.Player" },
        .{ "wraith.lua", "function c:heal(amount) end" },
        .{ "wraith_hooks.lua", "function hooks:hook(target, handler, options) end" },
    });
    try expectMade(.cs, &p, &.{
        .{ "Wraith.cs", "namespace Wraith\n" },
        .{ "WraithPlugin.cs", "public abstract class WraithPlugin" },
        .{ "WraithPlugin.cs", "public Hook Hook<H, W>(DeclaredFunction<H, W> target, W handler" },
        .{ "SalamanderCore.cs", "namespace Salamander.Raw\n" },
        .{ "Schema.cs", "namespace Kai\n" },
        .{ "Schema.cs", "Declared.Address(\"Kai.Player.instance\")" },
        .{ "Schema.cs", "    public void Heal(uint amount)" },
        .{ "Schema.cs", "        public static readonly HealFn Heal = new();" },
    });
    try expectMade(.rust, &p, &.{
        .{ "salamander/src/lib.rs", "pub struct Str {" },
        .{ "wraith/src/lib.rs", "macro_rules! plugin" },
        .{ "wraith/api_64.rs", "pub mod wraith {" },
        .{ "wraith/api_32.rs", "== 4, \"these types are for 32-bit code\"" },
        .{ "schema_64.rs", "    pub at: ::wraith::api::wraith::Vec3," },
        .{ "schema_64.rs", "pub unsafe fn heal(&mut self, amount: u32) {" },
        .{ "schema.rs", "include!(\"schema_32.rs\");" },
        .{ "schema.rs", "pub use kai::*;" },
    });
    try expectMade(.c, &p, &.{
        .{ "salamander.h", "#define SALAMANDER_H" },
        .{ "salamander_core.h", "sal_Host" },
        .{ "wraith.h", "Wraith_Api" },
        .{ "wraith_plugin.h", "#define WRAITH_PLUGIN(start_fn, stop_fn)" },
        .{ "schema.h", "#include \"wraith.h\"" },
        .{ "schema.h", "    Wraith_Vec3 at;" },
        .{ "schema.h", "#define Kai_Player_heal_name \"Kai.Player.heal\"" },
    });
    try expectMade(.cpp, &p, &.{
        .{ "salamander_runtime.hpp", "class Future" },
        .{ "salamander_core.hpp", "namespace sal {" },
        .{ "wraith.hpp", "struct Api {" },
        .{ "wraith_plugin.hpp", "#define WRAITH_PLUGIN(Type)" },
        .{ "schema.hpp", "#include \"wraith.hpp\"" },
        .{ "schema.hpp", "    ::Wraith::Vec3 at;" },
        .{ "schema.hpp", "    void heal(uint32_t amount);" },
    });
}

test "each dependency's in its namespace, with its [Service] traits as functions" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const files = [_]Project.File{
        .{ .name = "tally/tally.sal", .text = "[Service] trait Tally { u32 add(u32 n); }\ntrait Helper { void help(); }" },
        .{ .name = "schemas/own.sal", .text = "[Service] trait Mine { void go(); }\nstruct Uses { Helper* h; }" },
    };
    var p = Project.forTest(arena, &files, &.{"tally"}, "Mod");
    try expectMade(.js, &p, &.{ .{ "wraith.d.ts", "tally(): Tally.Tally;" }, .{ "wraith.d.ts", "instance(): Tally.Tally" } });
    try expectMade(.lua, &p, &.{ .{ "wraith.lua", "function c.tally() end" }, .{ "wraith.lua", "---@field Tally Tally\n" }, .{ "wraith.lua", "---@class Mod.Mine" } });
    try expectMade(.cs, &p, &.{.{ "Schema.cs", "public static Tally Instance => global::Salamander.Singletons.Get<Tally>();" }});
}
