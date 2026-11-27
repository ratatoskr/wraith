//! Workbench tabs, each a docked window of its own. They draw on the Workbench's own thread, so never call into the game there:
//! game-thread code `publish`es to a `Latest`, and drains edits from a `Queue`.
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
const ui = @import("wraith_ui");
const rt = @import("salamander_runtime");

const Owner = @import("Owner.zig");

const W = api.wraith;

pub const Error = error{ OwnerGone, Failed };

pub const Options = struct {
    /// Its tab's label. Empty uses the plugin's name.
    title: []const u8 = "",
    /// What it is, like `sheets`. With `id`, how Wraith remembers where it was moved. Empty uses the title.
    kind: []const u8 = "",
    /// Which one of its kind, for several at once, like an address.
    id: []const u8 = "",
    /// Where it goes the first time it shows. Closed, it comes back from View, or with `focus`.
    place: W.WorkbenchPanel.Place = .top,
    /// Lower comes first among tabs in the same place. Wraith's own are 100 apart, from 100, and 0 is after them.
    order: i32 = 0,
    /// Inside another tab, as one of its tabs: its kind for one of the plugin's own, like `ffxiv`, else
    /// `plugin/kind`, like `wraith/debug`.
    parent: []const u8 = "",
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

    /// Removes it, waiting for an in-progress draw unless called from one. Idempotent.
    pub fn remove(self: Panel) void {
        self.object.remove();
    }
};

/// Calls `func(target)` on the Workbench thread while shown, to draw with `sdk.ui`. Never touch the game.
pub fn addPanel(target: anytype, comptime func: fn (@TypeOf(target)) void, options: Options) Error!Panel {
    const T = @TypeOf(target);
    if (@typeInfo(T) != .pointer) @compileError("addPanel expects a pointer, found " ++ @typeName(T));
    const owner = Owner.current() orelse return error.OwnerGone;
    const object = owner.root.ui().addWorkbenchPanel(.{ .title = options.title, .kind = options.kind, .id = options.id, .place = options.place, .order = options.order, .parent = options.parent }, W.WorkbenchPanel.Draw.init(target, func));
    if (object.table == null) return error.Failed;
    return .{ .object = object };
}

/// A tab from `addTab`, or a kind of them for `multi`, gone with the plugin.
pub const Tab = struct {
    object: W.Contribution,

    /// Whether it showed last frame.
    pub fn isOpen(self: Tab) bool {
        return self.object.isOpen();
    }

    /// Opens it and brings it to the front.
    pub fn focus(self: Tab) void {
        self.object.focus();
    }

    /// For `multi`: opens the one with `id`, or brings it to the front. Any thread.
    pub fn open(self: Tab, id: []const u8) void {
        self.object.open(id);
    }

    /// For `multi`: closes the one with `id`, without asking. Any thread.
    pub fn close(self: Tab, id: []const u8) void {
        self.object.close(id);
    }

    /// Waits for a draw under way, unless called from one. Idempotent.
    pub fn remove(self: Tab) void {
        self.object.remove();
    }
};

/// A tab, or a kind of them for `multi`, from `T`'s functions on `target`, on the Workbench's thread:
/// `describe(target) WorkbenchTab.Info` and `draw(target, id)`. Optional, else what a missing method
/// gives: `status(target, id) WorkbenchTab.State` for its label and dot, `create(target) []const u8`
/// for View's New, and `keepOpen(target, id) bool` for its close button. `target` has to outlive it.
pub fn addTab(target: anytype, comptime T: type) Error!Tab {
    const Ptr = @TypeOf(target);
    if (@typeInfo(Ptr) != .pointer) @compileError("addTab expects a pointer, found " ++ @typeName(Ptr));
    const Impl = struct {
        pub fn describe(self: Ptr) W.WorkbenchTab.Info {
            return T.describe(self);
        }

        pub fn draw(self: Ptr, id: []const u8) void {
            T.draw(self, id);
        }

        pub fn status(self: Ptr, id: []const u8) W.WorkbenchTab.State {
            return if (@hasDecl(T, "status")) T.status(self, id) else .{};
        }

        pub fn create(self: Ptr) []const u8 {
            return if (@hasDecl(T, "create")) T.create(self) else "";
        }

        pub fn keepOpen(self: Ptr, id: []const u8) bool {
            return if (@hasDecl(T, "keepOpen")) T.keepOpen(self, id) else false;
        }
    };
    const owner = Owner.current() orelse return error.OwnerGone;
    const tab = W.WorkbenchTab.init(target, rt.implement(W.WorkbenchTab, Impl));
    const object = owner.root.ui().addWorkbenchTab(tab) catch return error.Failed;
    return .{ .object = object };
}

/// A tab holding others, which name its `kind` as their `parent`, as tabs inside it. Has to outlive it.
///
///     holder: sdk.workbench.Holder = .{ .options = .{ .title = "FFXIV", .kind = "ffxiv" } },
///
///     _ = try sdk.workbench.addHolder(&self.holder);
///     self.sheets = try sdk.workbench.addPanel(self, drawSheets, .{ .title = "Sheets", .parent = "ffxiv" });
pub const Holder = struct {
    options: Options,

    pub fn describe(self: *Holder) W.WorkbenchTab.Info {
        const o = self.options;
        return .{ .title = o.title, .kind = o.kind, .place = o.place, .order = o.order, .parent = o.parent, .parts = true };
    }

    pub fn draw(_: *Holder, _: []const u8) void {}
};

pub fn addHolder(holder: *Holder) Error!Tab {
    return addTab(holder, Holder);
}

/// Opens the Workbench's Classes on a C# class by full name, like `UnityEngine.Transform`.
pub fn showClass(class_name: []const u8) void {
    const owner = Owner.current() orelse return;
    owner.root.ui().showClass(class_name);
}

/// The newest value from one thread for another. Build in `next`'s allocator, `publish`, and readers
/// `read` it until `end`. Never waits.
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

        /// Allocator for the next value. Discards an unpublished previous one.
        pub fn next(self: *Self) std.mem.Allocator {
            const spare = self.spareSlot();
            _ = self.arenas[spare].reset(.retain_capacity);
            return self.arenas[spare].allocator();
        }

        /// Makes `value` the newest. False if a reader holds the last one; retry later. Never waits.
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

/// Work for another thread. `push` waits briefly; `drain` never waits.
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

        /// Pushed items, oldest first, valid till the next `drain`. Empty if a push is in progress.
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
