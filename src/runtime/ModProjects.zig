//! Installed project mods for the game Wraith's in, read for their tweaks, schemas and address
//! list. Not on the render thread, since it reads every one's files.

const std = @import("std");

const core = @import("wraith_core");

const discovery = @import("plugins/discovery.zig");
const Manifest = @import("Manifest.zig");
const Project = @import("Project.zig");
const Tweaks = @import("Tweaks.zig");
const schemas = @import("host/schemas.zig");

const log = core.log.scoped(.wraith_runtime);

/// Big enough for any tweak someone means to write.
const max_file = 1 << 20;

/// In `arena`. Ones for other games are left out, and so are folders that aren't projects and
/// copies the hub pulled, by `revoked` hashes.
pub fn read(arena: std.mem.Allocator, io: std.Io, mods_dir: []const u8, here: core.manifest.Here, revoked: []const []const u8) ![]const Tweaks.ModProject {
    var dir = std.Io.Dir.openDirAbsolute(io, mods_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(io);
    var out: std.ArrayList(Tweaks.ModProject) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const folder = try std.fs.path.join(arena, &.{ mods_dir, entry.name });
        const manifest = (Manifest.read(arena, io, folder) catch continue) orelse continue;
        const m = manifest.value;
        if (m.kind != .project or !m.isFor(here)) continue;
        switch (m.apiFit()) {
            .yes => {},
            .outdated => {
                log.warn("Not using {s}'s tweaks: its apiVersion is missing or older than {d}, so it needs updating for this Wraith", .{ m.id, core.manifest.min_api_version });
                continue;
            },
            .newer => {
                log.info("Not using {s}'s tweaks: it's made for a newer Wraith's API (this has {d})", .{ m.id, core.manifest.api_version });
                continue;
            },
        }
        if (discovery.installedRevoked(arena, io, revoked, mods_dir, entry.name)) {
            log.warn("Not using {s}'s tweaks: the hub pulled this version. Update or remove it", .{m.id});
            continue;
        }
        const files = tweakFiles(arena, io, folder) catch |err| {
            log.warn("Couldn't read {s}'s tweaks: {t}", .{ m.id, err });
            continue;
        };
        const schema_files = schemaFiles(arena, io, folder) catch |err| {
            log.warn("Couldn't read {s}'s schemas: {t}", .{ m.id, err });
            continue;
        };
        const addresses = readOptional(arena, io, folder, Project.addresses_file) catch |err| {
            log.warn("Couldn't read {s}'s address list: {t}", .{ m.id, err });
            continue;
        };
        if (files.len == 0 and schema_files.len == 0 and addresses == null) continue;
        try out.append(arena, .{ .id = m.id, .title = m.title orelse m.id, .files = files, .schemas = schema_files, .addresses = addresses });
    }
    std.mem.sort(Tweaks.ModProject, out.items, {}, struct {
        fn lessThan(_: void, a: Tweaks.ModProject, b: Tweaks.ModProject) bool {
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.lessThan);
    return out.items;
}

fn tweakFiles(arena: std.mem.Allocator, io: std.Io, folder: []const u8) ![]const Tweaks.ModFile {
    const path = try std.fs.path.join(arena, &.{ folder, "tweaks" });
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(io);
    var out: std.ArrayList(Tweaks.ModFile) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.ascii.endsWithIgnoreCase(entry.name, Project.ext.tweak)) continue;
        const text = try dir.readFileAlloc(io, entry.name, arena, .limited(max_file));
        try out.append(arena, .{ .path = try std.fmt.allocPrint(arena, "tweaks/{s}", .{entry.name}), .text = text });
    }
    return out.items;
}

/// Its `schemas/*.sal`, any folder down, by path like `schemas/game.sal`, read like a plugin's.
fn schemaFiles(arena: std.mem.Allocator, io: std.Io, folder: []const u8) ![]const schemas.File {
    var files: std.ArrayList(schemas.File) = .empty;
    try schemas.readFolder(arena, io, "schemas", folder, &files);
    return files.items;
}

fn readOptional(arena: std.mem.Allocator, io: std.Io, folder: []const u8, name: []const u8) !?[]const u8 {
    var dir = try std.Io.Dir.openDirAbsolute(io, folder, .{});
    defer dir.close(io);
    return dir.readFileAlloc(io, name, arena, .limited(max_file)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

/// Reads them again and hands them to `tweaks`. `cache_dir` has the hub's last revoked list.
pub fn refresh(tweaks: *Tweaks, gpa: std.mem.Allocator, io: std.Io, mods_dir: []const u8, cache_dir: []const u8, here: core.manifest.Here) void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const revoked = discovery.cachedRevoked(arena.allocator(), io, cache_dir);
    const mods = read(arena.allocator(), io, mods_dir, here, revoked) catch |err| {
        log.warn("Couldn't read the installed projects in {s}: {t}", .{ mods_dir, err });
        return;
    };
    tweaks.setMods(mods) catch |err| log.warn("Couldn't take the installed projects' tweaks: {t}", .{err});
}

test "only projects for this game, with their tweak files" {
    const testing = std.testing;
    const io = testing.io;
    const muted = core.log.mute(&.{.runtime});
    defer core.log.setFilter(muted);
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const files = [_][2][]const u8{
        .{ "tables/wraith.json", "{ \"id\": \"tables\", \"kind\": \"project\", \"apiVersion\": 2, \"title\": \"Tables\", \"game\": { \"exes\": [\"kai.exe\"] } }" },
        .{ "tables/tweaks/speed.rwt", "@js" },
        .{ "tables/tweaks/readme.md", "no" },
        .{ "elsewhere/wraith.json", "{ \"id\": \"elsewhere\", \"kind\": \"project\", \"apiVersion\": 2, \"game\": { \"ids\": [\"steam-2\"] } }" },
        .{ "elsewhere/tweaks/a.rwt", "@js" },
        .{ "old/wraith.json", "{ \"id\": \"old\", \"kind\": \"project\", \"game\": { \"exes\": [\"kai.exe\"] } }" },
        .{ "old/tweaks/a.rwt", "@js" },
        .{ "plug/wraith.json", "{ \"id\": \"plug\" }" },
        .{ "plug/tweaks/a.rwt", "@js" },
    };
    for (files) |f| {
        if (std.fs.path.dirname(f[0])) |d| try tmp.dir.createDirPath(io, d);
        try tmp.dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
    }
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const here: core.manifest.Here = .{ .id = "steam-1", .exe = "D:\\Games\\KAI.exe" };
    const found = try read(arena.allocator(), io, root, here, &.{});
    try testing.expectEqual(1, found.len);
    try testing.expectEqualStrings("tables", found[0].id);
    try testing.expectEqualStrings("Tables", found[0].title);
    try testing.expectEqual(1, found[0].files.len);
    try testing.expectEqualStrings("tweaks/speed.rwt", found[0].files[0].path);
    try testing.expectEqual(0, (try read(arena.allocator(), io, "Z:\\no\\such", .{}, &.{})).len);

    // A copy the hub pulled is skipped, by the hash it was installed with
    const registry = @import("wraith_registry");
    try tmp.dir.writeFile(io, .{ .sub_path = "tables/" ++ registry.installed_name, .data = ".{ .id = \"tables\", .version = \"1.0.0\", .sha256 = \"abc\" }" });
    const saved = core.log.mute(&.{.runtime});
    defer core.log.setFilter(saved);
    try testing.expectEqual(0, (try read(arena.allocator(), io, root, here, &.{"ABC"})).len);
    try testing.expectEqual(1, (try read(arena.allocator(), io, root, here, &.{"abd"})).len);
}
