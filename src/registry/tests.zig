const std = @import("std");

const core = @import("wraith_core");

const registry = @import("root.zig");

const testing = std.testing;
const io = testing.io;

const Ed25519 = std.crypto.sign.Ed25519;

/// A hub's dist folder, on disk.
const Hub = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    arena: std.heap.ArenaAllocator,
    pair: Ed25519.KeyPair,
    key: [64]u8,

    fn init() !Hub {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "site/p/hello");
        try tmp.dir.writeFile(io, .{ .sub_path = "site/p/hello/1.0.0.zip", .data = @embedFile("testdata/hello.zip") });
        try tmp.dir.createDirPath(io, "site/p/kai_tables");
        try tmp.dir.writeFile(io, .{ .sub_path = "site/p/kai_tables/1.0.0.zip", .data = @embedFile("testdata/project.zip") });
        const pair = try Ed25519.KeyPair.generateDeterministic(@splat(7));
        return .{
            .tmp = tmp,
            .root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator),
            .arena = .init(testing.allocator),
            .pair = pair,
            .key = std.fmt.bytesToHex(pair.public_key.toBytes(), .lower),
        };
    }

    fn deinit(self: *Hub) void {
        self.arena.deinit();
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn path(self: *Hub, sub: []const u8) []const u8 {
        return std.fs.path.join(self.arena.allocator(), &.{ self.root, sub }) catch unreachable;
    }

    fn source(self: *Hub) registry.Source {
        return .{ .location = self.path("site"), .key = &self.key, .cache_dir = self.path("cache") };
    }

    /// The signed index, with these packages' JSON and pulled hashes.
    fn publish(self: *Hub, packages: []const []const u8, revoked: []const []const u8) !void {
        const a = self.arena.allocator();
        var hashes: std.ArrayList(u8) = .empty;
        for (revoked, 0..) |h, i| try hashes.print(a, "{s}\"{s}\"", .{ if (i == 0) "" else ", ", h });
        const body = try std.fmt.allocPrint(a,
            \\{{ "format": 2, "generated": "now", "packages": [{s}], "revoked": [{s}],
            \\  "games": [{{ "name": "One", "idents": ["steam-1", "gog-1"], "image": "https://x/one.jpg" }}] }}
        , .{ try std.mem.join(a, ", ", packages), hashes.items });
        try self.tmp.dir.createDirPath(io, "site/v2");
        try self.tmp.dir.writeFile(io, .{ .sub_path = "site/" ++ registry.index_path, .data = try registry.sign(a, body, self.pair) });
    }

    /// Plugin `hello` with these versions, newest first, sharing one zip.
    fn hello(self: *Hub, versions: []const []const u8, extra: []const u8, version_extra: []const u8) ![]const u8 {
        const a = self.arena.allocator();
        var list: std.ArrayList(u8) = .empty;
        for (versions, 0..) |v, i| try list.print(a,
            \\{s}{{ "version": "{s}", "apiVersion": 3, "url": "p/hello/1.0.0.zip", "sha256": "{s}", "size": 1, "from_the_future": true{s} }}
        , .{ if (i == 0) "" else ", ", v, &helloSha256(), version_extra });
        return std.fmt.allocPrint(a,
            \\{{ "id": "hello", "kind": "plugin", "author": "me", "title": "Hello", "versions": [{s}]{s} }}
        , .{ list.items, extra });
    }

    fn index(self: *Hub) !registry.Index {
        return registry.fetch(self.arena.allocator(), io, self.source());
    }
};

/// A package with one version, 1.0.0, that isn't to install.
fn entry(a: std.mem.Allocator, id: []const u8, extra: []const u8, version_extra: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a,
        \\{{ "id": "{s}", "kind": "plugin", "title": "{s}", "versions": [{{ "version": "1.0.0", "apiVersion": 3, "url": "", "sha256": "00"{s} }}]{s} }}
    , .{ id, id, version_extra, extra });
}

fn sha256Of(data: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn helloSha256() [64]u8 {
    return sha256Of(@embedFile("testdata/hello.zip"));
}

test "the index, all in one signed file" {
    var hub: Hub = try .init();
    defer hub.deinit();
    const a = hub.arena.allocator();
    try hub.publish(&.{try hub.hello(&.{ "1.1.0", "1.0.0" }, "", "")}, &.{"ABC"});

    const index = try hub.index();
    const hello = index.find("hello").?;
    try testing.expectEqualStrings("me", hello.author);
    try testing.expectEqualStrings("1.1.0", hello.newest().?.version);
    try testing.expectEqualStrings("1.0.0", hello.find("1.0.0").?.version);
    try testing.expectEqual(null, index.find("nope"));
    try testing.expectEqualStrings("One", index.game("gog-1").?.name);
    try testing.expect(index.isRevoked("abc"));
    try testing.expect(!index.isRevoked("abd"));

    try testing.expectError(error.RegistryTooNew, registry.parse(registry.Index, a, "{\"format\": 99}"));
    try testing.expectError(error.BadRegistry, registry.parse(registry.Index, a, "{\"packages\": 1}"));
}

test "what's for the games asked about, their engines, any game or picked, plus what's installed" {
    var hub: Hub = try .init();
    defer hub.deinit();
    const a = hub.arena.allocator();
    try hub.publish(&.{
        try entry(a, "for_one", "", ", \"game\": { \"ids\": [\"steam-1\", \"gog-1\"] }"),
        try entry(a, "for_two", "", ", \"game\": { \"ids\": [\"steam-2\"] }"),
        try entry(a, "picked_for_two", ", \"featuredIn\": [\"steam-2\"]", ", \"game\": { \"ids\": [\"steam-2\"] }"),
        try entry(a, "picked", ", \"featured\": true, \"why\": \"Pretty\"", ", \"game\": { \"ids\": [\"steam-3\"] }"),
        try entry(a, "anywhere", "", ""),
        try entry(a, "any_unity", "", ", \"gameEngine\": { \"id\": \"unity\" }"),
        try entry(a, "il2cpp_only", "", ", \"gameEngine\": { \"id\": \"unity\", \"variants\": [\"IL2CPP\"] }"),
        try entry(a, "camera", ", \"library\": true", ""),
    }, &.{});
    const index = try hub.index();
    const made_with: []const registry.mods.MadeWith = &.{
        .{ .game = "steam-5", .here = .{ .game_engine = "unity", .game_engine_variant = "Mono" } },
        .{ .game = "steam-6", .here = .{ .game_engine = "unity", .game_engine_variant = "IL2CPP" } },
    };
    const listing = try registry.mods.list(a, io, index, hub.path("mods"), "1.0.0", &.{"gog-1"}, made_with);
    try testing.expectEqualStrings("gog-1", listing.find("for_one").?.games[0]);
    try testing.expectEqual(null, listing.find("for_two"));
    try testing.expectEqual(null, listing.find("picked_for_two"));
    try testing.expectEqualStrings("Pretty", listing.find("picked").?.why.?);
    try testing.expect(listing.find("anywhere").?.any_game);
    try testing.expectEqual(2, listing.find("any_unity").?.games.len);
    try testing.expectEqualStrings("unity", listing.find("any_unity").?.game_engine.?.id);
    const il2cpp = listing.find("il2cpp_only").?;
    try testing.expectEqual(1, il2cpp.games.len);
    try testing.expectEqualStrings("steam-6", il2cpp.games[0]);
    // Libraries are marked, so what lists mods for players can leave them out
    try testing.expect(listing.find("camera").?.library);
    try testing.expect(!listing.find("anywhere").?.library);

    // A pick for a game counts by any of its ids
    const two = try registry.mods.list(a, io, index, hub.path("mods"), "1.0.0", &.{"steam-2"}, &.{});
    try testing.expect(two.find("picked_for_two").?.featured);
    try testing.expect(!two.find("for_two").?.featured);
}

test "newest runnable version" {
    const pkg: registry.Package = .{
        .id = "p",
        .versions = &.{
            .{ .version = "1.0.0", .apiVersion = 3, .url = "", .sha256 = "" },
            .{ .version = "1.2.0", .apiVersion = 3, .wraith = "0.2.0", .url = "", .sha256 = "" },
            .{ .version = "1.1.0", .apiVersion = 3, .arches = &.{.x86}, .url = "", .sha256 = "" },
            .{ .version = "1.3.0", .apiVersion = 3, .yanked = true, .url = "", .sha256 = "" },
            // Made before there were API versions, and for a newer Wraith's
            .{ .version = "1.4.0", .url = "", .sha256 = "" },
            .{ .version = "1.5.0", .apiVersion = core.manifest.api_version + 1, .url = "", .sha256 = "" },
        },
    };
    try testing.expectEqualStrings("1.2.0", registry.latest(pkg, "0.2.0", null).?.version);
    // Wraith is too old for 1.2.0, 1.1.0 is x86 only, and 1.3.0 was yanked
    try testing.expectEqualStrings("1.0.0", registry.latest(pkg, "0.1.0", .x64).?.version);
    try testing.expectEqualStrings("1.1.0", registry.latest(pkg, "0.1.0", .x86).?.version);
    try testing.expectEqual(null, registry.latest(.{ .id = "none" }, "9.0.0", null));
}

test "mods not made for this Wraith's API say so" {
    var hub: Hub = try .init();
    defer hub.deinit();
    const a = hub.arena.allocator();
    try hub.publish(&.{
        \\{ "id": "old", "kind": "plugin", "title": "Old", "versions": [{ "version": "1.0.0", "url": "", "sha256": "00" }] }
        ,
        \\{ "id": "new", "kind": "plugin", "title": "New", "versions": [{ "version": "1.0.0", "apiVersion": 999, "url": "", "sha256": "00" }] }
        ,
        try entry(a, "ok", "", ""),
    }, &.{});
    const listing = try registry.mods.list(a, io, try hub.index(), hub.path("mods"), "1.0.0", &.{}, &.{});
    const old = listing.find("old").?;
    try testing.expect(old.outdated);
    try testing.expectEqual(null, old.latest);
    const new = listing.find("new").?;
    try testing.expect(!new.outdated);
    try testing.expectEqual(null, new.latest);
    try testing.expectEqualStrings("", new.needs_wraith.?);
    try testing.expectEqualStrings("1.0.0", listing.find("ok").?.latest.?);
}

test "tested builds" {
    const v: registry.Version = .{ .version = "1.0.0", .url = "", .sha256 = "", .game = .{
        .ids = &.{ "steam-1", "gog-1" },
        .builds = &.{"steam:5"},
    } };
    try testing.expectEqual(true, registry.testedOn(v, "steam-1", .{ .build = "steam:5" }));
    try testing.expectEqual(false, registry.testedOn(v, "steam-1", .{ .build = "steam:6" }));
    try testing.expectEqual(null, registry.testedOn(v, "gog-1", .{ .build = "gog:1" }));
    try testing.expectEqual(null, registry.testedOn(v, "steam-2", .{ .build = "steam:5" }));
}

test "signature checked, in the same file as what it signs" {
    var hub: Hub = try .init();
    defer hub.deinit();
    const a = hub.arena.allocator();
    const signed = try registry.sign(a, "{\"format\": 2}", hub.pair);
    _ = try registry.read(a, signed, &hub.key);
    const tampered = try a.dupe(u8, signed);
    tampered[tampered.len - 2] = '3';
    try testing.expectError(error.BadSignature, registry.read(a, tampered, &hub.key));
    try testing.expectError(error.BadSignature, registry.read(a, signed, registry.public_key));
    try testing.expectError(error.BadSignature, registry.read(a, "{\"format\": 2}", &hub.key));
    try testing.expectError(error.BadSignature, registry.verify("{}", "nothex", &hub.key));
}

test "cache fallback, and the revoked list offline" {
    const saved = core.log.mute(&.{.other});
    defer core.log.setFilter(saved);
    var hub: Hub = try .init();
    defer hub.deinit();
    try hub.publish(&.{try hub.hello(&.{"1.0.0"}, "", "")}, &.{"abc"});
    try testing.expectEqualStrings("Hello", (try hub.index()).find("hello").?.title);

    // Tampered, so it's refused and the copy from last time is used
    try hub.tmp.dir.writeFile(io, .{ .sub_path = "site/" ++ registry.index_path, .data = "00\n{\"format\": 2}" });
    try testing.expectEqualStrings("Hello", (try hub.index()).find("hello").?.title);
    try testing.expect(registry.isRevoked(try registry.cachedRevoked(hub.arena.allocator(), io, hub.source()), "abc"));

    // No cache either, so it errors
    var no_cache = hub.source();
    no_cache.cache_dir = null;
    try testing.expectError(error.BadSignature, registry.fetch(hub.arena.allocator(), io, no_cache));
}

test "install and remove" {
    const saved = core.log.mute(&.{.other});
    defer core.log.setFilter(saved);
    var hub: Hub = try .init();
    defer hub.deinit();
    const a = hub.arena.allocator();
    try hub.publish(&.{try hub.hello(&.{ "1.1.0", "1.0.0" }, "", "")}, &.{});
    const hello = (try hub.index()).find("hello").?.*;
    const plugins = hub.path("plugins");

    try registry.install(a, io, hub.source(), plugins, hello, hello.find("1.0.0").?);
    // The zip's single folder becomes the plugin folder
    try hub.tmp.dir.access(io, "plugins/hello/wraith.json", .{});
    try hub.tmp.dir.access(io, "plugins/hello/lib/util.js", .{});
    try testing.expectEqualStrings("1.0.0", (try registry.installed(a, io, plugins, "hello")).?.version);

    try registry.install(a, io, hub.source(), plugins, hello, registry.latest(hello, "1.0.0", null).?);
    const all = try registry.installedAll(a, io, plugins);
    try testing.expectEqual(1, all.len);
    try testing.expectEqualStrings("hello", all[0].id);
    try testing.expectEqualStrings("1.1.0", all[0].version);
    try testing.expectEqualStrings(&helloSha256(), all[0].sha256);
    // No leftovers next to it
    var dir = try hub.tmp.dir.openDir(io, "plugins", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |_| n += 1;
    try testing.expectEqual(1, n);

    try registry.remove(a, io, plugins, "hello");
    try testing.expectEqual(null, try registry.installed(a, io, plugins, "hello"));
}

test "installed ones the hub doesn't have any more are still listed" {
    const saved = core.log.mute(&.{.other});
    defer core.log.setFilter(saved);
    var hub: Hub = try .init();
    defer hub.deinit();
    const a = hub.arena.allocator();
    try hub.publish(&.{try hub.hello(&.{"1.0.0"}, "", "")}, &.{});
    const where: registry.mods.Where = .{ .source = hub.source(), .mods_dir = hub.path("mods"), .wraith = "1.0.0" };
    _ = try registry.mods.install(a, io, try hub.index(), where, "hello", null);

    try hub.publish(&.{}, &.{});
    const listing = try registry.mods.list(a, io, try hub.index(), where.mods_dir, where.wraith, &.{}, &.{});
    const listed = listing.find("hello").?;
    try testing.expectEqualStrings("1.0.0", listed.installed.?);
    try testing.expectEqual(null, listed.latest);
    try testing.expect(!listed.hasUpdate());
}

test "updates, and takes out pulled ones" {
    const saved = core.log.mute(&.{.other});
    defer core.log.setFilter(saved);
    var hub: Hub = try .init();
    defer hub.deinit();
    const a = hub.arena.allocator();
    try hub.publish(&.{try hub.hello(&.{"1.0.0"}, "", "")}, &.{});
    const where: registry.mods.Where = .{ .source = hub.source(), .mods_dir = hub.path("mods"), .wraith = "1.0.0" };
    _ = try registry.mods.install(a, io, try hub.index(), where, "hello", null);
    try testing.expectEqual(0, (try registry.mods.update(a, io, try hub.index(), where, null)).len);

    try hub.publish(&.{try hub.hello(&.{ "1.1.0", "1.0.0" }, "", "")}, &.{});
    const listing = try registry.mods.list(a, io, try hub.index(), where.mods_dir, where.wraith, &.{}, &.{});
    try testing.expect(listing.find("hello").?.hasUpdate());
    // What the app gets says so too
    const json = try std.json.Stringify.valueAlloc(a, listing.find("hello").?.*, .{});
    try testing.expect(std.mem.indexOf(u8, json, "\"has_update\":true") != null);
    const updated = try registry.mods.update(a, io, try hub.index(), where, null);
    try testing.expectEqualStrings("1.1.0", updated[0].version.?);

    try hub.publish(&.{try hub.hello(&.{ "1.1.0", "1.0.0" }, "", "")}, &.{&helloSha256()});
    const pulled = try registry.mods.update(a, io, try hub.index(), where, null);
    try testing.expectEqual(null, pulled[0].version);
    try testing.expectEqual(null, try registry.installed(a, io, where.mods_dir, "hello"));
}

test "only the package it says, and only plugins" {
    const saved = core.log.mute(&.{.other});
    defer core.log.setFilter(saved);
    var hub: Hub = try .init();
    defer hub.deinit();
    const a = hub.arena.allocator();
    const plugins = hub.path("plugins");
    const zip_sha = helloSha256();
    const version: registry.Version = .{ .version = "1.0.0", .url = "p/hello/1.0.0.zip", .sha256 = &zip_sha };

    // Its manifest says hello
    const other: registry.Package = .{ .id = "other" };
    try testing.expectError(error.WrongPackage, registry.install(a, io, hub.source(), plugins, other, version));
    try testing.expectEqual(0, (try registry.installedAll(a, io, plugins)).len);
}

test "projects install next to plugins" {
    var hub: Hub = try .init();
    defer hub.deinit();
    const a = hub.arena.allocator();
    const mods = hub.path("mods");
    const project_sha = sha256Of(@embedFile("testdata/project.zip"));
    const tables: registry.Package = .{ .id = "kai_tables", .kind = .project };
    try registry.install(a, io, hub.source(), mods, tables, .{ .version = "1.0.0", .url = "p/kai_tables/1.0.0.zip", .sha256 = &project_sha });
    const all = try registry.installedAll(a, io, mods);
    try testing.expectEqual(1, all.len);
}

test "bad zip not installed" {
    const saved = core.log.mute(&.{.other});
    defer core.log.setFilter(saved);
    var hub: Hub = try .init();
    defer hub.deinit();
    const a = hub.arena.allocator();
    try hub.publish(&.{try hub.hello(&.{"1.0.0"}, "", "")}, &.{});
    const hello = (try hub.index()).find("hello").?.*;
    const plugins = hub.path("plugins");
    try registry.install(a, io, hub.source(), plugins, hello, hello.versions[0]);

    var wrong = hello.versions[0];
    wrong.version = "2.0.0";
    wrong.sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
    try testing.expectError(error.HashMismatch, registry.install(a, io, hub.source(), plugins, hello, wrong));
    try testing.expectEqualStrings("1.0.0", (try registry.installed(a, io, plugins, "hello")).?.version);
}

test "remove skips non-registry" {
    var hub: Hub = try .init();
    defer hub.deinit();
    try hub.tmp.dir.createDirPath(io, "plugins/mine");
    try testing.expectError(error.NotFromRegistry, registry.remove(hub.arena.allocator(), io, hub.path("plugins"), "mine"));
    try hub.tmp.dir.access(io, "plugins/mine", .{});
}

test "locked plugin" {
    const saved = core.log.mute(&.{.other});
    defer core.log.setFilter(saved);
    var hub: Hub = try .init();
    defer hub.deinit();
    const a = hub.arena.allocator();
    try hub.publish(&.{try hub.hello(&.{"1.0.0"}, "", "")}, &.{});
    const hello = (try hub.index()).find("hello").?.*;
    const plugins = hub.path("plugins");
    try registry.install(a, io, hub.source(), plugins, hello, hello.versions[0]);

    // Pretend someone else is installing and holds the lock
    const theirs = try hub.tmp.dir.createFile(io, "plugins/.hello.lock", .{ .lock = .exclusive, .lock_nonblocking = true });
    try testing.expectError(error.Busy, registry.install(a, io, hub.source(), plugins, hello, hello.versions[0]));
    try testing.expectError(error.Busy, registry.remove(a, io, plugins, "hello"));
    theirs.close(io);

    try registry.remove(a, io, plugins, "hello");
}

test "a game's essential mods, by its id or exe, but not in other games or for any game" {
    var hub: Hub = try .init();
    defer hub.deinit();
    const a = hub.arena.allocator();
    const where: registry.mods.Where = .{ .source = hub.source(), .mods_dir = hub.path("mods"), .wraith = "1.0.0" };
    const ffxiv = ", \"game\": { \"ids\": [\"steam-39210\"], \"exes\": [\"ffxiv_dx11.exe\"] }";
    try hub.publish(&.{try hub.hello(&.{"1.0.0"}, ", \"essential\": true", ffxiv)}, &.{});

    const by_id = try registry.mods.essentials(a, io, try hub.index(), where, &.{.{ .game = "steam-39210", .here = .{} }}, null);
    try testing.expectEqual(1, by_id.len);
    try testing.expectEqual(null, by_id[0].game_engine);
    const by_exe: []const registry.mods.MadeWith = &.{.{ .here = .{ .exe = "Games/FFXIV/ffxiv_dx11.exe" } }};
    try testing.expectEqual(1, (try registry.mods.essentials(a, io, try hub.index(), where, by_exe, null)).len);
    try testing.expectEqual(0, (try registry.mods.essentials(a, io, try hub.index(), where, &.{.{ .game = "steam-1", .here = .{ .game_engine = "unity" } }}, null)).len);

    // One for any game would be in every game
    try hub.publish(&.{try hub.hello(&.{"1.0.0"}, ", \"essential\": true", "")}, &.{});
    try testing.expectEqual(0, (try registry.mods.essentials(a, io, try hub.index(), where, &.{.{ .game = "steam-39210", .here = .{ .game_engine = "unity" } }}, null)).len);
}

test "an engine's essential plugin isn't fetched for a game whose own essential plugin stands in for it" {
    var hub: Hub = try .init();
    defer hub.deinit();
    const a = hub.arena.allocator();
    const where: registry.mods.Where = .{ .source = hub.source(), .mods_dir = hub.path("mods"), .wraith = "1.0.0" };
    const unity = try entry(a, "unity", ", \"essential\": true", ", \"gameEngine\": { \"id\": \"unity\" }");
    const kai = try entry(a, "kai", ", \"essential\": true", ", \"game\": { \"ids\": [\"steam-1\"] }, \"supersedes\": [\"unity\"]");
    try hub.publish(&.{ unity, kai }, &.{});
    const kai_game: []const registry.mods.MadeWith = &.{.{ .game = "steam-1", .here = .{ .game_engine = "unity" } }};
    const found = try registry.mods.essentials(a, io, try hub.index(), where, kai_game, null);
    try testing.expectEqual(1, found.len);
    try testing.expectEqualStrings("kai", found[0].id);
    // Other Unity games still get it
    const other: []const registry.mods.MadeWith = &.{.{ .game = "steam-2", .here = .{ .game_engine = "unity" } }};
    try testing.expectEqualStrings("unity", (try registry.mods.essentials(a, io, try hub.index(), where, other, null))[0].id);
}

test "an engine's essential mods, missing or out of date, but never a pulled one or one put there by hand" {
    const saved = core.log.mute(&.{.other});
    defer core.log.setFilter(saved);
    var hub: Hub = try .init();
    defer hub.deinit();
    const a = hub.arena.allocator();
    const essential = ", \"essential\": true";
    const unity_only = ", \"gameEngine\": { \"id\": \"unity\" }";
    try hub.publish(&.{try hub.hello(&.{"1.0.0"}, essential, unity_only)}, &.{});
    const where: registry.mods.Where = .{ .source = hub.source(), .mods_dir = hub.path("mods"), .wraith = "1.0.0" };
    const unity: []const registry.mods.MadeWith = &.{.{ .here = .{ .game_engine = "unity" } }};

    try testing.expectEqual(0, (try registry.mods.essentials(a, io, try hub.index(), where, &.{.{ .here = .{ .game_engine = "unreal" } }}, null)).len);
    const missing = try registry.mods.essentials(a, io, try hub.index(), where, unity, null);
    try testing.expectEqual(1, missing.len);
    try testing.expectEqual(null, missing[0].installed);
    try testing.expectEqualStrings("1.0.0", missing[0].latest);
    try testing.expect((try registry.mods.list(a, io, try hub.index(), where.mods_dir, where.wraith, &.{}, unity)).find("hello").?.essential);

    _ = try registry.mods.install(a, io, try hub.index(), where, "hello", missing[0].latest);
    try testing.expectEqual(0, (try registry.mods.essentials(a, io, try hub.index(), where, unity, null)).len);

    try hub.publish(&.{try hub.hello(&.{ "1.1.0", "1.0.0" }, essential, unity_only)}, &.{});
    const old = try registry.mods.essentials(a, io, try hub.index(), where, unity, null);
    try testing.expectEqualStrings("1.0.0", old[0].installed.?);
    try testing.expectEqualStrings("1.1.0", old[0].latest);

    // Both versions are the one zip, so pulling it pulls the newest
    try hub.publish(&.{try hub.hello(&.{ "1.1.0", "1.0.0" }, essential, unity_only)}, &.{&helloSha256()});
    try testing.expectEqual(0, (try registry.mods.essentials(a, io, try hub.index(), where, unity, null)).len);

    try hub.publish(&.{try hub.hello(&.{"1.0.0"}, essential, unity_only)}, &.{});
    try registry.remove(a, io, where.mods_dir, "hello");
    try hub.tmp.dir.createDirPath(io, "mods/hello");
    try testing.expectEqual(0, (try registry.mods.essentials(a, io, try hub.index(), where, unity, null)).len);
}
