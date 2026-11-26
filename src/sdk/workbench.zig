//! Panels in the Workbench, for plugins that want tools there. An advanced feature, since a panel
//! draws on the Workbench's own thread: not the render thread or the game thread.
//!
//! A panel mustn't call into the game while it draws. Have your game-thread code, like an
//! `sdk.threads.onTick`, work out what the panel shows and `publish` it to a `Latest`, which the panel
//! `read`s. Changes go the other way through a `Queue`, which the game-thread code `drain`s. Neither
//! ever waits on the game thread, so a slow panel can't hold up the game.
//!
//!     self.panel = try sdk.workbench.addPanel(self, drawPanel, .{ .title = "Party" });
//!
//!     fn tick(self: *Plugin) void {
//!         // Game thread
//!         for (self.edits.drain()) |edit| apply(edit);
//!         const a = self.shown.next();
//!         self.shown.publish(readParty(a) catch return);
//!     }
//!
//!     fn drawPanel(self: *Plugin) void {
//!         // Workbench thread
//!         const party = self.shown.read() orelse return sdk.ui.textDisabled("Waiting for the game", .{});
//!         defer party.end();
//!         for (party.value.members) |m| if (sdk.ui.button(m.name)) self.edits.push(.{ .heal = m.id });
//!     }

const std = @import("std");

const api = @import("wraith_api");
const sys = @import("tuft_sys");

const Owner = @import("Owner.zig");

const W = api.wraith;

pub const Error = error{ OwnerGone, Failed };

pub const Options = struct {
    /// Its tab's label. Empty uses the plugin's name.
    title: []const u8 = "",
    /// In the game engine's group with Classes, like Unity's, rather than with the other plugins'
    /// panels. For engine plugins.
    engine: bool = false,
};

/// A panel of yours in the Workbench, gone with the plugin.
pub const Panel = struct {
    object: W.WorkbenchPanel,

    /// Whether its tab's open.
    pub fn isOpen(self: Panel) bool {
        return self.object.isOpen();
    }

    /// Opens it and brings its tab to the front.
    pub fn focus(self: Panel) void {
        self.object.focus();
    }

    /// Takes it out, waiting for a draw on the Workbench's thread to finish unless it's from inside
    /// one. After that, nothing of yours is drawn for it. Fine to call twice.
    pub fn remove(self: Panel) void {
        self.object.remove();
    }
};

/// Calls `func(target)` on the Workbench's thread whenever the panel's showing, inside its ImGui
/// frame, so it can draw with `sdk.ui`. Never call into the game from it.
pub fn addPanel(target: anytype, comptime func: fn (@TypeOf(target)) void, options: Options) Error!Panel {
    const T = @TypeOf(target);
    if (@typeInfo(T) != .pointer) @compileError("addPanel expects a pointer, found " ++ @typeName(T));
    const owner = Owner.current() orelse return error.OwnerGone;
    const object = owner.root.ui().addWorkbenchPanel(.{ .title = options.title, .engine = options.engine }, W.WorkbenchPanel.Draw.init(target, func));
    if (object.table == null) return error.Failed;
    return .{ .object = object };
}

/// Opens the Workbench's Classes on a C# class by full name, like `UnityEngine.Transform`.
pub fn showClass(class_name: []const u8) void {
    const owner = Owner.current() orelse return;
    owner.root.ui().showClass(class_name);
}

/// The newest value from one thread for another, like what your game-thread code found for a panel
/// to draw. Whoever makes values builds each in `next`'s allocator, so it can hold slices, and
/// `publish`es it, which never waits. Readers `read` the newest, holding it till `end`.
pub fn Latest(comptime T: type) type {
    return struct {
        const Self = @This();

        lock: sys.sync.Mutex = .{},
        arenas: [2]std.heap.ArenaAllocator = .{ .init(std.heap.page_allocator), .init(std.heap.page_allocator) },
        values: [2]T = undefined,
        /// Under `lock`. Which of `values` is the newest, if any.
        current: ?u1 = null,

        pub fn deinit(self: *Self) void {
            for (&self.arenas) |*a| a.deinit();
        }

        /// For building the next value, from whoever publishes. What was built for the last one
        /// that didn't make it goes.
        pub fn next(self: *Self) std.mem.Allocator {
            const spare = self.spareSlot();
            _ = self.arenas[spare].reset(.retain_capacity);
            return self.arenas[spare].allocator();
        }

        /// Makes `value` the newest, if no reader has the last one right now. False if one does, so
        /// try again later, like next tick. Never waits.
        pub fn publish(self: *Self, value: T) bool {
            if (!self.lock.tryLock()) return false;
            defer self.lock.unlock();
            const spare = self.spareSlot();
            self.values[spare] = value;
            self.current = spare;
            return true;
        }

        /// The newest, or null before the first. Waits for a publish under way, which is brief.
        pub fn read(self: *Self) ?Reading {
            self.lock.lock();
            const at = self.current orelse {
                self.lock.unlock();
                return null;
            };
            return .{ .value = &self.values[at], .latest = self };
        }

        pub const Reading = struct {
            value: *const T,
            latest: *Self,

            pub fn end(self: Reading) void {
                self.latest.lock.unlock();
            }
        };

        /// The one readers can't have. Only the publisher changes `current`, so it can read it here.
        fn spareSlot(self: *const Self) u1 {
            return if (self.current) |c| 1 - c else 0;
        }
    };
}

/// Things for another thread to do, like a panel's edits for your game-thread code. Anyone can
/// `push`, which waits briefly. Whoever does the work `drain`s, which never waits.
pub fn Queue(comptime A: type) type {
    return struct {
        const Self = @This();

        lock: sys.sync.Mutex = .{},
        /// Under `lock`.
        waiting: std.ArrayList(A) = .empty,
        /// What the last `drain` gave. Only the drainer touches it.
        taken: std.ArrayList(A) = .empty,

        const gpa = std.heap.page_allocator;

        pub fn deinit(self: *Self) void {
            self.waiting.deinit(gpa);
            self.taken.deinit(gpa);
        }

        /// Dropped if it's out of memory.
        pub fn push(self: *Self, item: A) void {
            self.lock.lock();
            defer self.lock.unlock();
            self.waiting.append(gpa, item) catch {};
        }

        /// What's been pushed since last time, oldest first, good till the next `drain`. Empty if
        /// someone's pushing right now, and it's there next time. Never waits.
        pub fn drain(self: *Self) []const A {
            self.taken.clearRetainingCapacity();
            if (!self.lock.tryLock()) return &.{};
            defer self.lock.unlock();
            std.mem.swap(std.ArrayList(A), &self.waiting, &self.taken);
            return self.taken.items;
        }
    };
}

const tests = struct {
    const testing = std.testing;

    const Party = struct { names: []const []const u8 };

    test "latest values go across, and publishing never waits on a reader" {
        var latest: Latest(Party) = .{};
        defer latest.deinit();
        try testing.expectEqual(null, latest.read());

        const a = latest.next();
        const names = try a.alloc([]const u8, 1);
        names[0] = try a.dupe(u8, "Ryza");
        try testing.expect(latest.publish(.{ .names = names }));

        const reading = latest.read().?;
        try testing.expectEqualStrings("Ryza", reading.value.names[0]);
        // A reader has it, so the next one waits for another try
        const b = latest.next();
        const more = try b.alloc([]const u8, 1);
        more[0] = try b.dupe(u8, "Klaudia");
        try testing.expect(!latest.publish(.{ .names = more }));
        // And what it was reading wasn't touched
        try testing.expectEqualStrings("Ryza", reading.value.names[0]);
        reading.end();

        const c = latest.next();
        const again = try c.alloc([]const u8, 1);
        again[0] = try c.dupe(u8, "Klaudia");
        try testing.expect(latest.publish(.{ .names = again }));
        const now = latest.read().?;
        defer now.end();
        try testing.expectEqualStrings("Klaudia", now.value.names[0]);
    }

    test "queued things come out once, in order, from another thread" {
        var queue: Queue(u32) = .{};
        defer queue.deinit();
        const Pusher = struct {
            fn run(q: *Queue(u32)) void {
                for (0..100) |i| q.push(@intCast(i));
            }
        };
        const t = try std.Thread.spawn(.{}, Pusher.run, .{&queue});
        var seen: u32 = 0;
        while (seen < 100) {
            for (queue.drain()) |n| {
                try testing.expectEqual(seen, n);
                seen += 1;
            }
            std.Thread.yield() catch {};
        }
        t.join();
        try testing.expectEqual(0, queue.drain().len);
    }
};

test {
    _ = tests;
}
