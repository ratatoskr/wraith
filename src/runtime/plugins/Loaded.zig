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
/// What's made now is tagged with this, so `host.stopTagged` can stop it apart from the rest. 0
/// for most things, or one of a session's tweaks while it runs.
making: Atomic(u32) = .init(0),
/// Ones `schemas` replaced, freed with it, since what they found may still be in use.
retired_schemas: std.ArrayList(*host_api.schemas.Schemas) = .empty,
/// What it offers plugins that depend on it, one per [Service] trait in its own schemas. The names
/// point into its schemas.
services: std.ArrayList(host_api.wraith.Service) = .empty,

pub const Echo = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, level: std.log.Level, text: []const u8) void,
};

/// The `PluginKind` from Salamander's registry that runs it, from `maker` or built in. The plugin that
/// made it stays loaded while this is.
pub const Runner = struct {
    kind: sal.Object(host_api.wraith.PluginKind) = .{},
    maker: ?*Loaded = null,
    plugin: sal.Object(host_api.wraith.Plugin) = .{},
};

/// Its title, or its name if it has none. For headings people see.
pub fn displayName(self: *const Loaded) []const u8 {
    const title = self.manifest.value.title orelse return self.name;
    return if (title.len != 0) title else self.name;
}

/// The plugin that made its kind, which has to outlive it.
pub fn maker(self: *const Loaded) ?*Loaded {
    return self.runner.maker;
}

pub fn library(self: *const Loaded) usize {
    return self.runner.plugin.module();
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

pub fn deinitForTest(self: *Loaded) void {
    self.owner.release();
}
