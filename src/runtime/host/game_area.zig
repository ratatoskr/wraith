//! The `game` area: what Wraith knows about the game it's in, from `GameInfo`, the overlay and the
//! build, and how fast it runs. Nothing here reads files, so it's cheap from any thread.

const std = @import("std");

const api = @import("wraith_api");
const build_info = @import("build_info");
const tuft_sys = @import("tuft_sys");
const Owner = @import("tuft_event").Owner;

const GameInfo = @import("../GameInfo.zig");
const speed_ = @import("../speed/root.zig");
const OnGone = @import("Owned.zig").OnGone;
const host = @import("root.zig");
const scratch = @import("scratch.zig");
const wraith = @import("wraith.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;

const sal = api.salamander;
const W = api.wraith;

pub const Game = W.Game;

const allocator = std.heap.page_allocator;

const HashPromise = sal.Plain(Game, "sha512");
const HashResolver = wraith.ResolverOf(HashPromise);

/// Who set the speed last, so it goes back to 1 when they go. Null for the player.
var setter: ?*Owner = null;
var speed_lock: tuft_sys.sync.RwLock = .{};
var speed_cleanup: OnGone(.closing, speedSetterGone) = .{};

fn speedSetterGone(owner: *Owner) void {
    speed_lock.lock();
    defer speed_lock.unlock();
    if (setter != owner) return;
    setter = null;
    speed_.set(1) catch {};
}

/// For Wraith's own settings and keys, which are the player's rather than a plugin's.
pub fn setSpeedForPlayer(s: f64) !void {
    speed_lock.lock();
    defer speed_lock.unlock();
    try speed_.set(s);
    setter = null;
}

pub const Impl = struct {
    pub fn info(_: *Loaded) W.GameInfo {
        const g = &GameInfo.global;
        const a = scratch.begin();
        var out: W.GameInfo = .{
            .id = g.id(),
            .store = @tagName(g.store),
            .title = g.title(),
            .build = g.build(),
            .exe = g.path(),
            .dir = std.fs.path.dirname(g.path()) orelse "",
            .game_engine = if (g.game_engine) |e| @tagName(e) else "",
            .game_engine_variant = g.engineVariant(),
            .game_engine_version = g.engineVersion(),
            .graphics_api = host.ui.graphicsApiName() orelse "",
            .window = host.ui.gameWindow(),
            .wraith_version = build_info.version,
        };
        if (g.version) |v| {
            out.file_version = std.fmt.allocPrint(a, "{f}", .{v.file}) catch "";
            out.product_version = std.fmt.allocPrint(a, "{f}", .{v.product}) catch "";
        }
        const found = g.anticheat();
        const list = a.alloc(W.AntiCheat, found.len) catch return out;
        for (list, found) |*item, product| item.* = .{ .id = @tagName(product), .name = product.label() };
        out.anticheat = list;
        return out;
    }

    pub fn speed(_: *Loaded) f64 {
        return speed_.get();
    }

    pub fn setSpeed(loaded: *Loaded, s: f64) sal.Plain(Game, "setSpeed") {
        const lease = speed_cleanup.lease(&loaded.owner) orelse return error.Failed;
        defer lease.end();
        speed_lock.lock();
        defer speed_lock.unlock();
        speed_.set(s) catch return error.Failed;
        setter = &loaded.owner;
    }

    pub fn sha512(loaded: *Loaded) HashPromise {
        const pair = HashPromise.make() catch return .{};
        const t = wraith.tablesOf(loaded) orelse {
            pair.resolver.drop();
            return pair.promise;
        };
        switch (GameInfo.global.hash_state.load(.acquire)) {
            .done => settleHash(pair.resolver),
            .idle, .failed => pair.resolver.fail(error.Failed),
            .hashing => {
                const job = allocator.create(HashWait) catch {
                    pair.resolver.fail(error.Failed);
                    return pair.promise;
                };
                job.* = .{ .owner = t.owner, .resolver = pair.resolver };
                const thread = std.Thread.spawn(.{}, HashWait.run, .{job}) catch {
                    allocator.destroy(job);
                    pair.resolver.fail(error.Failed);
                    return pair.promise;
                };
                thread.detach();
            },
        }
        return pair.promise;
    }
};

fn settleHash(r: HashResolver) void {
    const digest = GameInfo.global.hash() orelse return r.fail(error.Failed);
    const hex = std.fmt.bytesToHex(digest.*, .lower);
    r.settle(r.hold(&hex) catch return r.fail(error.Failed));
}

/// Waits off the caller's thread till the hash is worked out. Gives up once the plugin's gone.
const HashWait = struct {
    owner: *sal.Owner,
    resolver: HashResolver,

    fn run(job: *HashWait) void {
        defer allocator.destroy(job);
        while (GameInfo.global.hash_state.load(.acquire) == .hashing) {
            if (!job.owner.enter()) return job.resolver.drop();
            job.owner.leave();
            tuft_sys.thread.sleepMs(20);
        }
        if (!job.owner.enter()) return job.resolver.drop();
        defer job.owner.leave();
        if (GameInfo.global.hash_state.load(.acquire) != .done) return job.resolver.fail(error.Failed);
        settleHash(job.resolver);
    }
};

test "a plugin asks about the game" {
    const testing = std.testing;
    const sdk = @import("wraith_sdk");
    const core = @import("wraith_core");
    const saved = core.log.mute(&.{.runtime});
    defer core.log.setFilter(saved);
    GameInfo.global.start(testing.allocator, testing.io);
    defer GameInfo.global.stop();
    var loaded: Loaded = undefined;
    loaded.initForTest(testing.allocator, "kai");
    sdk.Owner.attach(loaded.root());
    defer sdk.Owner.detach();

    const game = sdk.wraith.root().?.game();
    const info = game.info();
    try testing.expectEqualStrings(GameInfo.global.path(), info.exe);
    try testing.expect(std.ascii.endsWithIgnoreCase(info.exe, ".exe"));
    try testing.expectEqualStrings(std.fs.path.dirname(info.exe).?, info.dir);
    try testing.expectEqualStrings(build_info.version, info.wraith_version);
    // No overlay in tests
    try testing.expectEqualStrings("", info.graphics_api);
    try testing.expectEqual(0, info.window);

    // Waits for it if it's still working it out
    const hex = try game.sha512().wait();
    const expected = std.fmt.bytesToHex(GameInfo.global.hash().?.*, .lower);
    try testing.expectEqualStrings(&expected, hex);

    loaded.deinitForTest();
    wraith.forget(&loaded);
}
