//! Spots anti-cheat so the launcher can warn. Wraith doesn't refuse.

const std = @import("std");

const inject = @import("tuft_inject");
const sys = @import("tuft_sys");

pub const Product = enum {
    easy_anti_cheat,
    battleye,
    vanguard,
    hoyoverse,
    ea_anticheat,
    faceit,
    esea,
    gameguard,
    xigncode,
    ricochet,
    anti_cheat_expert,
    punkbuster,
    netease_security,
    netease_yidun,
    denuvo,
    vac,
    blackcipher,
    anybrain,
    hackshield,
    tenprotect,
    equ8,
    fredaikis,
    roblox,
    warframe,

    pub fn label(p: Product) []const u8 {
        return switch (p) {
            .easy_anti_cheat => "Easy Anti-Cheat",
            .battleye => "BattlEye",
            .vanguard => "Riot Vanguard",
            .hoyoverse => "HoYoverse anti-cheat",
            .ea_anticheat => "EA Javelin",
            .faceit => "FACEIT",
            .esea => "ESEA",
            .gameguard => "nProtect GameGuard",
            .xigncode => "XIGNCODE3",
            .ricochet => "Ricochet",
            .anti_cheat_expert => "Anti-Cheat Expert (ACE)",
            .punkbuster => "PunkBuster",
            .netease_security => "NetEase Security",
            .netease_yidun => "NetEase Yidun",
            .denuvo => "Denuvo Anti-Cheat",
            .vac => "Valve Anti-Cheat",
            .blackcipher => "BlackCipher",
            .anybrain => "AnyBrain",
            .hackshield => "HackShield",
            .tenprotect => "TenProtect",
            .equ8 => "EQU8",
            .fredaikis => "Fredaikis Anti-Cheat",
            .roblox => "Roblox Anti-Cheat",
            .warframe => "Warframe Anti-Cheat",
        };
    }

    pub fn jsonStringify(p: Product, jw: anytype) !void {
        try jw.write(.{ .id = @tagName(p), .label = p.label() });
    }

    pub fn of(name: []const u8) ?Product {
        const exact = [_]struct { []const u8, Product }{
            .{ "start_protected_game.exe", .easy_anti_cheat },
            .{ "eac_launcher.exe", .easy_anti_cheat },
            .{ "battleye", .battleye },
            .{ "beclient.dll", .battleye },
            .{ "beclient_x64.dll", .battleye },
            .{ "bedaisy.sys", .battleye },
            .{ "beservice.exe", .battleye },
            .{ "beservice_x64.exe", .battleye },
            .{ "vgk.sys", .vanguard },
            .{ "vgc.exe", .vanguard },
            .{ "hoyokprotect.sys", .hoyoverse },
            .{ "hoyo_kprotect.sys", .hoyoverse },
            .{ "randgrid.sys", .ricochet },
            .{ "faceitclient.dll", .faceit },
            .{ "faceit.sys", .faceit },
            .{ "eseaclient.dll", .esea },
            .{ "npggnt.sys", .gameguard },
            .{ "npggnt64.sys", .gameguard },
            .{ "x3.xem", .xigncode },
            .{ "xnina.xem", .xigncode },
            .{ "xhunter1.sys", .xigncode },
            .{ "ace-base.dat", .anti_cheat_expert },
            .{ "ace-base.sys", .anti_cheat_expert },
            .{ "ace-base64.sys", .anti_cheat_expert },
            .{ "ace-core.sys", .anti_cheat_expert },
            .{ "ace-service64.exe", .anti_cheat_expert },
            .{ "ace-setup64.exe", .anti_cheat_expert },
            .{ "pbag.dll", .punkbuster },
            .{ "pbcl.dll", .punkbuster },
            .{ "pbsv.dll", .punkbuster },
            .{ "pbsvc.exe", .punkbuster },
            .{ "nep2.dll", .netease_yidun },
            .{ "denuvo-anti-cheat.sys", .denuvo },
            .{ "blackcat64.sys", .blackcipher },
            .{ "anybrainsdk.dll", .anybrain },
            .{ "3n.mhe", .hackshield },
            .{ "hshield.dat", .hackshield },
            .{ "asc_main.dll", .hackshield },
            .{ "tp3gameguard.dll", .tenprotect },
            .{ "tp3gameguard64.dll", .tenprotect },
            .{ "tenproxy64.dll", .tenprotect },
            .{ "equ8.db", .equ8 },
            .{ "equ8_conf.json", .equ8 },
            .{ "equ8-launcher.exe", .equ8 },
            .{ "robloxplayer.exe", .roblox },
            .{ "robloxplayerbeta.exe", .roblox },
            .{ "robloxplayer.dll", .roblox },
            .{ "robloxplayerbeta.dll", .roblox },
            .{ "warframe.x64.exe", .warframe },
        };
        for (exact) |e| if (std.ascii.eqlIgnoreCase(name, e[0])) return e[1];
        const within = [_]struct { []const u8, Product }{
            .{ "easyanticheat", .easy_anti_cheat },
            .{ "eaanticheat", .ea_anticheat },
            .{ "eajavelin", .ea_anticheat },
            .{ "mhyprot", .hoyoverse },
            .{ "anticheatexpert", .anti_cheat_expert },
            .{ "blackcipher", .blackcipher },
            .{ "anybrain", .anybrain },
            .{ "tenprotect", .tenprotect },
            .{ "equ8_client", .equ8 },
            .{ "fredaikisanticheat", .fredaikis },
        };
        for (within) |w| if (std.ascii.findIgnoreCase(name, w[0]) != null) return w[1];
        return null;
    }

    /// For drivers known by path. NetEase's loads from a temp folder as `NEP<random>.sys`.
    pub fn ofDriverPath(path: []const u8) ?Product {
        const file = path[(std.mem.lastIndexOfAny(u8, path, "\\/") orelse return null) + 1 ..];
        const dir = path[0 .. path.len - file.len - 1];
        const parent = dir[if (std.mem.lastIndexOfAny(u8, dir, "\\/")) |i| i + 1 else 0..];
        if (std.ascii.eqlIgnoreCase(parent, "temp") and std.ascii.startsWithIgnoreCase(file, "nep")) return .netease_security;
        return null;
    }
};

pub const Found = struct {
    product: Product,
    file: []const u8,
};

pub const List = struct {
    items: std.ArrayList(Found) = .empty,

    pub fn check(self: *List, arena: std.mem.Allocator, name: []const u8) !void {
        try self.add(arena, Product.of(name) orelse return, name);
    }

    pub fn add(self: *List, arena: std.mem.Allocator, product: Product, file: []const u8) !void {
        for (self.items.items) |f| if (f.product == product) return;
        try self.items.append(arena, .{ .product = product, .file = try arena.dupe(u8, file) });
    }

    pub fn addTagged(self: *List, arena: std.mem.Allocator, product: ?Product) !void {
        try self.add(arena, product orelse return, "Wraith's list of known games");
    }
};

const max_entries = 4096;

/// For Unreal games also checks the project folder and the one above.
pub fn ofGame(arena: std.mem.Allocator, io: std.Io, exe: []const u8, into: *List) !void {
    // Windows' own programs have thousands of files and no anti-cheat
    if (exe.len > 2 and std.ascii.startsWithIgnoreCase(exe[1..], ":\\windows\\")) return;
    var dir = std.fs.path.dirname(exe) orelse return;
    try ofFolder(arena, io, dir, into);
    const binaries = std.ascii.findIgnoreCase(dir, "\\binaries\\win") orelse return;
    dir = dir[0..binaries];
    try ofFolder(arena, io, dir, into);
    if (std.fs.path.dirname(dir)) |above| try ofFolder(arena, io, above, into);
}

const install_depth = 3;
const install_entries = 20_000;

pub fn ofInstall(arena: std.mem.Allocator, io: std.Io, dir: []const u8, into: *List) !void {
    var budget: usize = install_entries;
    try walkInstall(arena, io, dir, 0, &budget, into);
}

fn walkInstall(arena: std.mem.Allocator, io: std.Io, path: []const u8, depth: usize, budget: *usize, into: *List) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch return) |entry| {
        if (budget.* == 0) return;
        budget.* -= 1;
        const known = into.items.items.len;
        try into.check(arena, entry.name);
        // Skip anti-cheat's own folder, it's already found, and redist stuff
        if (entry.kind != .directory or depth == install_depth or into.items.items.len != known or isRedist(entry.name)) continue;
        try walkInstall(arena, io, try std.fs.path.join(arena, &.{ path, entry.name }), depth + 1, budget, into);
    }
}

fn isRedist(name: []const u8) bool {
    const redist = [_][]const u8{ "_CommonRedist", "CommonRedist", "Redist", "_Redist", "Redistributables", "__Installer", "DirectX", "vcredist", "Prerequisites" };
    for (redist) |r| if (std.ascii.eqlIgnoreCase(name, r)) return true;
    return false;
}

test ofInstall {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "Game\\EasyAntiCheat");
    try tmp.dir.createDirPath(io, "Proj\\Binaries\\Win64\\BattlEye");
    try tmp.dir.createDirPath(io, "a\\b\\c\\d\\EasyAntiCheat_EOS");
    try tmp.dir.createDirPath(io, "_CommonRedist\\vgc.exe");
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var list: List = .{};
    try ofInstall(arena.allocator(), io, root, &list);
    // Skips stuff that's too deep or in redistributables
    try testing.expectEqual(2, list.items.items.len);
    for (list.items.items) |f| try testing.expect(f.product == .easy_anti_cheat or f.product == .battleye);
}

fn ofFolder(arena: std.mem.Allocator, io: std.Io, path: []const u8, into: *List) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    var n: usize = 0;
    while (it.next(io) catch return) |entry| : (n += 1) {
        if (n == max_entries) return;
        try into.check(arena, entry.name);
    }
}

pub fn ofModules(arena: std.mem.Allocator, pid: u32, into: *List) !void {
    var modules = inject.Modules.init(pid) catch return;
    defer modules.deinit();
    while (modules.next()) |m| try into.check(arena, m.name);
}

pub fn system(arena: std.mem.Allocator) ![]const Found {
    var list: List = .{};
    var processes = try inject.Processes.init();
    defer processes.deinit();
    while (processes.next()) |p| try list.check(arena, p.name);
    // Some drivers only give themselves away by where their file is
    for (try sys.drivers.runningAlloc(arena)) |name| {
        try list.check(arena, name);
        try list.check(arena, try std.mem.concat(arena, u8, &.{ name, ".sys" }));
        const path = try driverPath(arena, name) orelse continue;
        if (Product.ofDriverPath(path)) |product| try list.add(arena, product, path);
    }
    return list.items.items;
}

fn driverPath(arena: std.mem.Allocator, name: []const u8) !?[]const u8 {
    const key_path = try std.mem.concat(arena, u8, &.{ "SYSTEM\\CurrentControlSet\\Services\\", name });
    const key = try sys.registry.Key.open(.local_machine, key_path, .native) orelse return null;
    defer key.close();
    return key.stringAlloc(arena, "ImagePath");
}

const tests = struct {
    const testing = std.testing;

    test "known by file name" {
        try testing.expectEqual(.battleye, Product.of("BEClient_x64.dll"));
        try testing.expectEqual(.easy_anti_cheat, Product.of("EasyAntiCheat_EOS.sys"));
        try testing.expectEqual(.easy_anti_cheat, Product.of("EasyAntiCheat"));
        try testing.expectEqual(.hoyoverse, Product.of("mhyprot2.sys"));
        try testing.expectEqual(.hoyoverse, Product.of("HoYoKProtect.sys"));
        try testing.expectEqual(.ea_anticheat, Product.of("EAAntiCheat.GameServiceLauncher.dll"));
        try testing.expectEqual(.vanguard, Product.of("vgk.sys"));
        try testing.expectEqual(.xigncode, Product.of("x3.xem"));
        try testing.expectEqual(null, Product.of("d3d11.dll"));
        try testing.expectEqual(null, Product.of("BEClient_x64.dll.bak"));
    }

    test "NetEase driver" {
        try testing.expectEqual(.netease_security, Product.ofDriverPath("\\??\\C:\\Users\\kai\\AppData\\Local\\Temp\\NEP2A1F.sys"));
        try testing.expectEqual(.netease_security, Product.ofDriverPath("C:\\Windows\\TEMP\\nep3.sys"));
        try testing.expectEqual(null, Product.ofDriverPath("\\SystemRoot\\System32\\drivers\\NEP.sys"));
        try testing.expectEqual(null, Product.ofDriverPath("C:\\Temp\\other.sys"));
        try testing.expectEqual(null, Product.ofDriverPath("NEP.sys"));
    }

    test "game folder anti-cheat" {
        const allocator = testing.allocator;
        const io = testing.io;
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        // One game with both, so both places get looked at
        try tmp.dir.createDirPath(io, "EasyAntiCheat");
        try tmp.dir.createDirPath(io, "Kai\\Binaries\\Win64");
        try tmp.dir.writeFile(io, .{ .sub_path = "Kai\\Binaries\\Win64\\HoYoKProtect.sys", .data = "" });
        const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(root);
        const exe = try std.fs.path.join(allocator, &.{ root, "Kai\\Binaries\\Win64\\Kai-Win64-Shipping.exe" });
        defer allocator.free(exe);

        var list: List = .{};
        try ofGame(arena.allocator(), io, exe, &list);
        try testing.expectEqual(2, list.items.items.len);
        try testing.expectEqual(.hoyoverse, list.items.items[0].product);
        try testing.expectEqual(.easy_anti_cheat, list.items.items[1].product);
    }

    test "system check" {
        // Asks Windows for every process and driver. A CI runner that's still starting up can sit on
        // that for minutes, so it gets a while and is skipped after
        const Check = struct {
            done: std.atomic.Value(bool) = .init(false),
            failed: ?anyerror = null,

            fn run(self: *@This()) void {
                var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
                defer arena.deinit();
                _ = system(arena.allocator()) catch |err| {
                    self.failed = err;
                };
                self.done.store(true, .release);
            }
        };
        const check = try std.heap.page_allocator.create(Check);
        check.* = .{};
        const thread = try std.Thread.spawn(.{}, Check.run, .{check});
        var waited: u32 = 0;
        while (!check.done.load(.acquire)) : (waited += 1) {
            // Left running, and `check` with it, since it's still using both
            if (waited == 3000) {
                thread.detach();
                return error.SkipZigTest;
            }
            sys.win.Sleep(10);
        }
        thread.join();
        defer std.heap.page_allocator.destroy(check);
        if (check.failed) |err| return err;
    }
};

test {
    _ = tests;
}
