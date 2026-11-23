//! itch.io, from the `.itch\receipt.json.gz` butler leaves, and the itch app's database for listing
//! what's installed.

const std = @import("std");

const platform = @import("wraith_platform");

const game = @import("root.zig");
const fs = @import("fs.zig");
const sqlite = @import("sqlite.zig");

pub const store: game.Store = .itch;

/// Each installed game, from a copy of the itch app's database, since the app keeps it open.
pub fn discover(arena: std.mem.Allocator, io: std.Io, options: game.Options, into: *std.ArrayList(game.Game)) !void {
    const roaming = if (options.app_data) |d| d.roaming else try platform.process.envAlloc(arena, "APPDATA") orelse return;
    const db_dir = try std.fs.path.join(arena, &.{ roaming, "itch", "db" });
    if (!fs.exists(io, try std.fs.path.join(arena, &.{ db_dir, "butler.db" }))) return;

    var name: [16]u8 = undefined;
    io.random(&name);
    const copy_dir = try std.fs.path.join(arena, &.{ try platform.fs.tempDirAlloc(arena), try std.fmt.allocPrint(arena, "wraith-itch-{x}", .{name[0..8]}) });
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, copy_dir);
    defer cwd.deleteTree(io, copy_dir) catch {};
    var from = try cwd.openDir(io, db_dir, .{});
    defer from.close(io);
    var to = try cwd.openDir(io, copy_dir, .{});
    defer to.close(io);
    // Changes not yet in the database are in the -wal beside it
    for ([_][]const u8{ "butler.db", "butler.db-wal", "butler.db-shm" }) |file| {
        from.copyFile(file, to, file, io, .{}) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    const db = try sqlite.Db.open(try std.fs.path.joinZ(arena, &.{ copy_dir, "butler.db" }), .{});
    defer db.close();
    try fromDb(arena, io, db, into);
}

fn fromDb(arena: std.mem.Allocator, io: std.Io, db: sqlite.Db, into: *std.ArrayList(game.Game)) !void {
    const caves = try db.prepare(
        \\SELECT c.game_id, g.title, c.custom_install_folder, l.path, c.install_folder_name
        \\FROM caves c JOIN games g ON g.id = c.game_id LEFT JOIN install_locations l ON l.id = c.install_location_id
        \\WHERE g.classification = 'game'
    );
    defer caves.deinit();
    while (try caves.step()) {
        const custom = try caves.text(arena, 2) orelse "";
        const dir = if (custom.len > 0) custom else blk: {
            const location = try caves.text(arena, 3) orelse continue;
            const folder = try caves.text(arena, 4) orelse continue;
            break :blk try std.fs.path.join(arena, &.{ location, folder });
        };
        if (!fs.exists(io, dir)) continue;
        try into.append(arena, .{
            .id = try game.id(arena, .itch, try std.fmt.allocPrint(arena, "{d}", .{caves.int(0)})),
            .store = .itch,
            .name = try caves.text(arena, 1),
            .dir = std.mem.trimEnd(u8, dir, "\\/"),
        });
    }
}

test "installed games from the itch app's tables" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    try tmp.dir.createDirPath(testing.io, "apps/celeste");
    try tmp.dir.createDirPath(testing.io, "elsewhere/skate");

    const db = try sqlite.Db.open(try std.fs.path.joinZ(a, &.{ root, "butler.db" }), .{ .create = true });
    defer db.close();
    const setup = try std.fmt.allocPrintSentinel(a,
        \\CREATE TABLE games (id INTEGER, title TEXT, classification TEXT);
        \\CREATE TABLE install_locations (id TEXT, path TEXT);
        \\CREATE TABLE caves (game_id INTEGER, custom_install_folder TEXT, install_location_id TEXT, install_folder_name TEXT);
        \\INSERT INTO games VALUES (31318, 'Celeste Classic', 'game'), (2, 'Skate', 'game'), (3, 'Gone', 'game'), (4, 'Some Tool', 'tool');
        \\INSERT INTO install_locations VALUES ('loc', '{s}');
        \\INSERT INTO caves VALUES (31318, '', 'loc', 'celeste'), (2, '{s}', NULL, NULL), (3, '', 'loc', 'gone'), (4, '', 'loc', 'celeste');
    , .{ try std.fs.path.join(a, &.{ root, "apps" }), try std.fs.path.join(a, &.{ root, "elsewhere", "skate" }) }, 0);
    var rest: []const u8 = setup;
    while (std.mem.indexOfScalar(u8, rest, ';')) |end| : (rest = rest[end + 1 ..]) {
        const s = try db.prepare(try std.fmt.allocPrintSentinel(a, "{s}", .{rest[0..end]}, 0));
        defer s.deinit();
        _ = try s.step();
    }

    var found: std.ArrayList(game.Game) = .empty;
    try fromDb(a, testing.io, db, &found);
    try testing.expectEqual(2, found.items.len);
    try testing.expectEqualStrings("itch-31318", found.items[0].id);
    try testing.expectEqualStrings("Celeste Classic", found.items[0].name.?);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ root, "apps", "celeste" }), found.items[0].dir);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ root, "elsewhere", "skate" }), found.items[1].dir);
}

pub fn identify(arena: std.mem.Allocator, io: std.Io, exe: []const u8, _: game.Options) !?game.Game {
    var dirs = fs.ancestors(exe, fs.max_depth);
    while (dirs.next()) |dir| {
        const path = try std.fs.path.join(arena, &.{ dir, ".itch", "receipt.json.gz" });
        const compressed = try fs.read(arena, io, path) orelse continue;
        const text = gunzip(arena, compressed) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        const receipt = std.json.parseFromSliceLeaky(Receipt, arena, text, .{ .ignore_unknown_fields = true }) catch continue;
        const g = receipt.game orelse continue;
        const key = try std.fmt.allocPrint(arena, "{d}", .{g.id});
        return .{ .id = try game.id(arena, .itch, key), .store = .itch, .name = g.title, .dir = dir };
    }
    return null;
}

const Receipt = struct {
    game: ?struct {
        id: u64,
        title: ?[]const u8 = null,
    } = null,
};

fn gunzip(arena: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(compressed);
    const window = try arena.alloc(u8, std.compress.flate.max_window_len);
    var gzip: std.compress.flate.Decompress = .init(&in, .gzip, window);
    return gzip.reader.allocRemaining(arena, .limited(fs.max_file)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidReceipt,
    };
}
