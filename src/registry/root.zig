//! Packages from the Wraith Hub. Its files live on dist.wraith.io, each signed, and a copy
//! of each is kept so it works offline. See the hub's README for what's in them.

const std = @import("std");

const core = @import("wraith_core");

const log = core.log.scoped(.wraith_registry);

/// The hub's signing key. Its private half is the hub's SIGNING_KEY.
pub const public_key = "edb40b1d003a41c82145590059cef9e415c09a5fa0f0337c5aeb367306df8b04";

pub const default_location = "https://dist.wraith.io/hub";

pub const installed_name = ".registry.zon";
pub const cache_folder = "registry";

/// Listing, installing and updating mods, for the CLI, the app and the overlay.
pub const mods = @import("mods.zig");

/// Newer formats get refused.
pub const format = 1;

pub const Kind = enum { plugin, project };
pub const Game = core.manifest.Game;
pub const GameEngine = core.manifest.GameEngine;
pub const Arch = core.arch.Arch;

/// A package in a list, at its newest version for there.
pub const Entry = struct {
    id: []const u8,
    kind: Kind = .plugin,
    author: []const u8 = "",
    title: []const u8 = "",
    summary: []const u8 = "",
    version: []const u8 = "",
    wraith: ?[]const u8 = null,
    /// Empty, with no `gameEngine` either, means any game.
    games: []const []const u8 = &.{},
    /// Every game made with this game engine, instead of `games`.
    gameEngine: ?GameEngine = null,
    /// Builds it was tested on, in a game's list.
    builds: []const []const u8 = &.{},
    /// Picked for that game, or for every game in the any-game and featured lists.
    featured: bool = false,
    /// Why it's picked, in the featured list.
    why: ?[]const u8 = null,
    updated: ?[]const u8 = null,
    /// Other mods use it, like Camera Tools, and it comes with them. Not one to list for players.
    library: bool = false,
};

pub const Link = struct {
    label: []const u8,
    url: []const u8,
};

pub const GameInfo = struct {
    name: []const u8,
    image: ?[]const u8 = null,
    /// Every id Wraith might know it by.
    idents: []const []const u8 = &.{},
    links: []const Link = &.{},
};

/// `v1/games/<id>.json`, `v1/engines/<id>.json`, `v1/any.json` or `v1/featured.json`.
pub const List = struct {
    format: u32,
    generated: []const u8 = "",
    /// Null for the game engine, any-game and featured lists.
    game: ?GameInfo = null,
    /// For a game engine's list.
    gameEngine: ?struct { id: []const u8, label: []const u8 = "" } = null,
    packages: []const Entry = &.{},
};

pub const CatalogGame = struct {
    name: []const u8,
    image: ?[]const u8 = null,
    idents: []const []const u8 = &.{},
    packages: u32 = 0,
};

/// `v1/games.json`, every game with something out for it.
pub const Catalog = struct {
    format: u32,
    generated: []const u8 = "",
    games: []const CatalogGame = &.{},

    pub fn find(self: Catalog, ident: []const u8) ?CatalogGame {
        for (self.games) |g| for (g.idents) |i| if (std.mem.eql(u8, i, ident)) return g;
        return null;
    }
};

pub const Version = struct {
    version: []const u8,
    url: []const u8,
    sha256: []const u8,
    size: u64 = 0,
    published: ?[]const u8 = null,
    /// Hidden from new installs.
    yanked: bool = false,
    wraith: ?[]const u8 = null,
    /// Null, with no `gameEngine` either, means any game.
    game: ?Game = null,
    gameEngine: ?GameEngine = null,
    /// Null means both.
    arches: ?[]const Arch = null,
    provider: ?[]const u8 = null,
    depends: []const []const u8 = &.{},

    pub fn runsOn(self: Version, wraith_version: []const u8) bool {
        return satisfies(wraith_version, self.wraith orelse return true);
    }

    pub fn builtFor(self: Version, arch: Arch) bool {
        const arches = self.arches orelse return true;
        return std.mem.indexOfScalar(Arch, arches, arch) != null;
    }
};

/// `v1/packages/<id>.json`.
pub const Package = struct {
    format: u32,
    generated: []const u8 = "",
    id: []const u8,
    kind: Kind = .plugin,
    author: []const u8 = "",
    title: []const u8 = "",
    summary: []const u8 = "",
    description: ?[]const u8 = null,
    license: ?[]const u8 = null,
    homepage: ?[]const u8 = null,
    /// Other mods use it, and it comes with them.
    library: bool = false,
    /// Newest first.
    versions: []const Version = &.{},

    pub fn find(self: Package, version: []const u8) ?Version {
        for (self.versions) |v| if (std.mem.eql(u8, v.version, version)) return v;
        return null;
    }
};

const Revoked = struct {
    format: u32,
    generated: []const u8 = "",
    sha256: []const []const u8 = &.{},
};

pub const compareVersions = core.manifest.compareVersions;
pub const satisfies = core.manifest.satisfies;

/// The newest that isn't yanked and runs here. Null `arch` means either.
pub fn latest(pkg: Package, wraith_version: []const u8, arch: ?Arch) ?Version {
    var best: ?Version = null;
    for (pkg.versions) |v| {
        if (v.yanked or !v.runsOn(wraith_version)) continue;
        if (arch) |a| if (!v.builtFor(a)) continue;
        if (best == null or compareVersions(v.version, best.?.version) == .gt) best = v;
    }
    return best;
}

/// Whether it was tested on this copy of the game Wraith knows as `ident`. Null if it doesn't
/// say, or it's for any game.
pub fn testedOn(version: Version, ident: []const u8, copy: core.manifest.Copy) ?bool {
    const game = version.game orelse return null;
    if (!game.matches(.{ .id = ident })) return null;
    return game.testedOn(copy);
}

pub const Source = struct {
    location: []const u8 = default_location,
    key: []const u8 = public_key,
    cache_dir: ?[]const u8 = null,

    /// Overrides come from `WRAITH_REGISTRY` and `WRAITH_REGISTRY_KEY`.
    pub fn of(cache_dir: []const u8, location: ?[]const u8, key: ?[]const u8) !Source {
        var source: Source = .{ .cache_dir = cache_dir };
        if (location) |l| if (l.len > 0) {
            source.location = l;
        };
        if (key) |k| if (k.len > 0) {
            source.key = k;
        };
        return source;
    }
};

/// Ids and game ids go in paths, so nothing that could leave the folder.
fn safe(name: []const u8) bool {
    if (name.len == 0 or name.len > 128 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |c| if (c < 0x20 or std.mem.indexOfScalar(u8, "<>:\"/\\|?*", c) != null) return false;
    return true;
}

/// A game's list, by any id Wraith knows it by. Null if the hub has nothing for it.
pub fn forGame(arena: std.mem.Allocator, io: std.Io, source: Source, ident: []const u8) !?List {
    if (!safe(ident)) return error.BadName;
    return read(List, arena, io, source, try std.fmt.allocPrint(arena, "v1/games/{s}.json", .{ident}));
}

/// Packages for every game made with a game engine, like `unity`. Null if the hub has none.
pub fn forGameEngine(arena: std.mem.Allocator, io: std.Io, source: Source, id: []const u8) !?List {
    if (!safe(id)) return error.BadName;
    return read(List, arena, io, source, try std.fmt.allocPrint(arena, "v1/engines/{s}.json", .{id}));
}

/// Packages that work in any game.
pub fn anyGame(arena: std.mem.Allocator, io: std.Io, source: Source) !List {
    return try read(List, arena, io, source, "v1/any.json") orelse .{ .format = format };
}

/// Our picks for every game.
pub fn featured(arena: std.mem.Allocator, io: std.Io, source: Source) !List {
    return try read(List, arena, io, source, "v1/featured.json") orelse .{ .format = format };
}

pub fn catalog(arena: std.mem.Allocator, io: std.Io, source: Source) !Catalog {
    return try read(Catalog, arena, io, source, "v1/games.json") orelse .{ .format = format };
}

/// Null if there's no such package.
pub fn package(arena: std.mem.Allocator, io: std.Io, source: Source, id: []const u8) !?Package {
    if (!safe(id)) return error.BadName;
    return read(Package, arena, io, source, try std.fmt.allocPrint(arena, "v1/packages/{s}.json", .{id}));
}

/// Hashes of zips that were pulled.
pub fn revoked(arena: std.mem.Allocator, io: std.Io, source: Source) ![]const []const u8 {
    const r = try read(Revoked, arena, io, source, "v1/revoked.json") orelse return &.{};
    return r.sha256;
}

/// From the last time it was fetched, without going online. For checking at load time.
pub fn cachedRevoked(arena: std.mem.Allocator, io: std.Io, source: Source) ![]const []const u8 {
    const r = try readCache(Revoked, arena, io, source, "v1/revoked.json");
    return r.sha256;
}

pub fn isRevoked(list: []const []const u8, sha256: []const u8) bool {
    for (list) |s| if (std.ascii.eqlIgnoreCase(s, sha256)) return true;
    return false;
}

/// Checked, and kept for next time. If it can't be got, the copy from last time, if there's one.
/// Null if the hub says there isn't one.
fn read(comptime T: type, arena: std.mem.Allocator, io: std.Io, source: Source, path: []const u8) !?T {
    return readFresh(T, arena, io, source, path) catch |err| switch (err) {
        error.NotFound => null,
        else => {
            const cached = readCache(T, arena, io, source, path) catch |cache_err| {
                log.err("Couldn't get {s} from {s} ({t}), and there's no copy of it to use ({t})", .{ path, source.location, err, cache_err });
                return err;
            };
            log.warn("Couldn't get {s} from {s} ({t}): using the copy from {s}", .{ path, source.location, err, cached.generated });
            return cached;
        },
    };
}

fn readFresh(comptime T: type, arena: std.mem.Allocator, io: std.Io, source: Source, path: []const u8) !T {
    const text = try get(arena, io, source.location, path, 16 << 20);
    const sig_path = try std.fmt.allocPrint(arena, "{s}.sig", .{path});
    const signature = try get(arena, io, source.location, sig_path, 1024);
    try verify(text, signature, source.key);
    const value = try parse(T, arena, text);
    if (source.cache_dir) |dir| writeCache(arena, io, dir, path, text, signature) catch |err| log.warn("Couldn't keep a copy of {s} in {s}: {t}", .{ path, dir, err });
    return value;
}

fn readCache(comptime T: type, arena: std.mem.Allocator, io: std.Io, source: Source, path: []const u8) !T {
    const dir = source.cache_dir orelse return error.NoCache;
    const text = try readFile(arena, io, dir, path, 16 << 20);
    const signature = try readFile(arena, io, dir, try std.fmt.allocPrint(arena, "{s}.sig", .{path}), 1024);
    // Check again, anyone could write to the cache
    try verify(text, signature, source.key);
    return parse(T, arena, text);
}

fn writeCache(arena: std.mem.Allocator, io: std.Io, dir: []const u8, path: []const u8, text: []const u8, signature: []const u8) !void {
    const full = try std.fs.path.join(arena, &.{ dir, path });
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(full)) |parent| try cwd.createDirPath(io, parent);
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}.sig", .{full}), .data = signature });
    try cwd.writeFile(io, .{ .sub_path = full, .data = text });
}

pub fn verify(text: []const u8, signature: []const u8, key: []const u8) !void {
    const Ed25519 = std.crypto.sign.Ed25519;
    var key_bytes: [Ed25519.PublicKey.encoded_length]u8 = undefined;
    const key_hex = std.mem.trim(u8, key, " \r\n");
    if (key_hex.len != key_bytes.len * 2) return error.BadKey;
    _ = std.fmt.hexToBytes(&key_bytes, key_hex) catch return error.BadKey;
    var sig_bytes: [Ed25519.Signature.encoded_length]u8 = undefined;
    const sig_hex = std.mem.trim(u8, signature, " \r\n");
    if (sig_hex.len != sig_bytes.len * 2) return error.BadSignature;
    _ = std.fmt.hexToBytes(&sig_bytes, sig_hex) catch return error.BadSignature;
    const pk = Ed25519.PublicKey.fromBytes(key_bytes) catch return error.BadKey;
    Ed25519.Signature.fromBytes(sig_bytes).verify(text, pk) catch return error.BadSignature;
}

pub fn parse(comptime T: type, arena: std.mem.Allocator, text: []const u8) !T {
    const value = std.json.parseFromSliceLeaky(T, arena, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.BadRegistry;
    if (value.format > format) return error.RegistryTooNew;
    return value;
}

fn get(arena: std.mem.Allocator, io: std.Io, location: []const u8, path: []const u8, max: usize) ![]u8 {
    if (!isUrl(location)) return readFile(arena, io, location, path, max) catch |err| switch (err) {
        error.FileNotFound => error.NotFound,
        else => err,
    };
    const url = try std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, location, "/"), path });
    return download(arena, io, url, max);
}

fn isUrl(location: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(location, "https://") or std.ascii.startsWithIgnoreCase(location, "http://");
}

fn readFile(arena: std.mem.Allocator, io: std.Io, dir: []const u8, path: []const u8, max: usize) ![]u8 {
    const full = try std.fs.path.join(arena, &.{ dir, path });
    return std.Io.Dir.cwd().readFileAlloc(io, full, arena, .limited(max));
}

fn download(arena: std.mem.Allocator, io: std.Io, url: []const u8, max: usize) ![]u8 {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(arena);
    const result = client.fetch(.{ .location = .{ .url = url }, .response_writer = &body.writer }) catch |err| {
        log.debug("GET {s}: {t}", .{ url, err });
        return err;
    };
    if (result.status == .not_found) return error.NotFound;
    if (result.status != .ok) {
        log.debug("GET {s}: HTTP {d}", .{ url, @backingInt(result.status) });
        return error.HttpError;
    }
    if (body.written().len > max) return error.TooBig;
    return body.written();
}

/// What `install` leaves in the plugin's folder, as `.registry.zon`.
pub const Installed = struct {
    id: []const u8,
    version: []const u8,
    sha256: []const u8,
};

/// On failure the old one stays untouched. Plugins and projects both go in `mods_dir`.
pub fn install(arena: std.mem.Allocator, io: std.Io, source: Source, mods_dir: []const u8, pkg: Package, version: Version) !void {
    if (!safe(pkg.id)) return error.BadName;
    const name = pkg.id;
    const zip = if (isUrl(version.url))
        try download(arena, io, version.url, 512 << 20)
    else
        try readFile(arena, io, source.location, version.url, 512 << 20);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(zip, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.ascii.eqlIgnoreCase(&hex, version.sha256)) {
        log.err("{s} {s}'s zip isn't the one the hub says (its sha-256 is {s}): not installed", .{ name, version.version, &hex });
        return error.HashMismatch;
    }

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, mods_dir);
    var dir = try cwd.openDir(io, mods_dir, .{});
    defer dir.close(io);
    const lock = try lockPlugin(arena, io, dir, name);
    defer unlockPlugin(arena, io, dir, name, lock);
    const partial = try std.fmt.allocPrint(arena, ".{s}.partial", .{name});
    const old = try std.fmt.allocPrint(arena, ".{s}.old", .{name});
    dir.deleteTree(io, partial) catch {};
    dir.deleteTree(io, old) catch {};
    defer dir.deleteTree(io, partial) catch {};

    try unzip(arena, io, dir, partial, zip);
    const top = try contentsOf(arena, io, dir, partial, name);
    var top_dir = try dir.openDir(io, top, .{});
    {
        defer top_dir.close(io);
        var record: std.Io.Writer.Allocating = .init(arena);
        try std.zon.stringify.serialize(Installed{ .id = name, .version = version.version, .sha256 = &hex }, .{}, &record.writer);
        try top_dir.writeFile(io, .{ .sub_path = installed_name, .data = record.written() });
    }

    // Move the old one aside first so there's always one or the other
    const had_old = if (dir.rename(name, dir, old, io)) true else |err| switch (err) {
        error.FileNotFound => false,
        else => return err,
    };
    dir.rename(top, dir, name, io) catch |err| {
        if (had_old) dir.rename(old, dir, name, io) catch {};
        return err;
    };
    if (had_old) dir.deleteTree(io, old) catch |err| log.warn("Couldn't delete the old {s} ({t}): it's left as {s}", .{ name, err, old });
    log.info("Installed {s} {s} in {s}", .{ name, version.version, mods_dir });
}

fn unzip(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, into: []const u8, zip: []const u8) !void {
    // std's zip reader wants a file
    const zip_name = try std.fmt.allocPrint(arena, "{s}.zip", .{into});
    try dir.writeFile(io, .{ .sub_path = zip_name, .data = zip });
    defer dir.deleteFile(io, zip_name) catch {};
    var file = try dir.openFile(io, zip_name, .{});
    defer file.close(io);
    try dir.createDirPath(io, into);
    var dest = try dir.openDir(io, into, .{});
    defer dest.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    std.zip.extract(dest, &reader, .{ .allow_backslashes = true }) catch |err| {
        log.err("The plugin's zip can't be unpacked: {t}", .{err});
        return error.BadZip;
    };
}

/// `partial` itself, or its single subfolder if the zip wrapped everything in one. Its
/// manifest has to say it's `name`.
fn contentsOf(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, partial: []const u8, name: []const u8) ![]const u8 {
    const top = try findContents(arena, io, dir, partial);
    const text = try dir.readFileAlloc(io, try std.fs.path.join(arena, &.{ top, core.manifest.file_name }), arena, .limited(64 << 10));
    const m = core.manifest.parse(arena, text, null) catch return error.BadManifest;
    if (!std.mem.eql(u8, m.id, name)) {
        log.err("The zip's {s} says it's {s}, not {s}", .{ core.manifest.file_name, m.id, name });
        return error.WrongPackage;
    }
    return top;
}

fn findContents(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, partial: []const u8) ![]const u8 {
    const manifest = core.manifest.file_name;
    if (hasFile(io, dir, try std.fs.path.join(arena, &.{ partial, manifest }))) return partial;
    var d = try dir.openDir(io, partial, .{ .iterate = true });
    defer d.close(io);
    var only: ?[]const u8 = null;
    var entries: usize = 0;
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        entries += 1;
        if (entry.kind == .directory) only = try arena.dupe(u8, entry.name);
    }
    if (entries == 1) if (only) |sub| {
        const inner = try std.fs.path.join(arena, &.{ partial, sub });
        if (hasFile(io, dir, try std.fs.path.join(arena, &.{ inner, manifest }))) return inner;
    };
    log.err("The zip has no {s} (at the top, or in one folder at the top)", .{manifest});
    return error.NoManifest;
}

fn hasFile(io: std.Io, dir: std.Io.Dir, path: []const u8) bool {
    dir.access(io, path, .{}) catch return false;
    return true;
}

/// Everything in `mods_dir` that came from the hub.
pub fn installedAll(arena: std.mem.Allocator, io: std.Io, mods_dir: []const u8) ![]const Installed {
    var dir = std.Io.Dir.cwd().openDir(io, mods_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(io);
    var found: std.ArrayList(Installed) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory or entry.name[0] == '.') continue;
        if (try installed(arena, io, mods_dir, entry.name)) |i| try found.append(arena, i);
    }
    return found.items;
}

pub fn installed(arena: std.mem.Allocator, io: std.Io, mods_dir: []const u8, name: []const u8) !?Installed {
    const path = try std.fs.path.join(arena, &.{ mods_dir, name, installed_name });
    const text = std.Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(64 << 10), .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(Installed, .{ .gpa = arena, .arena = arena, .source = text, .diagnostics = &diagnostics, .ignore_unknown_fields = true }) catch null;
}

/// Anything not from the registry gets `error.NotFromRegistry`.
pub fn remove(arena: std.mem.Allocator, io: std.Io, mods_dir: []const u8, name: []const u8) !void {
    if (try installed(arena, io, mods_dir, name) == null) return error.NotFromRegistry;
    var dir = try std.Io.Dir.cwd().openDir(io, mods_dir, .{});
    defer dir.close(io);
    const lock = try lockPlugin(arena, io, dir, name);
    defer unlockPlugin(arena, io, dir, name, lock);
    try dir.deleteTree(io, name);
    log.info("Removed {s} from {s}", .{ name, mods_dir });
}

/// OS lock on `.<name>.lock`, so it dies with the process and can't get stuck.
fn lockPlugin(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) !std.Io.File {
    const lock_name = try std.fmt.allocPrint(arena, ".{s}.lock", .{name});
    return dir.createFile(io, lock_name, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true }) catch |err| switch (err) {
        error.WouldBlock => {
            log.err("{s} is being installed or removed by something else (another game's Wraith?): try again in a moment", .{name});
            return error.Busy;
        },
        else => return err,
    };
}

fn unlockPlugin(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8, lock: std.Io.File) void {
    lock.close(io);
    const lock_name = std.fmt.allocPrint(arena, ".{s}.lock", .{name}) catch return;
    // Someone might be waiting on it already. Then it's theirs to clean up
    dir.deleteFile(io, lock_name) catch {};
}

test {
    _ = @import("tests.zig");
}

pub const testing = struct {
    pub const hello_zip = @embedFile("testdata/hello.zip");
};
