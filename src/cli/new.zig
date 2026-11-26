//! `wraith new`: scaffolds a plugin in any supported language, with a wraith.json for its game.

const std = @import("std");
const builtin = @import("builtin");

const core = @import("wraith_core");
const game_engine = @import("wraith_game").game_engine;
const build_info = @import("build_info");

const ops = @import("ops.zig");
const sdk = @import("sdk.zig");

const log = core.log.scoped(.wraith_cli);

pub const usage =
    \\  new [folder] [--language zig|ts|js|lua|cs] [--runtime aot|clr] [--game <game.exe | game id>]
    \\      [--engine [<engine>[:<variant>]]] [--id <id>] [--title <title>] [--summary <text>]
    \\      [--author <name>] [--library] [--dev | --no-dev] [--yes]
    \\                                       start a plugin in <folder>: its code, its build and a
    \\                                       wraith.json, with what the language needs (Zig: zig
    \\                                       init and fetch, TS/JS: npm create, Lua and C#: its
    \\                                       types). --runtime, for C#: aot compiles it with
    \\                                       NativeAOT, so games need no .NET, clr has .NET run it,
    \\                                       so it reloads. --game: the game's exe, identified so
    \\                                       its ID and exe name both go in, or a game ID (see
    \\                                       games). --engine: every game made with it instead,
    \\                                       like unity or unity:IL2CPP, or the --game's own with
    \\                                       no name. Neither is any game. --library: one other
    \\                                       plugins use. --dev: load it from where it builds
    \\                                       while you work on it (dev add). Asks for what isn't
    \\                                       given, unless --yes
;

pub const Language = enum {
    zig,
    ts,
    js,
    lua,
    cs,

    fn title(self: Language) []const u8 {
        return switch (self) {
            .zig => "Zig",
            .ts => "TypeScript",
            .js => "JavaScript",
            .lua => "Lua",
            .cs => "C#",
        };
    }
};

/// How a C# plugin runs.
pub const Runtime = enum {
    /// Compiled with NativeAOT into a native DLL
    aot,
    /// Run by .NET, the game's or the installed one
    clr,
};

const Options = struct {
    folder: ?[]const u8 = null,
    language: ?Language = null,
    runtime: ?Runtime = null,
    game: ?[]const u8 = null,
    /// Empty for the game's own.
    engine: ?[]const u8 = null,
    id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    author: ?[]const u8 = null,
    library: bool = false,
    dev: ?bool = null,
    yes: bool = false,
};

const repo_url = "git+https://github.com/ratatoskr/wraith";

const Manifest = core.manifest.Manifest;
pub fn run(ctx: ops.Context, args: anytype) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = ctx.io;

    const options = parseArgs(args) catch return usageError();
    if (options.id) |id| if (!core.manifest.validId(id)) {
        log.err("\"{s}\" can't be a plugin's id: 2 to 64 lowercase letters, digits, _ or -", .{id});
        return 1;
    };
    const interactive = !options.yes and (std.Io.File.stdin().isTty(io) catch false);
    var stdin_buf: [1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &stdin_buf);
    var ask: Asker = .{ .arena = arena, .reader = if (interactive) &stdin.interface else null };

    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", arena);
    const folder_given = options.folder orelse try ask.line("Folder", options.id orelse "my-plugin");
    const folder = try std.fs.path.resolve(arena, &.{ cwd, folder_given });
    if (!emptyOrMissing(io, folder)) {
        log.err("{s} isn't empty", .{folder});
        return 1;
    }
    const id = options.id orelse id: {
        const guess = try toId(arena, std.fs.path.basename(folder));
        while (true) {
            const answer = try ask.line("Id (its folder once installed)", guess);
            if (core.manifest.validId(answer)) break :id answer;
            log.printLn("2 to 64 lowercase letters, digits, _ or -", .{});
        }
    };
    const title = options.title orelse try ask.line("Title", try toTitle(arena, id));
    const author = options.author orelse try ask.line("Author", "");
    const language = options.language orelse language: {
        if (!interactive) {
            log.err("Which language? Say with --language zig, ts, js, lua or cs", .{});
            return 1;
        }
        while (true) {
            const answer = try ask.line("Language: zig, ts, js, lua or cs", "zig");
            if (std.meta.stringToEnum(Language, answer)) |l| break :language l;
        }
    };
    const runtime: Runtime = if (language != .cs) .aot else options.runtime orelse runtime: {
        while (true) {
            const answer = try ask.line("C# runs as aot (compiled, games need no .NET) or clr (.NET runs it, so it reloads)", "aot");
            if (std.meta.stringToEnum(Runtime, answer)) |r| break :runtime r;
        }
    };
    const game = options.game orelse try ask.line("Game it's for: its exe, or an id from `wraith games` (empty: any game)", "");
    const target = try forGame(ctx, arena, &ask, if (game.len == 0) null else game, options.engine) orelse return 1;
    const dev = options.dev orelse try ask.yes("Load it from where it builds while you work on it?", true);

    var manifest: Manifest = .{
        .id = id,
        .version = "0.0.0",
        .apiVersion = core.manifest.api_version,
        .title = title,
        .summary = options.summary orelse try std.fmt.allocPrint(arena, "{s}, a Wraith plugin", .{title}),
        .author = if (author.len > 0) author else null,
        .wraith = if (std.mem.eql(u8, build_info.version, core.manifest.dev_version)) null else build_info.version,
        .game = target.game,
        .gameEngine = target.engine,
        .provider = switch (language) {
            .zig => null,
            .ts, .js => "js",
            .lua => "lua",
            .cs => "cs",
        },
        .library = options.library,
        // Scripts run in either. Native plugins build per arch, and C#'s types are for one pointer size
        .arches = switch (language) {
            .zig => if (target.arch) |a| try arena.dupe(core.arch.Arch, &.{a}) else null,
            .cs => try arena.dupe(core.arch.Arch, &.{target.arch orelse .x64}),
            .ts, .js, .lua => null,
        },
    };
    if (language == .zig and manifest.arches != null) log.printLn("It's {s}, so it builds for {t} only. Take arches out of wraith.json to build both", .{ if (target.arch.? == .x64) "64-bit" else "32-bit", target.arch.? });

    log.printLn("", .{});
    const built = switch (language) {
        .zig => try makeZig(ctx, arena, folder, manifest),
        .ts, .js => try makeJs(ctx, arena, cwd, folder, &manifest, language),
        .lua => try makeLua(ctx, arena, folder, manifest),
        .cs => try makeCs(ctx, arena, folder, manifest, runtime),
    } orelse return 2;

    log.printLn("\nMade {s}, a {s} plugin, in {s}", .{ title, language.title(), folder });
    if (dev) {
        std.Io.Dir.cwd().createDirPath(io, built) catch {};
        const list = try core.dev_plugins.pathAlloc(arena, try ops.locations(arena));
        if (core.dev_plugins.add(arena, io, list, built)) |_| {
            log.printLn("Wraith loads it from {s} while you work on it. Refresh in the overlay's Mods window", .{built});
        } else |err| log.warn("Couldn't add it as a dev plugin: {t}. wraith dev add {s} does", .{ err, built });
    }
    const where = relative(arena, cwd, folder);
    log.printLn("\nNext:\n  cd {s}", .{where});
    switch (language) {
        .zig => log.printLn("  zig build", .{}),
        .ts, .js => log.printLn("  npm install\n  npm run dev", .{}),
        .lua => log.printLn("  (edit main.lua, then Reload it in the Mods window)", .{}),
        .cs => log.printLn("  dotnet publish", .{}),
    }
    if (!dev) log.printLn("  wraith dev add {s}", .{relative(arena, cwd, built)});
    return 0;
}

/// From `cwd`, or all of it if that won't do.
fn relative(arena: std.mem.Allocator, cwd: []const u8, path: []const u8) []const u8 {
    const rel = std.fs.path.relativeAlloc(arena, cwd, null, cwd, path) catch return path;
    return if (rel.len == 0) "." else rel;
}

fn usageError() u8 {
    log.err("Usage:\n{s}", .{usage});
    return 1;
}

fn parseArgs(args: anytype) !Options {
    var o: Options = .{};
    var pending: ?[]const u8 = null;
    while (pending orelse args.next()) |arg| {
        pending = null;
        if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
            o.yes = true;
        } else if (std.mem.eql(u8, arg, "--library")) {
            o.library = true;
        } else if (std.mem.eql(u8, arg, "--dev")) {
            o.dev = true;
        } else if (std.mem.eql(u8, arg, "--no-dev")) {
            o.dev = false;
        } else if (std.mem.eql(u8, arg, "--engine")) {
            // Its name's optional, so what's next may be the next flag or the folder
            o.engine = "";
            if (args.next()) |next| {
                if (std.mem.startsWith(u8, next, "--") or !isEngine(next)) pending = next else o.engine = next;
            }
        } else if (std.mem.eql(u8, arg, "--language") or std.mem.eql(u8, arg, "--lang")) {
            o.language = std.meta.stringToEnum(Language, args.next() orelse return error.Usage) orelse return error.Usage;
        } else if (std.mem.eql(u8, arg, "--runtime")) {
            o.runtime = std.meta.stringToEnum(Runtime, args.next() orelse return error.Usage) orelse return error.Usage;
        } else if (std.mem.eql(u8, arg, "--game")) {
            o.game = args.next() orelse return error.Usage;
        } else if (std.mem.eql(u8, arg, "--id") or std.mem.eql(u8, arg, "--name")) {
            o.id = args.next() orelse return error.Usage;
        } else if (std.mem.eql(u8, arg, "--title")) {
            o.title = args.next() orelse return error.Usage;
        } else if (std.mem.eql(u8, arg, "--summary")) {
            o.summary = args.next() orelse return error.Usage;
        } else if (std.mem.eql(u8, arg, "--author")) {
            o.author = args.next() orelse return error.Usage;
        } else if (std.mem.startsWith(u8, arg, "--") or o.folder != null) {
            return error.Usage;
        } else {
            o.folder = arg;
        }
    }
    return o;
}

/// Like `unity` or `unity:IL2CPP`.
fn isEngine(text: []const u8) bool {
    const name = text[0 .. std.mem.indexOfScalar(u8, text, ':') orelse text.len];
    return std.meta.stringToEnum(game_engine.GameEngine, name) != null;
}

/// Its game or game engine, for its wraith.json. Neither is any game.
const Target = struct {
    game: ?core.manifest.Game = null,
    engine: ?core.manifest.GameEngine = null,
    /// What its exe was built for, so a Zig plugin only builds that.
    arch: ?core.arch.Arch = null,
};

/// Null once it's said why not.
fn forGame(ctx: ops.Context, arena: std.mem.Allocator, ask: *Asker, game: ?[]const u8, engine: ?[]const u8) !?Target {
    if (engine) |named| if (named.len > 0) {
        if (!isEngine(named)) {
            log.err("There's no game engine {s}. It's one of: {s}", .{ named, try engineList(arena) });
            return null;
        }
        return .{ .engine = engineOf(arena, named) };
    };
    const given = game orelse {
        if (engine != null) {
            log.err("--engine without a name takes the --game's, so it needs the game's exe", .{});
            return null;
        }
        return .{};
    };
    if (!std.ascii.endsWithIgnoreCase(given, ".exe")) {
        if (engine != null) {
            log.err("--engine without a name takes the game's, so --game needs its exe, not its id", .{});
            return null;
        }
        return .{ .game = .{ .ids = try arena.dupe([]const u8, &.{given}) } };
    }
    const found = ops.identify(ctx, arena, given) catch return null;
    const exe = std.fs.path.basename(given);
    const made_with = game_engine.ofInstall(arena, ctx.io, found.dir) catch null;
    // Like `unity:IL2CPP` for its wraith.json, and `Unity IL2CPP` to ask
    var engine_name: []const u8 = "";
    var engine_label: []const u8 = "";
    if (made_with) |e| {
        engine_name = if (e.variant) |v| try std.fmt.allocPrint(arena, "{s}:{s}", .{ @tagName(e.game_engine), v }) else @tagName(e.game_engine);
        engine_label = if (e.variant) |v| try std.fmt.allocPrint(arena, "{s} {s}", .{ e.game_engine.label(), v }) else e.game_engine.label();
    }
    log.printLn("{s} is {s} ({t}, id {s}){s}{s}", .{
        exe,
        found.name orelse found.id,
        found.store,
        found.id,
        if (made_with != null) ", made with " else "",
        engine_label,
    });
    const for_engine = if (engine != null) true else if (made_with != null)
        try ask.yes(try std.fmt.allocPrint(arena, "For every {s} game, not just this one?", .{engine_label}), false)
    else
        false;
    if (for_engine) {
        if (made_with == null) {
            log.err("Wraith can't tell what {s} was made with, so name it: --engine <engine>", .{exe});
            return null;
        }
        return .{ .engine = engineOf(arena, engine_name) };
    }
    const arch: ?core.arch.Arch = if (ops.exeArch(ctx.io, given)) |a| switch (a) {
        .x86 => .x86,
        .x64 => .x64,
    } else |_| null;
    return .{
        .game = .{ .ids = try arena.dupe([]const u8, &.{found.id}), .exes = try arena.dupe([]const u8, &.{exe}) },
        .arch = arch,
    };
}

fn engineOf(arena: std.mem.Allocator, text: []const u8) core.manifest.GameEngine {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return .{ .id = text };
    const variant = text[colon + 1 ..];
    if (variant.len == 0) return .{ .id = text[0..colon] };
    return .{ .id = text[0..colon], .variants = arena.dupe([]const u8, &.{variant}) catch &.{} };
}

fn engineList(arena: std.mem.Allocator) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (std.enums.values(game_engine.GameEngine), 0..) |e, i| try out.writer.print("{s}{t}", .{ if (i > 0) ", " else "", e });
    return out.written();
}

/// Asks on the terminal, or takes the default without one.
const Asker = struct {
    arena: std.mem.Allocator,
    reader: ?*std.Io.Reader,

    fn line(self: *Asker, question: []const u8, default: []const u8) ![]const u8 {
        const r = self.reader orelse return default;
        if (default.len > 0) log.print("{s} ({s}): ", .{ question, default }) else log.print("{s}: ", .{question});
        const answer = std.mem.trim(u8, (r.takeDelimiter('\n') catch null) orelse "", " \t\r");
        return if (answer.len == 0) default else try self.arena.dupe(u8, answer);
    }

    fn yes(self: *Asker, question: []const u8, default: bool) !bool {
        if (self.reader == null) return default;
        const answer = try self.line(question, if (default) "Y/n" else "y/N");
        if (answer.len == 0 or answer[0] == 'Y' or answer[0] == 'N') return default;
        return answer[0] == 'y';
    }
};

fn emptyOrMissing(io: std.Io, folder: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch |err| return err == error.FileNotFound;
    defer dir.close(io);
    var it = dir.iterate();
    return (it.next(io) catch return false) == null;
}

/// From a folder's name, like `My Plugin` to `my-plugin`.
pub fn toId(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (name) |ch| {
        const c = std.ascii.toLower(ch);
        if (std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_') {
            try out.append(arena, c);
        } else if (out.items.len > 0 and out.items[out.items.len - 1] != '-') {
            try out.append(arena, '-');
        }
    }
    const trimmed = std.mem.trim(u8, out.items, "-_");
    const id = trimmed[0..@min(64, trimmed.len)];
    return if (core.manifest.validId(id)) id else "my-plugin";
}

/// `my-plugin` to `My Plugin`.
pub fn toTitle(arena: std.mem.Allocator, id: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var words = std.mem.tokenizeAny(u8, id, "-_");
    while (words.next()) |word| {
        if (out.items.len > 0) try out.append(arena, ' ');
        try out.append(arena, std.ascii.toUpper(word[0]));
        try out.appendSlice(arena, word[1..]);
    }
    return out.items;
}

/// What `zig fetch` gets: this release's tag, or the newest for a dev build.
pub fn fetchUrl(arena: std.mem.Allocator, version: []const u8) ![]const u8 {
    if (std.mem.eql(u8, version, core.manifest.dev_version)) return repo_url;
    return std.fmt.allocPrint(arena, "{s}#v{s}", .{ repo_url, version });
}

/// Runs it with the terminal, in `cwd`. False if it couldn't, or failed, said why.
fn runTool(ctx: ops.Context, argv: []const []const u8, cwd: []const u8) bool {
    var child = std.process.spawn(ctx.io, .{ .argv = argv, .cwd = .{ .path = cwd } }) catch |err| {
        log.err("Couldn't run {s}: {t}", .{ argv[0], err });
        return false;
    };
    const term = child.wait(ctx.io) catch |err| {
        log.err("{s} didn't finish: {t}", .{ argv[0], err });
        return false;
    };
    if (term == .exited and term.exited == 0) return true;
    log.err("{s} {s} failed", .{ argv[0], if (argv.len > 1) argv[1] else "" });
    return false;
}

/// What it says to `--version` or `version`, trimmed. Null if it's not there.
fn toolVersion(ctx: ops.Context, arena: std.mem.Allocator, argv: []const []const u8) ?[]const u8 {
    const result = std.process.run(arena, ctx.io, .{ .argv = argv }) catch return null;
    if (result.term != .exited or result.term.exited != 0) return null;
    return std.mem.trim(u8, result.stdout, " \r\n");
}

fn writeFile(ctx: ops.Context, folder: []const u8, name: []const u8, data: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(ctx.io, folder, .{});
    defer dir.close(ctx.io);
    if (std.fs.path.dirname(name)) |sub| try dir.createDirPath(ctx.io, sub);
    try dir.writeFile(ctx.io, .{ .sub_path = name, .data = data });
}

fn readManifest(ctx: ops.Context, arena: std.mem.Allocator, folder: []const u8) ?Manifest {
    var dir = std.Io.Dir.cwd().openDir(ctx.io, folder, .{}) catch return null;
    defer dir.close(ctx.io);
    const text = dir.readFileAlloc(ctx.io, core.manifest.file_name, arena, .limited(64 << 10)) catch return null;
    return core.manifest.parse(arena, text, null) catch null;
}

fn writeManifest(ctx: ops.Context, arena: std.mem.Allocator, folder: []const u8, manifest: Manifest) !void {
    try writeFile(ctx, folder, core.manifest.file_name, try manifest.toJson(arena));
}

/// zig init and fetch, then its build, code and manifest. Where it builds to, or null.
fn makeZig(ctx: ops.Context, arena: std.mem.Allocator, folder: []const u8, manifest: Manifest) !?[]const u8 {
    const have = toolVersion(ctx, arena, &.{ "zig", "version" }) orelse {
        log.err("Zig isn't on your PATH. Wraith plugins need Zig {s}: https://ziglang.org/download", .{builtin.zig_version_string});
        return null;
    };
    if (!std.mem.eql(u8, have, builtin.zig_version_string)) {
        log.warn("This Wraith is built with Zig {s} and you have {s}. Zig changes fast, so match it exactly if the build fails", .{ builtin.zig_version_string, have });
    }
    try std.Io.Dir.cwd().createDirPath(ctx.io, folder);
    if (!runTool(ctx, &.{ "zig", "init", "--minimal" }, folder)) return null;
    log.printLn("Fetching Wraith's SDK...", .{});
    if (!runTool(ctx, &.{ "zig", "fetch", "--save=wraith", try fetchUrl(arena, build_info.version) }, folder)) return null;
    try writeFile(ctx, folder, "build.zig", try std.fmt.allocPrint(arena, zig_build, .{manifest.id}));
    try writeFile(ctx, folder, "src/root.zig", zig_root);
    try writeManifest(ctx, arena, folder, manifest);
    try writeIgnore(ctx, folder, "zig-out/\n.zig-cache/\n");
    return try std.fs.path.join(arena, &.{ folder, "zig-out" });
}

/// npm create, then its manifest. Where it builds to, or null.
fn makeJs(ctx: ops.Context, arena: std.mem.Allocator, cwd: []const u8, folder: []const u8, manifest: *Manifest, language: Language) !?[]const u8 {
    if (toolVersion(ctx, arena, &.{ "npm", "--version" }) == null) {
        log.err("npm isn't on your PATH. Install Node from https://nodejs.org", .{});
        return null;
    }
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "npm", "create", "@ratatoskr.io/plugin@latest", folder, "--", "--name", manifest.id, "--title", manifest.title.?, "--yes" });
    if (manifest.summary) |s| try argv.appendSlice(arena, &.{ "--summary", s });
    if (manifest.author) |a| try argv.appendSlice(arena, &.{ "--author", a });
    if (language == .js) try argv.append(arena, "--js");
    if (!runTool(ctx, argv.items, cwd)) return null;
    // Its own, with the game and engine as found here, keeping the oldest Wraith it found
    if (manifest.wraith == null) if (readManifest(ctx, arena, folder)) |made| {
        manifest.wraith = made.wraith;
    };
    try writeManifest(ctx, arena, folder, manifest.*);
    return try std.fs.path.join(arena, &.{ folder, "dist" });
}

/// Its manifest and main.lua, then its types. Where it loads from, or null.
fn makeLua(ctx: ops.Context, arena: std.mem.Allocator, folder: []const u8, manifest: Manifest) !?[]const u8 {
    try std.Io.Dir.cwd().createDirPath(ctx.io, folder);
    try writeManifest(ctx, arena, folder, manifest);
    try writeFile(ctx, folder, "main.lua", lua_main);
    try writeIgnore(ctx, folder, ".wraith/\n");
    // For LuaLS, from this wraith
    const self = try std.process.executablePathAlloc(ctx.io, arena);
    if (!runTool(ctx, &.{ self, "sdk", "lua", "types" }, folder)) log.warn("No Lua types yet. wraith sdk lua types in its folder makes them", .{});
    return folder;
}

/// Its project, code and manifest, then its types. Where it publishes to, or null.
fn makeCs(ctx: ops.Context, arena: std.mem.Allocator, folder: []const u8, manifest: Manifest, runtime: Runtime) !?[]const u8 {
    if (toolVersion(ctx, arena, &.{ "dotnet", "--version" }) == null) {
        log.err("dotnet isn't on your PATH. C# plugins need the .NET 10 SDK: https://dot.net", .{});
        return null;
    }
    const arch = manifest.arches.?[0];
    const ns = try sdk.pascal(arena, manifest.id);
    const pointer_size: []const u8 = if (arch == .x86) "4" else "8";
    const how = switch (runtime) {
        .aot => try std.fmt.allocPrint(arena, cs_aot, .{ if (arch == .x86) "win-x86" else "win-x64", manifest.id, @tagName(arch) }),
        .clr => try std.fmt.allocPrint(arena, cs_clr, .{manifest.id}),
    };
    try std.Io.Dir.cwd().createDirPath(ctx.io, folder);
    try writeFile(ctx, folder, try std.fmt.allocPrint(arena, "{s}.csproj", .{ns}), try std.fmt.allocPrint(arena, cs_project, .{ how, pointer_size }));
    try writeFile(ctx, folder, "Plugin.cs", try std.fmt.allocPrint(arena, cs_plugin, .{ ns, ns }));
    try writeManifest(ctx, arena, folder, manifest);
    try writeIgnore(ctx, folder, "bin/\nobj/\ndist/\n.wraith/\n");
    // So an editor knows Wraith's API before the first build
    const self = try std.process.executablePathAlloc(ctx.io, arena);
    if (!runTool(ctx, &.{ self, "sdk", "cs", "types", "--pointer-size", pointer_size }, folder)) log.warn("No C# types yet. The first build makes them", .{});
    return try std.fs.path.join(arena, &.{ folder, "dist" });
}

fn writeIgnore(ctx: ops.Context, folder: []const u8, text: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(ctx.io, folder, .{});
    defer dir.close(ctx.io);
    // zig init may have made one
    if (dir.access(ctx.io, ".gitignore", .{})) |_| return else |_| {}
    try dir.writeFile(ctx.io, .{ .sub_path = ".gitignore", .data = text });
}

const zig_build =
    \\const std = @import("std");
    \\const wraith = @import("wraith");
    \\
    \\pub fn build(b: *std.Build) void {{
    \\    const plugin: wraith.Plugin = .init(b, .{{
    \\        .name = "{s}",
    \\        .root_source_file = b.path("src/root.zig"),
    \\        .target = b.standardTargetOptions(.{{}}),
    \\        .optimize = b.standardOptimizeOption(.{{}}),
    \\    }});
    \\    plugin.install(b);
    \\}}
    \\
;

const zig_root =
    \\const std = @import("std");
    \\const sdk = @import("wraith_sdk");
    \\
    \\pub const std_options: std.Options = .{ .logFn = sdk.logFn };
    \\pub const panic = sdk.panic;
    \\
    \\const log = sdk.log.scoped(.plugin);
    \\
    \\pub const Plugin = struct {
    \\    ctx: *sdk.Context = undefined,
    \\
    \\    pub fn start(self: *Plugin, ctx: *sdk.Context) !void {
    \\        self.ctx = ctx;
    \\        log.info("Hello!", .{});
    \\    }
    \\
    \\    pub fn stop(self: *Plugin) void {
    \\        _ = self;
    \\    }
    \\};
    \\
    \\comptime {
    \\    sdk.exportPlugin(Plugin);
    \\}
    \\
;

const lua_main =
    \\local Wraith = require("wraith").Wraith
    \\
    \\Wraith.log():info("Hello!")
    \\
;

/// How it's built, then the pointer size its types are for.
const cs_project =
    \\<Project Sdk="Microsoft.NET.Sdk">
    \\  <PropertyGroup>
    \\    <TargetFramework>net10.0</TargetFramework>
    \\    <Nullable>enable</Nullable>
    \\    <AllowUnsafeBlocks>true</AllowUnsafeBlocks>
    \\{s}
    \\    <PublishDir>dist/</PublishDir>
    \\    <DefaultItemExcludes>$(DefaultItemExcludes);dist/**</DefaultItemExcludes>
    \\    <!-- The WRAITH environment variable can point at a wraith.exe -->
    \\    <Wraith Condition="'$(Wraith)' == ''">wraith</Wraith>
    \\  </PropertyGroup>
    \\
    \\  <ItemGroup>
    \\    <None Update="wraith.json;schemas/*.sal" CopyToPublishDirectory="PreserveNewest" />
    \\  </ItemGroup>
    \\
    \\  <!-- Wraith's API and the schemas as C#, in .wraith/cs, made again when they change -->
    \\  <Target Name="WraithTypes" BeforeTargets="BeforeBuild" Inputs="wraith.json;@(None)" Outputs=".wraith/cs/Schema.cs">
    \\    <Exec Command="&quot;$(Wraith)&quot; sdk cs types --pointer-size {s}" />
    \\  </Target>
    \\  <Target Name="WraithSources" AfterTargets="WraithTypes" BeforeTargets="BeforeBuild">
    \\    <ItemGroup>
    \\      <Compile Include=".wraith/cs/*.cs" />
    \\    </ItemGroup>
    \\  </Target>
    \\</Project>
    \\
;

/// Its runtime, id and arch.
const cs_aot =
    \\    <!-- Compiled with NativeAOT into a native DLL, so the game needs no .NET -->
    \\    <RuntimeIdentifier>{s}</RuntimeIdentifier>
    \\    <PublishAot>true</PublishAot>
    \\    <NativeLib>Shared</NativeLib>
    \\    <AssemblyName>wraith_{s}_{s}</AssemblyName>
;

const cs_clr =
    \\    <!-- Run by .NET, the game's or the installed one. Wraith finds it by this name -->
    \\    <AssemblyName>wraith_{s}</AssemblyName>
    \\    <!-- Its dependencies go beside it, where Wraith looks for them -->
    \\    <CopyLocalLockFileAssemblies>true</CopyLocalLockFileAssemblies>
;

const cs_plugin =
    \\using Wraith;
    \\
    \\namespace {s}
    \\{{
    \\    sealed class Main : WraithPlugin
    \\    {{
    \\        public override void Start(Context context)
    \\        {{
    \\            Log.Instance.Info("Hello!");
    \\        }}
    \\    }}
    \\}}
    \\
    \\namespace Wraith
    \\{{
    \\    // The plugin Wraith starts
    \\    static partial class Entry
    \\    {{
    \\        internal static partial WraithPlugin Create() => new global::{s}.Main();
    \\    }}
    \\}}
    \\
;

const testing = std.testing;

test "ids and titles from a folder's name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("my-plugin", try toId(a, "My Plugin"));
    try testing.expectEqualStrings("kai_tools", try toId(a, "kai_tools"));
    try testing.expectEqualStrings("my-plugin", try toId(a, "!!"));
    try testing.expectEqualStrings("Kai Tools", try toTitle(a, "kai_tools"));
}

test "a release fetches its own tag" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(repo_url, try fetchUrl(arena.allocator(), "0.0.0"));
    try testing.expectEqualStrings(repo_url ++ "#v0.2.1", try fetchUrl(arena.allocator(), "0.2.1"));
}

test "an engine and its variant, for every game made with it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const engine: Manifest = .{ .id = "unity_tools", .title = "Unity tools", .gameEngine = engineOf(a, "unity:IL2CPP") };
    const e = try core.manifest.parse(a, try engine.toJson(a), null);
    try testing.expect(e.isFor(.{ .game_engine = "unity", .game_engine_variant = "IL2CPP" }));
    try testing.expect(!e.isFor(.{ .game_engine = "unity", .game_engine_variant = "Mono" }));
    try testing.expect(engineOf(a, "unity").variants.len == 0);
}

test "flags, with --engine's name optional" {
    const Args = struct {
        items: []const []const u8,
        at: usize = 0,
        fn next(self: *@This()) ?[]const u8 {
            if (self.at == self.items.len) return null;
            defer self.at += 1;
            return self.items[self.at];
        }
    };
    var with_name: Args = .{ .items = &.{ "kai", "--language", "lua", "--engine", "unity:Mono", "--yes" } };
    const a = try parseArgs(&with_name);
    try testing.expectEqualStrings("kai", a.folder.?);
    try testing.expectEqual(.lua, a.language.?);
    try testing.expectEqualStrings("unity:Mono", a.engine.?);
    try testing.expect(a.yes);
    var bare: Args = .{ .items = &.{ "--game", "D:\\kai.exe", "--engine", "kai" } };
    const b = try parseArgs(&bare);
    try testing.expectEqualStrings("", b.engine.?);
    try testing.expectEqualStrings("kai", b.folder.?);
    var bad: Args = .{ .items = &.{ "--language", "cobol" } };
    try testing.expectError(error.Usage, parseArgs(&bad));
    var cs: Args = .{ .items = &.{ "--language", "cs", "--runtime", "clr" } };
    try testing.expectEqual(.clr, (try parseArgs(&cs)).runtime.?);
    var bad_runtime: Args = .{ .items = &.{ "--runtime", "mono" } };
    try testing.expectError(error.Usage, parseArgs(&bad_runtime));
}
