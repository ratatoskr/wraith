const std = @import("std");

const core = @import("wraith_core");

const registry = @import("root.zig");

const testing = std.testing;
const io = testing.io;

const Ed25519 = std.crypto.sign.Ed25519;

const TestKey = struct {
    pair: Ed25519.KeyPair,
    hex: [64]u8,

    fn init() !TestKey {
        const pair = try Ed25519.KeyPair.generateDeterministic(@splat(7));
        return .{ .pair = pair, .hex = std.fmt.bytesToHex(pair.public_key.toBytes(), .lower) };
    }

    fn sign(self: TestKey, text: []const u8) ![128]u8 {
        const sig = try self.pair.sign(text, null);
        return std.fmt.bytesToHex(sig.toBytes(), .lower);
    }
};

/// A hub's dist folder, on disk.
const Hub = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    arena: std.heap.ArenaAllocator,
    key: TestKey,

    fn init() !Hub {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "site/p/hello");
        try tmp.dir.writeFile(io, .{ .sub_path = "site/p/hello/1.0.0.zip", .data = @embedFile("testdata/hello.zip") });
        try tmp.dir.createDirPath(io, "site/p/kai_tables");
        try tmp.dir.writeFile(io, .{ .sub_path = "site/p/kai_tables/1.0.0.zip", .data = @embedFile("testdata/project.zip") });
        return .{ .tmp = tmp, .root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator), .arena = .init(testing.allocator), .key = try .init() };
    }

    fn deinit(self: *Hub) void {
        self.arena.deinit();
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn path(self: *Hub, sub: []const u8) []const u8 {
        return std.fs.path.join(self.arena.allocator(), &.{ self.root, sub }) catch unreachable;
    }

    /// Signed, at `site/<file>`.
    fn publish(self: *Hub, file: []const u8, text: []const u8) !void {
        const a = self.arena.allocator();
        const full = try std.fmt.allocPrint(a, "site/{s}", .{file});
        if (std.fs.path.dirname(full)) |dir| try self.tmp.dir.createDirPath(io, dir);
        try self.tmp.dir.writeFile(io, .{ .sub_path = full, .data = text });
        try self.tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}.sig", .{full}), .data = &try self.key.sign(text) });
    }

    fn source(self: *Hub) registry.Source {
        return .{ .location = self.path("site"), .key = &self.key.hex, .cache_dir = self.path("cache") };
    }

    /// `hello`, a plugin, with these versions all pointing at the one zip.
    fn publishHello(self: *Hub, versions: []const []const u8, sha256: []const u8) !void {
        const a = self.arena.allocator();
        var list: std.ArrayList(u8) = .empty;
        for (versions, 0..) |v, i| try list.print(a,
            \\{s}{{ "version": "{s}", "url": "p/hello/1.0.0.zip", "sha256": "{s}", "size": 1, "from_the_future": true }}
        , .{ if (i == 0) "" else ", ", v, sha256 });
        try self.publish("v1/packages/hello.json", try std.fmt.allocPrint(a,
            \\{{ "format": 1, "generated": "now", "id": "hello", "kind": "plugin", "author": "me", "title": "Hello", "versions": [{s}] }}
        , .{list.items}));
    }
};

fn sha256Of(data: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn helloSha256() [64]u8 {
    return sha256Of(@embedFile("testdata/hello.zip"));
}

test "lists and packages" {
    var hub: Hub = try .init();
    defer hub.deinit();
    const a = hub.arena.allocator();
    try hub.publish("v1/games/steam-1.json",
        \\{ "format": 1, "generated": "now", "game": { "name": "One", "idents": ["steam-1", "gog-1"], "links": [{ "label": "Wiki", "url": "https://w" }] },
        \\  "packages": [{ "id": "hello", "kind": "plugin", "title": "Hello", "version": "1.0.0", "games": ["steam-1"], "builds": ["steam:5"], "featured": true }] }
    );
    try hub.publish("v1/games.json",
        \\{ "format": 1, "games": [{ "name": "One", "idents": ["steam-1", "gog-1"], "packages": 1 }] }
    );
    try hub.publishHello(&.{ "1.0.0", "1.1.0" }, &helloSha256());

    const one = (try registry.forGame(a, io, hub.source(), "steam-1")).?;
    try testing.expectEqualStrings("One", one.game.?.name);
    try testing.expectEqualStrings("Wiki", one.game.?.links[0].label);
    try testing.expect(one.packages[0].featured);
    try testing.expectEqualStrings("steam:5", one.packages[0].builds[0]);
    // Nothing for it on the hub
    try testing.expectEqual(null, try registry.forGame(a, io, hub.source(), "steam-2"));
    try testing.expectError(error.BadName, registry.forGame(a, io, hub.source(), "../steam-1"));
    // Ones the hub hasn't written yet are just empty
    try testing.expectEqual(0, (try registry.anyGame(a, io, hub.source())).packages.len);

    const catalog = try registry.catalog(a, io, hub.source());
    try testing.expectEqualStrings("One", catalog.find("gog-1").?.name);
    try testing.expectEqual(null, catalog.find("gog-2"));

    const hello = (try registry.package(a, io, hub.source(), "hello")).?;
    try testing.expectEqualStrings("me", hello.author);
    try testing.expectEqual(2, hello.versions.len);
    try testing.expectEqualStrings("1.1.0", hello.find("1.1.0").?.version);

    try testing.expectError(error.RegistryTooNew, registry.parse(registry.List, a, "{\"format\": 99}"));
    try testing.expectError(error.BadRegistry, registry.parse(registry.Package, a, "{\"format\": 1}"));
}

test "newest runnable version" {
    const pkg: registry.Package = .{ .format = 1, .id = "p", .versions = &.{
        .{ .version = "1.0.0", .url = "", .sha256 = "" },
        .{ .version = "1.2.0", .wraith = "0.2.0", .url = "", .sha256 = "" },
        .{ .version = "1.1.0", .arches = &.{.x86}, .url = "", .sha256 = "" },
        .{ .version = "1.3.0", .yanked = true, .url = "", .sha256 = "" },
    } };
    try testing.expectEqualStrings("1.2.0", registry.latest(pkg, "0.2.0", null).?.version);
    // Wraith is too old for 1.2.0, 1.1.0 is x86 only, and 1.3.0 was yanked
    try testing.expectEqualStrings("1.0.0", registry.latest(pkg, "0.1.0", .x64).?.version);
    try testing.expectEqualStrings("1.1.0", registry.latest(pkg, "0.1.0", .x86).?.version);
    try testing.expectEqual(null, registry.latest(.{ .format = 1, .id = "none" }, "9.0.0", null));
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

test "signature checked" {
    const key: TestKey = try .init();
    const text = "{\"format\": 1}";
    const sig = try key.sign(text);
    try registry.verify(text, &sig, &key.hex);
    try testing.expectError(error.BadSignature, registry.verify("{\"format\": 2}", &sig, &key.hex));
    try testing.expectError(error.BadSignature, registry.verify(text, &sig, registry.public_key));
    try testing.expectError(error.BadSignature, registry.verify(text, "nothex", &key.hex));
}

test "cache fallback" {
    const saved = core.log.mute(&.{.other});
    defer core.log.setFilter(saved);
    var hub: Hub = try .init();
    defer hub.deinit();
    const a = hub.arena.allocator();
    try hub.publishHello(&.{"1.0.0"}, &helloSha256());

    const first = (try registry.package(a, io, hub.source(), "hello")).?;
    try testing.expectEqualStrings("Hello", first.title);

    // Tampered, so it's refused and we use the cached copy
    try hub.tmp.dir.writeFile(io, .{ .sub_path = "site/v1/packages/hello.json", .data = "{\"format\": 1, \"id\": \"hello\", \"title\": \"Evil\"}" });
    const second = (try registry.package(a, io, hub.source(), "hello")).?;
    try testing.expectEqualStrings("Hello", second.title);

    // No cache either, so it errors
    var no_cache = hub.source();
    no_cache.cache_dir = null;
    try testing.expectError(error.BadSignature, registry.package(a, io, no_cache, "hello"));
}

test "revoked, and from the cache" {
    var hub: Hub = try .init();
    defer hub.deinit();
    const a = hub.arena.allocator();
    try testing.expectEqual(0, (try registry.revoked(a, io, hub.source())).len);
    try hub.publish("v1/revoked.json", "{ \"format\": 1, \"sha256\": [\"ABC\"] }");
    const list = try registry.revoked(a, io, hub.source());
    try testing.expect(registry.isRevoked(list, "abc"));
    try testing.expect(!registry.isRevoked(list, "abd"));
    // Offline, from what was fetched
    var offline = hub.source();
    offline.location = hub.path("nowhere");
    try testing.expect(registry.isRevoked(try registry.cachedRevoked(a, io, offline), "abc"));
}

test "install and remove" {
    const saved = core.log.mute(&.{.other});
    defer core.log.setFilter(saved);
    var hub: Hub = try .init();
    defer hub.deinit();
    const a = hub.arena.allocator();
    try hub.publishHello(&.{ "1.0.0", "1.1.0" }, &helloSha256());
    const hello = (try registry.package(a, io, hub.source(), "hello")).?;
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
    const other: registry.Package = .{ .format = 1, .id = "other" };
    try testing.expectError(error.WrongPackage, registry.install(a, io, hub.source(), plugins, other, version));
    try testing.expectEqual(0, (try registry.installedAll(a, io, plugins)).len);
}

test "projects install next to plugins" {
    var hub: Hub = try .init();
    defer hub.deinit();
    const a = hub.arena.allocator();
    const mods = hub.path("mods");
    const project_sha = sha256Of(@embedFile("testdata/project.zip"));
    const tables: registry.Package = .{ .format = 1, .id = "kai_tables", .kind = .project };
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
    try hub.publishHello(&.{"1.0.0"}, &helloSha256());
    const hello = (try registry.package(a, io, hub.source(), "hello")).?;
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
    try hub.publishHello(&.{"1.0.0"}, &helloSha256());
    const hello = (try registry.package(a, io, hub.source(), "hello")).?;
    const plugins = hub.path("plugins");
    try registry.install(a, io, hub.source(), plugins, hello, hello.versions[0]);

    // Pretend someone else is installing and holds the lock
    const theirs = try hub.tmp.dir.createFile(io, "plugins/.hello.lock", .{ .lock = .exclusive, .lock_nonblocking = true });
    try testing.expectError(error.Busy, registry.install(a, io, hub.source(), plugins, hello, hello.versions[0]));
    try testing.expectError(error.Busy, registry.remove(a, io, plugins, "hello"));
    theirs.close(io);

    try registry.remove(a, io, plugins, "hello");
}
