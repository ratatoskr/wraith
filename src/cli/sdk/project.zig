//! The plugin in the folder `wraith sdk` runs in: its schemas, those of the plugins it depends on, and
//! Wraith's, parsed the way Wraith parses them as it loads it. Every language's types are made from this.

const std = @import("std");

const core = @import("wraith_core");
const api = @import("wraith_api");
const salamander_schema = @import("salamander_schema");

const ops = @import("../ops.zig");
const deps = @import("../deps.zig");

const log = core.log.scoped(.wraith_cli);

const Project = @This();
const Schema = salamander_schema.Schema;
pub const File = salamander_schema.File;
pub const Parsed = salamander_schema.Parsed;

arena: std.mem.Allocator,
/// Its own `.sal` files then its dependencies', named like `schemas/game.sal` and `freecam/cam.sal`.
files: []const File,
/// The plugins its wraith.json depends on. Their schemas are in their own namespaces.
depends: []const []const u8,
/// Its schemas', like `TrailsHorizon`.
namespace: []const u8,
pointer_size: u8,
/// Everything it's made from, absolute: this wraith, wraith.json, and each schema folder and file.
inputs: []const []const u8,
diag: Schema.Diagnostic = .{},

pub const Options = struct {
    /// Its id in PascalCase if empty.
    namespace: []const u8 = "",
    pointer_size: u8 = 8,
    /// Don't download dependencies from the hub.
    offline: bool = false,
    /// `.sal` files or folders besides schemas/.
    extra: []const []const u8 = &.{},
};

pub fn load(ctx: ops.Context, arena: std.mem.Allocator, options: Options) !Project {
    const io = ctx.io;
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", arena);
    var files: std.ArrayList(File) = .empty;
    var inputs: std.ArrayList([]const u8) = .empty;
    try inputs.append(arena, try slashed(arena, try std.process.executablePathAlloc(io, arena)));
    try inputs.append(arena, try absolute(arena, cwd, core.manifest.file_name));

    try addOwn(arena, io, cwd, "schemas", &files, &inputs, true);
    for (options.extra) |input| addOwn(arena, io, cwd, input, &files, &inputs, false) catch |err| {
        log.err("{s}: {t}", .{ input, err });
        return error.InvalidSchema;
    };

    const found = try deps.resolve(ctx, arena, try deps.listed(arena, io), !options.offline);
    const names = try arena.alloc([]const u8, found.len);
    for (found, names) |f, *n| {
        n.* = f.name;
        try addDependency(arena, io, f, &files, &inputs);
    }
    return .{
        .arena = arena,
        .files = files.items,
        .depends = names,
        .namespace = if (options.namespace.len > 0) options.namespace else try namespaceOf(arena, io),
        .pointer_size = options.pointer_size,
        .inputs = inputs.items,
    };
}

/// A folder's or file's schemas, and it as an input. A missing folder's fine when `optional`.
fn addOwn(arena: std.mem.Allocator, io: std.Io, cwd: []const u8, input: []const u8, files: *std.ArrayList(File), inputs: *std.ArrayList([]const u8), optional: bool) !void {
    const start = files.items.len;
    collect(arena, io, input, files) catch |err| switch (err) {
        error.FileNotFound => if (optional) return else return err,
        else => return err,
    };
    try inputs.append(arena, try absolute(arena, cwd, input));
    for (files.items[start..]) |f| try inputs.append(arena, try absolute(arena, cwd, f.name));
}

/// A dependency's schemas, named like `name/path.sal` the way Wraith names them.
fn addDependency(arena: std.mem.Allocator, io: std.Io, dep: deps.Found, files: *std.ArrayList(File), inputs: *std.ArrayList([]const u8)) !void {
    const dir = try std.fs.path.join(arena, &.{ dep.dir, "schemas" });
    const start = files.items.len;
    collect(arena, io, dir, files) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    try inputs.append(arena, try slashed(arena, dir));
    const prefix = (try slashed(arena, dir)).len + 1;
    for (files.items[start..]) |*f| {
        try inputs.append(arena, f.name);
        f.name = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dep.name, f.name[prefix..] });
    }
}

/// Each package's schemas parse in its own namespace, and every file sees Wraith's and its dependencies' without `use`.
pub fn parseOptions(self: *const Project) !salamander_schema.Options {
    var o = api.sal_options;
    o.pointer_size = self.pointer_size;
    o.namespace = self.namespace;
    const base = api.sal_options.global_uses;
    const uses = try self.arena.alloc([]const u8, base.len + self.depends.len);
    @memcpy(uses[0..base.len], base);
    const file_ns = try self.arena.alloc(salamander_schema.FileNamespace, self.depends.len);
    for (self.depends, file_ns, uses[base.len..]) |d, *f, *u| {
        const ns = try pascal(self.arena, d);
        f.* = .{ .prefix = try std.fmt.allocPrint(self.arena, "{s}/", .{d}), .namespace = ns };
        u.* = ns;
    }
    o.global_uses = uses;
    o.file_namespaces = file_ns;
    return o;
}

/// Its own and its dependencies' files as one bundle.
fn own(self: *Project) ![]const u8 {
    return salamander_schema.bundle(self.arena, self.files) catch |err| {
        if (err == error.InvalidFileName) log.err("A schema's file name can't be used: {t}", .{err});
        return if (err == error.InvalidFileName) error.InvalidSchema else err;
    };
}

fn parse(self: *Project, text: []const u8) !Parsed {
    return salamander_schema.parse(self.arena, text, try self.parseOptions(), &self.diag) catch |err| {
        if (err == error.InvalidSchema) log.err("{s}", .{self.diag.message()});
        return err;
    };
}

/// Wraith's own API.
pub fn wraith(self: *Project) !Parsed {
    return self.parse(api.wraith_sal);
}

/// Wraith's then its own, as one schema, for scripts that see them all as globals.
pub fn all(self: *Project) !Parsed {
    return self.parse(try std.mem.concat(self.arena, u8, &.{ api.wraith_sal, "\n", try self.own() }));
}

/// The same with Wraith's files named `wraith/...` like plugin builds name them, so a language's alias for
/// `wraith/` uses Wraith's types from where its API was written instead of writing them again.
pub fn mine(self: *Project) !Parsed {
    const marker = Schema.bundle_marker;
    const renamed = try std.mem.replaceOwned(u8, self.arena, api.wraith_sal, "\n" ++ marker, "\n" ++ marker ++ "wraith/");
    return self.parse(try std.mem.concat(self.arena, u8, &.{ marker ++ "wraith/", renamed[marker.len..], "\n", try self.own() }));
}

/// The [Service] traits its dependencies offer, like `Freecam.Freecam`, which scripts get as `Freecam.freecam()`.
pub fn services(self: *const Project, parsed: Parsed) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (self.depends) |d| for (parsed.schema.traits) |*t| if (isServiceOf(parsed, t, d)) try out.append(self.arena, t.name);
    return out.items;
}

/// A generator's NameClash as what's wrong with its schemas.
pub fn clash(self: *Project, err: anyerror) anyerror {
    if (err == error.NameClash) {
        log.err("{s}", .{self.diag.message()});
        return error.InvalidSchema;
    }
    return err;
}

fn isServiceOf(parsed: Parsed, t: *const Schema.Trait, plugin: []const u8) bool {
    if (Schema.findAnnotation(t.annotations, "wraith", "Service") == null) return false;
    const file = Schema.fileOf(parsed.source, t.at);
    return file.len > plugin.len and std.mem.startsWith(u8, file, plugin) and file[plugin.len] == '/';
}

/// The plugin's id from its wraith.json in PascalCase, like `TrailsHorizon`, or `Plugin` without one.
fn namespaceOf(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(io, core.manifest.file_name, arena, .limited(1 << 20)) catch return "Plugin";
    const m = std.json.parseFromSliceLeaky(struct { id: []const u8 = "" }, arena, text, .{ .ignore_unknown_fields = true }) catch return "Plugin";
    return pascal(arena, m.id);
}

/// The namespace for a plugin's id, like `TrailsHorizon`.
pub fn pascal(arena: std.mem.Allocator, id: []const u8) ![]const u8 {
    var buf: [core.manifest.namespace_max]u8 = undefined;
    return arena.dupe(u8, core.manifest.namespaceOf(&buf, id));
}

/// `input`'s `.sal` files, a folder's in order, named by their path from here.
fn collect(arena: std.mem.Allocator, io: std.Io, input: []const u8, files: *std.ArrayList(File)) !void {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, input, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return files.append(arena, .{ .name = try slashed(arena, input), .text = try cwd.readFileAlloc(io, input, arena, .limited(16 << 20)) }),
        else => return err,
    };
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit(io);
    var found: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".sal")) continue;
        try found.append(arena, try std.fs.path.join(arena, &.{ input, entry.path }));
    }
    std.mem.sort([]const u8, found.items, {}, lessThan);
    for (found.items) |path| try files.append(arena, .{ .name = try slashed(arena, path), .text = try cwd.readFileAlloc(io, path, arena, .limited(16 << 20)) });
}

fn absolute(arena: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]const u8 {
    return slashed(arena, try std.fs.path.resolve(arena, &.{ cwd, path }));
}

pub fn slashed(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, path);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// One for tests, with these files and no dependencies' or inputs.
pub fn forTest(arena: std.mem.Allocator, files: []const File, depends: []const []const u8, namespace: []const u8) Project {
    return .{ .arena = arena, .files = files, .depends = depends, .namespace = namespace, .pointer_size = 8, .inputs = &.{} };
}
