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
/// Higher for each load, so above its dependencies'. See `host.ranked`.
load_order: u64 = 0,
/// Its `Wraith` and the rest of `wraith.sal`, made the first time it asks.
wraith: ?*host_api.wraith.Tables = null,
/// Wraith's schemas with its own and its dependencies'. Null if it has none, so it uses Wraith's alone.
schemas: ?*host_api.schemas.Schemas = null,
/// Also gets what it logs, like a workbench session's output.
echo: ?Echo = null,
/// A script session's, not a plugin's.
session: bool = false,
/// Its project, by where its tweaks list: "" for the open one, else a mod's id. Null for plugins.
project: ?[]const u8 = null,
/// Tags what's made now so `host.stopTagged` can stop it apart. Nonzero while a session's tweak runs.
making: Atomic(u32) = .init(0),
/// Ones `schemas` replaced, freed with it, since what they found may still be in use.
retired_schemas: std.ArrayList(*host_api.schemas.Schemas) = .empty,
/// One per [Service] trait in its own schemas. Names point into its schemas.
services: std.ArrayList(host_api.wraith.Plugin.Service) = .empty,
/// The `tuft_mem.Sources` its lookups may use. 0 uses Wraith's setting.
address_sources: Atomic(u8) = .init(0),

pub const Echo = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, level: std.log.Level, text: []const u8) void,
};

/// The `PluginKind` the runtime provides that runs it.
pub const Runner = struct {
    kind: sal.Object(host_api.wraith.Plugin.Kind) = .{},
    plugin: sal.Object(host_api.wraith.Plugin) = .{},
};

/// Who wins contested game parts: game plugin 2, engine plugin 1, else 0. See `host.ranked`.
pub fn tier(self: *const Loaded) u8 {
    const m = self.manifest.value;
    if (m.game != null) return 2;
    if (m.gameEngine != null) return 1;
    return 0;
}

/// Its title, or its name if it has none.
pub fn displayName(self: *const Loaded) []const u8 {
    const title = self.manifest.value.title orelse return self.name;
    return if (title.len != 0) title else self.name;
}

/// `name` as its own, like `kai.hp`. The open project's have no prefix.
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

/// A NativeAOT C# plugin. Can't unload, since .NET's threads in its DLL never leave.
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

/// Once its owner's released: forgets its `Wraith` and frees its schemas. Its strings are the caller's.
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
