//! Works out which game an exe is. Needs lots of stack, never call from a hooked game thread.

const std = @import("std");

const core = @import("wraith_core");

pub const vdf = @import("vdf.zig");
pub const exes = @import("exes.zig");
pub const Exe = exes.Exe;
pub const anticheat = @import("anticheat.zig");
pub const game_engine = @import("game_engine.zig");
const fs = @import("fs.zig");
pub const KnownGame = @import("known_game.zig").KnownGame;
const standalone = @import("local.zig");
const launchers = @import("launchers.zig");
const added = @import("added.zig");
const steam = @import("steam.zig");
const gog = @import("gog.zig");
const itch = @import("itch.zig");
const epic = @import("epic.zig");
const xbox = @import("xbox.zig");

const log = core.log.scoped(.wraith_game);

pub const Store = enum {
    steam,
    gog,
    itch,
    epic,
    xbox,
    local,

    pub fn label(s: Store) []const u8 {
        return switch (s) {
            .steam => "Steam",
            .gog => "GOG",
            .itch => "itch.io",
            .epic => "Epic",
            .xbox => "Xbox",
            .local => "Local",
        };
    }

    pub fn jsonStringify(s: Store, jw: anytype) !void {
        try jw.write(.{ .id = @tagName(s), .label = s.label() });
    }
};

pub const Launch = @import("launch.zig").Launch;

pub const Game = struct {
    id: []const u8,
    store: Store,
    name: ?[]const u8 = null,
    /// For `local`, the exe's folder.
    dir: []const u8,
    /// Use this, not `store_exe`.
    launch: Launch = .{ .start = .none },
    store_exe: ?[]const u8 = null,
    /// Then `id` is its tag.
    known: ?KnownGame = null,
    anticheat: ?anticheat.Product = null,
    store_id: ?[]const u8 = null,
    /// The store's build, like `steam:18234455`, as manifests' `builds` list them.
    build: ?[]const u8 = null,
    /// Unix seconds. Only Steam gives this, and only on `discover`.
    last_played: ?i64 = null,
    added: bool = false,
};

pub const Options = struct {
    epic_manifests: ?[]const u8 = null,
    known_installs: ?[]const standalone.Install = null,
    app_data: ?launchers.AppData = null,
    added: ?[]const u8 = null,
};

fn finish(arena: std.mem.Allocator, game: Game, set_up: []const launchers.Found) !Game {
    var out = game;
    if (game.known) |k| {
        out.id = @tagName(k);
        if (game.store != .local) out.store_id = game.id;
        if (out.anticheat == null) out.anticheat = k.anticheat();
    }
    out.launch = try .plan(arena, out, set_up);
    return out;
}

fn launchersSetUp(arena: std.mem.Allocator, io: std.Io, options: Options) ![]const launchers.Found {
    return launchers.find(arena, io, options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            log.warn("Couldn't check for third-party launchers: {t}", .{err});
            return &.{};
        },
    };
}

pub fn identify(arena: std.mem.Allocator, io: std.Io, exe: []const u8, options: Options) !Game {
    const path = fs.withoutPrefix(exe);
    if (!std.fs.path.isAbsolute(path)) return error.NotAbsolute;
    inline for (.{ steam, gog, itch, epic, xbox, standalone, launchers }) |probe| {
        const found = probe.identify(arena, io, path, options) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => blk: {
                log.warn("Couldn't check whether {s} is from {t}: {t}", .{ path, probe.store, err });
                break :blk null;
            },
        };
        if (found) |game| {
            var asked = game;
            asked.dir = try arena.dupe(u8, game.dir);
            asked.store_exe = try arena.dupe(u8, path);
            asked.last_played = null;
            const set_up = if (game.known != null) try launchersSetUp(arena, io, options) else &.{};
            return finish(arena, asked, set_up);
        }
    }
    return local(arena, path);
}

pub fn discover(arena: std.mem.Allocator, io: std.Io, options: Options) ![]const Game {
    var games: std.ArrayList(Game) = .empty;
    inline for (.{ steam, gog, epic, xbox, standalone, launchers }) |store| {
        store.discover(arena, io, options, &games) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => log.warn("Couldn't list {t}'s games: {t}", .{ store.store, err }),
        };
    }
    const set_up = try launchersSetUp(arena, io, options);
    // Same game found twice, e.g. a library listed twice. Keep the first
    var unique: std.ArrayList(Game) = .empty;
    for (games.items) |found| {
        const g = try finish(arena, found, set_up);
        for (unique.items) |u| {
            if (std.mem.eql(u8, u.id, g.id)) break;
        } else try unique.append(arena, g);
    }
    // After the stores' so a store's entry for the same game wins
    if (options.added) |path| for (try added.read(arena, io, path)) |exe| {
        if (!fs.exists(io, exe)) continue;
        const g = try addedGame(arena, io, exe, options);
        for (unique.items) |u| {
            if (std.mem.eql(u8, u.id, g.id)) break;
        } else try unique.append(arena, g);
    };
    std.mem.sort(Game, unique.items, {}, byName);
    return unique.items;
}

fn addedGame(arena: std.mem.Allocator, io: std.Io, exe: []const u8, options: Options) !Game {
    var g = try identify(arena, io, exe, options);
    g.added = true;
    if (g.name == null) g.name = std.fs.path.basename(g.dir);
    return g;
}

pub const Added = struct {
    game: Game,
    new: bool,
};

pub fn add(arena: std.mem.Allocator, io: std.Io, exe: []const u8, options: Options) !Added {
    const path = options.added orelse return error.NoAddedFile;
    const g = try addedGame(arena, io, exe, options);
    for (try discover(arena, io, options)) |listed| {
        if (std.mem.eql(u8, listed.id, g.id)) return .{ .game = listed, .new = false };
    }
    _ = try added.add(arena, io, path, g.store_exe orelse fs.withoutPrefix(exe));
    return .{ .game = g, .new = true };
}

pub fn remove(arena: std.mem.Allocator, io: std.Io, game_id: []const u8, options: Options) !bool {
    const path = options.added orelse return false;
    const Context = struct {
        arena: std.mem.Allocator,
        io: std.Io,
        options: Options,
        id: []const u8,

        fn keep(c: @This(), exe: []const u8) bool {
            const g = identify(c.arena, c.io, exe, c.options) catch return true;
            return !std.mem.eql(u8, g.id, c.id);
        }
    };
    return try added.removeIf(arena, io, path, Context{ .arena = arena, .io = io, .options = options, .id = game_id }, Context.keep) != 0;
}

fn byName(_: void, a: Game, b: Game) bool {
    return std.ascii.lessThanIgnoreCase(a.name orelse a.id, b.name orelse b.id);
}

pub fn local(arena: std.mem.Allocator, exe: []const u8) !Game {
    const path = fs.withoutPrefix(exe);
    const dir = std.fs.path.dirname(path) orelse "";
    // FNV-1a is fixed, so IDs won't change if Zig's hashes do
    var hash: std.hash.Fnv1a_32 = .init();
    for (std.mem.trimEnd(u8, dir, "\\/")) |c| hash.update(&.{fs.fold(c)});

    const file = std.fs.path.basename(path);
    const stem = if (std.ascii.endsWithIgnoreCase(file, ".exe")) file[0 .. file.len - 4] else file;
    const key = try std.fmt.allocPrint(arena, "{s}-{x:0>8}", .{ stem, hash.final() });
    for (key) |*c| c.* = std.ascii.toLower(c.*);
    const owned = try arena.dupe(u8, path);
    return .{
        .id = try id(arena, .local, key),
        .store = .local,
        .dir = try arena.dupe(u8, dir),
        .store_exe = owned,
        .launch = .{ .start = .{ .exe = owned }, .game_exe = owned },
    };
}

/// Chars that can't go in a folder name get replaced in `key`.
pub fn id(arena: std.mem.Allocator, store: Store, key: []const u8) ![]const u8 {
    const text = try std.fmt.allocPrint(arena, "{t}-{s}", .{ store, key });
    for (text[@tagName(store).len + 1 ..]) |*c| {
        if (c.* < 0x20 or std.mem.indexOfScalar(u8, "<>:\"/\\|?*", c.*) != null) c.* = '_';
    }
    return text;
}

const tests = struct {
    const testing = std.testing;

    const Tree = struct {
        tmp: std.testing.TmpDir,
        root: [:0]const u8,
        arena: std.heap.ArenaAllocator,

        fn init() !Tree {
            var tmp = testing.tmpDir(.{});
            errdefer tmp.cleanup();
            return .{ .tmp = tmp, .root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator), .arena = .init(testing.allocator) };
        }

        fn deinit(self: *Tree) void {
            self.arena.deinit();
            testing.allocator.free(self.root);
            self.tmp.cleanup();
        }

        fn put(self: *Tree, sub_path: []const u8, text: []const u8) !void {
            if (std.fs.path.dirname(sub_path)) |dir| try self.tmp.dir.createDirPath(testing.io, dir);
            try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = text });
        }

        fn path(self: *Tree, sub_path: []const u8) []const u8 {
            return std.fs.path.join(self.arena.allocator(), &.{ self.root, sub_path }) catch unreachable;
        }

        /// No Epic manifests, known installs or launchers, so the machine's own don't count.
        fn identifyAt(self: *Tree, sub_path: []const u8) !Game {
            return identify(self.arena.allocator(), testing.io, self.path(sub_path), self.options());
        }

        fn options(self: *Tree) Options {
            const none = self.path("none");
            return .{ .epic_manifests = none, .known_installs = &.{}, .app_data = .{ .roaming = none, .local = none } };
        }
    };

    test "added games" {
        var tree: Tree = try .init();
        defer tree.deinit();
        const a = tree.arena.allocator();
        try tree.put("Mine\\Odd Game\\odd.exe", "");
        var options = tree.options();
        options.added = tree.path("settings\\games.zon");

        const exe = tree.path("Mine\\Odd Game\\odd.exe");
        const result = try add(a, testing.io, exe, options);
        try testing.expect(result.new);
        const g = result.game;
        try testing.expect(g.added);
        try testing.expectEqualStrings("Odd Game", g.name.?);
        try testing.expect(g.launch.startsGame());
        try testing.expect(!(try add(a, testing.io, exe, options)).new);
        const listed = for (try discover(a, testing.io, options)) |d| {
            if (std.mem.eql(u8, d.id, g.id)) break d;
        } else return error.TestNotListed;
        try testing.expect(listed.added);
        try testing.expectEqualStrings(exe, listed.launch.game_exe.?);

        try testing.expect(try remove(a, testing.io, g.id, options));
        try testing.expect(!try remove(a, testing.io, g.id, options));
        for (try discover(a, testing.io, options)) |d| try testing.expect(!std.mem.eql(u8, d.id, g.id));
    }

    test "XIVLauncher" {
        var tree: Tree = try .init();
        defer tree.deinit();
        const a = tree.arena.allocator();
        try tree.put("Steam\\steamapps\\appmanifest_39210.acf",
            \\"AppState" { "appid" "39210" "name" "FINAL FANTASY XIV Online" "installdir" "FINAL FANTASY XIV Online" }
        );
        try tree.put("Steam\\steamapps\\common\\FINAL FANTASY XIV Online\\game\\ffxiv_dx11.exe", "");
        try tree.put("Local\\XIVLauncher\\current\\XIVLauncher.exe", "");
        const game_path = try std.json.Stringify.valueAlloc(a, tree.path("Steam\\steamapps\\common\\FINAL FANTASY XIV Online\\"), .{});
        try tree.put("Roaming\\XIVLauncher\\launcherConfigV3.json", try std.fmt.allocPrint(a,
            \\{{"GamePath": {s}, "AutoStartSteam": false}}
        , .{game_path}));
        var options = tree.options();
        options.app_data = .{ .roaming = tree.path("Roaming"), .local = tree.path("Local") };

        const ffxiv = tree.path("Steam\\steamapps\\common\\FINAL FANTASY XIV Online\\game\\ffxiv_dx11.exe");
        const found = try identify(a, testing.io, ffxiv, options);
        try testing.expectEqualStrings("ffxiv", found.id);
        try testing.expectEqual(.steam, found.store);
        const launcher = tree.path("Local\\XIVLauncher\\current\\XIVLauncher.exe");
        try testing.expectEqualStrings(launcher, found.launch.start.exe);
        try testing.expectEqualStrings(ffxiv, found.launch.game_exe.?);
        try testing.expect(!found.launch.startsGame());

        // Without its config it's not set up, so Steam starts it
        var without = options;
        without.app_data.?.roaming = tree.path("none");
        try testing.expect((try identify(a, testing.io, ffxiv, without)).launch.start == .store);

        // A copy only XIVLauncher knows about is still FFXIV
        try tree.put("Roaming\\XIVLauncher\\launcherConfigV3.json", try std.fmt.allocPrint(a,
            \\{{"GamePath": {s}}}
        , .{try std.json.Stringify.valueAlloc(a, tree.path("Mine\\FFXIV"), .{})}));
        try tree.put("Mine\\FFXIV\\game\\ffxiv_dx11.exe", "");
        const mine = try identify(a, testing.io, tree.path("Mine\\FFXIV\\game\\ffxiv_dx11.exe"), options);
        try testing.expectEqualStrings("ffxiv", mine.id);
        try testing.expectEqualStrings(launcher, mine.launch.start.exe);
        // And the Steam copy isn't the one it starts any more
        try testing.expect((try identify(a, testing.io, ffxiv, options)).launch.start == .store);
    }

    test "known Steam game" {
        var tree: Tree = try .init();
        defer tree.deinit();
        const a = tree.arena.allocator();
        try tree.put("Steam\\steamapps\\appmanifest_39210.acf",
            \\"AppState" { "appid" "39210" "name" "FINAL FANTASY XIV Online" "installdir" "FINAL FANTASY XIV Online" "buildid" "18234455" }
        );
        try tree.put("Steam\\steamapps\\common\\FINAL FANTASY XIV Online\\game\\ffxiv_dx11.exe", "");

        const found = try tree.identifyAt("Steam\\steamapps\\common\\FINAL FANTASY XIV Online\\game\\ffxiv_dx11.exe");
        try testing.expectEqualStrings("ffxiv", found.id);
        try testing.expectEqual(.steam, found.store);
        try testing.expectEqual(.ffxiv, found.known.?);
        try testing.expectEqualStrings("steam-39210", found.store_id.?);
        try testing.expectEqualStrings("steam:18234455", found.build.?);
        try testing.expectEqualStrings("steam://rungameid/39210", found.launch.start.store);
        try testing.expectEqualStrings(tree.path("Steam\\steamapps\\common\\FINAL FANTASY XIV Online\\game\\ffxiv_dx11.exe"), found.launch.game_exe.?);

        var from_steam: std.ArrayList(Game) = .empty;
        try steam.discoverIn(a, testing.io, tree.path("Steam"), &from_steam);
        try testing.expectEqual(.ffxiv, from_steam.items[0].known.?);
    }

    test "known installer game" {
        var tree: Tree = try .init();
        defer tree.deinit();
        const a = tree.arena.allocator();
        const dir = tree.path("SquareEnix\\FINAL FANTASY XIV - A Realm Reborn");
        try tree.put("SquareEnix\\FINAL FANTASY XIV - A Realm Reborn\\boot\\ffxivboot.exe", "");
        const installs = [_]standalone.Install{
            .{ .known = .ffxiv, .dir = dir, .name = "FINAL FANTASY XIV ONLINE" },
            // Uninstalled, folder's gone
            .{ .known = .ffxiv, .dir = tree.path("Gone") },
        };
        var options = tree.options();
        options.known_installs = &installs;

        const found = try identify(a, testing.io, tree.path("SquareEnix\\FINAL FANTASY XIV - A Realm Reborn\\game\\ffxiv_dx11.exe"), options);
        try testing.expectEqualStrings("ffxiv", found.id);
        try testing.expectEqual(.local, found.store);
        try testing.expectEqualStrings(dir, found.dir);
        try testing.expectEqual(null, found.store_id);
        // Starts from its launcher, and wraith goes into the game
        try testing.expectEqualStrings(tree.path("SquareEnix\\FINAL FANTASY XIV - A Realm Reborn\\boot\\ffxivboot.exe"), found.launch.start.exe);
        try testing.expectEqualStrings(tree.path("SquareEnix\\FINAL FANTASY XIV - A Realm Reborn\\game\\ffxiv_dx11.exe"), found.launch.game_exe.?);
        try testing.expect(!found.launch.startsGame());
        // Next to it isn't in it
        try testing.expectEqual(null, (try identify(a, testing.io, tree.path("SquareEnix\\other.exe"), options)).known);

        var listed: std.ArrayList(Game) = .empty;
        try standalone.discover(a, testing.io, options, &listed);
        try testing.expectEqual(1, listed.items.len);
        const g = try finish(a, listed.items[0], &.{});
        try testing.expectEqualStrings("ffxiv", g.id);
        try testing.expectEqualStrings(found.launch.start.exe, g.launch.start.exe);
        try testing.expectEqualStrings(found.launch.game_exe.?, g.launch.game_exe.?);
    }

    test "local game ID" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        // Don't change these, settings are stored under them
        try testing.expectEqualStrings("local-kai-51c185e4", (try local(a, "C:\\Games\\Kai\\Kai.exe")).id);
        try testing.expectEqualStrings("local-kai-51c185e4", (try local(a, "c:/games/kai/KAI.EXE")).id);
        try testing.expectEqualStrings("local-kai-51c185e4", (try local(a, "\\\\?\\C:\\Games\\Kai\\kai.exe")).id);
        try testing.expect(!std.mem.eql(u8, "local-kai-51c185e4", (try local(a, "C:\\Games\\Kai2\\kai.exe")).id));
    }

    test "Steam game ID" {
        var tree: Tree = try .init();
        defer tree.deinit();
        try tree.put("lib\\steamapps\\appmanifest_10.acf",
            \\"AppState" { "appid" "10" "name" "Other" "installdir" "Other" }
        );
        try tree.put("lib\\steamapps\\appmanifest_1245620.acf",
            \\"AppState"
            \\{
            \\    "appid"        "1245620"
            \\    "name"        "ELDEN RING"
            \\    "installdir"        "ELDEN RING"
            \\}
        );
        const found = try tree.identifyAt("lib\\steamapps\\common\\elden ring\\Game\\eldenring.exe");
        try testing.expectEqualStrings("steam-1245620", found.id);
        try testing.expectEqualStrings("ELDEN RING", found.name.?);
        try testing.expectEqualStrings(tree.path("lib\\steamapps\\common\\elden ring"), found.dir);

        // No manifest for it, so it's local
        try testing.expectEqual(.local, (try tree.identifyAt("lib\\steamapps\\common\\Copied\\game.exe")).store);
    }

    test "GOG game ID" {
        var tree: Tree = try .init();
        defer tree.deinit();
        try tree.put("Witcher\\goggame-1207664663.info",
            \\{"gameId": "1207664663", "rootGameId": "1207664643", "name": "Hearts of Stone"}
        );
        try tree.put("Witcher\\goggame-1207664643.info",
            \\{"gameId": "1207664643", "rootGameId": "1207664643", "name": "The Witcher 3"}
        );
        const found = try tree.identifyAt("Witcher\\bin\\x64\\witcher3.exe");
        try testing.expectEqualStrings("gog-1207664643", found.id);
        try testing.expectEqualStrings("The Witcher 3", found.name.?);
        try testing.expectEqualStrings(tree.path("Witcher"), found.dir);
    }

    test "itch game ID" {
        var tree: Tree = try .init();
        defer tree.deinit();
        var gz: std.Io.Writer.Allocating = .init(tree.arena.allocator());
        var buf: [256]u8 = undefined;
        var raw: std.compress.flate.Compress.Raw = try .init(&gz.writer, &buf, .gzip);
        try raw.writer.writeAll(
            \\{"game": {"id": 107465, "title": "Celeste Classic", "url": "https://x.itch.io/c"}, "files": []}
        );
        try raw.finish();
        try tree.put("itch\\apps\\celeste\\.itch\\receipt.json.gz", gz.written());

        const found = try tree.identifyAt("itch\\apps\\celeste\\bin\\celeste.exe");
        try testing.expectEqualStrings("itch-107465", found.id);
        try testing.expectEqualStrings("Celeste Classic", found.name.?);
        try testing.expectEqualStrings(tree.path("itch\\apps\\celeste"), found.dir);
    }

    test "Epic game ID" {
        var tree: Tree = try .init();
        defer tree.deinit();
        const a = tree.arena.allocator();
        const location = try std.json.Stringify.valueAlloc(a, tree.path("Epic\\Sugar"), .{});
        try tree.put("manifests\\A1.item", try std.fmt.allocPrint(a,
            \\{{"AppName": "Sugar", "DisplayName": "Cake Game", "InstallLocation": {s}}}
        , .{location}));
        try tree.put("Copied\\.egstore\\B2.mancpn",
            \\{"FormatVersion": 0, "AppName": "Sugar", "CatalogNamespace": "x"}
        );
        // An engine plugin's manifest points at the engine folder. Exes there aren't the plugin
        const engine = try std.json.Stringify.valueAlloc(a, tree.path("Epic\\UE_5.8"), .{});
        try tree.put("manifests\\C3.item", try std.fmt.allocPrint(a,
            \\{{"AppName": "Bridge", "bIsApplication": false, "HostInstallationGuid": "DC7C", "InstallLocation": {s}}}
        , .{engine}));
        const options: Options = .{ .epic_manifests = tree.path("manifests") };

        const installed = try identify(a, testing.io, tree.path("Epic\\Sugar\\Bin\\cake.exe"), options);
        try testing.expectEqualStrings("epic-Sugar", installed.id);
        try testing.expectEqualStrings("Cake Game", installed.name.?);
        try testing.expectEqualStrings(tree.path("Epic\\Sugar"), installed.dir);

        // Moved from where the launcher put it, but .egstore still says what it is
        const copied = try identify(a, testing.io, tree.path("Copied\\cake.exe"), options);
        try testing.expectEqualStrings("epic-Sugar", copied.id);
        try testing.expectEqualStrings("Cake Game", copied.name.?);

        // A sibling folder with the same name prefix doesn't count as inside it
        try testing.expectEqual(.local, (try identify(a, testing.io, tree.path("Epic\\Sugar2\\cake.exe"), options)).store);
        try testing.expectEqual(.local, (try identify(a, testing.io, tree.path("Epic\\UE_5.8\\Engine\\editor.exe"), options)).store);
    }

    test "Xbox game ID" {
        var tree: Tree = try .init();
        defer tree.deinit();
        try tree.put("XboxGames\\Halo\\Content\\MicrosoftGame.config",
            \\<?xml version="1.0" encoding="utf-8"?>
            \\<Game configVersion="1">
            \\  <IdentityExtra Name="not this"/>
            \\  <Identity
            \\    Version="1.0.0.0" Name="Microsoft.Halo" Publisher="CN=Microsoft"/>
            \\  <ShellVisuals DefaultDisplayName="Halo &amp; Friends" PublisherDisplayName="Xbox"/>
            \\</Game>
        );
        const found = try tree.identifyAt("XboxGames\\Halo\\Content\\halo.exe");
        try testing.expectEqualStrings("xbox-Microsoft.Halo", found.id);
        try testing.expectEqualStrings("Halo & Friends", found.name.?);
    }

    test "store launches" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const plan = struct {
            fn of(arena_: std.mem.Allocator, g: Game) !Launch {
                return Launch.plan(arena_, g, &.{});
            }
        }.of;
        try testing.expectEqualStrings("steam://rungameid/1245620", (try plan(a, .{ .id = "steam-1245620", .store = .steam, .dir = "D:\\x" })).start.store);
        try testing.expectEqualStrings("com.epicgames.launcher://apps/Sugar?action=launch&silent=true", (try plan(a, .{ .id = "epic-Sugar", .store = .epic, .dir = "D:\\x" })).start.store);
        const gog_game = try plan(a, .{ .id = "gog-1", .store = .gog, .dir = "D:\\x", .store_exe = "D:\\x\\x.exe" });
        try testing.expectEqualStrings("D:\\x\\x.exe", gog_game.start.exe);
        try testing.expect(gog_game.startsGame());
        const xbox_game = try plan(a, .{ .id = "xbox-A", .store = .xbox, .dir = "D:\\x", .store_exe = "D:\\x\\x.exe" });
        try testing.expect(xbox_game.start == .none);
        try testing.expectEqualStrings("D:\\x\\x.exe", xbox_game.game_exe.?);
    }

    test "Steam discover" {
        var tree: Tree = try .init();
        defer tree.deinit();
        const a = tree.arena.allocator();
        const other = try std.json.Stringify.valueAlloc(a, tree.path("Library2"), .{});
        try tree.put("Steam\\steamapps\\libraryfolders.vdf", try std.fmt.allocPrint(a,
            \\"libraryfolders" {{ "0" {{ "path" "x" }} "1" {{ "path" {s} }} }}
        , .{other}));
        try tree.put("Steam\\steamapps\\appmanifest_10.acf",
            \\"AppState" { "appid" "10" "name" "Counter-Strike" "installdir" "Half-Life" "LastPlayed" "1794630414" }
        );
        try tree.put("Steam\\steamapps\\common\\Half-Life\\hl.exe", "");
        // A tool, and a game whose folder is gone
        try tree.put("Steam\\steamapps\\appmanifest_228980.acf",
            \\"AppState" { "appid" "228980" "name" "Steamworks Common Redistributables" "installdir" "Steamworks Shared" }
        );
        try tree.put("Steam\\steamapps\\common\\Steamworks Shared\\x", "");
        try tree.put("Steam\\steamapps\\appmanifest_20.acf",
            \\"AppState" { "appid" "20" "name" "Gone" "installdir" "Gone" }
        );
        try tree.put("Library2\\steamapps\\appmanifest_1245620.acf",
            \\"AppState" { "appid" "1245620" "name" "ELDEN RING" "installdir" "ELDEN RING" }
        );
        try tree.put("Library2\\steamapps\\common\\ELDEN RING\\Game\\eldenring.exe", "");

        var found: std.ArrayList(Game) = .empty;
        try steam.discoverIn(a, testing.io, tree.path("Steam"), &found);
        try testing.expectEqual(2, found.items.len);
        try testing.expectEqualStrings("steam-10", found.items[0].id);
        try testing.expectEqualStrings("steam-1245620", found.items[1].id);
        try testing.expectEqual(1794630414, found.items[0].last_played);
        try testing.expectEqual(null, found.items[1].last_played);
        // VAC lives in Steam, so we tag the games that have it
        try testing.expectEqual(.vac, found.items[0].anticheat);
        try testing.expectEqual(null, found.items[1].anticheat);
        const identified = try tree.identifyAt("Library2\\steamapps\\common\\ELDEN RING\\Game\\eldenring.exe");
        try testing.expectEqualStrings(identified.id, found.items[1].id);
        try testing.expectEqualStrings(identified.dir, found.items[1].dir);
    }

    test "Epic discover" {
        var tree: Tree = try .init();
        defer tree.deinit();
        const a = tree.arena.allocator();
        const sugar = try std.json.Stringify.valueAlloc(a, tree.path("Epic\\Sugar"), .{});
        try tree.put("manifests\\A1.item", try std.fmt.allocPrint(a,
            \\{{"AppName": "Sugar", "DisplayName": "Cake Game", "InstallLocation": {s}, "LaunchExecutable": "Bin/cake.exe"}}
        , .{sugar}));
        try tree.put("manifests\\C3.item", try std.fmt.allocPrint(a,
            \\{{"AppName": "Bridge", "bIsApplication": false, "InstallLocation": {s}}}
        , .{sugar}));
        try tree.put("Epic\\Sugar\\Bin\\cake.exe", "");

        var found: std.ArrayList(Game) = .empty;
        try epic.discover(a, testing.io, .{ .epic_manifests = tree.path("manifests") }, &found);
        try testing.expectEqual(1, found.items.len);
        try testing.expectEqualStrings("epic-Sugar", found.items[0].id);
        try testing.expectEqualStrings(tree.path("Epic\\Sugar\\Bin/cake.exe"), found.items[0].store_exe.?);
    }

    test "Xbox discover" {
        var tree: Tree = try .init();
        defer tree.deinit();
        const a = tree.arena.allocator();
        // RGBX, 1 folder: "Games\Xbox"
        var root: std.ArrayList(u8) = .empty;
        try root.appendSlice(a, "RGBX\x01\x00\x00\x00");
        for (std.unicode.utf8ToUtf16LeStringLiteral("Games\\Xbox")) |c| try root.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, c)));
        try root.appendSlice(a, "\x00\x00");
        try tree.put(".GamingRoot", root.items);
        try tree.put("Games\\Xbox\\Halo\\Content\\MicrosoftGame.config",
            \\<Game><Identity Name="Microsoft.Halo"/><ExecutableList><Executable Name="bin\halo.exe" Id="Game"/></ExecutableList></Game>
        );
        try tree.put("Games\\Xbox\\Empty\\readme.txt", "");

        var found: std.ArrayList(Game) = .empty;
        try xbox.discoverIn(a, testing.io, tree.root, &found);
        try testing.expectEqual(1, found.items.len);
        try testing.expectEqualStrings("xbox-Microsoft.Halo", found.items[0].id);
        try testing.expectEqualStrings(tree.path("Games\\Xbox\\Halo\\Content\\bin\\halo.exe"), found.items[0].store_exe.?);
    }
};

test {
    _ = vdf;
    _ = exes;
    _ = fs;
    _ = @import("launch.zig");
    _ = added;
    _ = anticheat;
    _ = game_engine;
    _ = tests;
}
