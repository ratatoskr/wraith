//! The open project and installed project mods, each a `Loaded` published like a plugin from its
//! `schemas/*.sal`, so its tweaks, statics and address lists show up. Any thread.

const std = @import("std");

const core = @import("wraith_core");
const sync = @import("tuft_sys").sync;
const SalSchema = @import("salamander_schema").Schema;

const Loaded = @import("../PluginLoader.zig").Loaded;
const Names = @import("../Names.zig");
const schemas = @import("schemas.zig");
const shared_schemas = @import("shared_schemas.zig");
const addresses = @import("addresses.zig");

const log = core.log.scoped(.wraith_runtime);
const allocator = std.heap.page_allocator;

pub const File = schemas.File;

/// What a project has now.
pub const Content = struct {
    /// "" for the open project, else the mod's id.
    key: []const u8,
    title: []const u8,
    /// Its `schemas/*.sal`, by path like `schemas/game.sal`.
    schemas: []const File = &.{},
    /// Its address list as saved, or as the workbench has it for the open one. Null leaves it be.
    addresses: ?[]const u8 = null,
};

const Project = struct {
    loaded: Loaded,
    key: []u8,
    title: []u8,
    hash: u64 = 0,
    /// Its schemas as it has them, named like `kai/game.sal`.
    files: []File = &.{},
};

var lock: sync.RwLock = .{};
var list: std.ArrayList(*Project) = .empty;

/// Its `Loaded`'s name, which its files are named under.
fn nameOf(key: []const u8) []const u8 {
    return if (key.len == 0) "project" else key;
}

/// Sets what `c.key`'s project has. Bad schemas are logged and the old ones stay. True if its schemas changed.
pub fn set(c: Content) bool {
    var h = std.hash.Wyhash.init(0);
    h.update(c.title);
    for (c.schemas) |f| {
        h.update(f.name);
        h.update(&.{0});
        h.update(f.text);
        h.update(&.{0});
    }
    if (c.addresses) |a| h.update(a);
    const hash = h.final() | 1;

    lock.lock();
    defer lock.unlock();
    const p = find(c.key) orelse (create(c.key) catch return false);
    if (p.hash == hash) return false;
    p.hash = hash;

    const old_title = p.title;
    p.title = allocator.dupe(u8, c.title) catch old_title;
    p.loaded.manifest.value.title = p.title;
    // Names and lists copy the title or are published again below, so the old one can go after
    defer if (p.title.ptr != old_title.ptr) allocator.free(old_title);

    const now = named(p.loaded.name, c.schemas) catch return false;
    const changed = !sameFiles(p.files, now);
    if (changed) {
        freeFiles(p.files);
        p.files = now;
        useSchemas(p);
    } else freeFiles(now);
    shared_schemas.publish(&p.loaded);
    if (c.addresses) |text| {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        if (Names.parseList(arena.allocator(), text)) |saved| {
            addresses.publishList(&p.loaded, saved.items);
        } else |err| log.warn("{s}'s address list can't be read: {t}", .{ c.title, err });
    }
    return changed;
}

/// Every project but these goes, like a mod that's uninstalled.
pub fn keep(keys: []const []const u8) void {
    lock.lock();
    defer lock.unlock();
    var i: usize = 0;
    while (i < list.items.len) {
        const p = list.items[i];
        const kept = for (keys) |k| {
            if (std.mem.eql(u8, k, p.key)) break true;
        } else false;
        if (kept) {
            i += 1;
            continue;
        }
        _ = list.orderedRemove(i);
        destroy(p);
    }
}

/// Its schemas' files, named like `kai/game.sal`, copied into `arena`. Empty if it has none.
pub fn files(key: []const u8, arena: std.mem.Allocator) []const File {
    lock.lockShared();
    defer lock.unlockShared();
    const p = find(key) orelse return &.{};
    const out = arena.alloc(File, p.files.len) catch return &.{};
    for (p.files, out) |f, *o| o.* = .{
        .name = arena.dupe(u8, f.name) catch return &.{},
        .text = arena.dupe(u8, f.text) catch return &.{},
    };
    return out;
}

/// `files` as one text, like `.sal` that names each file, or "" if there are none.
pub fn bundle(key: []const u8, arena: std.mem.Allocator) []const u8 {
    const these = files(key, arena);
    if (these.len == 0) return "";
    return @import("salamander_schema").bundle(arena, these) catch "";
}

fn find(key: []const u8) ?*Project {
    for (list.items) |p| if (std.mem.eql(u8, p.key, key)) return p;
    return null;
}

fn create(key: []const u8) !*Project {
    const p = try allocator.create(Project);
    errdefer allocator.destroy(p);
    const owned = try allocator.dupe(u8, key);
    errdefer allocator.free(owned);
    p.* = .{ .loaded = undefined, .key = owned, .title = &.{} };
    p.loaded.initBare(allocator, nameOf(owned), "", "");
    p.loaded.project = owned;
    try list.append(allocator, p);
    return p;
}

/// From its files now. What it found before stays till it goes, since it may still be in use.
fn useSchemas(p: *Project) void {
    if (p.files.len == 0) return retire(p, null);
    var diag: SalSchema.Diagnostic = .{};
    const made = schemas.fromFilesWhy(p.files, &diag) catch |err| {
        switch (err) {
            error.InvalidSchema => log.warn("{s}'s schemas: {s}", .{ p.loaded.displayName(), diag.message() }),
            error.OutOfMemory => log.warn("{s}'s schemas: out of memory", .{p.loaded.displayName()}),
        }
        return;
    };
    made.setHome(p.loaded.name);
    retire(p, made);
}

fn retire(p: *Project, next: ?*schemas.Schemas) void {
    if (p.loaded.schemas) |old| p.loaded.retired_schemas.append(allocator, old) catch {};
    p.loaded.schemas = next;
}

fn destroy(p: *Project) void {
    // What it published goes with its owner
    p.loaded.owner.close();
    p.loaded.owner.release();
    p.loaded.free();
    freeFiles(p.files);
    allocator.free(p.title);
    allocator.free(p.key);
    allocator.destroy(p);
}

/// `schemas/game.sal` as `name/game.sal`, like a plugin's.
fn named(name: []const u8, from: []const File) ![]File {
    const out = try allocator.alloc(File, from.len);
    var done: usize = 0;
    errdefer freeFiles(out[0..done]);
    for (from, out) |f, *o| {
        const rest = if (std.mem.startsWith(u8, f.name, "schemas/")) f.name["schemas/".len..] else f.name;
        const n = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ name, rest });
        errdefer allocator.free(n);
        o.* = .{ .name = n, .text = try allocator.dupe(u8, f.text) };
        done += 1;
    }
    return out;
}

fn sameFiles(a: []const File, b: []const File) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x.name, y.name) or !std.mem.eql(u8, x.text, y.text)) return false;
    return true;
}

fn freeFiles(these: []File) void {
    for (these) |f| {
        allocator.free(f.name);
        allocator.free(f.text);
    }
    if (these.len > 0) allocator.free(these);
}
