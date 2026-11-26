//! What the loader knows about one plugin folder, and the copy of it the UI gets.

const Known = @This();

const std = @import("std");

const tuft_sys = @import("tuft_sys");
const Text = @import("tuft_text").Text;
const Owner = @import("tuft_event").Owner;

const Loaded = @import("Loaded.zig");
const Manifest = @import("../Manifest.zig");
const core_manifest = @import("wraith_core").manifest;

/// Its lock guards every `Known` in it, and is never held across a start or stop.
pub const List = tuft_sys.sync.SharedList(*Known);

pub const State = enum {
    unloaded,
    loading,
    loaded,
    unloading,
    failed,
    /// For another game, arch or a newer Wraith.
    unsupported,
    /// A C# plugin with `clrMode: wait`, till a CoreCLR's running.
    waiting,
};

pub const Info = struct {
    name: Text(64) = .{},
    state: State = .unloaded,
    last_error: ?anyerror = null,
    about: About = .{},
    /// The kind that runs it, like `native` or `js`.
    provider: Text(64) = .{},
    source_dir: Text(260) = .{},
    /// Compare it, don't follow it. It may be unloaded by now.
    owner: ?*const Owner = null,
    copy_dir: Text(260) = .{},
    config_dir: Text(260) = .{},
    game_config_dir: Text(260) = .{},
    library: usize = 0,
    /// Compiled with NativeAOT, so it stays loaded till the game closes.
    pinned: bool = false,
    start_ns: u64 = 0,
    /// What it couldn't load without, like `unity@1.2`, when that's why it failed.
    needs: Text(80) = .{},
    /// The game's plugin that stands in for it here, when that's why it's off.
    superseded_by: Text(64) = .{},
};

pub const About = struct {
    title: Text(64) = .{},
    version: Text(32) = .{},
    author: Text(64) = .{},
    /// Empty means any.
    games: Text(128) = .{},
    /// Empty means any.
    wraith: Text(32) = .{},

    pub fn of(manifest: Manifest) About {
        var about: About = .{};
        const m = manifest.value;
        about.title.set(m.title orelse "");
        about.version.set(m.version orelse "");
        about.author.set(m.author orelse "");
        about.wraith.set(m.wraith orelse "");
        var games: [about.games.buf.len]u8 = undefined;
        about.games.set(manifest.gamesText(&games));
        return about;
    }
};

name: []u8,
state: State = .unloaded,
last_error: ?anyerror = null,
about: About = .{},
provider: ?[]u8 = null,
dir: ?[]u8 = null,
loaded: ?*Loaded = null,
auto_load: bool = true,
/// What a `cs` plugin does without .NET running.
clr_mode: core_manifest.ClrMode = .load,
/// From its manifest, like `unity@1.2`.
depends: [][]u8 = &.{},
needs: Text(80) = .{},
/// Game plugins only: the engine plugins it stands in for.
supersedes: [][]u8 = &.{},
/// Its manifest's `game` or `gameEngine`, once it's read.
for_game: bool = false,
for_engine: bool = false,
superseded_by: Text(64) = .{},

/// Needs the list's lock held.
pub fn infoOf(k: *Known, info: *Info) void {
    info.* = .{ .state = k.state, .last_error = k.last_error, .needs = k.needs, .superseded_by = k.superseded_by };
    info.name.set(k.name);
    info.about = k.about;
    if (k.provider) |p| info.provider.set(p);
    if (k.dir) |dir| info.source_dir.set(dir);
    const loaded = k.loaded orelse return;
    info.owner = &loaded.owner;
    info.copy_dir.set(loaded.copy_dir);
    info.config_dir.set(loaded.config_dir);
    info.game_config_dir.set(loaded.game_config_dir);
    // Safe since what made its kind stays loaded while it is
    info.library = loaded.library();
    info.pinned = loaded.pinned();
    info.start_ns = loaded.start_ns;
}

/// Needs the list's lock held.
pub fn find(list: *List, name: []const u8) ?*Known {
    for (list.items.items) |k| {
        if (std.ascii.eqlIgnoreCase(k.name, name)) return k;
    }
    return null;
}

/// Needs the list's lock held exclusively.
pub fn findOrAdd(list: *List, allocator: std.mem.Allocator, name: []const u8) !*Known {
    if (find(list, name)) |k| return k;
    try list.items.ensureUnusedCapacity(allocator, 1);
    const k = try allocator.create(Known);
    errdefer allocator.destroy(k);
    k.* = .{ .name = try allocator.dupe(u8, name) };
    list.items.appendAssumeCapacity(k);
    return k;
}

/// Needs the list's lock held exclusively, or the loader being torn down.
pub fn destroy(k: *Known, allocator: std.mem.Allocator) void {
    k.setDepends(allocator, &.{}) catch unreachable;
    k.setSupersedes(allocator, &.{}) catch unreachable;
    if (k.provider) |p| allocator.free(p);
    if (k.dir) |d| allocator.free(d);
    allocator.free(k.name);
    allocator.destroy(k);
}

/// Needs the list's lock held exclusively. Keeps the old ones if it fails.
pub fn setDepends(k: *Known, allocator: std.mem.Allocator, depends: []const []const u8) !void {
    try setList(allocator, &k.depends, depends);
}

/// Needs the list's lock held exclusively. Keeps the old ones if it fails.
pub fn setSupersedes(k: *Known, allocator: std.mem.Allocator, supersedes: []const []const u8) !void {
    try setList(allocator, &k.supersedes, supersedes);
}

fn setList(allocator: std.mem.Allocator, list: *[][]u8, items: []const []const u8) !void {
    const copy = try allocator.alloc([]u8, items.len);
    var made: usize = 0;
    errdefer {
        for (copy[0..made]) |d| allocator.free(d);
        allocator.free(copy);
    }
    for (items) |d| {
        copy[made] = try allocator.dupe(u8, d);
        made += 1;
    }
    for (list.*) |d| allocator.free(d);
    allocator.free(list.*);
    list.* = copy;
}

/// Needs the list's lock held. Whether `name` is in its `depends`.
pub fn dependsOn(k: *const Known, name: []const u8) bool {
    for (k.depends) |d| {
        if (std.ascii.eqlIgnoreCase(core_manifest.Dependency.parse(d).name, name)) return true;
    }
    return false;
}

pub fn setState(k: *Known, list: *List, state: State, err: ?anyerror) void {
    list.lock.lock();
    defer list.lock.unlock();
    k.state = state;
    k.last_error = err;
    k.needs = .{};
}
