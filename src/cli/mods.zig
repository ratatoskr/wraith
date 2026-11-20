//! `wraith mods`: list and install mods from the Wraith Hub. Mods are plugins and projects, and
//! both go in the same folder. Wraith loads the plugins and leaves projects to the Workbench.

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
    const yours = ops.discover(ctx, arena) catch &.{};
    const ids = try arena.alloc([]const u8, yours.len);
    for (ids, yours) |*id, g| id.* = g.id;
    // Each game's engine, so mods for every game made with it are listed under it too
    var made_with: std.ArrayList(registry.mods.MadeWith) = .empty;
    for (yours) |g| if (games.game_engine.ofInstall(arena, ctx.io, g.dir) catch null) |e| {
        try made_with.append(arena, .{ .game = g.id, .here = .{ .game_engine = @tagName(e.game_engine), .game_engine_variant = e.variant } });
    };
    const listing = try registry.mods.list(arena, ctx.io, w.source, w.mods_dir, w.wraith, ids, made_with.items);
    return .{ .generated = listing.generated, .mods_dir = w.mods_dir, .mods = listing.mods };
}

/// Null `version` means the newest this Wraith runs, plus any mods it needs.
pub fn install(ctx: ops.Context, arena: std.mem.Allocator, id: []const u8, version: ?[]const u8) ![]const u8 {
    return registry.mods.install(arena, ctx.io, try where(ctx, arena), id, version);
}

pub fn remove(ctx: ops.Context, arena: std.mem.Allocator, id: []const u8) !void {
    const w = try where(ctx, arena);
    return registry.mods.remove(arena, ctx.io, w.mods_dir, id);
}

pub const Updated = registry.mods.Updated;

/// Failures get logged and the rest still update.
pub fn updateAll(ctx: ops.Context, arena: std.mem.Allocator) ![]const Updated {
    return registry.mods.update(arena, ctx.io, try where(ctx, arena), null);
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
    const at = try setup(ctx, arena);
    const io = ctx.io;
    var shown: std.ArrayList(registry.Entry) = .empty;
    if (game_arg) |arg| {
        const id = gameIdOf(ctx, arena, arg) orelse {
            log.err("Couldn't tell which game {s} is", .{arg});
            return 2;
        };
        const for_game = registry.forGame(arena, io, at.source, id) catch |err| {
            log.err("Couldn't get the mods for {s}: {t}", .{ id, err });
            return 2;
        };
        if (for_game) |g| {
            log.printLn("For {s}:", .{if (g.game) |info| info.name else id});
            try shown.appendSlice(arena, g.packages);
        } else log.printLn("Nothing on the hub for {s} yet", .{id});
        if (madeWith(ctx, arena, arg, id)) |here| {
            if (registry.forGameEngine(arena, io, at.source, here.game_engine.?) catch null) |l| {
                for (l.packages) |e| if (e.gameEngine == null or e.gameEngine.?.matches(here)) try shown.append(arena, e);
            }
        }
    } else {
        try shown.appendSlice(arena, (registry.featured(arena, io, at.source) catch return 2).packages);
    }
    const any = registry.anyGame(arena, io, at.source) catch return 2;
    for (any.packages) |e| {
        const seen = for (shown.items) |s| {
            if (std.mem.eql(u8, s.id, e.id)) break true;
        } else false;
        if (!seen) try shown.append(arena, e);
    }

    for (shown.items) |e| {
        const runs = registry.satisfies(build_info.version, e.wraith orelse "0.0.0");
        const have = try registry.installed(arena, io, at.mods_dir, e.id);
        log.print("{s: <20} {s: <10} {s}{s}", .{ e.id, e.version, e.title, if (e.featured) "  (recommended)" else "" });
        if (have) |h| {
            const outdated = runs and registry.compareVersions(e.version, h.version) == .gt;
            log.print("  [installed {s}{s}]", .{ h.version, if (outdated) ", update available" else "" });
        }
        if (!runs) log.print("  (needs Wraith {s})", .{e.wraith.?});
        log.print("\n", .{});
    }
    if (shown.items.len == 0) log.printLn("None", .{});
    log.printLn("Installed in {s}", .{at.mods_dir});
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
