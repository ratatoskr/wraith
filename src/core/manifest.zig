//! A package's manifest, `wraith.json` at the top of its folder. The hub has its schema, at
//! https://hub.wraith.io/schema/v1/wraith.json. Plugins, projects and providers all use it.

const std = @import("std");

const Arch = @import("arch.zig").Arch;

pub const file_name = "wraith.json";

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
};

pub const Kind = enum { plugin, project, provider };

pub const Manifest = struct {
    /// Its name, and its folder's. Letters, digits, `_` and `-`.
    id: []const u8 = "",
    kind: Kind = .plugin,
    version: ?[]const u8 = null,
    title: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    description: ?[]const u8 = null,
    author: ?[]const u8 = null,
    license: ?[]const u8 = null,
    homepage: ?[]const u8 = null,
    /// The oldest Wraith it runs on. Null means any.
    wraith: ?[]const u8 = null,
    /// Null means any game.
    game: ?Game = null,
    /// Null means every arch.
    arches: ?[]const Arch = null,
    /// Null means `zig`.
    provider: ?[]const u8 = null,
    autoLoad: bool = true,
    /// Code for other plugins, with nothing of its own to use.
    library: bool = false,
    /// Plugins it needs loaded first, as `name` or `name@minimum-version`.
    depends: []const []const u8 = &.{},

    pub fn isFor(self: Manifest, here: Here) bool {
        const game = self.game orelse return true;
        return game.matches(here);
    }

    pub fn builtFor(self: Manifest, arch: Arch) bool {
        const arches = self.arches orelse return true;
        return std.mem.indexOfScalar(Arch, arches, arch) != null;
    }

    pub fn runsOn(self: Manifest, version: []const u8) bool {
        return satisfies(version, self.wraith orelse return true);
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

pub const ParseError = error{ OutOfMemory, BadManifest, BadId };

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

test "version comparing" {
    try std.testing.expectEqual(.gt, compareVersions("1.10.0", "1.9.9"));
    try std.testing.expectEqual(.eq, compareVersions("1.2", "1.2.0"));
    try std.testing.expectEqual(.lt, compareVersions("0.0.1", "0.1.0"));
    try std.testing.expectEqual(.lt, compareVersions("1.0.0-beta.2", "1.0.0"));
    try std.testing.expectEqual(.lt, compareVersions("1.0.0-beta.2", "1.0.0-beta.10"));
    try std.testing.expectEqual(.lt, compareVersions("1.0.0-alpha", "1.0.0-beta"));
    try std.testing.expectEqual(.gt, compareVersions("1.0.1-alpha", "1.0.0"));
}
