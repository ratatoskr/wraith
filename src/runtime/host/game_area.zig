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

/// The speed asked for, which `speed` gives. Under `speed_lock`, like the rest.
var wanted: f64 = 1;
/// Who set the speed last, so it goes back to 1 when they go. Null for the player.
var setter: ?*Owner = null;
/// A plugin's own way of changing the speed, asked first.
const Provider = struct { owner: *Owner, handler: W.SpeedHandler };
var provider: ?Provider = null;
var speed_lock: tuft_sys.sync.RwLock = .{};
var speed_cleanup: OnGone(.closing, speedOwnerGone) = .{};

fn speedOwnerGone(owner: *Owner) void {
    speed_lock.lock();
    defer speed_lock.unlock();
    var changed = false;
    if (provider) |p| if (p.owner == owner) {
        p.handler.release();
        provider = null;
        changed = true;
    };
    if (setter == owner) {
        setter = null;
        wanted = 1;
        changed = true;
    }
    if (changed) apply() catch {};
}

/// The provider if it takes it, else the clocks, which can't go below their minimum. Needs `speed_lock`.
/// `wanted` stays as asked, so a provider that comes back still gets a pause.
fn apply() !void {
    if (provider) |p| if (p.handler.invoke(.{wanted})) {
        try speed_.set(1);
        return;
    };
    try speed_.set(@max(wanted, speed_.min));
}

fn setLocked(s: f64, owner: ?*Owner) !void {
    const before = wanted;
    wanted = std.math.clamp(s, 0, speed_.max);
    apply() catch |err| {
        wanted = before;
        return err;
    };
    setter = owner;
    if (wanted != 0) resume_to = wanted;
}

/// What unpausing goes back to.
var resume_to: f64 = 1;

/// For Wraith's own settings and keys, which are the player's rather than a plugin's.
pub fn setSpeedForPlayer(s: f64) !void {
    speed_lock.lock();
    defer speed_lock.unlock();
    try setLocked(s, null);
}

/// Pausing is speed 0, and unpausing goes back to the speed from before.
pub fn setPausedForPlayer(on: bool) !void {
    speed_lock.lock();
    defer speed_lock.unlock();
    if (on == (wanted == 0)) return;
    try setLocked(if (on) 0 else resume_to, null);
}

pub fn paused() bool {
    return currentSpeed() == 0;
}

/// What it's at, as asked for.
pub fn currentSpeed() f64 {
    speed_lock.lockShared();
    defer speed_lock.unlockShared();
    return wanted;
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
        return currentSpeed();
    }

    pub fn setSpeed(loaded: *Loaded, s: f64) sal.Plain(Game, "setSpeed") {
        const lease = speed_cleanup.lease(&loaded.owner) orelse return error.Failed;
        defer lease.end();
        speed_lock.lock();
        defer speed_lock.unlock();
        setLocked(s, &loaded.owner) catch return error.Failed;
    }

    pub fn provideSpeed(loaded: *Loaded, handler: W.SpeedHandler) void {
        const lease = speed_cleanup.lease(&loaded.owner) orelse return handler.release();
        defer lease.end();
        speed_lock.lock();
        defer speed_lock.unlock();
        if (provider) |old| old.handler.release();
        provider = .{ .owner = &loaded.owner, .handler = handler };
        apply() catch {};
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

test "a plugin that provides speed gets it first, and the clocks carry on once it's gone" {
    const testing = std.testing;
    const sdk = @import("wraith_sdk");
    const tuft_hook = @import("tuft_hook");
    try tuft_hook.init(testing.allocator);
    defer tuft_hook.deinit();
    defer speed_.stop();
    var loaded: Loaded = undefined;
    loaded.initForTest(testing.allocator, "engine");
    sdk.Owner.attach(loaded.root());
    defer sdk.Owner.detach();

    const State = struct {
        got: f64 = -1,
        takes: bool = true,
        fn handle(self: *@This(), s: f64) bool {
            self.got = s;
            return self.takes;
        }
    };
    var state: State = .{};
    const game = sdk.wraith.root().?.game();
    game.provideSpeed(W.SpeedHandler.init(&state, State.handle));
    // Told straight away
    try testing.expectEqual(1, state.got);

    // It pauses, and the clocks aren't touched
    try game.setSpeed(0);
    try testing.expectEqual(0, state.got);
    try testing.expectEqual(0, game.speed());
    try testing.expectEqual(1, speed_.get());

    // One it won't do goes to the clocks
    state.takes = false;
    try game.setSpeed(0.5);
    try testing.expectEqual(0.5, speed_.get());
    state.takes = true;

    // The player's speed stays once the provider's gone, on the clocks now
    try setSpeedForPlayer(3);
    try testing.expectEqual(3, state.got);
    try testing.expectEqual(1, speed_.get());
    loaded.deinitForTest();
    wraith.forget(&loaded);
    try testing.expectEqual(3, speed_.get());
    try testing.expectEqual(3, currentSpeed());
    try setSpeedForPlayer(1);
}

test "pausing goes back to the speed from before, and stays a pause on the clocks" {
    const testing = std.testing;
    const tuft_hook = @import("tuft_hook");
    try tuft_hook.init(testing.allocator);
    defer tuft_hook.deinit();
    defer speed_.stop();
    defer setSpeedForPlayer(1) catch {};
    try setSpeedForPlayer(2.5);
    try setPausedForPlayer(true);
    try testing.expect(paused());
    // The clocks can't stop, but what was asked for is still a pause
    try testing.expectEqual(speed_.min, speed_.get());
    try testing.expectEqual(0, currentSpeed());
    try setPausedForPlayer(false);
    try testing.expectEqual(2.5, currentSpeed());
    // Sliding it to 0 is a pause too, and carrying on goes back to before
    try setSpeedForPlayer(0.5);
    try setSpeedForPlayer(0);
    try setPausedForPlayer(false);
    try testing.expectEqual(0.5, currentSpeed());
}
