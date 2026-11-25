//! A loaded plugin, run by a `PluginKind`. Heap-allocated because its objects point at it.

const Loaded = @This();

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const Owner = @import("tuft_event").Owner;
const api = @import("wraith_api");
const sal = api.salamander;

const host_api = @import("../host/root.zig");
const Manifest = @import("../Manifest.zig");

name: []const u8,
/// Its wraith.json, from the copy it runs. Empty for sessions and tests.
manifest: Manifest = .{},
owner: Owner,
copy_dir: []const u8,
config_dir: []const u8,
game_config_dir: []const u8,
runner: Runner,
allocator: std.mem.Allocator,
start_ns: u64 = 0,
/// Its `Wraith` and the rest of `wraith.sal`, made the first time it asks.
wraith: ?*host_api.wraith.Tables = null,
/// Wraith's schemas with its own and its dependencies'. Null if it has none, so it uses Wraith's alone.
schemas: ?*host_api.schemas.Schemas = null,
/// Also gets what it logs, like a workbench session's output.
echo: ?Echo = null,
/// A script session's, not a plugin's.
session: bool = false,
/// The project it's for, by where its tweaks list: "" for the open one, else an installed mod's id.
/// Null for a plugin. A project's own `Loaded` has it too, and so do its tweaks' sessions.
project: ?[]const u8 = null,
/// What's made now is tagged with this, so `host.stopTagged` can stop it apart from the rest. 0
/// for most things, or one of a session's tweaks while it runs.
making: Atomic(u32) = .init(0),
/// Ones `schemas` replaced, freed with it, since what they found may still be in use.
retired_schemas: std.ArrayList(*host_api.schemas.Schemas) = .empty,
/// What it offers plugins that depend on it, one per [Service] trait in its own schemas. The names
/// point into its schemas.
services: std.ArrayList(host_api.wraith.Service) = .empty,
/// Which copies of the game's code its lookups may use, a `tuft_mem.Sources`. 0 leaves it to
/// Wraith's setting.
address_sources: Atomic(u8) = .init(0),

pub const Echo = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, level: std.log.Level, text: []const u8) void,
};

/// The `PluginKind` the runtime provides that runs it.
pub const Runner = struct {
    kind: sal.Object(host_api.wraith.PluginKind) = .{},
    plugin: sal.Object(host_api.wraith.Plugin) = .{},
};

/// Its title, or its name if it has none. For headings people see.
pub fn displayName(self: *const Loaded) []const u8 {
    const title = self.manifest.value.title orelse return self.name;
    return if (title.len != 0) title else self.name;
}

/// `name` as one of its own in `Names`, like `kai.hp` for a plugin's `hp`. A project's are named
/// after it, except the open one's, which have no prefix.
pub fn ownName(self: *const Loaded, buf: []u8, name: []const u8) ?[]const u8 {
    const p = self.prefix();
    if (p.len == 0) return name;
    return std.fmt.bufPrint(buf, "{s}.{s}", .{ p, name }) catch null;
}

/// What its own names start with, without the dot. Empty for the open project's.
pub fn prefix(self: *const Loaded) []const u8 {
    return self.project orelse self.name;
}

pub fn library(self: *const Loaded) usize {
    return self.runner.plugin.module();
}

/// A C# plugin compiled with NativeAOT. Its DLL has .NET's runtime in it, whose threads never
/// leave, so it can't be unloaded, and loading it again would only load a second copy beside it.
pub fn pinned(self: *const Loaded) bool {
    return std.ascii.eqlIgnoreCase(self.manifest.providerName(), "cs") and self.library() != 0;
}

/// Its `Wraith`, like for running the SDK as it in tests.
pub fn root(self: *Loaded) sal.AnyObject {
    return host_api.wraith.root(self);
}

pub fn initForTest(self: *Loaded, allocator: std.mem.Allocator, name: []const u8) void {
    self.initBare(allocator, name, "", "");
}

/// Not a plugin, like a workbench session. Nothing runs it, and the names are the caller's.
pub fn initBare(self: *Loaded, allocator: std.mem.Allocator, name: []const u8, config_dir: []const u8, game_config_dir: []const u8) void {
    self.* = .{
        .name = name,
        .owner = .init(name),
        .copy_dir = "",
        .config_dir = config_dir,
        .game_config_dir = game_config_dir,
        .runner = .{},
        .allocator = allocator,
    };
}

/// Once its owner's released, so nothing's in its objects: forgets its `Wraith` and frees its
/// schemas. Its strings are the caller's.
pub fn free(self: *Loaded) void {
    host_api.wraith.forget(self);
    if (self.schemas) |s| s.destroy();
    for (self.retired_schemas.items) |s| s.destroy();
    self.retired_schemas.deinit(std.heap.page_allocator);
    self.schemas = null;
}

pub fn deinitForTest(self: *Loaded) void {
    self.owner.release();
}
