//! Hub mods alongside installed ones: listing, installing and updating for the CLI, app and overlay.
//! Each call takes the hub index, so an operation fetches it once.

const std = @import("std");

const core = @import("wraith_core");

const registry = @import("root.zig");
const Index = registry.Index;
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
    /// The Wraith it needs, if that's why `latest` is null. Empty if unknown.
    needs_wraith: ?[]const u8,
    /// Its newest targets another API version, so it's waiting on its author.
    outdated: bool = false,
    installed: ?[]const u8,
    /// The installed copy was pulled. `update` takes it out, and Wraith won't load it.
    revoked: bool,
    /// Only installed as a dependency, so not offered on its own. Still listed when installed.
    library: bool = false,
    /// A DLL, run by the native provider.
    native: bool = false,
    /// Wraith keeps it installed for games made with its engine, so it's not one to uninstall.
    essential: bool = false,

    pub fn hasUpdate(self: Listed) bool {
        const have = self.installed orelse return false;
        const latest = self.latest orelse return false;
        return self.revoked or registry.compareVersions(latest, have) == .gt;
    }

    /// With `has_update`, so the app needn't compare versions itself.
    pub fn jsonStringify(self: Listed, jw: anytype) !void {
        try jw.beginObject();
        inline for (@typeInfo(Listed).@"struct".field_names) |name| {
            try jw.objectField(name);
            try jw.write(@field(self, name));
        }
        try jw.objectField("has_update");
        try jw.write(self.hasUpdate());
        try jw.endObject();
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

/// A game asked about, by the game engine it's made with.
pub const MadeWith = struct {
    /// Its id, which the mods for its engine are listed under. Null for one Wraith has no id for.
    game: ?[]const u8 = null,
    /// Engine, variant and exe (if known), for finding the game's essentials.
    here: core.manifest.Here,
};

/// Picks, any-game mods, mods for `games` and their engines, plus what's installed.
pub fn list(arena: std.mem.Allocator, io: std.Io, index: Index, mods_dir: []const u8, wraith: []const u8, games: []const []const u8, made_with: []const MadeWith) !Listing {
    var listed: std.ArrayList(Listed) = .empty;
    for (index.packages) |*p| {
        const l = try listedOf(arena, p.*, wraith, games, made_with) orelse continue;
        if (l.featured or l.any_game or l.games.len > 0 or forEngine(p.*, made_with)) try listed.append(arena, l);
    }
    // Installed ones that aren't for any of those
    for (try registry.installedAll(arena, io, mods_dir)) |have| {
        if (find(listed.items, have.id) == null) {
            const from_hub = if (index.find(have.id)) |p| try listedOf(arena, p.*, wraith, games, made_with) else null;
            // Still listed when the hub's dropped it, so it can be taken out
            try listed.append(arena, from_hub orelse try installedOnly(arena, io, mods_dir, have));
        }
        const l = find(listed.items, have.id).?;
        l.installed = have.version;
        l.revoked = index.isRevoked(have.sha256);
    }
    return .{ .generated = index.generated, .mods = listed.items };
}

fn find(listed: []Listed, id: []const u8) ?*Listed {
    for (listed) |*l| if (std.mem.eql(u8, l.id, id)) return l;
    return null;
}

/// For one of `made_with`'s game engines.
fn forEngine(p: registry.Package, made_with: []const MadeWith) bool {
    const v = p.newest() orelse return false;
    const target = v.gameEngine orelse return false;
    for (made_with) |m| if (target.matches(m.here)) return true;
    return false;
}

/// Its newest version this Wraith runs, else its newest. Null if all are yanked.
fn listedOf(arena: std.mem.Allocator, p: registry.Package, wraith: []const u8, games: []const []const u8, made_with: []const MadeWith) !?Listed {
    const runs = registry.latest(p, wraith, null);
    const v = runs orelse p.newest() orelse return null;
    var for_games: std.ArrayList([]const u8) = .empty;
    var picked = p.featured;
    for (games) |g| {
        if (v.forGame(g)) try for_games.append(arena, g);
        if (p.featuredFor(g)) picked = true;
    }
    if (v.gameEngine) |target| for (made_with) |m| {
        const g = m.game orelse continue;
        if (target.matches(m.here) and !isSeen(for_games.items, g)) try for_games.append(arena, g);
    };
    const api = core.manifest.ApiFit.of(v.apiVersion);
    const wraith_ok = registry.satisfies(wraith, v.wraith orelse "0.0.0");
    return .{
        .id = p.id,
        .kind = p.kind,
        .title = p.title,
        .summary = p.summary,
        .author = p.author,
        .any_game = v.anyGame(),
        .games = for_games.items,
        .game_engine = v.gameEngine,
        .featured = picked,
        .why = p.why,
        .latest = if (runs) |r| r.version else null,
        .needs_wraith = if (runs != null) null else if (!wraith_ok) v.wraith else if (api == .newer) v.wraith orelse "" else null,
        .outdated = runs == null and wraith_ok and api == .outdated,
        .installed = null,
        .revoked = false,
        .library = p.library,
        .native = isNative(v.provider),
        .essential = p.essential,
    };
}

/// One the hub doesn't have, from its own wraith.json.
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
        .native = isNative(m.provider),
    };
}

fn isNative(provider: ?[]const u8) bool {
    return std.mem.eql(u8, provider orelse "", "native");
}

pub const Where = struct {
    source: Source,
    mods_dir: []const u8,
    /// The running Wraith's version.
    wraith: []const u8,

    /// What the hub has now, else the copy from last time.
    pub fn index(self: Where, arena: std.mem.Allocator, io: std.Io) !Index {
        return registry.fetch(arena, io, self.source);
    }
};

/// Installs with missing dependencies; null `version` means newest compatible. Returns the version.
pub fn install(arena: std.mem.Allocator, io: std.Io, index: Index, where: Where, id: []const u8, version: ?[]const u8) ![]const u8 {
    var seen: std.ArrayList([]const u8) = .empty;
    return installWith(arena, io, index, where, id, version, &seen);
}

fn installWith(arena: std.mem.Allocator, io: std.Io, index: Index, where: Where, id: []const u8, version: ?[]const u8, seen: *std.ArrayList([]const u8)) ![]const u8 {
    try seen.append(arena, id);
    const pkg = index.find(id) orelse {
        log.err("There's no {s} on the hub", .{id});
        return error.NoSuchMod;
    };
    const chosen = if (version) |wanted| pkg.find(wanted) orelse {
        log.err("{s} has no version {s}", .{ id, wanted });
        return error.NoSuchVersion;
    } else registry.latest(pkg.*, where.wraith, null) orelse {
        if (pkg.newest()) |newest| if (core.manifest.ApiFit.of(newest.apiVersion) == .outdated) {
            log.err("{s} hasn't been updated for this Wraith's API ({d}) yet", .{ id, core.manifest.api_version });
            return error.OutdatedApi;
        };
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
    if (index.isRevoked(chosen.sha256)) {
        log.err("{s} {s} was pulled from the hub", .{ id, chosen.version });
        return error.Revoked;
    }
    try registry.install(arena, io, where.source, where.mods_dir, pkg.*, chosen);
    for (chosen.depends) |text| {
        const dep: core.manifest.Dependency = .parse(text);
        if (isSeen(seen.items, dep.name)) continue;
        if (try hasDependency(arena, io, where.mods_dir, dep)) continue;
        log.info("{s} needs {s}, installing it", .{ id, text });
        _ = installWith(arena, io, index, where, dep.name, null, seen) catch |err| {
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
    return putThere(arena, io, mods_dir, dep.name);
}

fn putThere(arena: std.mem.Allocator, io: std.Io, mods_dir: []const u8, id: []const u8) !bool {
    const dir = try std.fs.path.join(arena, &.{ mods_dir, id });
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

/// Which installed mods `update` looks at.
pub const Only = union(enum) {
    all,
    id: []const u8,
    /// Those that load in this game: for it, its engine or any game.
    game: MadeWith,
};

/// Updates installed mods and removes pulled ones; failures are logged.
pub fn update(arena: std.mem.Allocator, io: std.Io, index: Index, where: Where, only: Only) ![]const Updated {
    var updated: std.ArrayList(Updated) = .empty;
    for (try registry.installedAll(arena, io, where.mods_dir)) |have| {
        switch (only) {
            .all => {},
            .id => |id| if (!std.mem.eql(u8, id, have.id)) continue,
            .game => |m| if (!loadsIn((index.find(have.id) orelse continue).*, m)) continue,
        }
        if (index.isRevoked(have.sha256)) {
            log.warn("{s} {s} was pulled from the hub, so it's being taken out", .{ have.id, have.version });
            registry.remove(arena, io, where.mods_dir, have.id) catch continue;
            try updated.append(arena, .{ .id = have.id, .version = null });
            continue;
        }
        const pkg = index.find(have.id) orelse continue;
        const newest = registry.latest(pkg.*, where.wraith, null) orelse continue;
        if (registry.compareVersions(newest.version, have.version) != .gt) continue;
        registry.install(arena, io, where.source, where.mods_dir, pkg.*, newest) catch continue;
        try updated.append(arena, .{ .id = have.id, .version = newest.version });
    }
    return updated.items;
}

fn loadsIn(p: registry.Package, m: MadeWith) bool {
    const v = p.newest() orelse return false;
    return v.anyGame() or essentialIn(v, m);
}

/// A missing or outdated essential: an engine's official plugin, or a game's replacement for it.
pub const Essential = struct {
    id: []const u8,
    title: []const u8,
    /// Null if it's not installed yet.
    installed: ?[]const u8,
    latest: []const u8,
    /// The game engine it's for, like `unity`. Null for one that's for a game.
    game_engine: ?[]const u8,
};

/// Essentials for `made_with` that need installing or updating; hand-placed copies are left alone.
pub fn essentials(arena: std.mem.Allocator, io: std.Io, index: Index, where: Where, made_with: []const MadeWith, arch: ?registry.Arch) ![]const Essential {
    var out: std.ArrayList(Essential) = .empty;
    for (index.packages) |p| {
        if (!p.essential) continue;
        const newest = registry.latest(p, where.wraith, arch) orelse continue;
        const wanted = for (made_with) |m| {
            if (essentialIn(newest, m) and !supersededIn(index, p.id, newest, m, where.wraith, arch)) break true;
        } else false;
        if (!wanted or index.isRevoked(newest.sha256)) continue;
        const have = try registry.installed(arena, io, where.mods_dir, p.id);
        if (have) |h| {
            if (registry.compareVersions(newest.version, h.version) != .gt) continue;
        } else if (try putThere(arena, io, where.mods_dir, p.id)) continue;
        try out.append(arena, .{
            .id = p.id,
            .title = if (p.title.len > 0) p.title else p.id,
            .installed = if (have) |h| h.version else null,
            .latest = newest.version,
            .game_engine = if (newest.gameEngine) |e| e.id else null,
        });
    }
    return out.items;
}

/// Whether `m`'s game has its own essential that supersedes engine plugin `id`.
fn supersededIn(index: Index, id: []const u8, v: registry.Version, m: MadeWith, wraith: []const u8, arch: ?registry.Arch) bool {
    if (v.gameEngine == null) return false;
    packages: for (index.packages) |q| {
        if (!q.essential) continue;
        const qv = registry.latest(q, wraith, arch) orelse continue;
        if (qv.game == null or !essentialIn(qv, m)) continue;
        // Built on it, so it can't stand in for it
        for (qv.depends) |d| if (std.mem.eql(u8, core.manifest.Dependency.parse(d).name, id)) continue :packages;
        for (qv.supersedes) |s| if (std.mem.eql(u8, s, id)) return true;
    }
    return false;
}

/// Whether `v` targets `m`'s game or its engine. Any-game mods don't count.
fn essentialIn(v: registry.Version, m: MadeWith) bool {
    if (v.game) |game| {
        var here = m.here;
        if (here.id == null) here.id = m.game;
        return game.matches(here);
    }
    const target = v.gameEngine orelse return false;
    return target.matches(m.here);
}
