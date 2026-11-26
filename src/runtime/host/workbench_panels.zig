//! Plugins' Workbench panels, added from any thread and drawn on the Workbench's. `remove` waits for a
//! draw under way, unless that'd wait on itself: from the Workbench's thread or from a script.

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const api = @import("wraith_api");
const sync = @import("tuft_sys").sync;

const host = @import("root.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;

const W = api.wraith;
pub const Draw = W.WorkbenchPanel.Draw;

const gpa = std.heap.page_allocator;

pub const Panel = struct {
    loaded: *Loaded,
    /// What its tab says
    title: [:0]u8,
    /// Its tab's ImGui label, unique across plugins
    label: [:0]u8,
    engine: bool,
    draw: Draw,
    /// Draws under way in the low bits, plus `stopped_bit`. Whoever stops it with none under way lets go of `draw`.
    state: Atomic(u32) = .init(0),
    /// `draw`'s been let go of, so nothing of the plugin's runs for it again.
    finished: Atomic(bool) = .init(false),
    let_go: Atomic(bool) = .init(false),
    /// Asked for from any thread, done by the Workbench.
    focus_wanted: Atomic(bool) = .init(false),
    /// Set by the Workbench each frame from the frame before, so other threads never see it briefly false.
    shown: Atomic(bool) = .init(false),
    /// Drawn this Workbench frame. Workbench thread.
    drawn: bool = false,
    /// Workbench thread.
    warned: bool = false,
    /// Freed while this thread held it, so its `release` frees it. Only that thread touches it.
    free_pending: bool = false,

    const stopped_bit: u32 = 1 << 31;

    pub fn stopped(self: *const Panel) bool {
        return self.state.load(.acquire) & stopped_bit != 0;
    }

    /// No more draws, waiting for one under way unless that'd wait on itself.
    pub fn stop(self: *Panel) void {
        self.markStopped();
        if (heldHere(self) or !std.mem.eql(u8, self.loaded.manifest.providerName(), api.default_provider)) return;
        self.waitFinished();
    }

    pub fn free(self: *Panel) void {
        self.markStopped();
        {
            lock.lock();
            defer lock.unlock();
            if (std.mem.indexOfScalar(*Panel, list.items, self)) |at| _ = list.orderedRemove(at);
        }
        // Its owner's closed by now, so a script's draw has given up waiting for its lock
        if (heldHere(self)) {
            self.free_pending = true;
            return;
        }
        self.waitFinished();
        self.destroy();
    }

    pub fn going(self: *Panel) bool {
        return !self.stopped();
    }

    fn markStopped(self: *Panel) void {
        const was = self.state.fetchOr(stopped_bit, .acq_rel);
        if (was & stopped_bit != 0) return;
        _ = changes.fetchAdd(1, .release);
        if (was == 0) self.finish();
    }

    fn finish(self: *Panel) void {
        // A take that saw it stopped can bring the count back to 0 after it's finished
        if (self.let_go.swap(true, .acq_rel)) return;
        self.draw.release();
        // Last, since a waiting `free` destroys it once it's seen
        self.finished.store(true, .release);
    }

    fn waitFinished(self: *Panel) void {
        while (!self.finished.load(.acquire)) std.Thread.yield() catch {};
    }

    fn destroy(self: *Panel) void {
        gpa.free(self.title);
        gpa.free(self.label);
        gpa.destroy(self);
    }

    /// One draw's done.
    fn put(self: *Panel) void {
        const pending = self.free_pending;
        if (self.state.fetchSub(1, .acq_rel) != stopped_bit | 1) return;
        self.finish();
        if (pending) self.destroy();
    }

    fn call(ctx: ?*anyopaque) callconv(.c) void {
        const self: *Panel = @ptrCast(@alignCast(ctx.?));
        self.draw.invoke(.{});
    }
};

var lock: sync.RwLock = .{};
/// Under `lock`, in the order they were added.
var list: std.ArrayList(*Panel) = .empty;
var records: host.Owned(Panel) = .{};
/// Bumped whenever one's added or goes, so the Workbench knows to look again.
var changes: Atomic(u32) = .init(0);

/// What this thread has from `take` and hasn't released, so it never waits on those.
threadlocal var held: [64]*Panel = undefined;
threadlocal var held_len: usize = 0;

fn heldHere(p: *const Panel) bool {
    for (held[0..held_len]) |h| if (h == p) return true;
    return false;
}

/// Through `ui.sal`. Null if the plugin's going or out of memory, with `draw` released.
pub fn add(loaded: *Loaded, options: W.WorkbenchPanel.Options, draw: Draw) ?*Panel {
    const p = make(loaded, options, draw) catch {
        draw.release();
        return null;
    };
    records.add(p) catch {
        draw.release();
        p.destroy();
        return null;
    };
    {
        lock.lock();
        defer lock.unlock();
        list.append(gpa, p) catch {
            // Owned still frees it with the plugin
            p.stop();
            return null;
        };
    }
    _ = changes.fetchAdd(1, .release);
    return p;
}

fn make(loaded: *Loaded, options: W.WorkbenchPanel.Options, draw: Draw) !*Panel {
    const p = try gpa.create(Panel);
    errdefer gpa.destroy(p);
    const title = try gpa.dupeSentinel(u8, if (options.title.len > 0) options.title else loaded.displayName(), 0);
    errdefer gpa.free(title);
    const label = try std.fmt.allocPrintSentinel(gpa, "{s}###wraith/{s}/{s}", .{ title, loaded.name, title }, 0);
    p.* = .{ .loaded = loaded, .title = title, .label = label, .engine = options.engine, .draw = draw };
    return p;
}

/// Changes whenever the list does.
pub fn version() u32 {
    return changes.load(.acquire);
}

/// Marks none showing, for a closed Workbench. Workbench thread.
pub fn hideAll() void {
    lock.lockShared();
    defer lock.unlockShared();
    for (list.items) |p| {
        p.drawn = false;
        p.shown.store(false, .release);
    }
}

/// The live `engine` panels or the rest, into `out`, each held till `release`. Workbench thread.
pub fn take(engine: bool, out: []*Panel) []*Panel {
    lock.lockShared();
    defer lock.unlockShared();
    var n: usize = 0;
    for (list.items) |p| {
        if (n == out.len or held_len == held.len) break;
        if (p.engine != engine) continue;
        // Held before checking, so a stop either sees it or this sees it's stopped
        if (p.state.fetchAdd(1, .acq_rel) & Panel.stopped_bit != 0) {
            p.put();
            continue;
        }
        out[n] = p;
        n += 1;
        held[held_len] = p;
        held_len += 1;
    }
    return out[0..n];
}

/// Lets go of what `take` gave. They mustn't be used after.
pub fn release(taken: []const *Panel) void {
    for (taken) |p| {
        if (std.mem.indexOfScalar(*Panel, held[0..held_len], p)) |at| {
            held_len -= 1;
            held[at] = held[held_len];
        }
        p.put();
    }
}

/// Draws it in the current window, scoped to its plugin. Only what `take` gave, not once it's stopped.
pub fn drawPanel(p: *Panel) void {
    if (p.stopped()) return;
    host.ui.runInWorkbench(p.loaded, &p.warned, p, Panel.call);
}

// `focus` and `showClass`, picked up by the Workbench

var class_lock: sync.RwLock = .{};
/// Under `class_lock`. Empty for none.
var class_wanted: std.ArrayList(u8) = .empty;

pub fn showClass(name: []const u8) void {
    class_lock.lock();
    defer class_lock.unlock();
    class_wanted.clearRetainingCapacity();
    class_wanted.appendSlice(gpa, name) catch class_wanted.clearRetainingCapacity();
}

/// The class asked for since last time, copied into `buf`, or null. Workbench thread.
pub fn takeClass(buf: []u8) ?[]const u8 {
    class_lock.lock();
    defer class_lock.unlock();
    if (class_wanted.items.len == 0) return null;
    const n = @min(buf.len, class_wanted.items.len);
    @memcpy(buf[0..n], class_wanted.items[0..n]);
    class_wanted.clearRetainingCapacity();
    return buf[0..n];
}

const tests = struct {
    const testing = std.testing;

    const Counts = struct {
        draws: u32 = 0,
        panel: ?W.WorkbenchPanel = null,
        remove_inside: bool = false,

        fn draw(self: *Counts) void {
            self.draws += 1;
            if (self.remove_inside) if (self.panel) |p| p.remove();
        }
    };

    fn drawAll(engine: bool) usize {
        var buf: [8]*Panel = undefined;
        const got = take(engine, &buf);
        defer release(got);
        for (got) |p| drawPanel(p);
        return got.len;
    }

    test "panels draw till they're removed or their plugin goes" {
        const sdk = @import("wraith_sdk");
        var a: Loaded = undefined;
        a.initForTest(testing.allocator, "a");
        sdk.Owner.attach(a.root());
        defer sdk.Owner.detach();
        const area = sdk.wraith.root().?.ui();

        var engine_counts: Counts = .{};
        var other_counts: Counts = .{ .remove_inside = true };
        const engine_panel = area.addWorkbenchPanel(.{ .title = "Explorer", .engine = true }, .init(&engine_counts, Counts.draw));
        other_counts.panel = area.addWorkbenchPanel(.{ .title = "Other", .engine = false }, .init(&other_counts, Counts.draw));
        try testing.expect(engine_panel.table != null);

        try testing.expectEqual(1, drawAll(true));
        try testing.expectEqual(1, engine_counts.draws);
        // Removing itself from inside its draw doesn't wait on itself
        try testing.expectEqual(1, drawAll(false));
        try testing.expectEqual(0, drawAll(false));
        try testing.expectEqual(1, other_counts.draws);

        // Gone with the plugin
        a.owner.close();
        try testing.expectEqual(0, drawAll(true));
        try testing.expectEqual(1, engine_counts.draws);
        a.deinitForTest();
    }

    const Sibling = struct {
        other: ?W.WorkbenchPanel = null,
        draws: u32 = 0,

        fn draw(self: *Sibling) void {
            self.draws += 1;
            if (self.other) |o| o.remove();
        }
    };

    test "a draw removing another of the group's panels doesn't wait on itself" {
        const sdk = @import("wraith_sdk");
        var a: Loaded = undefined;
        a.initForTest(testing.allocator, "a");
        sdk.Owner.attach(a.root());
        defer sdk.Owner.detach();
        const area = sdk.wraith.root().?.ui();
        var first: Sibling = .{};
        var second: Sibling = .{};
        _ = area.addWorkbenchPanel(.{ .title = "First" }, .init(&first, Sibling.draw));
        first.other = area.addWorkbenchPanel(.{ .title = "Second" }, .init(&second, Sibling.draw));
        // The second's held for this frame too, so it's skipped rather than waited for
        try testing.expectEqual(2, drawAll(false));
        try testing.expectEqual(1, first.draws);
        try testing.expectEqual(0, second.draws);
        try testing.expectEqual(1, drawAll(false));
        a.owner.close();
        a.deinitForTest();
    }

    const Slow = struct {
        inside: Atomic(bool) = .init(false),
        go: Atomic(bool) = .init(false),
        done: Atomic(bool) = .init(false),

        fn draw(self: *Slow) void {
            self.inside.store(true, .release);
            while (!self.go.load(.acquire)) std.Thread.yield() catch {};
            self.done.store(true, .release);
        }

        fn remove(panel: W.WorkbenchPanel, removed: *Atomic(bool)) void {
            panel.remove();
            removed.store(true, .release);
        }
    };

    test "removing from another thread waits for a draw under way" {
        const sdk = @import("wraith_sdk");
        var a: Loaded = undefined;
        a.initForTest(testing.allocator, "a");
        sdk.Owner.attach(a.root());
        defer sdk.Owner.detach();
        const area = sdk.wraith.root().?.ui();
        var slow: Slow = .{};
        const panel = area.addWorkbenchPanel(.{ .title = "Slow" }, .init(&slow, Slow.draw));

        var buf: [8]*Panel = undefined;
        const got = take(false, &buf);
        var removed: Atomic(bool) = .init(false);
        const drawing = try std.Thread.spawn(.{}, struct {
            fn run(ps: []*Panel) void {
                for (ps) |p| drawPanel(p);
            }
        }.run, .{got});
        while (!slow.inside.load(.acquire)) std.Thread.yield() catch {};
        const remover = try std.Thread.spawn(.{}, Slow.remove, .{ panel, &removed });
        try testing.io.sleep(.fromMilliseconds(20), .awake);
        try testing.expect(!removed.load(.acquire));
        slow.go.store(true, .release);
        drawing.join();
        // `take` was this thread's, so letting go is too
        release(got);
        remover.join();
        try testing.expect(removed.load(.acquire));
        try testing.expect(slow.done.load(.acquire));
        try testing.expectEqual(0, drawAll(false));
        a.owner.close();
        a.deinitForTest();
    }

    test "showClass is picked up once" {
        showClass("UnityEngine.Transform");
        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings("UnityEngine.Transform", takeClass(&buf).?);
        try testing.expectEqual(null, takeClass(&buf));
    }
};

test {
    _ = tests;
}
