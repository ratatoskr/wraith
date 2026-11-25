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
const threads = @import("threads.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;

const sal = api.salamander;
const W = api.wraith;

pub const Game = W.Game;

const allocator = std.heap.page_allocator;

const HashPromise = sal.Plain(Game, "sha512");
const HashResolver = threads.Back(wraith.ResolverOf(HashPromise));

/// The speed asked for, which `speed` gives. Under `speed_lock`, like the rest.
var wanted: f64 = 1;
/// Who set the speed last, so it goes back to 1 when they go. Null for the player.
var setter: ?*Owner = null;
/// A plugin's own way of changing the speed, asked first.
const Provider = struct { owner: *Owner, handler: W.Game.SpeedHandler };
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
        // The clocks can only speed it up, so a pause or slow motion ends with the plugin
        if (wanted < 1) wanted = 1;
    };
    if (setter == owner) {
        setter = null;
        wanted = 1;
        changed = true;
    }
    const was_on = controlLocked();
    dropVote(owner);
    if (!controlLocked() and was_on) offLocked();
    if (changed) apply() catch {};
}

/// Plugins' say on whether the game's speed can be changed, the newest last. With none it can.
const Vote = struct { owner: *Owner, on: bool };
var votes: [32]Vote = undefined;
var votes_len: usize = 0;

fn dropVote(owner: *Owner) void {
    var i: usize = 0;
    while (i < votes_len) {
        if (votes[i].owner == owner) {
            std.mem.copyForwards(Vote, votes[i .. votes_len - 1], votes[i + 1 .. votes_len]);
            votes_len -= 1;
        } else i += 1;
    }
}

/// Needs `speed_lock`.
fn controlLocked() bool {
    return if (votes_len == 0) true else votes[votes_len - 1].on;
}

/// Back to normal, and stays there. Needs `speed_lock`.
fn offLocked() void {
    wanted = 1;
    resume_to = 1;
    setter = null;
    apply() catch {};
}

/// `owner`'s say, which beats older ones till it goes.
fn voteLocked(owner: *Owner, on: bool) void {
    const was_on = controlLocked();
    dropVote(owner);
    if (votes_len == votes.len) {
        std.mem.copyForwards(Vote, votes[0 .. votes_len - 1], votes[1..votes_len]);
        votes_len -= 1;
    }
    votes[votes_len] = .{ .owner = owner, .on = on };
    votes_len += 1;
    if (was_on and !controlLocked()) offLocked();
}

/// Whether the game's speed can be changed now. A game's plugin can keep it as it is, and turn it
/// on only where it works, like a photo mode.
pub fn controllable() bool {
    speed_lock.lockShared();
    defer speed_lock.unlockShared();
    return controlLocked();
}

/// The provider if it takes it, else the clocks. Those only ever speed the game up, since games
/// cap their frame rate with the same clocks, so slowing them slows the frame rate and Wraith's
/// windows drawn with it. Needs `speed_lock`.
fn apply() !void {
    if (provider) |p| if (p.handler.invoke(.{wanted})) {
        try speed_.set(1);
        return;
    };
    try speed_.set(@max(wanted, 1));
}

/// Below 1 needs a plugin that handles the game's speed. Needs `speed_lock`.
fn lowest() f64 {
    return if (provider != null) 0 else 1;
}

fn setLocked(s: f64, owner: ?*Owner) !void {
    if (!controlLocked()) return error.SpeedOff;
    const before = wanted;
    wanted = std.math.clamp(s, lowest(), speed_.max);
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

/// Pausing is speed 0, and unpausing goes back to the speed from before. Pausing needs a plugin
/// that handles the game's speed.
pub fn setPausedForPlayer(on: bool) !void {
    speed_lock.lock();
    defer speed_lock.unlock();
    if (on == (wanted == 0)) return;
    if (!controlLocked()) return error.SpeedOff;
    if (on and provider == null) return error.NeedsPlugin;
    try setLocked(if (on) 0 else resume_to, null);
}

pub fn paused() bool {
    return currentSpeed() == 0;
}

/// Whether it can go below 1 and pause, which takes a plugin that handles the game's speed, like
/// one for its engine.
pub fn canSlow() bool {
    speed_lock.lockShared();
    defer speed_lock.unlockShared();
    return provider != null and controlLocked();
}

/// What it's at, as asked for.
pub fn currentSpeed() f64 {
    speed_lock.lockShared();
    defer speed_lock.unlockShared();
    return wanted;
}

pub const Impl = struct {
    pub fn gameInfo(_: *Loaded) W.Game.Info {
        const g = &GameInfo.global;
        const a = scratch.begin();
        var out: W.Game.Info = .{
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
        const list = a.alloc(W.Game.AntiCheat, found.len) catch return out;
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
        setLocked(s, &loaded.owner) catch |err| return if (err == error.SpeedOff) error.SpeedOff else error.Failed;
    }

    pub fn setSpeedControl(loaded: *Loaded, on: bool) void {
        const lease = speed_cleanup.lease(&loaded.owner) orelse return;
        defer lease.end();
        speed_lock.lock();
        defer speed_lock.unlock();
        voteLocked(&loaded.owner, on);
    }

    pub fn speedControl(_: *Loaded) bool {
        return controllable();
    }

    pub fn provideSpeed(loaded: *Loaded, handler: W.Game.SpeedHandler) void {
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
            .done => settleHash(.of(pair.resolver)),
            .idle, .failed => pair.resolver.fail(error.Failed),
            .hashing => {
                const job = allocator.create(HashWait) catch {
                    pair.resolver.fail(error.Failed);
                    return pair.promise;
                };
                job.* = .{ .owner = t.owner, .resolver = .of(pair.resolver) };
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
    const info = game.gameInfo();
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
    game.provideSpeed(W.Game.SpeedHandler.init(&state, State.handle));
    // Told straight away
    try testing.expectEqual(1, state.got);

    // It pauses, and the clocks aren't touched
    try game.setSpeed(0);
    try testing.expectEqual(0, state.got);
    try testing.expectEqual(0, game.speed());
    try testing.expectEqual(1, speed_.get());

    // One it won't do goes to the clocks, which only speed up
    state.takes = false;
    try game.setSpeed(0.5);
    try testing.expectEqual(1, speed_.get());
    try game.setSpeed(2);
    try testing.expectEqual(2, speed_.get());
    state.takes = true;

    // Paused when it goes, the game carries on at normal, since the clocks can't pause
    try setSpeedForPlayer(2.5);
    try setPausedForPlayer(true);
    try testing.expectEqual(0, state.got);
    loaded.deinitForTest();
    wraith.forget(&loaded);
    try testing.expectEqual(1, currentSpeed());
    try testing.expect(!canSlow());
    // The player's speed-up carries on, on the clocks
    try setSpeedForPlayer(3);
    try testing.expectEqual(3, speed_.get());
    try setSpeedForPlayer(1);
}

test "without a plugin for its speed, the game only speeds up, and can't pause" {
    const testing = std.testing;
    const tuft_hook = @import("tuft_hook");
    try tuft_hook.init(testing.allocator);
    defer tuft_hook.deinit();
    defer speed_.stop();
    defer setSpeedForPlayer(1) catch {};
    try testing.expect(!canSlow());
    try setSpeedForPlayer(0.5);
    try testing.expectEqual(1, currentSpeed());
    try testing.expectError(error.NeedsPlugin, setPausedForPlayer(true));
    try testing.expect(!paused());
    try setSpeedForPlayer(4);
    try testing.expectEqual(4, speed_.get());
}

test "pausing with a plugin goes back to the speed from before" {
    const testing = std.testing;
    const sdk = @import("wraith_sdk");
    var loaded: Loaded = undefined;
    loaded.initForTest(testing.allocator, "engine");
    defer {
        loaded.deinitForTest();
        wraith.forget(&loaded);
    }
    sdk.Owner.attach(loaded.root());
    defer sdk.Owner.detach();
    const Takes = struct {
        fn handle(_: *@This(), _: f64) bool {
            return true;
        }
    };
    var takes: Takes = .{};
    sdk.wraith.root().?.game().provideSpeed(W.Game.SpeedHandler.init(&takes, Takes.handle));
    defer setSpeedForPlayer(1) catch {};

    try setSpeedForPlayer(0.5);
    try setPausedForPlayer(true);
    try testing.expect(paused());
    try setPausedForPlayer(false);
    try testing.expectEqual(0.5, currentSpeed());
    // Sliding it to 0 is a pause too
    try setSpeedForPlayer(2.5);
    try setSpeedForPlayer(0);
    try setPausedForPlayer(false);
    try testing.expectEqual(2.5, currentSpeed());
}

test "a game's plugin keeps the speed off, and another turns it on where it works" {
    const testing = std.testing;
    const sdk = @import("wraith_sdk");
    const Takes = struct {
        got: f64 = -1,
        fn handle(self: *@This(), s: f64) bool {
            self.got = s;
            return true;
        }
    };
    var takes: Takes = .{};
    var game_plugin: Loaded = undefined;
    game_plugin.initForTest(testing.allocator, "ffxiv");
    sdk.Owner.attach(game_plugin.root());
    const game = sdk.wraith.root().?.game();
    game.provideSpeed(W.Game.SpeedHandler.init(&takes, Takes.handle));
    game.setSpeedControl(false);
    sdk.Owner.detach();
    try testing.expect(!game.speedControl());
    try testing.expect(!canSlow());
    try testing.expectError(error.SpeedOff, setSpeedForPlayer(2));
    try testing.expectError(error.SpeedOff, setPausedForPlayer(true));

    var gpose: Loaded = undefined;
    gpose.initForTest(testing.allocator, "gpose");
    sdk.Owner.attach(gpose.root());
    const posing = sdk.wraith.root().?.game();
    posing.setSpeedControl(true);
    sdk.Owner.detach();
    try testing.expect(controllable());
    try setSpeedForPlayer(0.5);
    try testing.expectEqual(0.5, takes.got);

    // Off again puts it back to normal
    sdk.Owner.attach(gpose.root());
    posing.setSpeedControl(false);
    sdk.Owner.detach();
    try testing.expectEqual(1, currentSpeed());
    try testing.expectEqual(1, takes.got);

    // When the plugin that turned it on goes, the game plugin's say is back, and when that goes too
    // it's on, as it is in other games
    sdk.Owner.attach(gpose.root());
    posing.setSpeedControl(true);
    sdk.Owner.detach();
    try setSpeedForPlayer(2);
    gpose.deinitForTest();
    wraith.forget(&gpose);
    try testing.expect(!controllable());
    try testing.expectEqual(1, currentSpeed());
    game_plugin.deinitForTest();
    wraith.forget(&game_plugin);
    try testing.expect(controllable());
}
