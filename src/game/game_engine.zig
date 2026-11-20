//! Works out which game engine a game's made with, like Unity or Unreal, from the files beside its
//! exe. Not script engines or the hook engine. For the launcher to show, and for tools that only work
//! with one, like a Unity plugin.

const std = @import("std");

const sys = @import("tuft_sys");

pub const GameEngine = enum {
    unity,
    unreal,
    godot,
    gamemaker,
    rpg_maker,
    renpy,
    source,
    source2,
    cryengine,
    re_engine,
    fna,
    monogame,
    xna,
    love,
    nwjs,
    electron,

    pub fn label(e: GameEngine) []const u8 {
        return switch (e) {
            .unity => "Unity",
            .unreal => "Unreal Engine",
            .godot => "Godot",
            .gamemaker => "GameMaker",
            .rpg_maker => "RPG Maker",
            .renpy => "Ren'Py",
            .source => "Source",
            .source2 => "Source 2",
            .cryengine => "CRYENGINE",
            .re_engine => "RE Engine",
            .fna => "FNA",
            .monogame => "MonoGame",
            .xna => "XNA",
            .love => "LÖVE",
            .nwjs => "NW.js",
            .electron => "Electron",
        };
    }

    pub fn jsonStringify(e: GameEngine, jw: anytype) !void {
        try jw.write(.{ .id = @tagName(e), .label = e.label() });
    }
};

pub const Found = struct {
    game_engine: GameEngine,
    /// Which kind, like `IL2CPP` or `Mono` for Unity and `MV` for RPG Maker.
    variant: ?[]const u8 = null,
    /// Like `2021.3.16`, when the files say.
    version: ?[]const u8 = null,
    /// What gave it away, from the folder it looked in.
    file: []const u8,
};

const max_entries = 4096;

/// From the exe's folder. For Unreal, the exe can sit in its project's Binaries too.
pub fn ofGame(arena: std.mem.Allocator, io: std.Io, exe: []const u8) !?Found {
    // Windows' own programs have thousands of files and no engine
    if (exe.len > 2 and std.ascii.startsWithIgnoreCase(exe[1..], ":\\windows\\")) return null;
    const dir = std.fs.path.dirname(exe) orelse return null;
    if (try ofFolder(arena, io, dir)) |found| return found;
    return ofUnrealBinaries(arena, io, dir, std.fs.path.basename(exe));
}

/// From an install folder, then the folders right inside it, for games whose exe is a level down.
pub fn ofInstall(arena: std.mem.Allocator, io: std.Io, dir: []const u8) !?Found {
    if (try ofFolder(arena, io, dir)) |found| return found;
    var root = std.Io.Dir.openDirAbsolute(io, dir, .{ .iterate = true }) catch return null;
    defer root.close(io);
    var it = root.iterate();
    var n: usize = 0;
    while (it.next(io) catch return null) |entry| : (n += 1) {
        if (n == max_entries) return null;
        if (entry.kind != .directory or isRedist(entry.name)) continue;
        if (try ofFolder(arena, io, try std.fs.path.join(arena, &.{ dir, entry.name }))) |found| return found;
    }
    return null;
}

/// `<Project>\Binaries\Win64\<Name>-Win64-Shipping.exe`, with the content next to Binaries.
fn ofUnrealBinaries(arena: std.mem.Allocator, io: std.Io, dir: []const u8, exe_name: []const u8) !?Found {
    const binaries = std.fs.path.dirname(dir) orelse return null;
    if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(binaries), "Binaries")) return null;
    const platform = std.fs.path.basename(dir);
    if (!std.ascii.startsWithIgnoreCase(platform, "Win")) return null;
    const shipping = std.ascii.findIgnoreCase(exe_name, "-shipping.exe") != null;
    const project = std.fs.path.dirname(binaries) orelse return null;
    var project_dir = std.Io.Dir.openDirAbsolute(io, project, .{}) catch return null;
    defer project_dir.close(io);
    if (exists(io, project_dir, "Content\\Paks")) return .{ .game_engine = .unreal, .file = "Content\\Paks" };
    if (shipping) return .{ .game_engine = .unreal, .file = try arena.dupe(u8, exe_name) };
    return null;
}

/// What's in a folder that gives an engine away. Several can show, like NW.js under RPG Maker,
/// so it's all looked at before picking.
const Seen = struct {
    unity_player: bool = false,
    game_assembly: bool = false,
    /// `<Game>_Data`, Unity's.
    data_dir: ?[]const u8 = null,
    /// Its game code's in `<Game>_Data\Managed`, for Mono.
    managed: bool = false,
    il2cpp_data: bool = false,
    unreal_engine: bool = false,
    engine2: bool = false,
    source_bin: bool = false,
    pck: ?[]const u8 = null,
    gamemaker: bool = false,
    rgss: ?[]const u8 = null,
    rpg_mv: bool = false,
    rpg_mz: bool = false,
    renpy: bool = false,
    cryengine: bool = false,
    re_chunk: ?[]const u8 = null,
    fna: bool = false,
    monogame: bool = false,
    xna: ?[]const u8 = null,
    love: bool = false,
    nwjs: bool = false,
    electron: bool = false,
};

fn ofFolder(arena: std.mem.Allocator, io: std.Io, path: []const u8) !?Found {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var seen: Seen = .{};
    var exes: std.ArrayList([]const u8) = .empty;
    var pcks: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    var n: usize = 0;
    while (it.next(io) catch null) |entry| : (n += 1) {
        if (n == max_entries) break;
        const name = entry.name;
        if (entry.kind == .directory) {
            if (std.ascii.endsWithIgnoreCase(name, "_Data") and seen.data_dir == null) {
                seen.managed = exists(io, dir, try std.fs.path.join(arena, &.{ name, "Managed" }));
                seen.il2cpp_data = exists(io, dir, try std.fs.path.join(arena, &.{ name, "il2cpp_data" }));
                if (seen.managed or seen.il2cpp_data) seen.data_dir = try arena.dupe(u8, name);
            } else if (std.ascii.eqlIgnoreCase(name, "Engine")) {
                seen.unreal_engine = exists(io, dir, "Engine\\Binaries");
            } else if (std.ascii.eqlIgnoreCase(name, "bin")) {
                seen.source_bin = exists(io, dir, "bin\\engine.dll");
            } else if (std.ascii.eqlIgnoreCase(name, "www")) {
                seen.rpg_mv = exists(io, dir, "www\\js\\rpg_core.js");
            } else if (std.ascii.eqlIgnoreCase(name, "js")) {
                seen.rpg_mz = exists(io, dir, "js\\rmmz_core.js");
            } else if (std.ascii.eqlIgnoreCase(name, "System")) {
                if (seen.rgss == null) seen.rgss = try rgssIn(arena, io, dir);
            } else if (std.ascii.eqlIgnoreCase(name, "renpy")) {
                seen.renpy = true;
            } else if (std.ascii.eqlIgnoreCase(name, "resources")) {
                seen.electron = exists(io, dir, "resources\\app.asar");
            }
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "UnityPlayer.dll")) {
            seen.unity_player = true;
        } else if (std.ascii.eqlIgnoreCase(name, "GameAssembly.dll")) {
            seen.game_assembly = true;
        } else if (std.ascii.eqlIgnoreCase(name, "engine2.dll")) {
            seen.engine2 = true;
        } else if (std.ascii.eqlIgnoreCase(name, "data.win")) {
            seen.gamemaker = true;
        } else if (std.ascii.eqlIgnoreCase(name, "CrySystem.dll")) {
            seen.cryengine = true;
        } else if (std.ascii.eqlIgnoreCase(name, "FNA.dll")) {
            seen.fna = true;
        } else if (std.ascii.eqlIgnoreCase(name, "MonoGame.Framework.dll")) {
            seen.monogame = true;
        } else if (std.ascii.eqlIgnoreCase(name, "love.dll")) {
            seen.love = true;
        } else if (std.ascii.eqlIgnoreCase(name, "nw.dll")) {
            seen.nwjs = true;
        } else if (std.ascii.startsWithIgnoreCase(name, "Microsoft.Xna.Framework") and std.ascii.endsWithIgnoreCase(name, ".dll")) {
            if (seen.xna == null) seen.xna = try arena.dupe(u8, name);
        } else if (std.ascii.startsWithIgnoreCase(name, "re_chunk_") and std.ascii.endsWithIgnoreCase(name, ".pak")) {
            if (seen.re_chunk == null) seen.re_chunk = try arena.dupe(u8, name);
        } else if (std.ascii.startsWithIgnoreCase(name, "RGSS") and std.ascii.endsWithIgnoreCase(name, ".dll")) {
            if (seen.rgss == null) seen.rgss = try arena.dupe(u8, name);
        } else if (std.ascii.endsWithIgnoreCase(name, ".exe")) {
            try exes.append(arena, try arena.dupe(u8, name[0 .. name.len - 4]));
        } else if (std.ascii.endsWithIgnoreCase(name, ".pck")) {
            try pcks.append(arena, try arena.dupe(u8, name));
        }
    }
    // Godot's pack is named after its exe. Other .pck files are often Wwise sound banks
    for (pcks.items) |pck| for (exes.items) |exe| {
        if (std.ascii.eqlIgnoreCase(pck[0 .. pck.len - 4], exe)) seen.pck = pck;
    };
    return try pick(arena, path, seen);
}

/// Earlier ones win, so an engine beats the runtime it ships in, like RPG Maker MV's NW.js.
fn pick(arena: std.mem.Allocator, path: []const u8, seen: Seen) !?Found {
    if (seen.unity_player or seen.data_dir != null) return try unity(arena, path, seen);
    if (seen.unreal_engine) return .{ .game_engine = .unreal, .file = "Engine\\Binaries" };
    if (seen.engine2) return .{ .game_engine = .source2, .file = "engine2.dll" };
    if (seen.source_bin) return .{ .game_engine = .source, .file = "bin\\engine.dll" };
    if (seen.pck) |pck| return .{ .game_engine = .godot, .file = pck };
    if (seen.gamemaker) return .{ .game_engine = .gamemaker, .file = "data.win" };
    if (seen.rpg_mz) return .{ .game_engine = .rpg_maker, .variant = "MZ", .file = "js\\rmmz_core.js" };
    if (seen.rpg_mv) return .{ .game_engine = .rpg_maker, .variant = "MV", .file = "www\\js\\rpg_core.js" };
    if (seen.rgss) |dll| return .{ .game_engine = .rpg_maker, .variant = rgssVariant(dll), .file = dll };
    if (seen.renpy) return .{ .game_engine = .renpy, .file = "renpy" };
    if (seen.cryengine) return .{ .game_engine = .cryengine, .file = "CrySystem.dll" };
    if (seen.re_chunk) |pak| return .{ .game_engine = .re_engine, .file = pak };
    if (seen.fna) return .{ .game_engine = .fna, .file = "FNA.dll" };
    if (seen.monogame) return .{ .game_engine = .monogame, .file = "MonoGame.Framework.dll" };
    if (seen.xna) |dll| return .{ .game_engine = .xna, .file = dll };
    if (seen.love) return .{ .game_engine = .love, .file = "love.dll" };
    if (seen.nwjs) return .{ .game_engine = .nwjs, .file = "nw.dll" };
    if (seen.electron) return .{ .game_engine = .electron, .file = "resources\\app.asar" };
    return null;
}

/// IL2CPP compiles the game's C# to native code in GameAssembly.dll, Mono runs it from Managed.
/// UnityPlayer.dll's version is Unity's. Before 2017.2 the engine was in the exe, so there's none.
fn unity(arena: std.mem.Allocator, path: []const u8, seen: Seen) !Found {
    var found: Found = .{ .game_engine = .unity, .file = if (seen.unity_player) "UnityPlayer.dll" else seen.data_dir.? };
    if (seen.game_assembly or seen.il2cpp_data) {
        found.variant = "IL2CPP";
    } else if (seen.managed) {
        found.variant = "Mono";
    }
    if (seen.unity_player) {
        const player = try std.fs.path.join(arena, &.{ path, "UnityPlayer.dll" });
        if (sys.version.fileInfo(arena, player) catch null) |info| if (info.versions) |v| {
            found.version = try std.fmt.allocPrint(arena, "{d}.{d}.{d}", .{ v.file.major, v.file.minor, v.file.patch });
        };
    }
    return found;
}

fn rgssIn(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !?[]const u8 {
    var system = dir.openDir(io, "System", .{ .iterate = true }) catch return null;
    defer system.close(io);
    var it = system.iterate();
    while (it.next(io) catch null) |entry| {
        if (std.ascii.startsWithIgnoreCase(entry.name, "RGSS") and std.ascii.endsWithIgnoreCase(entry.name, ".dll")) {
            return try std.fs.path.join(arena, &.{ "System", entry.name });
        }
    }
    return null;
}

/// RGSS1 is XP, 2 is VX and 3 is VX Ace.
fn rgssVariant(dll: []const u8) ?[]const u8 {
    const name = std.fs.path.basename(dll);
    if (name.len < 5) return null;
    return switch (name[4]) {
        '1' => "XP",
        '2' => "VX",
        '3' => "VX Ace",
        else => null,
    };
}

fn exists(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) bool {
    dir.access(io, sub_path, .{}) catch return false;
    return true;
}

fn isRedist(name: []const u8) bool {
    const redist = [_][]const u8{ "_CommonRedist", "CommonRedist", "Redist", "_Redist", "Redistributables", "__Installer", "DirectX", "vcredist", "Prerequisites" };
    for (redist) |r| if (std.ascii.eqlIgnoreCase(name, r)) return true;
    return false;
}

const tests = struct {
    const testing = std.testing;

    const Tree = struct {
        tmp: testing.TmpDir,
        root: [:0]const u8,

        fn init(files: []const []const u8) !Tree {
            const io = testing.io;
            var tmp = testing.tmpDir(.{});
            errdefer tmp.cleanup();
            // Ending in \ is a folder
            for (files) |f| {
                if (std.mem.endsWith(u8, f, "\\")) {
                    try tmp.dir.createDirPath(io, f[0 .. f.len - 1]);
                    continue;
                }
                if (std.fs.path.dirname(f)) |d| try tmp.dir.createDirPath(io, d);
                try tmp.dir.writeFile(io, .{ .sub_path = f, .data = "" });
            }
            return .{ .tmp = tmp, .root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator) };
        }

        fn deinit(self: *Tree) void {
            testing.allocator.free(self.root);
            self.tmp.cleanup();
        }

        fn game(self: *const Tree, arena: std.mem.Allocator, exe: []const u8) !?Found {
            return ofGame(arena, testing.io, try std.fs.path.join(arena, &.{ self.root, exe }));
        }
    };

    fn arenaOf() std.heap.ArenaAllocator {
        return .init(testing.allocator);
    }

    test "Unity, IL2CPP or Mono" {
        var arena = arenaOf();
        defer arena.deinit();
        var il2cpp: Tree = try .init(&.{ "Kai.exe", "UnityPlayer.dll", "GameAssembly.dll", "Kai_Data\\il2cpp_data\\Metadata\\global-metadata.dat" });
        defer il2cpp.deinit();
        const a = (try il2cpp.game(arena.allocator(), "Kai.exe")).?;
        try testing.expectEqual(.unity, a.game_engine);
        try testing.expectEqualStrings("IL2CPP", a.variant.?);

        // Old Unity, with the engine in the exe
        var mono: Tree = try .init(&.{ "Old.exe", "Old_Data\\Managed\\Assembly-CSharp.dll" });
        defer mono.deinit();
        const b = (try mono.game(arena.allocator(), "Old.exe")).?;
        try testing.expectEqual(.unity, b.game_engine);
        try testing.expectEqualStrings("Mono", b.variant.?);
        try testing.expectEqualStrings("Old_Data", b.file);
    }

    test "Unreal, from Binaries or the install" {
        var arena = arenaOf();
        defer arena.deinit();
        var tree: Tree = try .init(&.{ "Kai.exe", "Engine\\Binaries\\ThirdParty\\", "Kai\\Binaries\\Win64\\Kai-Win64-Shipping.exe", "Kai\\Content\\Paks\\Kai.pak" });
        defer tree.deinit();
        try testing.expectEqual(.unreal, (try tree.game(arena.allocator(), "Kai\\Binaries\\Win64\\Kai-Win64-Shipping.exe")).?.game_engine);
        try testing.expectEqual(.unreal, (try tree.game(arena.allocator(), "Kai.exe")).?.game_engine);
        try testing.expectEqual(.unreal, (try ofInstall(arena.allocator(), testing.io, tree.root)).?.game_engine);
    }

    test "the engine beats what it runs in" {
        var arena = arenaOf();
        defer arena.deinit();
        var tree: Tree = try .init(&.{ "Game.exe", "nw.dll", "www\\js\\rpg_core.js" });
        defer tree.deinit();
        const found = (try tree.game(arena.allocator(), "Game.exe")).?;
        try testing.expectEqual(.rpg_maker, found.game_engine);
        try testing.expectEqualStrings("MV", found.variant.?);
    }

    test "the rest, by their files" {
        var arena = arenaOf();
        defer arena.deinit();
        const cases = [_]struct { []const []const u8, GameEngine, ?[]const u8 }{
            .{ &.{ "Kai.exe", "Kai.pck" }, .godot, null },
            .{ &.{ "Kai.exe", "data.win" }, .gamemaker, null },
            .{ &.{ "Game.exe", "System\\RGSS301.dll" }, .rpg_maker, "VX Ace" },
            .{ &.{ "Kai.exe", "renpy\\" }, .renpy, null },
            .{ &.{ "hl2.exe", "bin\\engine.dll" }, .source, null },
            .{ &.{ "cs2.exe", "engine2.dll" }, .source2, null },
            .{ &.{ "re4.exe", "re_chunk_000.pak" }, .re_engine, null },
            .{ &.{ "Kai.exe", "FNA.dll" }, .fna, null },
            .{ &.{ "Kai.exe", "resources\\app.asar" }, .electron, null },
        };
        for (cases) |case| {
            var tree: Tree = try .init(case[0]);
            defer tree.deinit();
            const found = (try tree.game(arena.allocator(), case[0][0])) orelse {
                std.debug.print("MISSING {t}\n", .{case[1]});
                return error.Missing;
            };
            try testing.expectEqual(case[1], found.game_engine);
            if (case[2]) |v| try testing.expectEqualStrings(v, found.variant.?);
        }
    }

    test "not an engine" {
        var arena = arenaOf();
        defer arena.deinit();
        // A Wwise bank isn't Godot's pack, and a folder called GameEngine needs Binaries in it
        var tree: Tree = try .init(&.{ "Kai.exe", "Init.pck", "Engine\\Config\\", "readme.txt" });
        defer tree.deinit();
        try testing.expectEqual(null, try tree.game(arena.allocator(), "Kai.exe"));
    }
};

test {
    _ = tests;
}
