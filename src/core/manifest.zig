//! A package's manifest, `wraith.json` at the top of its folder. The hub has its schema, at
//! https://hub.wraith.io/schema/v1/wraith.json. Plugins and projects both use it.

const std = @import("std");

const Arch = @import("arch.zig").Arch;

pub const file_name = "wraith.json";
/// What editors check it against, the hub's.
pub const schema_url = "https://hub.wraith.io/schema/v1/wraith.json";

/// The game a package is for. Any of its ids or exes will do.
pub const Game = struct {
    /// Wraith's ids for it, like ffxiv or steam-1245620.
    ids: []const []const u8 = &.{},
    /// Exe names, like kai.exe, for copies Wraith has no id for.
    exes: []const []const u8 = &.{},
    /// Builds it was tested on, like steam:18234455.
    builds: []const []const u8 = &.{},
    /// SHA-512s of exes it was tested on, in hex. Works for any store or a local copy.
    hashes: []const []const u8 = &.{},

    pub fn matches(self: Game, here: Here) bool {
        if (here.id) |have| for (self.ids) |want| if (std.mem.eql(u8, want, have)) return true;
        if (here.exe) |have| for (self.exes) |want| if (std.ascii.eqlIgnoreCase(want, std.fs.path.basename(have))) return true;
        return false;
    }

    /// Whether it was tested on this copy. Null if it lists nothing to tell by.
    pub fn testedOn(self: Game, copy: Copy) ?bool {
        var any = false;
        if (copy.sha512) |have| {
            for (self.hashes) |h| if (std.ascii.eqlIgnoreCase(h, have)) return true;
            any = self.hashes.len != 0;
        }
        if (copy.build) |build| {
            const store = build[0 .. std.mem.indexOfScalar(u8, build, ':') orelse build.len];
            for (self.builds) |b| {
                if (std.mem.eql(u8, b, build)) return true;
                if (b.len > store.len and b[store.len] == ':' and std.mem.startsWith(u8, b, store)) any = true;
            }
        }
        return if (any) false else null;
    }
};

/// One copy of a game, to check against what a package was tested on.
pub const Copy = struct {
    /// Like steam:18234455.
    build: ?[]const u8 = null,
    /// The exe's SHA-512, in hex.
    sha512: ?[]const u8 = null,
};

/// The game Wraith's in.
pub const Here = struct {
    id: ?[]const u8 = null,
    exe: ?[]const u8 = null,
    /// Like `unity`, from the files beside its exe.
    game_engine: ?[]const u8 = null,
    /// Like `IL2CPP`.
    game_engine_variant: ?[]const u8 = null,
};

/// Every game made with a game engine, for a package that works on any of them. Not script engines
/// or the hook engine.
pub const GameEngine = struct {
    /// Like `unity`, the way Wraith names them.
    id: []const u8 = "",
    /// Like `IL2CPP`. Empty means any.
    variants: []const []const u8 = &.{},

    pub fn matches(self: GameEngine, here: Here) bool {
        const have = here.game_engine orelse return false;
        if (!std.ascii.eqlIgnoreCase(self.id, have)) return false;
        if (self.variants.len == 0) return true;
        const variant = here.game_engine_variant orelse return false;
        for (self.variants) |v| if (std.ascii.eqlIgnoreCase(v, variant)) return true;
        return false;
    }
};

pub const Kind = enum { plugin, project };

/// What a `cs` plugin does about .NET when no CoreCLR is running yet.
pub const ClrMode = enum {
    /// Joins the game's CoreCLR, else starts the installed .NET.
    load,
    /// Never starts one. It starts once one's running, like a mod loader's that comes later.
    wait,
    /// Only runs where one's running already as it loads, else it isn't loaded.
    provided,
};

/// The version of Wraith's API this Wraith has. It goes up when plugins and projects need
/// updating for it, and packages say which they're made for with `apiVersion`.
pub const api_version: u32 = 2;
/// The oldest `apiVersion` this Wraith still loads. 2 put the API in `namespace Wraith`, which
/// changed every trait's hash.
pub const min_api_version: u32 = 2;

/// Whether this Wraith loads a package made for `apiVersion`.
pub const ApiFit = enum {
    yes,
    /// It doesn't say, or it's for an older API. It needs updating by its author.
    outdated,
    /// It's for a newer Wraith.
    newer,

    pub fn of(version: ?u32) ApiFit {
        const v = version orelse return .outdated;
        if (v < min_api_version) return .outdated;
        if (v > api_version) return .newer;
        return .yes;
    }
};

pub const Manifest = struct {
    id: []const u8 = "",
    kind: Kind = .plugin,
    version: ?[]const u8 = null,
    /// The version of Wraith's API it's made for, see `api_version`. Without it, it won't load.
    apiVersion: ?u32 = null,
    title: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    description: ?[]const u8 = null,
    author: ?[]const u8 = null,
    license: ?[]const u8 = null,
    homepage: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    icon: ?[]const u8 = null,
    images: []const []const u8 = &.{},
    wraith: ?[]const u8 = null,
    game: ?Game = null,
    gameEngine: ?GameEngine = null,
    arches: ?[]const Arch = null,
    provider: ?[]const u8 = null,
    /// For `cs` plugins, see `ClrMode`.
    clrMode: ClrMode = .load,
    autoLoad: bool = true,
    library: bool = false,
    depends: []const []const u8 = &.{},
    /// For building against plugins you're working on: a name from `depends` to its folder, or
    /// its wraith.json, relative to this one. Left out of packages, see `packaged`.
    devDepends: std.json.ArrayHashMap([]const u8) = .{},
    /// A Markdown file relative to this one, instead of `description`. Packages have it put in
    /// `description`, see `packaged`.
    descriptionFile: ?[]const u8 = null,

    pub fn isFor(self: Manifest, here: Here) bool {
        if (self.game) |game| return game.matches(here);
        if (self.gameEngine) |engine| return engine.matches(here);
        return true;
    }

    pub fn builtFor(self: Manifest, arch: Arch) bool {
        const arches = self.arches orelse return true;
        return std.mem.indexOfScalar(Arch, arches, arch) != null;
    }

    pub fn runsOn(self: Manifest, version: []const u8) bool {
        return satisfies(version, self.wraith orelse return true);
    }

    pub fn apiFit(self: Manifest) ApiFit {
        return .of(self.apiVersion);
    }

    /// As the file, with the schema first and what's empty or a default left out.
    pub fn write(self: Manifest, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const Out = struct {
            @"$schema": []const u8 = schema_url,
            id: []const u8,
            kind: Kind,
            version: ?[]const u8 = null,
            apiVersion: ?u32 = null,
            title: ?[]const u8 = null,
            summary: ?[]const u8 = null,
            description: ?[]const u8 = null,
            author: ?[]const u8 = null,
            license: ?[]const u8 = null,
            homepage: ?[]const u8 = null,
            repo: ?[]const u8 = null,
            tags: ?[]const []const u8 = null,
            icon: ?[]const u8 = null,
            images: ?[]const []const u8 = null,
            wraith: ?[]const u8 = null,
            game: ?struct {
                ids: ?[]const []const u8 = null,
                exes: ?[]const []const u8 = null,
                builds: ?[]const []const u8 = null,
                hashes: ?[]const []const u8 = null,
            } = null,
            gameEngine: ?struct {
                id: []const u8,
                variants: ?[]const []const u8 = null,
            } = null,
            arches: ?[]const Arch = null,
            provider: ?[]const u8 = null,
            clrMode: ?ClrMode = null,
            autoLoad: ?bool = null,
            library: ?bool = null,
            depends: ?[]const []const u8 = null,
            devDepends: ?std.json.ArrayHashMap([]const u8) = null,
            descriptionFile: ?[]const u8 = null,
        };
        const out: Out = .{
            .id = self.id,
            .kind = self.kind,
            .version = text(self.version),
            .apiVersion = self.apiVersion,
            .title = text(self.title),
            .summary = text(self.summary),
            .description = text(self.description),
            .author = text(self.author),
            .license = text(self.license),
            .homepage = text(self.homepage),
            .repo = text(self.repo),
            .tags = list(self.tags),
            .icon = text(self.icon),
            .images = list(self.images),
            .wraith = text(self.wraith),
            .game = if (self.game) |g| .{ .ids = list(g.ids), .exes = list(g.exes), .builds = list(g.builds), .hashes = list(g.hashes) } else null,
            .gameEngine = if (self.gameEngine) |e| .{ .id = e.id, .variants = list(e.variants) } else null,
            .arches = self.arches,
            .provider = text(self.provider),
            .clrMode = if (self.clrMode == .load) null else self.clrMode,
            .autoLoad = if (self.autoLoad) null else false,
            .library = if (self.library) true else null,
            .depends = list(self.depends),
            .devDepends = if (self.devDepends.map.count() > 0) self.devDepends else null,
            .descriptionFile = text(self.descriptionFile),
        };
        try std.json.Stringify.value(out, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, w);
        try w.writeByte('\n');
    }

    /// `write`, in `gpa`.
    pub fn toJson(self: Manifest, gpa: std.mem.Allocator) error{OutOfMemory}![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        self.write(&out.writer) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }

    fn text(s: ?[]const u8) ?[]const u8 {
        const t = s orelse return null;
        return if (t.len > 0) t else null;
    }

    fn list(l: []const []const u8) ?[]const []const u8 {
        return if (l.len > 0) l else null;
    }
};

/// Only releases get a real one.
pub const dev_version = "0.0.0";

/// Dev builds always are, so they load everything.
pub fn satisfies(have: []const u8, needs: []const u8) bool {
    return compareVersions(have, dev_version) == .eq or compareVersions(needs, have) != .gt;
}

/// One of `depends`, like `unity` or `unity@1.2`.
pub const Dependency = struct {
    name: []const u8,
    /// Null means any version.
    min: ?[]const u8 = null,

    pub fn parse(text: []const u8) Dependency {
        const at = std.mem.indexOfScalar(u8, text, '@') orelse return .{ .name = text };
        const min = text[at + 1 ..];
        return .{ .name = text[0..at], .min = if (min.len == 0) null else min };
    }

    /// Whether a plugin at `version` will do. No version counts as a dev build.
    pub fn fits(self: Dependency, version: []const u8) bool {
        return satisfies(if (version.len == 0) dev_version else version, self.min orelse return true);
    }
};

pub fn validId(id: []const u8) bool {
    if (id.len < 2 or id.len > 64) return false;
    if (!std.ascii.isLower(id[0]) and !std.ascii.isDigit(id[0])) return false;
    for (id) |c| if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '_' and c != '-') return false;
    return true;
}

/// Room for any id's namespace, with the `_` a digit at the front gets.
pub const namespace_max = 65;

/// The namespace a plugin's schemas are in, its id in PascalCase, like `TrailsHorizon` for
/// `trails_horizon`. `Plugin` for one with no letters or digits.
pub fn namespaceOf(buf: *[namespace_max]u8, id: []const u8) []const u8 {
    var n: usize = 0;
    var up = true;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c)) {
            up = true;
            continue;
        }
        if (n == 0 and std.ascii.isDigit(c)) {
            buf[0] = '_';
            n = 1;
        }
        if (n == buf.len) break;
        buf[n] = if (up) std.ascii.toUpper(c) else c;
        n += 1;
        up = false;
    }
    if (n == 0) return "Plugin";
    return buf[0..n];
}

test "a plugin's namespace is its id in PascalCase" {
    var buf: [namespace_max]u8 = undefined;
    try std.testing.expectEqualStrings("TrailsHorizon", namespaceOf(&buf, "trails_horizon"));
    try std.testing.expectEqualStrings("QualityOfLife", namespaceOf(&buf, "quality-of-life"));
    try std.testing.expectEqualStrings("_7thDragon", namespaceOf(&buf, "7th_dragon"));
}

/// Like `camera` or `quality-of-life`: lowercase letters, digits and `-`, up to 24.
pub fn validTag(tag: []const u8) bool {
    if (tag.len == 0 or tag.len > 24 or tag[0] == '-') return false;
    for (tag) |c| if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '-') return false;
    return true;
}

/// A picture's path in the package, like `images/menu.png`. PNG, JPEG or WebP, with `/` between
/// folders and no `..` anywhere, as the hub has it.
pub fn validImage(path: []const u8) bool {
    if (path.len == 0 or path.len > 128 or path[0] == '/' or path[0] == '.') return false;
    if (std.mem.indexOf(u8, path, "..") != null) return false;
    for (path) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "_ ./-", c) == null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, "..")) return false;
    for ([_][]const u8{ ".png", ".jpg", ".jpeg", ".webp" }) |ext| if (std.ascii.endsWithIgnoreCase(path, ext)) return true;
    return false;
}

pub const ParseError = error{ OutOfMemory, BadManifest, BadId };

pub const PackageError = error{ OutOfMemory, BadManifest, BothDescriptions, DescriptionFile };

/// Bytes of a description file. The hub takes up to 20000 characters.
const description_limit = 64 << 10;

/// The file as it goes in a package: without `devDepends`, which only means something in your
/// checkout, and with `descriptionFile`'s text as `description`. `dir` is the manifest's folder.
/// Everything else stays, fields this doesn't know included. Null if it's already that.
pub fn packaged(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, text: []const u8) PackageError!?[]u8 {
    var value = std.json.parseFromSliceLeaky(std.json.Value, arena, std.mem.trimStart(u8, text, "\xEF\xBB\xBF"), .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadManifest,
    };
    if (value != .object) return error.BadManifest;
    var changed = value.object.orderedRemove("devDepends");
    if (value.object.fetchOrderedRemove("descriptionFile")) |entry| {
        if (entry.value != .string) return error.BadManifest;
        if (value.object.contains("description")) return error.BothDescriptions;
        const markdown = dir.readFileAlloc(io, entry.value.string, arena, .limited(description_limit)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.DescriptionFile,
        };
        const trimmed = std.mem.trim(u8, std.mem.trimStart(u8, markdown, "\xEF\xBB\xBF"), " \t\r\n");
        try value.object.put(arena, "description", .{ .string = trimmed });
        changed = true;
    }
    if (!changed) return null;
    var out: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.written();
}

/// Unknown fields are skipped, so newer manifests still load. The hub checks the rest.
pub fn parse(arena: std.mem.Allocator, text: []const u8, problem: ?*[]const u8) ParseError!Manifest {
    var diagnostics: std.json.Diagnostics = .{};
    var scanner: std.json.Scanner = .initCompleteInput(arena, std.mem.trimStart(u8, text, "\xEF\xBB\xBF"));
    scanner.enableDiagnostics(&diagnostics);
    const m = std.json.parseFromTokenSourceLeaky(Manifest, arena, &scanner, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (problem) |p| p.* = std.fmt.allocPrint(arena, "line {d}, column {d}: {t}", .{ diagnostics.getLine(), diagnostics.getColumn(), err }) catch "";
        return error.BadManifest;
    };
    if (!validId(m.id)) {
        if (problem) |p| p.* = std.fmt.allocPrint(arena, "its id \"{s}\" should be 2 to 64 lowercase letters, digits, _ or -", .{m.id}) catch "";
        return error.BadId;
    }
    if (m.game) |g| if (g.ids.len == 0 and g.exes.len == 0) {
        if (problem) |p| p.* = "its game needs ids or exes. Leave game out for any game";
        return error.BadManifest;
    };
    return m;
}

/// Like semver: numbers first, then a prerelease comes before its release. Junk parts count as 0.
pub fn compareVersions(a: []const u8, b: []const u8) std.math.Order {
    const ra = std.mem.indexOfScalar(u8, a, '-');
    const rb = std.mem.indexOfScalar(u8, b, '-');
    var ia = std.mem.splitScalar(u8, a[0 .. ra orelse a.len], '.');
    var ib = std.mem.splitScalar(u8, b[0 .. rb orelse b.len], '.');
    while (true) {
        const pa = ia.next();
        const pb = ib.next();
        if (pa == null and pb == null) break;
        const na = std.fmt.parseInt(u64, pa orelse "0", 10) catch 0;
        const nb = std.fmt.parseInt(u64, pb orelse "0", 10) catch 0;
        const order = std.math.order(na, nb);
        if (order != .eq) return order;
    }
    const pre_a = if (ra) |i| a[i + 1 ..] else return if (rb == null) .eq else .gt;
    const pre_b = if (rb) |i| b[i + 1 ..] else return .lt;
    var xa = std.mem.splitScalar(u8, pre_a, '.');
    var xb = std.mem.splitScalar(u8, pre_b, '.');
    while (true) {
        const pa = xa.next() orelse return if (xb.next() == null) .eq else .lt;
        const pb = xb.next() orelse return .gt;
        const na = std.fmt.parseInt(u64, pa, 10) catch null;
        const nb = std.fmt.parseInt(u64, pb, 10) catch null;
        const order: std.math.Order = if (na != null and nb != null)
            std.math.order(na.?, nb.?)
        else if (na != null)
            .lt
        else if (nb != null)
            .gt
        else
            std.mem.order(u8, pa, pb);
        if (order != .eq) return order;
    }
}

test "written as the file, read back the same" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const made: Manifest = .{
        .id = "kai",
        .kind = .project,
        .version = "0.1.0",
        .apiVersion = api_version,
        .title = "Kai",
        .author = "",
        .game = .{ .ids = &.{"steam-1"}, .exes = &.{"kai.exe"} },
        .autoLoad = false,
    };
    const text = try made.toJson(a);
    try std.testing.expect(std.mem.startsWith(u8, text, "{\n  \"$schema\": \"" ++ schema_url ++ "\",\n  \"id\": \"kai\",\n  \"kind\": \"project\""));
    // Nothing empty or left as it is anyway
    for ([_][]const u8{ "author", "builds", "library", "tags" }) |left_out| try std.testing.expect(std.mem.indexOf(u8, text, left_out) == null);
    const back = try parse(a, text, null);
    try std.testing.expectEqual(.project, back.kind);
    try std.testing.expectEqual(api_version, back.apiVersion.?);
    try std.testing.expect(!back.autoLoad);
    try std.testing.expect(back.isFor(.{ .exe = "kai.exe" }));
}

test "manifest parsing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const m = try parse(arena.allocator(),
        \\{
        \\    "id": "kai", "kind": "plugin", "title": "Kai", "version": "1.0.0", "wraith": "0.2.0", "arches": ["x64"],
        \\    "game": { "ids": ["steam-3316940", "gog-1"], "exes": ["Kai.exe", "kai_dx12.exe"], "builds": ["steam:5"] },
        \\    "autoLoad": false, "library": true, "from_the_future": 1
        \\}
    , null);
    try std.testing.expectEqualStrings("Kai", m.title.?);
    try std.testing.expect(!m.autoLoad);
    try std.testing.expect(m.library);
    try std.testing.expect(m.isFor(.{ .id = "steam-3316940" }));
    try std.testing.expect(m.isFor(.{ .id = "gog-1" }));
    try std.testing.expect(m.isFor(.{ .exe = "D:\\Games\\kai.EXE" }));
    try std.testing.expect(m.isFor(.{ .exe = "kai_dx12.exe" }));
    try std.testing.expect(!m.isFor(.{ .id = "steam-2", .exe = "other.exe" }));
    try std.testing.expect(m.builtFor(.x64));
    try std.testing.expect(!m.builtFor(.x86));
    try std.testing.expect(m.runsOn("0.10.0"));
    try std.testing.expect(!m.runsOn("0.1.9"));

    const any: Manifest = .{};
    try std.testing.expect(any.isFor(.{}));
    try std.testing.expect(any.builtFor(.x86));
    try std.testing.expect(any.runsOn("0.0.0"));
    try std.testing.expect(m.runsOn(dev_version));
}

test "only packages made for this API load" {
    try std.testing.expectEqual(.outdated, ApiFit.of(null));
    try std.testing.expectEqual(.outdated, ApiFit.of(min_api_version - 1));
    try std.testing.expectEqual(.yes, ApiFit.of(min_api_version));
    try std.testing.expectEqual(.yes, ApiFit.of(api_version));
    try std.testing.expectEqual(.newer, ApiFit.of(api_version + 1));
}

/// The hub's schema, kept in step by the hub's `npm run sync-schema`.
const schema_json = @embedFile("wraith.schema.json");

fn expectFieldsMatch(comptime T: type, properties: std.json.ObjectMap, comptime skip: []const []const u8) !void {
    const fields = @typeInfo(T).@"struct".field_names;
    inline for (fields) |name| {
        if (properties.get(name) == null) {
            std.debug.print("{s}.{s} isn't in wraith.schema.json\n", .{ @typeName(T), name });
            return error.NotInSchema;
        }
    }
    var it = properties.iterator();
    outer: while (it.next()) |entry| {
        inline for (fields) |name| if (std.mem.eql(u8, name, entry.key_ptr.*)) continue :outer;
        for (skip) |s| if (std.mem.eql(u8, s, entry.key_ptr.*)) continue :outer;
        std.debug.print("wraith.schema.json's {s} isn't in {s}\n", .{ entry.key_ptr.*, @typeName(T) });
        return error.NotInStruct;
    }
}

test "the manifest has every field the hub's schema has, and no others" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, schema_json, .{});
    defer parsed.deinit();
    const properties = parsed.value.object.get("properties").?.object;
    try expectFieldsMatch(Manifest, properties, &.{"$schema"});
    try expectFieldsMatch(Game, properties.get("game").?.object.get("properties").?.object, &.{});
    try expectFieldsMatch(GameEngine, properties.get("gameEngine").?.object.get("properties").?.object, &.{});
}

test "bad manifests say why" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var problem: []const u8 = "";
    try std.testing.expectError(error.BadManifest, parse(arena.allocator(), "{ \"id\": \"kai\", \"game\": 3 }", &problem));
    try std.testing.expect(problem.len > 0);
    problem = "";
    try std.testing.expectError(error.BadManifest, parse(arena.allocator(), "{ \"id\": \"kai\", \"game\": { \"builds\": [\"steam:1\"] } }", &problem));
    try std.testing.expect(problem.len > 0);
    try std.testing.expectError(error.BadId, parse(arena.allocator(), "{ \"id\": \"Kai Bones\" }", &problem));
    try std.testing.expectError(error.BadId, parse(arena.allocator(), "{}", null));
}

test "tags and pictures" {
    try std.testing.expect(validTag("camera"));
    try std.testing.expect(validTag("quality-of-life"));
    try std.testing.expect(!validTag("Camera"));
    try std.testing.expect(!validTag("-ui"));
    try std.testing.expect(!validTag("a much too long tag for the hub"));
    try std.testing.expect(validImage("icon.png"));
    try std.testing.expect(validImage("images/Main Menu.JPG"));
    try std.testing.expect(!validImage("icon.gif"));
    try std.testing.expect(!validImage("../icon.png"));
    try std.testing.expect(!validImage("images/../../icon.png"));
    try std.testing.expect(!validImage("/icon.png"));
    try std.testing.expect(!validImage("images\\icon.png"));
    try std.testing.expect(!validImage(".hidden.png"));
}

test "for every game of a game engine" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const m = try parse(arena.allocator(),
        \\{ "id": "unity_tools", "kind": "plugin", "gameEngine": { "id": "unity", "variants": ["IL2CPP"] } }
    , null);
    try std.testing.expect(m.isFor(.{ .game_engine = "unity", .game_engine_variant = "il2cpp" }));
    try std.testing.expect(!m.isFor(.{ .game_engine = "unity", .game_engine_variant = "Mono" }));
    try std.testing.expect(!m.isFor(.{ .game_engine = "unreal" }));
    try std.testing.expect(!m.isFor(.{ .id = "steam-1" }));
    // Any variant without a list
    const any: Manifest = .{ .gameEngine = .{ .id = "unity" } };
    try std.testing.expect(any.isFor(.{ .game_engine = "unity" }));
}

test "tested builds go by store" {
    const game: Game = .{ .ids = &.{"steam-1"}, .builds = &.{ "steam:5", "steam:6" } };
    try std.testing.expectEqual(true, game.testedOn(.{ .build = "steam:6" }));
    try std.testing.expectEqual(false, game.testedOn(.{ .build = "steam:7" }));
    try std.testing.expectEqual(null, game.testedOn(.{ .build = "gog:1" }));
    try std.testing.expectEqual(null, (Game{}).testedOn(.{ .build = "steam:5" }));
}

test "tested hashes work for any copy" {
    const game: Game = .{ .exes = &.{"kai.exe"}, .builds = &.{"steam:5"}, .hashes = &.{"AB12"} };
    try std.testing.expectEqual(true, game.testedOn(.{ .sha512 = "ab12" }));
    try std.testing.expectEqual(true, game.testedOn(.{ .build = "gog:1", .sha512 = "ab12" }));
    try std.testing.expectEqual(false, game.testedOn(.{ .build = "gog:1", .sha512 = "cd34" }));
    try std.testing.expectEqual(true, game.testedOn(.{ .build = "steam:5", .sha512 = "cd34" }));
    try std.testing.expectEqual(null, (Game{ .builds = &.{"steam:5"} }).testedOn(.{ .sha512 = "cd34" }));
}

test "dependencies" {
    const any: Dependency = .parse("unity");
    try std.testing.expectEqualStrings("unity", any.name);
    try std.testing.expect(any.fits("0.1.0"));
    const min: Dependency = .parse("unity@1.2");
    try std.testing.expectEqualStrings("unity", min.name);
    try std.testing.expect(min.fits("1.2.0") and min.fits("1.10.0"));
    try std.testing.expect(!min.fits("1.1.9"));
    try std.testing.expect(min.fits(""));
}

test "devDepends is kept, but left out of packages" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\{ "id": "kai", "depends": ["freecam"], "devDepends": { "freecam": "../../libs/freecam" }, "from_the_future": [1] }
    ;
    const m = try parse(a, text, null);
    try std.testing.expectEqualStrings("../../libs/freecam", m.devDepends.map.get("freecam").?);
    try std.testing.expect(std.mem.indexOf(u8, try m.toJson(a), "\"devDepends\": {") != null);

    const here = std.Io.Dir.cwd();
    const packed_text = (try packaged(a, std.testing.io, here, text)).?;
    try std.testing.expect(std.mem.indexOf(u8, packed_text, "devDepends") == null);
    try std.testing.expect(std.mem.indexOf(u8, packed_text, "from_the_future") != null);
    try std.testing.expectEqualStrings("freecam", (try parse(a, packed_text, null)).depends[0]);
    try std.testing.expectEqual(null, try packaged(a, std.testing.io, here, packed_text));
}

test "a description file goes into packages as the description" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "about.md", .data = "\xEF\xBB\xBF# Camera\n\nFlies.\n\n" });

    const text =
        \\{ "id": "camera", "descriptionFile": "about.md" }
    ;
    try std.testing.expectEqualStrings("about.md", (try parse(a, text, null)).descriptionFile.?);
    const m = try parse(a, (try packaged(a, io, tmp.dir, text)).?, null);
    try std.testing.expectEqualStrings("# Camera\n\nFlies.", m.description.?);
    try std.testing.expectEqual(null, m.descriptionFile);

    try std.testing.expectError(error.BothDescriptions, packaged(a, io, tmp.dir,
        \\{ "id": "camera", "description": "Flies", "descriptionFile": "about.md" }
    ));
    try std.testing.expectError(error.DescriptionFile, packaged(a, io, tmp.dir,
        \\{ "id": "camera", "descriptionFile": "gone.md" }
    ));
}

test "version comparing" {
    try std.testing.expectEqual(.gt, compareVersions("1.10.0", "1.9.9"));
    try std.testing.expectEqual(.eq, compareVersions("1.2", "1.2.0"));
    try std.testing.expectEqual(.lt, compareVersions("0.0.1", "0.1.0"));
    try std.testing.expectEqual(.lt, compareVersions("1.0.0-beta.2", "1.0.0"));
    try std.testing.expectEqual(.lt, compareVersions("1.0.0-beta.2", "1.0.0-beta.10"));
    try std.testing.expectEqual(.lt, compareVersions("1.0.0-alpha", "1.0.0-beta"));
    try std.testing.expectEqual(.gt, compareVersions("1.0.1-alpha", "1.0.0"));
}
