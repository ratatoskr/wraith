//! The `game` area: game and build info, and speed. Reads no files, so it's cheap from any thread.

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
const ranked = @import("ranked.zig");
const leases = @import("leases.zig");

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
/// The lease holding the game's speed, see `leases`. Set under `speed_lock` as it changes hands.
var holder: ?*leases.Lease = null;
var speed_lock: tuft_sys.sync.RwLock = .{};
var speed_cleanup: OnGone(.closing, speedOwnerGone) = .{};

/// Needs `speed_lock`.
fn provider() ?W.Game.SpeedHandler {
    const h = holder orelse return null;
    return h.speed;
}

/// As the speed changes hands, from `leases`. The old one restores the game's own, so they never both change it.
pub fn speedHandedOver(before: ?*leases.Lease, after: ?*leases.Lease) void {
    speed_lock.lock();
    defer speed_lock.unlock();
    if (before) |b| if (b.speed) |s| {
        _ = s.invoke(.{1});
    };
    holder = after;
    // The clocks only speed up, so a pause or slow motion ends with the plugin
    if (after == null and wanted < 1) wanted = 1;
    apply() catch {};
}

fn speedOwnerGone(owner: *Owner) void {
    speed_lock.lock();
    defer speed_lock.unlock();
    var changed = false;
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

/// Plugins' say on whether the speed can be changed, see `ranked`. With none it can.
const Vote = struct { owner: *Owner, on: bool };
fn voteOwner(v: Vote) usize {
    return @intFromPtr(v.owner);
}
var votes: ranked.Ranked(Vote, voteOwner) = .{};

fn dropVote(owner: *Owner) void {
    _ = votes.take(@intFromPtr(owner));
}

/// Needs `speed_lock`.
fn controlLocked() bool {
    return if (votes.best()) |v| v.on else true;
}

/// Back to normal, and stays there. Needs `speed_lock`.
fn offLocked() void {
    wanted = 1;
    resume_to = 1;
    setter = null;
    apply() catch {};
}

/// `loaded`'s say, which beats older ones from its kind of plugin till it goes.
fn voteLocked(loaded: *Loaded, on: bool) void {
    const was_on = controlLocked();
    _ = votes.put(allocator, .{ .owner = &loaded.owner, .on = on }, .sayOf(loaded)) catch return;
    if (was_on and !controlLocked()) offLocked();
}

/// Whether the game's speed can be changed now. A game's plugin can allow it only where it works.
pub fn controllable() bool {
    speed_lock.lockShared();
    defer speed_lock.unlockShared();
    return controlLocked();
}

/// The provider if it takes it, else the clocks, which only speed up: games cap their frame rate
/// with them, so slowing them slows Wraith's windows too. Needs `speed_lock`.
fn apply() !void {
    if (provider()) |p| if (p.invoke(.{wanted})) {
        try speed_.set(1);
        return;
    };
    try speed_.set(@max(wanted, 1));
}

/// Below 1 needs a plugin that handles the game's speed. Needs `speed_lock`.
fn lowest() f64 {
    return if (provider() != null) 0 else 1;
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

/// Pausing is speed 0, unpausing restores the speed before. Pausing needs a plugin that handles speed.
pub fn setPausedForPlayer(on: bool) !void {
    speed_lock.lock();
    defer speed_lock.unlock();
    if (on == (wanted == 0)) return;
    if (!controlLocked()) return error.SpeedOff;
    if (on and provider() == null) return error.NeedsPlugin;
    try setLocked(if (on) 0 else resume_to, null);
}

pub fn paused() bool {
    return currentSpeed() == 0;
}

/// Whether it can go below 1 and pause, which takes a plugin that handles the game's speed.
pub fn canSlow() bool {
    speed_lock.lockShared();
    defer speed_lock.unlockShared();
    return provider() != null and controlLocked();
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
        voteLocked(loaded, on);
    }

    pub fn speedControl(_: *Loaded) bool {
        return controllable();
    }

    pub fn claimSpeed(loaded: *Loaded, handler: W.Game.SpeedHandler, changed: ?W.Lease.Changed) sal.Plain(Game, "claimSpeed") {
        const t = wraith.tablesOf(loaded) orelse {
            handler.release();
            if (changed) |c| c.release();
            return error.Failed;
        };
        const l = leases.claim(loaded, .speed, changed, handler) catch return error.Failed;
        return .init(l, t.lease);
    }

    pub fn sha512(loaded: *Loaded) HashPromise {
        const pair = HashPromise.make() catch return .{};
        const t = wraith.tablesOf(loaded) orelse {
            pair.resolver.drop();
            return pair.promise;
        };
        switch (GameInfo.global.hash_state.load(.acquire)) {
            .done => settleHash(.of(pair.resolver, loaded)),
            .idle, .failed => pair.resolver.fail(error.Failed),
            .hashing => {
                const job = allocator.create(HashWait) catch {
                    pair.resolver.fail(error.Failed);
                    return pair.promise;
                };
                job.* = .{ .owner = t.owner, .resolver = .of(pair.resolver, loaded) };
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

test "a plugin holding the speed gets it first, and the clocks carry on once it's gone" {
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
    _ = try game.claimSpeed(W.Game.SpeedHandler.init(&state, State.handle), null);
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

test "a game's plugin gets the speed over its engine's, whichever came first, and hands it back as it goes" {
    const testing = std.testing;
    const sdk = @import("wraith_sdk");
    const tuft_hook = @import("tuft_hook");
    try tuft_hook.init(testing.allocator);
    defer tuft_hook.deinit();
    defer speed_.stop();
    defer setSpeedForPlayer(1) catch {};
    const State = struct {
        got: f64 = -1,
        fn handle(self: *@This(), s: f64) bool {
            self.got = s;
            return true;
        }
    };

    var game_plugin: Loaded = undefined;
    game_plugin.initForTest(testing.allocator, "kai");
    game_plugin.manifest.value.game = .{ .ids = &.{"kai"} };
    var game_state: State = .{};
    sdk.Owner.attach(game_plugin.root());
    _ = try sdk.wraith.root().?.game().claimSpeed(W.Game.SpeedHandler.init(&game_state, State.handle), null);
    sdk.Owner.detach();
    try setSpeedForPlayer(0.5);
    try testing.expectEqual(0.5, game_state.got);

    // Newer, but an engine's
    var engine_plugin: Loaded = undefined;
    engine_plugin.initForTest(testing.allocator, "unity");
    engine_plugin.manifest.value.gameEngine = .{ .id = "unity" };
    defer {
        engine_plugin.deinitForTest();
        wraith.forget(&engine_plugin);
    }
    var engine_state: State = .{};
    sdk.Owner.attach(engine_plugin.root());
    const Told = struct {
        held: ?bool = null,
        fn changed(self: *@This(), held: bool) void {
            self.held = held;
        }
    };
    var engine_told: Told = .{};
    const engine_lease = try sdk.wraith.root().?.game().claimSpeed(W.Game.SpeedHandler.init(&engine_state, State.handle), W.Lease.Changed.init(&engine_told, Told.changed));
    sdk.Owner.detach();
    // Waiting, so it's not asked
    try testing.expect(!engine_lease.held());
    try testing.expectEqual(-1, engine_state.got);
    try setSpeedForPlayer(0.25);
    try testing.expectEqual(0.25, game_state.got);
    try testing.expectEqual(-1, engine_state.got);
    try testing.expectEqual(null, engine_told.held);

    // The engine's takes over, at the same speed, and is told
    game_plugin.deinitForTest();
    wraith.forget(&game_plugin);
    try testing.expectEqual(0.25, engine_state.got);
    try testing.expect(engine_lease.held());
    try testing.expectEqual(true, engine_told.held);
    try testing.expect(canSlow());

    // Letting go puts the game's own speed back
    engine_lease.release();
    try testing.expectEqual(1, engine_state.got);
    try testing.expect(!canSlow());
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
    _ = try sdk.wraith.root().?.game().claimSpeed(W.Game.SpeedHandler.init(&takes, Takes.handle), null);
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
    _ = try game.claimSpeed(W.Game.SpeedHandler.init(&takes, Takes.handle), null);
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

    // Once the plugin that turned it on goes, the game plugin's say is back, and once that goes it's on
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
