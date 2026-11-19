//! The game the runtime got injected into.

const GameInfo = @This();

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const core = @import("wraith_core");
const wraith_platform = @import("wraith_platform");
const games = @import("wraith_game");
const tuft_sys = @import("tuft_sys");
const memory = @import("tuft_mem");

const log = core.log.scoped(.wraith_runtime);

pub const HashState = enum(u8) { idle, hashing, done, failed };

path_buf: [1024]u8 = undefined,
path_len: usize = 0,
id_buf: [256]u8 = undefined,
id_len: usize = 0,
store: games.Store = .local,
title_buf: [256]u8 = undefined,
title_len: usize = 0,
version: ?tuft_sys.version.Versions = null,
hash_state: Atomic(HashState) = .init(.idle),
/// Valid once `hash_state` is `done`.
digest: [64]u8 = undefined,
hash_ns: u64 = 0,
cancel: Atomic(bool) = .init(false),
thread: ?std.Thread = null,

pub var global: GameInfo = .{};

pub fn start(self: *GameInfo, allocator: std.mem.Allocator, io: std.Io) void {
    self.* = .{};
    const exe = memory.Module.main().path(&self.path_buf) orelse {
        log.warn("Couldn't find the game's executable", .{});
        return;
    };
    self.path_len = exe.len;
    self.identify(allocator, io);
    self.version = versionsOf(allocator, exe) catch |err| blk: {
        log.warn("Couldn't read the game's version: {t}", .{err});
        break :blk null;
    };
    if (self.version) |v| {
        log.info("Game: {s} (file version {f}, product version {f})", .{ self.name(), v.file, v.product });
    } else {
        log.info("Game: {s} (no version resource)", .{self.name()});
    }

    self.hash_state.store(.hashing, .release);
    self.thread = std.Thread.spawn(.{}, hashInBackground, .{ self, io }) catch |err| {
        log.warn("Couldn't hash the game's executable: {t}", .{err});
        self.hash_state.store(.failed, .release);
        return;
    };
}

fn versionsOf(allocator: std.mem.Allocator, exe: []const u8) !?tuft_sys.version.Versions {
    var info = (try tuft_sys.version.fileInfo(allocator, exe)) orelse return null;
    defer info.deinit(allocator);
    return info.versions;
}

/// Runs on an `Io` worker since it reads files and game threads may have little stack.
fn identify(self: *GameInfo, allocator: std.mem.Allocator, io: std.Io) void {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const found = identifyOnWorker(a, io, self.path()) catch |err| fallback: {
        log.warn("Couldn't identify the game ({t}): taking it as a local one", .{err});
        break :fallback games.local(a, self.path()) catch return;
    };
    if (found.id.len > self.id_buf.len) return log.warn("The game's ID is too long: {s}", .{found.id});
    @memcpy(self.id_buf[0..found.id.len], found.id);
    self.id_len = found.id.len;
    self.store = found.store;
    const store_name = found.name orelse "";
    self.title_len = @min(store_name.len, self.title_buf.len);
    @memcpy(self.title_buf[0..self.title_len], store_name[0..self.title_len]);
    log.info("Game ID: {s}{s}{s}", .{ self.id(), if (store_name.len > 0) ", " else "", self.title() });
}

fn identifyOnWorker(arena: std.mem.Allocator, io: std.Io, exe: []const u8) !games.Game {
    var identifying = try io.concurrent(games.identify, .{ arena, io, exe, .{} });
    return identifying.await(io);
}

pub fn stop(self: *GameInfo) void {
    self.cancel.store(true, .monotonic);
    if (self.thread) |t| t.join();
    self.thread = null;
}

pub fn path(self: *const GameInfo) []const u8 {
    return self.path_buf[0..self.path_len];
}

pub fn name(self: *const GameInfo) []const u8 {
    return std.fs.path.basename(self.path());
}

/// Like `steam-1245620`, or `unknown` if the exe wasn't found.
pub fn id(self: *const GameInfo) []const u8 {
    return if (self.id_len == 0) "unknown" else self.id_buf[0..self.id_len];
}

pub fn title(self: *const GameInfo) []const u8 {
    return self.title_buf[0..self.title_len];
}

pub fn hash(self: *const GameInfo) ?*const [64]u8 {
    return if (self.hash_state.load(.acquire) == .done) &self.digest else null;
}

fn hashInBackground(self: *GameInfo, io: std.Io) void {
    const started = core.timing.now();
    self.digest = wraith_platform.fs.sha512File(io, self.path(), &self.cancel) catch |err| {
        if (err != error.Canceled) log.warn("Couldn't hash the game's executable: {t}", .{err});
        self.hash_state.store(.failed, .release);
        return;
    };
    self.hash_ns = core.timing.now() -| started;
    self.hash_state.store(.done, .release);
    log.debug("Game sha-512: {s}", .{&std.fmt.bytesToHex(self.digest, .lower)});
}

test "identifies and hashes the exe" {
    const io = std.testing.io;
    const saved = core.log.mute(&.{.runtime});
    defer core.log.setFilter(saved);

    var info: GameInfo = .{};
    info.start(std.testing.allocator, io);
    defer info.stop();
    try std.testing.expect(std.ascii.endsWithIgnoreCase(info.name(), ".exe"));

    while (info.hash_state.load(.acquire) == .hashing) io.sleep(.fromMilliseconds(1), .awake) catch {};
    const expected = try wraith_platform.fs.sha512File(io, info.path(), null);
    try std.testing.expectEqualSlices(u8, &expected, info.hash().?);
}
