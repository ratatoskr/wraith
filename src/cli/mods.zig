//! `wraith mods`: list and install mods (plugins and projects) from the Wraith Hub.

const std = @import("std");

const core = @import("wraith_core");
const games = @import("wraith_game");
const platform = @import("wraith_platform");
const registry = @import("wraith_registry");
const build_info = @import("build_info");

const ops = @import("ops.zig");

const log = core.log.scoped(.wraith_cli);

pub const usage =
    \\  mods [<game.exe | game id>]          mods from the hub, plugins and projects: ours, ones
    \\                                       for any game, and those for the game and its game
    \\                                       engine, if given (see `games` for IDs)
    \\  mods install <id> [<version>]        install one (its newest, unless a version's given),
    \\                                       or update it, plus any mods it needs
    \\  mods update                          update every installed one that has a newer version,
    \\                                       and take out any the hub pulled
    \\  mods remove <id>                     take one out (only one installed from the hub)
;

pub const Setup = struct {
    source: registry.Source,
    /// Where mods go, plugins and projects alike.
    mods_dir: []const u8,
};

pub fn setup(ctx: ops.Context, arena: std.mem.Allocator) !Setup {
    _ = ctx;
    const locations = try ops.locations(arena);
    const cache_dir = try std.fs.path.join(arena, &.{ locations.root, "cache", registry.cache_folder });
    const source: registry.Source = try .of(
        cache_dir,
        try platform.process.envAlloc(arena, "WRAITH_REGISTRY"),
        try platform.process.envAlloc(arena, "WRAITH_REGISTRY_KEY"),
    );
    return .{ .source = source, .mods_dir = locations.mods };
}

pub const Listed = registry.mods.Listed;

pub const Catalog = struct {
    generated: []const u8,
    mods_dir: []const u8,
    mods: []const Listed,
};

fn where(ctx: ops.Context, arena: std.mem.Allocator) !registry.mods.Where {
    const s = try setup(ctx, arena);
    return .{ .source = s.source, .mods_dir = s.mods_dir, .wraith = build_info.version };
}

/// The hub's for any game and for your games, plus what's installed.
pub fn catalog(ctx: ops.Context, arena: std.mem.Allocator) !Catalog {
    const w = try where(ctx, arena);
    const yours = try yourGames(ctx, arena);
    const listing = try registry.mods.list(arena, ctx.io, try w.index(arena, ctx.io), w.mods_dir, w.wraith, yours.ids, yours.made_with);
    return .{ .generated = listing.generated, .mods_dir = w.mods_dir, .mods = listing.mods };
}

const Yours = struct {
    ids: []const []const u8,
    /// Each game by id, exe and engine, so engine-wide mods and essentials are found too.
    made_with: []const registry.mods.MadeWith,
};

fn yourGames(ctx: ops.Context, arena: std.mem.Allocator) !Yours {
    const found = ops.discover(ctx, arena) catch &.{};
    const ids = try arena.alloc([]const u8, found.len);
    for (ids, found) |*id, g| id.* = g.id;
    const made_with = try arena.alloc(registry.mods.MadeWith, found.len);
    for (made_with, found) |*m, g| m.* = try gameMadeWith(ctx, arena, g);
    return .{ .ids = ids, .made_with = made_with };
}

fn gameMadeWith(ctx: ops.Context, arena: std.mem.Allocator, g: games.Game) !registry.mods.MadeWith {
    const engine = games.game_engine.ofInstall(arena, ctx.io, g.dir) catch null;
    return .{ .game = g.id, .here = .{
        .id = g.id,
        .exe = g.launch.game_exe,
        .game_engine = if (engine) |e| @tagName(e.game_engine) else null,
        .game_engine_variant = if (engine) |e| e.variant else null,
    } };
}

pub const Kept = struct {
    id: []const u8,
    title: []const u8,
    /// Null if it was just added.
    was: ?[]const u8,
    version: []const u8,
    /// The game engine it's for, like `unity`. Null for one that's for a game.
    game_engine: ?[]const u8,
};

pub const KeepOptions = struct {
    /// Only this game's, by its id, like right before it's played. Null is every game's.
    game: ?[]const u8 = null,
    /// Only update ones that are installed, adding none.
    installed_only: bool = false,
};

/// Installs or updates essential mods for your games and engines. Failures are logged, not fatal.
pub fn keepEssentials(ctx: ops.Context, arena: std.mem.Allocator, options: KeepOptions) ![]const Kept {
    const w = try where(ctx, arena);
    const made_with = if (options.game) |id| blk: {
        const g = for (ops.discover(ctx, arena) catch &.{}) |g| {
            if (std.mem.eql(u8, g.id, id)) break g;
        } else return error.GameNotFound;
        break :blk try arena.dupe(registry.mods.MadeWith, &.{try gameMadeWith(ctx, arena, g)});
    } else (try yourGames(ctx, arena)).made_with;
    const index = try w.index(arena, ctx.io);
    var kept: std.ArrayList(Kept) = .empty;
    for (try registry.mods.essentials(arena, ctx.io, index, w, made_with, null)) |e| {
        if (options.installed_only and e.installed == null) continue;
        _ = registry.mods.install(arena, ctx.io, index, w, e.id, e.latest) catch |err| {
            log.err("Couldn't {s} {s}: {t}", .{ if (e.installed == null) "add" else "update", e.id, err });
            continue;
        };
        try kept.append(arena, .{ .id = e.id, .title = e.title, .was = e.installed, .version = e.latest, .game_engine = e.game_engine });
    }
    return kept.items;
}

/// Null `version` means the newest this Wraith runs, plus any mods it needs.
pub fn install(ctx: ops.Context, arena: std.mem.Allocator, id: []const u8, version: ?[]const u8) ![]const u8 {
    const w = try where(ctx, arena);
    return registry.mods.install(arena, ctx.io, try w.index(arena, ctx.io), w, id, version);
}

pub fn remove(ctx: ops.Context, arena: std.mem.Allocator, id: []const u8) !void {
    const w = try where(ctx, arena);
    return registry.mods.remove(arena, ctx.io, w.mods_dir, id);
}

pub const Updated = registry.mods.Updated;

/// Failures get logged and the rest still update.
pub fn updateAll(ctx: ops.Context, arena: std.mem.Allocator) ![]const Updated {
    const w = try where(ctx, arena);
    return registry.mods.update(arena, ctx.io, try w.index(arena, ctx.io), w, null);
}

pub fn run(ctx: ops.Context, args: anytype) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const first = args.next();
    const Sub = enum { install, update, remove };
    const sub = (if (first) |f| std.meta.stringToEnum(Sub, f) else null) orelse return list(ctx, arena, first);
    switch (sub) {
        .install => {
            const id = args.next() orelse {
                log.err("Which mod? Usage: wraith mods install <id> [<version>]", .{});
                return 1;
            };
            _ = install(ctx, arena, id, args.next()) catch return 2;
        },
        .update => {
            const updated = updateAll(ctx, arena) catch return 2;
            log.info("{d} mod(s) updated or taken out", .{updated.len});
        },
        .remove => {
            const id = args.next() orelse {
                log.err("Which mod? Usage: wraith mods remove <id>", .{});
                return 1;
            };
            remove(ctx, arena, id) catch return 2;
        },
    }
    return 0;
}

fn list(ctx: ops.Context, arena: std.mem.Allocator, game_arg: ?[]const u8) !u8 {
    const w = try where(ctx, arena);
    const index = w.index(arena, ctx.io) catch |err| {
        log.err("Couldn't get mods from the hub: {t}", .{err});
        return 2;
    };
    var ids: []const []const u8 = &.{};
    var made_with: []const registry.mods.MadeWith = &.{};
    if (game_arg) |arg| {
        const id = gameIdOf(ctx, arena, arg) orelse {
            log.err("Couldn't tell which game {s} is", .{arg});
            return 2;
        };
        ids = try arena.dupe([]const u8, &.{id});
        if (madeWith(ctx, arena, arg, id)) |here| made_with = try arena.dupe(registry.mods.MadeWith, &.{.{ .game = id, .here = here }});
        log.printLn("For {s}:", .{if (index.game(id)) |g| g.name else id});
    }
    const listing = try registry.mods.list(arena, ctx.io, index, w.mods_dir, w.wraith, ids, made_with);
    var shown: usize = 0;
    for (listing.mods) |m| {
        // Libraries come with the mods that need them, so only once they're here
        if (m.library and m.installed == null) continue;
        shown += 1;
        log.print("{s: <20} {s: <10} {s}{s}", .{ m.id, m.latest orelse m.installed orelse "-", m.title, if (m.featured) "  (recommended)" else "" });
        if (m.installed) |have| log.print("  [installed {s}{s}]", .{ have, if (m.revoked) ", pulled from the hub" else if (m.hasUpdate()) ", update available" else "" });
        if (m.latest == null and m.installed == null) {
            if (m.outdated) log.print("  (not updated for this Wraith yet)", .{}) else if (m.needs_wraith) |needs| log.print("  (needs Wraith {s})", .{if (needs.len > 0) needs else "newer"});
        }
        log.print("\n", .{});
    }
    if (shown == 0) log.printLn("None", .{});
    log.printLn("Installed in {s}", .{w.mods_dir});
    return 0;
}
/// What the game's made with, from its exe or, for an id, its install. Null if Wraith can't tell.
fn madeWith(ctx: ops.Context, arena: std.mem.Allocator, arg: []const u8, id: []const u8) ?core.manifest.Here {
    const found = if (std.ascii.endsWithIgnoreCase(arg, ".exe"))
        games.game_engine.ofGame(arena, ctx.io, arg) catch null
    else blk: {
        const yours = ops.discover(ctx, arena) catch break :blk null;
        for (yours) |g| if (std.mem.eql(u8, g.id, id)) break :blk games.game_engine.ofInstall(arena, ctx.io, g.dir) catch null;
        break :blk null;
    };
    const e = found orelse return null;
    return .{ .game_engine = @tagName(e.game_engine), .game_engine_variant = e.variant };
}

/// An exe or a game ID.
fn gameIdOf(ctx: ops.Context, arena: std.mem.Allocator, arg: []const u8) ?[]const u8 {
    if (!std.ascii.endsWithIgnoreCase(arg, ".exe")) return arg;
    const found: games.Game = ops.identify(ctx, arena, arg) catch return null;
    return found.id;
}
