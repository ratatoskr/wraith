//! A project's `wraith.json`: what it's called on the hub, who made it and which game it's for.
//! Projects are mods too, so it's the same file plugins have, with `"kind": "project"` and none of
//! the fields only plugins can have.

const std = @import("std");

const core = @import("wraith_core");
const game_engine = @import("wraith_game").game_engine;

const Project = @import("Project.zig");

pub const file = core.manifest.file_name;
pub const schema_url = core.manifest.schema_url;

pub const Details = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    summary: []const u8 = "",
    author: []const u8 = "",
    version: []const u8 = "0.1.0",
    description: []const u8 = "",
    license: []const u8 = "",
    homepage: []const u8 = "",
    repo: []const u8 = "",
    /// Like `camera`, for finding it on the hub.
    tags: []const []const u8 = &.{},
    /// Pictures in the project, like `icon.png`, shown on the hub.
    icon: []const u8 = "",
    images: []const []const u8 = &.{},
    /// The oldest Wraith it runs on. Empty means any.
    wraith: []const u8 = "",
    /// Game ids, like steam-1245620. No ids, exes or game engine means any game.
    ids: []const []const u8 = &.{},
    exes: []const []const u8 = &.{},
    /// Every game made with this game engine, like `unity`, instead of ids and exes.
    game_engine: []const u8 = "",
    /// Like `IL2CPP`. Empty means any.
    game_engine_variants: []const []const u8 = &.{},
    depends: []const []const u8 = &.{},
};

/// The game it's made in, for the defaults.
pub const Game = struct {
    /// Null for a copy Wraith only knows by its folder, whose id means nothing elsewhere.
    id: ?[]const u8 = null,
    /// Just the file's name, like kai.exe.
    exe: ?[]const u8 = null,
};

/// Named after the project, for the game it's made in.
pub fn defaults(arena: std.mem.Allocator, name: []const u8, game: Game) !Details {
    var id_buf: [64]u8 = undefined;
    const id = slug(&id_buf, name);
    return .{
        .id = try arena.dupe(u8, id),
        .title = if (std.mem.eql(u8, name, "Untitled")) "My project" else try arena.dupe(u8, name),
        .summary = "Tweaks for the game.",
        .ids = if (game.id) |g| try arena.dupe([]const u8, &.{g}) else &.{},
        .exes = if (game.exe) |e| if (e.len > 0) try arena.dupe([]const u8, &.{e}) else &.{} else &.{},
    };
}

/// A valid id from a name, like `Kai Tables` to `kai_tables`.
pub fn slug(buf: *[64]u8, name: []const u8) []const u8 {
    var n: usize = 0;
    for (name) |c| {
        if (n == buf.len) break;
        const lower = std.ascii.toLower(c);
        const ok = std.ascii.isLower(lower) or std.ascii.isDigit(lower) or lower == '-' or lower == '_';
        const out: u8 = if (ok) lower else '_';
        // No runs of _, and not first
        if (out == '_' and (n == 0 or buf[n - 1] == '_')) continue;
        buf[n] = out;
        n += 1;
    }
    while (n > 0 and buf[n - 1] == '_') n -= 1;
    const id = buf[0..n];
    return if (core.manifest.validId(id)) id else "my_project";
}

/// Null if the project has none. Its text if it can't be read, as `problem`.
pub fn read(arena: std.mem.Allocator, project: *Project, problem: *[]const u8) !?Details {
    const text = try project.read(arena, file) orelse return null;
    const m = core.manifest.parse(arena, text, problem) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return err,
    };
    const game = m.game orelse core.manifest.Game{};
    return .{
        .id = m.id,
        .title = m.title orelse "",
        .summary = m.summary orelse "",
        .author = m.author orelse "",
        .version = m.version orelse "",
        .description = m.description orelse "",
        .license = m.license orelse "",
        .homepage = m.homepage orelse "",
        .repo = m.repo orelse "",
        .tags = m.tags,
        .icon = m.icon orelse "",
        .images = m.images,
        .wraith = m.wraith orelse "",
        .ids = game.ids,
        .exes = game.exes,
        .game_engine = if (m.gameEngine) |e| e.id else "",
        .game_engine_variants = if (m.gameEngine) |e| e.variants else &.{},
        .depends = m.depends,
    };
}

/// What's wrong with it, said plainly, or null. Like the hub's checks.
pub fn check(d: Details) ?[]const u8 {
    if (!core.manifest.validId(d.id)) return "The id should be 2 to 64 lowercase letters, digits, _ or -, starting with a letter or digit";
    if (d.title.len == 0 or d.title.len > 80) return "The title should be 1 to 80 characters";
    if (d.summary.len == 0 or d.summary.len > 200) return "The summary should be one line of up to 200 characters";
    if (!isVersion(d.version)) return "The version should be like 1.2.0";
    if (d.wraith.len > 0 and !isNumbers(d.wraith, 3)) return "The oldest Wraith should be like 0.4 or 0.4.1";
    if (d.homepage.len > 0 and !std.mem.startsWith(u8, d.homepage, "https://")) return "The homepage should start with https://";
    if (d.repo.len > 0 and !std.mem.startsWith(u8, d.repo, "https://")) return "The repo should start with https://";
    if (d.tags.len > 10) return "Up to 10 tags";
    for (d.tags) |t| if (!core.manifest.validTag(t)) return "Tags are lowercase words, like camera or quality-of-life";
    if (d.icon.len > 0 and !core.manifest.validImage(d.icon)) return "The icon should be a PNG, JPEG or WebP in the project, like icon.png";
    if (d.images.len > 8) return "Up to 8 images";
    for (d.images) |i| if (!core.manifest.validImage(i)) return "Images should be PNGs, JPEGs or WebPs in the project, like images/menu.png";
    for (d.exes) |e| if (!std.ascii.endsWithIgnoreCase(e, ".exe") or std.mem.indexOfAny(u8, e, "/\\:") != null) return "Exes should be just a file's name, like game.exe";
    for (d.ids) |id| if (id.len == 0 or std.mem.indexOfAny(u8, id, " /\\") != null) return "Game ids look like steam-1245620, with no spaces";
    for (d.depends) |dep| if (!core.manifest.validId(core.manifest.Dependency.parse(dep).name)) return "Depends should be mod ids, like unity or unity@1.2";
    if (d.game_engine.len > 0) {
        if (d.ids.len > 0 or d.exes.len > 0) return "It's for one game or every game made with a game engine, not both";
        if (std.meta.stringToEnum(game_engine.GameEngine, d.game_engine) == null) return "That's not a game engine Wraith knows";
    } else if (d.game_engine_variants.len > 0) return "Variants need a game engine";
    return null;
}

fn isVersion(v: []const u8) bool {
    const core_part = v[0 .. std.mem.indexOfScalar(u8, v, '-') orelse v.len];
    var it = std.mem.splitScalar(u8, core_part, '.');
    var n: usize = 0;
    while (it.next()) |p| : (n += 1) {
        if (p.len == 0 or (p.len > 1 and p[0] == '0')) return false;
        for (p) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return n == 3;
}

fn isNumbers(v: []const u8, max: usize) bool {
    var it = std.mem.splitScalar(u8, v, '.');
    var n: usize = 0;
    while (it.next()) |p| : (n += 1) {
        if (p.len == 0) return false;
        for (p) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return n >= 1 and n <= max;
}

/// As the file, with empty fields left out.
pub fn toJson(arena: std.mem.Allocator, d: Details) ![]u8 {
    const has_game = d.ids.len > 0 or d.exes.len > 0;
    const m: core.manifest.Manifest = .{
        .id = d.id,
        .kind = .project,
        .version = d.version,
        .title = d.title,
        .summary = d.summary,
        .description = d.description,
        .author = d.author,
        .license = d.license,
        .homepage = d.homepage,
        .repo = d.repo,
        .tags = d.tags,
        .icon = d.icon,
        .images = d.images,
        .wraith = d.wraith,
        .game = if (has_game) .{ .ids = d.ids, .exes = d.exes } else null,
        .gameEngine = if (d.game_engine.len > 0) .{ .id = d.game_engine, .variants = d.game_engine_variants } else null,
        .depends = d.depends,
    };
    return m.toJson(arena);
}
/// Writes it into the project. Fails with what `check` says.
pub fn write(project: *Project, gpa: std.mem.Allocator, d: Details) !void {
    if (check(d) != null) return error.Invalid;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try project.write(file, try toJson(arena.allocator(), d));
}

test "ids from names" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("kai_tables", slug(&buf, "Kai Tables"));
    try std.testing.expectEqualStrings("kai_tables", slug(&buf, "  Kai  Tables! "));
    try std.testing.expectEqualStrings("my_project", slug(&buf, "!!"));
    try std.testing.expectEqualStrings("my_project", slug(&buf, "Ü"));
}

test "written, read back and checked like the hub" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const project = try Project.create(testing.allocator, testing.io, dir);
    defer project.destroy();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var problem: []const u8 = "";

    try testing.expectEqual(null, try read(a, project, &problem));
    try write(project, testing.allocator, try defaults(a, "Kai Tables", .{ .id = "steam-1", .exe = "kai.exe" }));
    const made = (try read(a, project, &problem)).?;
    try testing.expectEqualStrings("kai_tables", made.id);
    try testing.expectEqualStrings("Kai Tables", made.title);
    try testing.expectEqualStrings("steam-1", made.ids[0]);
    try testing.expectEqualStrings("kai.exe", made.exes[0]);
    const text = (try project.read(a, file)).?;
    try testing.expect(std.mem.indexOf(u8, text, "\"kind\": \"project\"") != null);
    // Nothing only plugins have, and nothing empty
    try testing.expect(std.mem.indexOf(u8, text, "autoLoad") == null);
    try testing.expect(std.mem.indexOf(u8, text, "author") == null);

    var changed = made;
    changed.author = "Asgard";
    changed.ids = &.{};
    changed.exes = &.{};
    try write(project, testing.allocator, changed);
    const again = (try read(a, project, &problem)).?;
    try testing.expectEqualStrings("Asgard", again.author);
    try testing.expectEqual(0, again.ids.len + again.exes.len);

    // Hub extras survive being written back
    var extras = again;
    extras.repo = "https://github.com/me/kai";
    extras.tags = &.{ "tables", "ui" };
    extras.icon = "icon.png";
    extras.images = &.{"images/menu.png"};
    try write(project, testing.allocator, extras);
    const kept = (try read(a, project, &problem)).?;
    try testing.expectEqualStrings("https://github.com/me/kai", kept.repo);
    try testing.expectEqualStrings("ui", kept.tags[1]);
    try testing.expectEqualStrings("icon.png", kept.icon);
    try testing.expectEqualStrings("images/menu.png", kept.images[0]);
    var bad_tag = kept;
    bad_tag.tags = &.{"Tables"};
    try testing.expect(check(bad_tag) != null);

    // Every Unity IL2CPP game, never one game as well
    var engine = again;
    engine.game_engine = "unity";
    engine.game_engine_variants = &.{"IL2CPP"};
    try write(project, testing.allocator, engine);
    const for_engine = (try read(a, project, &problem)).?;
    try testing.expectEqualStrings("unity", for_engine.game_engine);
    try testing.expectEqualStrings("IL2CPP", for_engine.game_engine_variants[0]);
    try testing.expect(std.mem.indexOf(u8, (try project.read(a, file)).?, "\"gameEngine\"") != null);
    var both = for_engine;
    both.ids = &.{"steam-1"};
    try testing.expect(check(both) != null);
    var unknown = for_engine;
    unknown.game_engine = "frostbite9";
    try testing.expect(check(unknown) != null);

    var bad = again;
    bad.version = "1.2";
    try testing.expect(check(bad) != null);
    try testing.expectError(error.Invalid, write(project, testing.allocator, bad));

    // Exported as a mod: wraith.json at the top, without the project's own manifest
    try project.write(Project.manifest_file, ".{}");
    try project.write("tweaks/speed.rwt", "@js\n");
    const zip = try std.fs.path.join(a, &.{ dir, "out", "kai_tables-0.1.0.zip" });
    try project.exportMod(zip);
    try tmp.dir.createDirPath(testing.io, "unzipped");
    var unzipped = try tmp.dir.openDir(testing.io, "unzipped", .{});
    defer unzipped.close(testing.io);
    {
        var f = try std.Io.Dir.cwd().openFile(testing.io, zip, .{});
        defer f.close(testing.io);
        var buf: [4096]u8 = undefined;
        var reader = f.reader(testing.io, &buf);
        try std.zip.extract(unzipped, &reader, .{});
    }
    try unzipped.access(testing.io, file, .{});
    try unzipped.access(testing.io, "tweaks/speed.rwt", .{});
    try testing.expectError(error.FileNotFound, unzipped.access(testing.io, Project.manifest_file, .{}));
    bad = again;
    bad.exes = &.{"C:/kai.exe"};
    try testing.expect(check(bad) != null);
    bad = again;
    bad.id = "Kai";
    try testing.expect(check(bad) != null);
}
