//! Who wins when plugins want the same part of the game, whoever asks first: a game's plugin over an
//! engine's over the rest, then the later loaded (so it beats what it's built on), then the latest ask.
//! Says, like whether speed can change, skip load order so the newest wins within a tier.

const std = @import("std");

const Loaded = @import("../PluginLoader.zig").Loaded;

pub const Rank = struct {
    /// See `Loaded.tier`.
    tier: u8,
    /// See `Loaded.load_order`. 0 for says, which go by `claim` alone.
    load: u64 = 0,
    /// When it was asked for. `Ranked` fills it in.
    claim: u64 = 0,

    /// For something `loaded` takes over.
    pub fn of(loaded: *const Loaded) Rank {
        return .{ .tier = loaded.tier(), .load = loaded.load_order };
    }

    /// For something `loaded` says, where the newest say wins.
    pub fn sayOf(loaded: *const Loaded) Rank {
        return .{ .tier = loaded.tier() };
    }

    pub fn beats(a: Rank, b: Rank) bool {
        if (a.tier != b.tier) return a.tier > b.tier;
        if (a.load != b.load) return a.load > b.load;
        return a.claim > b.claim;
    }
};

/// Every plugin's ask for one thing, best on top. Asking again replaces by `key`. Callers lock it.
pub fn Ranked(comptime T: type, comptime key: fn (T) usize) type {
    return struct {
        const Self = @This();

        pub const Entry = struct { value: T, rank: Rank };

        entries: std.ArrayList(Entry) = .empty,
        next_claim: u64 = 1,

        /// Adds it, or replaces the one with the same key, which it gives back to let go of.
        pub fn put(self: *Self, gpa: std.mem.Allocator, value: T, rank: Rank) error{OutOfMemory}!?T {
            var r = rank;
            r.claim = self.next_claim;
            self.next_claim += 1;
            if (self.find(key(value))) |e| {
                const old = e.value;
                e.* = .{ .value = value, .rank = r };
                return old;
            }
            try self.entries.append(gpa, .{ .value = value, .rank = r });
            return null;
        }

        /// Takes out the one with this key, if there is one.
        pub fn take(self: *Self, k: usize) ?T {
            for (self.entries.items, 0..) |e, i| if (key(e.value) == k) {
                _ = self.entries.orderedRemove(i);
                return e.value;
            };
            return null;
        }

        pub fn find(self: *Self, k: usize) ?*Entry {
            for (self.entries.items) |*e| if (key(e.value) == k) return e;
            return null;
        }

        /// The one that wins.
        pub fn best(self: *const Self) ?T {
            var top: ?Entry = null;
            for (self.entries.items) |e| {
                if (top == null or e.rank.beats(top.?.rank)) top = e;
            }
            return if (top) |t| t.value else null;
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.entries.deinit(gpa);
        }
    };
}

test "a game's plugin wins, then whichever loaded later, then its newest ask" {
    const testing = std.testing;
    const byId = struct {
        fn f(v: u32) usize {
            return v / 10;
        }
    }.f;
    var r: Ranked(u32, byId) = .{};
    defer r.deinit(testing.allocator);
    const engine: Rank = .{ .tier = 1, .load = 1 };
    const fixes: Rank = .{ .tier = 1, .load = 2 };
    const game: Rank = .{ .tier = 2, .load = 3 };

    // The engine's fixes asked first, but loaded after the engine's plugin
    try testing.expectEqual(null, try r.put(testing.allocator, 20, fixes));
    try testing.expectEqual(null, try r.put(testing.allocator, 10, engine));
    try testing.expectEqual(20, r.best());
    try testing.expectEqual(null, try r.put(testing.allocator, 30, game));
    try testing.expectEqual(30, r.best());
    try testing.expectEqual(30, r.take(3));
    try testing.expectEqual(20, r.best());
    // Asking again replaces its own
    try testing.expectEqual(20, try r.put(testing.allocator, 21, fixes));
    try testing.expectEqual(21, r.best());
    try testing.expectEqual(null, r.take(3));

    // Says go by the newest
    var says: Ranked(u32, byId) = .{};
    defer says.deinit(testing.allocator);
    _ = try says.put(testing.allocator, 10, .{ .tier = 1 });
    _ = try says.put(testing.allocator, 20, .{ .tier = 1 });
    try testing.expectEqual(20, says.best());
    _ = try says.put(testing.allocator, 11, .{ .tier = 1 });
    try testing.expectEqual(11, says.best());
}
