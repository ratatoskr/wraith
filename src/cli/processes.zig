//! Processes in the user's session, likeliest games first.

const std = @import("std");

const inject = @import("tuft_inject");

const ops = @import("ops.zig");
const anticheat = @import("wraith_game").anticheat;

pub const Hint = enum {
    steam,
    epic,
    gog,
    xbox,
    unity,
    unreal,
    middleware,
    d3d12,
    d3d11,
    d3d10,
    d3d9,
    vulkan,
    opengl,
    gamepad,
    browser,

    pub fn label(hint: Hint) []const u8 {
        return switch (hint) {
            .steam => "Steam",
            .epic => "Epic",
            .gog => "GOG",
            .xbox => "Xbox",
            .unity => "Unity",
            .unreal => "Unreal",
            .middleware => "Middleware",
            .d3d12 => "D3D12",
            .d3d11 => "D3D11",
            .d3d10 => "D3D10",
            .d3d9 => "D3D9",
            .vulkan => "Vulkan",
            .opengl => "OpenGL",
            .gamepad => "Gamepad",
            .browser => "Browser",
        };
    }

    pub fn jsonStringify(hint: Hint, jw: anytype) !void {
        try jw.write(.{ .id = @tagName(hint), .label = hint.label() });
    }

    fn weight(hint: Hint) i32 {
        return switch (hint) {
            .steam, .epic, .gog, .xbox, .unity, .unreal => 40,
            .middleware => 25,
            .d3d12, .d3d11, .d3d9, .vulkan => 30,
            .d3d10 => 25,
            .opengl => 15,
            .gamepad => 10,
            .browser => -50,
        };
    }

    fn isGraphics(hint: Hint) bool {
        return switch (hint) {
            .d3d12, .d3d11, .d3d10, .d3d9, .vulkan, .opengl => true,
            else => false,
        };
    }
};

pub const Hints = std.EnumSet(Hint);

const window_weight = 20;
/// For an elevated game it might be the only clue.
const anticheat_weight: i32 = 60;

pub const Process = struct {
    pid: u32,
    name: []const u8,
    path: ?[]const u8,
    arch: ?inject.Arch,
    windowed: bool,
    /// Only windowed processes we're allowed into.
    inspected: bool,
    wraith: bool,
    hints: []const Hint,
    anticheat: []const anticheat.Found,
    score: i32,
};

pub const Options = struct {
    all: bool = false,
};

pub fn list(arena: std.mem.Allocator, io: std.Io, options: Options) ![]Process {
    const self_pid = inject.currentPid();
    const session = try inject.sessionOf(self_pid);
    const windowed = try inject.windowedPids(arena);

    var result: std.ArrayList(Process) = .empty;
    var processes = try inject.Processes.init();
    defer processes.deinit();
    while (processes.next()) |entry| {
        if (entry.pid == self_pid or entry.pid <= 4) continue;
        if ((inject.sessionOf(entry.pid) catch continue) != session) continue;
        const has_window = std.mem.indexOfScalar(u32, windowed, entry.pid) != null;
        if (!has_window and !options.all) continue;

        var process: Process = .{
            .pid = entry.pid,
            .name = try arena.dupe(u8, entry.name),
            .path = null,
            .arch = null,
            .windowed = has_window,
            .inspected = false,
            .wraith = false,
            .hints = &.{},
            .anticheat = &.{},
            .score = 0,
        };
        var hints: Hints = .empty;
        var found: anticheat.List = .{};
        var path_buf: [4096]u8 = undefined;
        if (inject.queryImage(entry.pid, &path_buf)) |image| {
            process.arch = image.arch;
            process.path = try arena.dupe(u8, image.path);
            hints.setUnion(hintsOfPath(image.path));
            if (has_window) try anticheat.ofGame(arena, io, image.path, &found);
        } else |_| {}
        if (has_window) inspect: {
            var modules = inject.Modules.init(entry.pid) catch break :inspect;
            defer modules.deinit();
            process.inspected = true;
            while (modules.next()) |module| {
                if (ops.isBootstrap(module.name)) process.wraith = true;
                if (hintOfModule(module.name)) |hint| hints.insert(hint);
                try found.check(arena, module.name);
            }
        }
        process.anticheat = found.items.items;
        // Only games ship anti-cheat
        process.score = score(hints, has_window) + if (process.anticheat.len != 0) anticheat_weight else 0;
        var hint_list: std.ArrayList(Hint) = .empty;
        var it = hints.iterator();
        while (it.next()) |hint| try hint_list.append(arena, hint);
        process.hints = hint_list.items;
        try result.append(arena, process);
    }
    std.mem.sort(Process, result.items, {}, likelierFirst);
    return result.items;
}

fn likelierFirst(_: void, a: Process, b: Process) bool {
    if (a.score != b.score) return a.score > b.score;
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

/// Only the best graphics API counts.
pub fn score(hints: Hints, windowed: bool) i32 {
    var total: i32 = if (windowed) window_weight else 0;
    var graphics: i32 = 0;
    var it = hints.iterator();
    while (it.next()) |hint| {
        if (hint.isGraphics()) graphics = @max(graphics, hint.weight()) else total += hint.weight();
    }
    return total + graphics;
}

pub fn hintOfModule(name: []const u8) ?Hint {
    const exact = [_]struct { []const u8, Hint }{
        .{ "d3d9.dll", .d3d9 },                  .{ "d3d10.dll", .d3d10 },
        .{ "d3d10_1.dll", .d3d10 },              .{ "d3d11.dll", .d3d11 },
        .{ "d3d12.dll", .d3d12 },                .{ "vulkan-1.dll", .vulkan },
        .{ "opengl32.dll", .opengl },            .{ "steam_api.dll", .steam },
        .{ "steam_api64.dll", .steam },          .{ "eossdk-win32-shipping.dll", .epic },
        .{ "eossdk-win64-shipping.dll", .epic }, .{ "galaxy.dll", .gog },
        .{ "galaxy64.dll", .gog },               .{ "unityplayer.dll", .unity },
        .{ "gameassembly.dll", .unity },         .{ "xinput1_3.dll", .gamepad },
        .{ "xinput1_4.dll", .gamepad },          .{ "xinput9_1_0.dll", .gamepad },
        .{ "dinput8.dll", .gamepad },            .{ "libcef.dll", .browser },
        .{ "chrome_elf.dll", .browser },         .{ "embeddedbrowserwebview.dll", .browser },
        .{ "xul.dll", .browser },
    };
    for (exact) |e| if (std.ascii.eqlIgnoreCase(name, e[0])) return e[1];
    const middleware = [_][]const u8{ "fmod", "bink", "aksoundengine", "physx", "nvngx_dlss", "amd_ags", "amd_fidelityfx", "gfsdk_", "sl.interposer" };
    for (middleware) |prefix| if (std.ascii.startsWithIgnoreCase(name, prefix)) return .middleware;
    return null;
}

pub fn hintsOfPath(path: []const u8) Hints {
    var hints: Hints = .empty;
    const libraries = [_]struct { []const u8, Hint }{
        .{ "\\steamapps\\common\\", .steam },
        .{ "\\epic games\\", .epic },
        .{ "\\gog galaxy\\games\\", .gog },
        .{ "\\gog games\\", .gog },
        .{ "\\xboxgames\\", .xbox },
    };
    for (libraries) |l| if (std.ascii.findIgnoreCase(path, l[0]) != null) hints.insert(l[1]);
    // The Epic Games Launcher lives in there too
    if (std.ascii.findIgnoreCase(path, "\\epic games\\launcher\\") != null) hints.remove(.epic);
    const name = std.fs.path.basename(path);
    for ([_][]const u8{ "-win64-shipping.exe", "-win32-shipping.exe", "-wingdk-shipping.exe" }) |suffix| {
        if (std.ascii.endsWithIgnoreCase(name, suffix)) hints.insert(.unreal);
    }
    return hints;
}

const tests = struct {
    const testing = std.testing;

    fn scoreOf(path: []const u8, modules: []const []const u8) i32 {
        var hints = hintsOfPath(path);
        for (modules) |m| if (hintOfModule(m)) |h| hints.insert(h);
        return score(hints, true);
    }

    test "ranking" {
        const game = scoreOf("D:\\SteamLibrary\\steamapps\\common\\Kai\\Kai.exe", &.{ "kernel32.dll", "UnityPlayer.dll", "d3d11.dll", "steam_api64.dll", "fmodstudio.dll" });
        const unreal = scoreOf("C:\\Games\\Kai\\Binaries\\Win64\\Kai-Win64-Shipping.exe", &.{"d3d12.dll"});
        const renders = scoreOf("C:\\Program Files\\Paint\\paint.exe", &.{ "d3d11.dll", "d3d12.dll" });
        const browser = scoreOf("C:\\Program Files\\Browser\\browser.exe", &.{ "chrome_elf.dll", "d3d11.dll", "xinput1_4.dll" });
        const plain = scoreOf("C:\\Windows\\notepad.exe", &.{"kernel32.dll"});
        try testing.expect(game > unreal);
        try testing.expect(unreal > renders);
        try testing.expect(renders > plain);
        try testing.expect(plain > browser);
    }

    test "epic launcher isn't a game" {
        try testing.expect(!hintsOfPath("C:\\Program Files (x86)\\Epic Games\\Launcher\\Portal\\Binaries\\Win64\\EpicGamesLauncher.exe").contains(.epic));
        try testing.expect(hintsOfPath("C:\\Program Files\\Epic Games\\Kai\\Kai.exe").contains(.epic));
    }

    test "listing processes" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const found = try list(arena.allocator(), testing.io, .{ .all = true });
        if (found.len < 2) return;
        for (found[1..], found[0 .. found.len - 1]) |b, a| try testing.expect(a.score >= b.score);
    }
};

test {
    _ = tests;
}
