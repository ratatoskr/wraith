//! Undo and redo for Photo mode. Each part keeps its own state and says when it's changed; this takes
//! a snapshot of them all once an edit's done, so a drag or a typed value is one step. Render thread.

const History = @This();

const std = @import("std");

/// A part's state, like Posing's edits. Each takes its `ctx` and locks what it needs itself.
pub const State = struct {
    ctx: *anyopaque,
    /// Bumped on every change, so finding none costs nothing
    version: *const fn (*anyopaque) u64,
    /// All of it, in `a`, or null if out of memory
    save: *const fn (*anyopaque, a: std.mem.Allocator) ?[]u8,
    /// Back to what `save` gave
    load: *const fn (*anyopaque, bytes: []const u8) void,

    /// From `Impl`'s pub `version`, `save` and `load`, each taking `ctx` first.
    pub fn of(ctx: anytype, comptime Impl: type) State {
        const T = @TypeOf(ctx);
        const S = struct {
            fn me(p: *anyopaque) T {
                return @ptrCast(@alignCast(p));
            }
            fn version(p: *anyopaque) u64 {
                return Impl.version(me(p));
            }
            fn save(p: *anyopaque, a: std.mem.Allocator) ?[]u8 {
                return Impl.save(me(p), a);
            }
            fn load(p: *anyopaque, bytes: []const u8) void {
                Impl.load(me(p), bytes);
            }
        };
        return .{ .ctx = @ptrCast(@constCast(ctx)), .version = S.version, .save = S.save, .load = S.load };
    }
};

/// Every part's state at once, in the order they were added.
const Snapshot = struct {
    parts: [][]u8,

    fn free(s: Snapshot, a: std.mem.Allocator) void {
        for (s.parts) |p| a.free(p);
        a.free(s.parts);
    }

    fn eql(a: Snapshot, b: Snapshot) bool {
        if (a.parts.len != b.parts.len) return false;
        for (a.parts, b.parts) |x, y| if (!std.mem.eql(u8, x, y)) return false;
        return true;
    }
};

const Tracked = struct { state: State, seen: u64 = 0 };

/// Steps kept to go back.
pub const max = 100;

allocator: std.mem.Allocator,
states: std.ArrayList(Tracked) = .empty,
/// What's there now, which undoing goes back from. Null till the first tick
now: ?Snapshot = null,
undos: std.ArrayList(Snapshot) = .empty,
redos: std.ArrayList(Snapshot) = .empty,

pub fn init(allocator: std.mem.Allocator) History {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *History) void {
    self.forget();
    self.states.deinit(self.allocator);
    self.undos.deinit(self.allocator);
    self.redos.deinit(self.allocator);
}

/// Starts afresh, since the snapshots so far don't have it.
pub fn add(self: *History, state: State) !void {
    try self.states.append(self.allocator, .{ .state = state });
    self.forget();
}

/// Every step and what's now.
fn forget(self: *History) void {
    if (self.now) |n| n.free(self.allocator);
    self.now = null;
    for (self.undos.items) |s| s.free(self.allocator);
    self.undos.clearRetainingCapacity();
    for (self.redos.items) |s| s.free(self.allocator);
    self.redos.clearRetainingCapacity();
}

/// Once a frame. While `busy`, like mid-drag, changes wait, so the whole edit's one step.
pub fn tick(self: *History, busy: bool) void {
    if (self.now == null) {
        self.now = self.snapshot();
        self.see();
        return;
    }
    if (busy or !self.changed()) return;
    const next = self.snapshot() orelse return;
    self.see();
    const now = self.now.?;
    // Changed and back again, or touched without changing
    if (next.eql(now)) return next.free(self.allocator);
    if (self.undos.items.len == max) self.undos.orderedRemove(0).free(self.allocator);
    self.undos.append(self.allocator, now) catch {
        now.free(self.allocator);
    };
    for (self.redos.items) |s| s.free(self.allocator);
    self.redos.clearRetainingCapacity();
    self.now = next;
}

pub fn canUndo(self: *const History) bool {
    return self.undos.items.len > 0;
}

pub fn canRedo(self: *const History) bool {
    return self.redos.items.len > 0;
}

pub fn undo(self: *History) void {
    self.step(&self.undos, &self.redos);
}

pub fn redo(self: *History) void {
    self.step(&self.redos, &self.undos);
}

/// Back to the last of `from`, keeping what's now on `to`.
fn step(self: *History, from: *std.ArrayList(Snapshot), to: *std.ArrayList(Snapshot)) void {
    const now = self.now orelse return;
    const back = from.pop() orelse return;
    to.append(self.allocator, now) catch {
        from.appendAssumeCapacity(back);
        return;
    };
    self.now = back;
    for (self.states.items, back.parts) |*t, part| t.state.load(t.state.ctx, part);
    self.see();
}

fn changed(self: *const History) bool {
    for (self.states.items) |t| if (t.state.version(t.state.ctx) != t.seen) return true;
    return false;
}

fn see(self: *History) void {
    for (self.states.items) |*t| t.seen = t.state.version(t.state.ctx);
}

fn snapshot(self: *History) ?Snapshot {
    const parts = self.allocator.alloc([]u8, self.states.items.len) catch return null;
    for (self.states.items, 0..) |t, i| {
        parts[i] = t.state.save(t.state.ctx, self.allocator) orelse {
            for (parts[0..i]) |p| self.allocator.free(p);
            self.allocator.free(parts);
            return null;
        };
    }
    return .{ .parts = parts };
}

const testing = std.testing;

/// A number that counts its changes.
const Counter = struct {
    value: u32 = 0,
    changes: u64 = 0,

    fn set(c: *Counter, v: u32) void {
        c.value = v;
        c.changes += 1;
    }

    pub fn version(c: *Counter) u64 {
        return c.changes;
    }

    pub fn save(c: *Counter, a: std.mem.Allocator) ?[]u8 {
        return a.dupe(u8, std.mem.asBytes(&c.value)) catch null;
    }

    pub fn load(c: *Counter, bytes: []const u8) void {
        c.value = std.mem.bytesToValue(u32, bytes);
        c.changes += 1;
    }
};

test "a change is a step once nothing's busy, and undo and redo go back and forth" {
    var h: History = .init(testing.allocator);
    defer h.deinit();
    var c: Counter = .{};
    try h.add(.of(&c, Counter));
    h.tick(false);
    try testing.expect(!h.canUndo());

    // A drag: many changes, one step once it's let go
    for (1..5) |v| {
        c.set(@intCast(v));
        h.tick(true);
    }
    try testing.expect(!h.canUndo());
    h.tick(false);
    try testing.expect(h.canUndo());
    c.set(10);
    h.tick(false);

    h.undo();
    try testing.expectEqual(4, c.value);
    h.undo();
    try testing.expectEqual(0, c.value);
    try testing.expect(!h.canUndo());
    h.redo();
    try testing.expectEqual(4, c.value);
    // Undoing isn't itself a step
    h.tick(false);
    try testing.expect(h.canRedo());

    // A new change drops what could be redone
    c.set(7);
    h.tick(false);
    try testing.expect(!h.canRedo());
    h.undo();
    try testing.expectEqual(4, c.value);
}

test "a change that ends where it started isn't a step, and only so many are kept" {
    var h: History = .init(testing.allocator);
    defer h.deinit();
    var c: Counter = .{};
    try h.add(.of(&c, Counter));
    h.tick(false);
    c.set(3);
    c.set(0);
    h.tick(false);
    try testing.expect(!h.canUndo());

    for (1..max + 20) |v| {
        c.set(@intCast(v));
        h.tick(false);
    }
    try testing.expectEqual(max, h.undos.items.len);
}
