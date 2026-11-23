//! Mods from the hub alongside what's installed: what the CLI, the app and the overlay list,
//! install and update. Mods are plugins and projects, and both go in the same folder.

const std = @import("std");

const core = @import("wraith_core");

const registry = @import("root.zig");
const Source = registry.Source;

const log = core.log.scoped(.wraith_registry);

pub const Listed = struct {
    id: []const u8,
    kind: registry.Kind,
    title: []const u8,
    summary: []const u8,
    author: []const u8,
    any_game: bool,
    /// Which of the games asked about it's for, by their game engine too.
    games: []const []const u8,
    /// Every game made with this game engine, instead of a list of games.
    game_engine: ?registry.GameEngine = null,
    /// Recommended, for every game or one of those.
    featured: bool,
    /// Why, if it's recommended for every game.
    why: ?[]const u8,
    /// Newest version this Wraith can run. Null if it can't.
    latest: ?[]const u8,
    /// The Wraith it needs, if that's why `latest` is null. Empty when it's for a newer Wraith's
    /// API, without saying which.
    needs_wraith: ?[]const u8,
    /// Its newest isn't made for this Wraith's API, see `core.manifest.api_version`, so it's
    /// waiting on its author to update it.
    outdated: bool = false,
    installed: ?[]const u8,
    /// The installed copy was pulled. `updateAll` takes it out, and Wraith won't load it.
    revoked: bool,
    /// Other mods use it and it comes with them, so it's not one to offer on its own. It's still
    /// here when installed, so it gets updated.
    library: bool = false,

    pub fn hasUpdate(self: Listed) bool {
        const have = self.installed orelse return false;
        const latest = self.latest orelse return false;
        return self.revoked or registry.compareVersions(latest, have) == .gt;
    }
};

pub const Listing = struct {
    generated: []const u8,
    mods: []const Listed,

    pub fn find(self: Listing, id: []const u8) ?*const Listed {
        for (self.mods) |*l| if (std.mem.eql(u8, l.id, id)) return l;
        return null;
    }
};

const Gather = struct {
    arena: std.mem.Allocator,
    wraith: []const u8,
    listed: std.ArrayList(Listed) = .empty,

    fn find(self: *Gather, id: []const u8) ?*Listed {
        for (self.listed.items) |*l| if (std.mem.eql(u8, l.id, id)) return l;
        return null;
    }

    /// `game` is one asked about it was listed for.
    fn add(self: *Gather, e: registry.Entry, game: ?[]const u8) !void {
        const l = self.find(e.id) orelse blk: {
            const api = core.manifest.ApiFit.of(e.apiVersion);
            const wraith_ok = registry.satisfies(self.wraith, e.wraith orelse "0.0.0");
            const runs = wraith_ok and api == .yes;
            try self.listed.append(self.arena, .{
                .id = e.id,
                .kind = e.kind,
                .title = e.title,
                .summary = e.summary,
                .author = e.author,
                .any_game = e.games.len == 0 and e.gameEngine == null,
                .games = &.{},
                .game_engine = e.gameEngine,
                .featured = false,
                .why = null,
                .latest = if (runs) e.version else null,
                .needs_wraith = if (!wraith_ok) e.wraith else if (api == .newer) e.wraith orelse "" else null,
                .outdated = wraith_ok and api == .outdated,
                .installed = null,
                .revoked = false,
                .library = e.library,
            });
            break :blk &self.listed.items[self.listed.items.len - 1];
        };
        if (e.featured) l.featured = true;
        if (e.why) |w| l.why = w;
        if (game) |g| l.games = try std.mem.concat(self.arena, []const u8, &.{ l.games, &.{g} });
    }
};

/// A game asked about, by the game engine it's made with.
pub const MadeWith = struct {
    /// Its id, which the mods for its engine are listed under. Null for one Wraith has no id for.
    game: ?[]const u8 = null,
    /// Its `game_engine` and `game_engine_variant`.
    here: core.manifest.Here,
};

/// Our picks, ones for any game, ones for `games`, by any id Wraith knows them by, and ones for the
/// game engines in `made_with`, plus what's installed. `wraith` is the running Wraith's version.
pub fn list(arena: std.mem.Allocator, io: std.Io, source: Source, mods_dir: []const u8, wraith: []const u8, games: []const []const u8, made_with: []const MadeWith) !Listing {
    var gather: Gather = .{ .arena = arena, .wraith = wraith };

    const picks = try registry.featured(arena, io, source);
    for (picks.packages) |e| try gather.add(e, null);
    const any = try registry.anyGame(arena, io, source);
    for (any.packages) |e| try gather.add(e, null);

    // Only fetch the lists of games the hub has something for
    const known = try registry.catalog(arena, io, source);
    for (games) |g| {
        if (known.find(g) == null) continue;
        const for_game = (registry.forGame(arena, io, source, g) catch continue) orelse continue;
        for (for_game.packages) |e| try gather.add(e, g);
    }

    // Each engine's list once, then just the kinds of it each game is
    var engine_lists: std.StringHashMapUnmanaged(?registry.List) = .empty;
    for (made_with) |m| {
        const engine = m.here.game_engine orelse continue;
        const got = try engine_lists.getOrPut(arena, engine);
        if (!got.found_existing) got.value_ptr.* = registry.forGameEngine(arena, io, source, engine) catch null;
        const for_engine = got.value_ptr.* orelse continue;
        for (for_engine.packages) |e| {
            if (e.gameEngine) |target| if (!target.matches(m.here)) continue;
            try gather.add(e, m.game);
        }
    }

    // Installed ones that aren't in any of those
    const revoked = registry.revoked(arena, io, source) catch &.{};
    for (try registry.installedAll(arena, io, mods_dir)) |have| {
        if (gather.find(have.id) == null) {
            // Still listed when the hub's dropped it or can't be asked, so it can be taken out
            if (registry.package(arena, io, source, have.id) catch null) |pkg| {
                const newest = registry.latest(pkg, wraith, null);
                try gather.add(.{
                    .id = pkg.id,
                    .kind = pkg.kind,
                    .author = pkg.author,
                    .title = pkg.title,
                    .summary = pkg.summary,
                    .version = if (newest) |v| v.version else have.version,
                    .wraith = if (newest) |v| v.wraith else null,
                    .apiVersion = if (newest) |v| v.apiVersion else null,
                    .games = if (newest) |v| if (v.game) |g| g.ids else &.{} else &.{},
                    .gameEngine = if (newest) |v| v.gameEngine else null,
                    .library = pkg.library,
                }, null);
            } else try gather.listed.append(arena, try installedOnly(arena, io, mods_dir, have));
        }
        const l = gather.find(have.id) orelse continue;
        l.installed = have.version;
        l.revoked = registry.isRevoked(revoked, have.sha256);
    }
    const generated = if (any.generated.len > 0) any.generated else if (picks.generated.len > 0) picks.generated else known.generated;
    return .{ .generated = generated, .mods = gather.listed.items };
}

/// One the hub doesn't have, or couldn't say about, from its own wraith.json.
fn installedOnly(arena: std.mem.Allocator, io: std.Io, mods_dir: []const u8, have: registry.Installed) !Listed {
    const path = try std.fs.path.join(arena, &.{ mods_dir, have.id, core.manifest.file_name });
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch "";
    const m: core.manifest.Manifest = core.manifest.parse(arena, text, null) catch .{};
    return .{
        .id = have.id,
        .kind = if (m.kind == .project) .project else .plugin,
        .title = m.title orelse "",
        .summary = m.summary orelse "",
        .author = m.author orelse "",
        .any_game = m.game == null and m.gameEngine == null,
        .games = &.{},
        .game_engine = m.gameEngine,
        .featured = false,
        .why = null,
        .latest = null,
        .needs_wraith = null,
        .installed = have.version,
        .revoked = false,
        .library = m.library,
    };
}

pub const Where = struct {
    source: Source,
    mods_dir: []const u8,
    /// The running Wraith's version.
    wraith: []const u8,
};

/// Null `version` means the newest this Wraith runs. What it depends on gets installed too, unless
/// it's there already. Returns the version installed.
pub fn install(arena: std.mem.Allocator, io: std.Io, where: Where, id: []const u8, version: ?[]const u8) ![]const u8 {
    var seen: std.ArrayList([]const u8) = .empty;
    return installWith(arena, io, where, id, version, &seen);
}

fn installWith(arena: std.mem.Allocator, io: std.Io, where: Where, id: []const u8, version: ?[]const u8, seen: *std.ArrayList([]const u8)) ![]const u8 {
    try seen.append(arena, id);
    const found = registry.package(arena, io, where.source, id) catch |err| {
        log.err("Couldn't get {s} from the hub: {t}", .{ id, err });
        return err;
    };
    const pkg = found orelse {
        log.err("There's no {s} on the hub", .{id});
        return error.NoSuchMod;
    };
    const chosen = if (version) |wanted| pkg.find(wanted) orelse {
        log.err("{s} has no version {s}", .{ id, wanted });
        return error.NoSuchVersion;
    } else registry.latest(pkg, where.wraith, null) orelse {
        if (pkg.versions.len > 0 and core.manifest.ApiFit.of(pkg.versions[0].apiVersion) == .outdated) {
            log.err("{s} hasn't been updated for this Wraith's API ({d}) yet", .{ id, core.manifest.api_version });
            return error.OutdatedApi;
        }
        log.err("No version of {s} runs on this Wraith ({s}): update Wraith", .{ id, where.wraith });
        return error.NeedsNewerWraith;
    };
    if (core.manifest.ApiFit.of(chosen.apiVersion) == .outdated) {
        log.err("{s} {s} is made for an older Wraith API, so this Wraith won't load it", .{ id, chosen.version });
        return error.OutdatedApi;
    }
    if (!chosen.runsOn(where.wraith)) {
        if (chosen.wraith) |needs| {
            log.err("{s} {s} needs Wraith {s} (this is {s}): update Wraith", .{ id, chosen.version, needs, where.wraith });
        } else log.err("{s} {s} is made for a newer Wraith's API: update Wraith", .{ id, chosen.version });
        return error.NeedsNewerWraith;
    }
    const revoked = registry.revoked(arena, io, where.source) catch &.{};
    if (registry.isRevoked(revoked, chosen.sha256)) {
        log.err("{s} {s} was pulled from the hub", .{ id, chosen.version });
        return error.Revoked;
    }
    try registry.install(arena, io, where.source, where.mods_dir, pkg, chosen);
    for (chosen.depends) |text| {
        const dep: core.manifest.Dependency = .parse(text);
        if (isSeen(seen.items, dep.name)) continue;
        if (try hasDependency(arena, io, where.mods_dir, dep)) continue;
        log.info("{s} needs {s}, installing it", .{ id, text });
        _ = installWith(arena, io, where, dep.name, null, seen) catch |err| {
            log.err("{s} is installed, but {s}, which it needs, couldn't be: {t}", .{ id, dep.name, err });
            return err;
        };
    }
    return chosen.version;
}

fn isSeen(seen: []const []const u8, name: []const u8) bool {
    for (seen) |s| if (std.ascii.eqlIgnoreCase(s, name)) return true;
    return false;
}

/// One from the hub that's new enough, or one put there by hand, which is left alone.
fn hasDependency(arena: std.mem.Allocator, io: std.Io, mods_dir: []const u8, dep: core.manifest.Dependency) !bool {
    if (try registry.installed(arena, io, mods_dir, dep.name)) |have| return dep.fits(have.version);
    const dir = try std.fs.path.join(arena, &.{ mods_dir, dep.name });
    std.Io.Dir.accessAbsolute(io, dir, .{}) catch return false;
    return true;
}

/// Only ones installed from the hub.
pub fn remove(arena: std.mem.Allocator, io: std.Io, mods_dir: []const u8, id: []const u8) !void {
    registry.remove(arena, io, mods_dir, id) catch |err| {
        if (err == error.NotFromRegistry) log.err("{s} in {s} wasn't installed from the hub: not removing it", .{ id, mods_dir }) else log.err("Couldn't remove {s}: {t}", .{ id, err });
        return err;
    };
}

pub const Updated = struct {
    id: []const u8,
    /// Null if it was taken out, since the hub pulled it.
    version: ?[]const u8,
};

/// Every installed one with a newer version, and takes out any the hub pulled. Failures get
/// logged and the rest still update. Null `only` means all of them.
pub fn update(arena: std.mem.Allocator, io: std.Io, where: Where, only: ?[]const u8) ![]const Updated {
    const revoked = registry.revoked(arena, io, where.source) catch &.{};
    var updated: std.ArrayList(Updated) = .empty;
    for (try registry.installedAll(arena, io, where.mods_dir)) |have| {
        if (only) |id| if (!std.mem.eql(u8, id, have.id)) continue;
        if (registry.isRevoked(revoked, have.sha256)) {
            log.warn("{s} {s} was pulled from the hub, so it's being taken out", .{ have.id, have.version });
            registry.remove(arena, io, where.mods_dir, have.id) catch continue;
            try updated.append(arena, .{ .id = have.id, .version = null });
            continue;
        }
        const pkg = (registry.package(arena, io, where.source, have.id) catch continue) orelse continue;
        const newest = registry.latest(pkg, where.wraith, null) orelse continue;
        if (registry.compareVersions(newest.version, have.version) != .gt) continue;
        registry.install(arena, io, where.source, where.mods_dir, pkg, newest) catch continue;
        try updated.append(arena, .{ .id = have.id, .version = newest.version });
    }
    return updated.items;
}
