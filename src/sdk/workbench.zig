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
    const object = owner.root.ui().addWorkbenchPanel(.{ .title = options.title, .kind = options.kind, .id = options.id, .place = options.place, .order = options.order }, W.WorkbenchPanel.Draw.init(target, func));
    if (object.table == null) return error.Failed;
    return .{ .object = object };
}

/// Tabs inside one of yours, one per value of the enum `Part`, like Scene and Classes. Draw it from
/// the tab's draw; `showing` and `focus` work from any thread.
///
///     parts: sdk.workbench.Parts(Part) = .init(.{ .scene = "Scene", .classes = "Classes" }),
///
///     fn draw(self: *Explorer) void {
///         self.parts.draw(self, drawPart);
///     }
pub fn Parts(comptime Part: type) type {
    return struct {
        const Self = @This();

        labels: std.EnumArray(Part, [:0]const u8),
        /// In front at the last draw.
        front: std.atomic.Value(u8) = .init(0),
        /// To bring to the front at the next, plus one, or 0.
        pick: std.atomic.Value(u8) = .init(0),

        pub fn init(labels: std.enums.EnumFieldStruct(Part, [:0]const u8, null)) Self {
            return .{ .labels = .init(labels) };
        }

        /// Whether `part`'s in front while `panel`'s open.
        pub fn showing(self: *const Self, panel: ?Panel, part: Part) bool {
            const p = panel orelse return false;
            return p.isOpen() and self.front.load(.acquire) == index(part);
        }

        /// Brings `part` to the front, and `panel` with it.
        pub fn focus(self: *Self, panel: ?Panel, part: Part) void {
            self.pick.store(index(part) + 1, .release);
            if (panel) |p| p.focus();
        }

        /// A tab bar, with `func(target, part)` drawing the one in front.
        pub fn draw(self: *Self, target: anytype, comptime func: fn (@TypeOf(target), Part) void) void {
            const pick = self.pick.swap(0, .acq_rel);
            const bar = ui.tabBar("parts") orelse return;
            defer bar.end();
            for (std.enums.values(Part)) |part| {
                const tab = ui.tabItem(self.labels.get(part), .{ .select = pick == index(part) + 1 }) orelse continue;
                defer tab.end();
                self.front.store(index(part), .release);
                const child = ui.child(self.labels.get(part), .{ 0, 0 }, .{}) orelse continue;
                defer child.end();
                func(target, part);
            }
        }

        fn index(part: Part) u8 {
            return @intCast(@backingInt(part));
        }
    };
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
