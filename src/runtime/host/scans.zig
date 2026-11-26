//! Value scans plugins start, like Cheat Engine's. Searches run on a worker. Freed with the plugin or by `destroy`.

const std = @import("std");

const mem = @import("tuft_mem");
const sync = @import("tuft_sys").sync;
const Atomic = @import("tuft_arch").atomic.Value;

const host = @import("root.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;

const Search = mem.Search;
const parse = mem.values.parse;
const max_len = mem.values.max_len;
const allocator = std.heap.page_allocator;

/// What the scanned value is.
pub const Type = enum { u8, u16, u32, u64, i8, i16, i32, i64, f32, f64, string, utf16, bytes };

pub const Compare = enum { exact, changed, unchanged, increased, decreased, greater, less, between };

pub fn kindOf(t: Type) Search.Kind {
    return switch (t) {
        .u8, .i8 => .byte,
        .u16, .i16 => .two_bytes,
        .u32, .i32 => .four_bytes,
        .u64, .i64 => .eight_bytes,
        .f32 => .float,
        .f64 => .double,
        .string => .text,
        .utf16 => .text_utf16,
        .bytes => .bytes,
    };
}

pub fn isNumber(t: Type) bool {
    return switch (t) {
        .string, .utf16, .bytes => false,
        else => true,
    };
}

/// A value to look for or compare with, as bytes of `t`.
pub const Bound = struct {
    buf: [max_len]?u8 = undefined,
    len: usize = 0,

    pub fn get(self: *const Bound) []const ?u8 {
        return self.buf[0..self.len];
    }
};

pub fn boundOf(t: Type, text: []const u8) !Bound {
    var b: Bound = .{};
    b.len = (try parse(kindOf(t), text, &b.buf)).len;
    return b;
}

/// A number as it sits in memory, for comparing.
const Num = union(enum) {
    int: i128,
    float: f64,

    fn of(t: Type, bytes: []const u8) Num {
        return switch (t) {
            .u8 => .{ .int = bytes[0] },
            .i8 => .{ .int = @as(i8, @bitCast(bytes[0])) },
            .u16 => .{ .int = std.mem.readInt(u16, bytes[0..2], .little) },
            .i16 => .{ .int = std.mem.readInt(i16, bytes[0..2], .little) },
            .u32 => .{ .int = std.mem.readInt(u32, bytes[0..4], .little) },
            .i32 => .{ .int = std.mem.readInt(i32, bytes[0..4], .little) },
            .u64 => .{ .int = std.mem.readInt(u64, bytes[0..8], .little) },
            .i64 => .{ .int = std.mem.readInt(i64, bytes[0..8], .little) },
            .f32 => .{ .float = @as(f32, @bitCast(std.mem.readInt(u32, bytes[0..4], .little))) },
            .f64 => .{ .float = @as(f64, @bitCast(std.mem.readInt(u64, bytes[0..8], .little))) },
            .string, .utf16, .bytes => unreachable,
        };
    }

    /// Null for NaN.
    fn order(a: Num, b: Num) ?std.math.Order {
        return switch (a) {
            .int => |x| std.math.order(x, b.int),
            .float => |x| if (std.math.isNan(x) or std.math.isNan(b.float)) null else std.math.order(x, b.float),
        };
    }

    fn fromBound(t: Type, b: Bound) Num {
        var bytes: [8]u8 = undefined;
        for (b.get(), 0..) |byte, i| bytes[i] = byte orelse 0;
        return of(t, bytes[0..b.len]);
    }
};

/// What a worker runs, made before it starts.
pub const Step = union(enum) {
    first: struct { where: Search.Where, text: []u8, options: Search.Options },
    next: struct { compare: Compare, low: Bound = .{}, high: Bound = .{}, text: []u8 = &.{} },

    pub fn deinit(self: Step) void {
        switch (self) {
            .first => |f| allocator.free(f.text),
            .next => |n| allocator.free(n.text),
        }
    }
};

/// On the worker that owns `search` while busy.
pub fn run(scan_type: Type, search: *Search, step: Step) !void {
    switch (step) {
        .first => |f| try search.first(f.where, kindOf(scan_type), f.text, f.options),
        .next => |n| switch (n.compare) {
            .exact => try search.next(.exact, n.text),
            .changed => try search.next(.changed, ""),
            .unchanged => try search.next(.unchanged, ""),
            else => {
                const Test = struct {
                    t: Type,
                    compare: Compare,
                    low: Num,
                    high: Num,

                    fn keep(self: @This(), now_bytes: []const u8, before_bytes: []const u8) bool {
                        const now = Num.of(self.t, now_bytes);
                        return switch (self.compare) {
                            .increased => now.order(Num.of(self.t, before_bytes)) == .gt,
                            .decreased => now.order(Num.of(self.t, before_bytes)) == .lt,
                            .greater => now.order(self.low) == .gt,
                            .less => now.order(self.low) == .lt,
                            .between => {
                                const lo = now.order(self.low) orelse return false;
                                const hi = now.order(self.high) orelse return false;
                                return lo != .lt and hi != .gt;
                            },
                            else => unreachable,
                        };
                    }
                };
                const uses_low = n.compare == .greater or n.compare == .less or n.compare == .between;
                try search.narrow(Test{
                    .t = scan_type,
                    .compare = n.compare,
                    .low = if (uses_low) Num.fromBound(scan_type, n.low) else .{ .int = 0 },
                    .high = if (n.compare == .between) Num.fromBound(scan_type, n.high) else .{ .int = 0 },
                }, Test.keep);
            },
        },
    }
}

/// One plugin's scan. Kept till the plugin's freed, since its object can outlive its results.
pub const Scan = struct {
    loaded: *Loaded,
    value_type: Type,
    lock: sync.RwLock = .{},
    /// Null once it's freed.
    search: ?*Search,
    /// A worker owns `search` till it lands. Under `lock`.
    busy: bool = false,
    /// Destroyed, or the plugin's going. Under `lock`.
    gone: bool = false,
    count: Atomic(u64) = .init(0),

    /// Freed with the plugin.
    pub fn create(loaded: *Loaded, t: Type) !*Scan {
        const search = try allocator.create(Search);
        search.* = .init(.local);
        const self = allocator.create(Scan) catch |err| {
            allocator.destroy(search);
            return err;
        };
        self.* = .{ .loaded = loaded, .value_type = t, .search = search };
        scans.add(self) catch |err| {
            self.freeSearch();
            allocator.destroy(self);
            return err;
        };
        return self;
    }

    /// Frees its results, or has the worker do it as it lands. Safe twice.
    pub fn destroy(self: *Scan) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.gone = true;
        self.count.store(0, .release);
        const s = self.search orelse return;
        if (self.busy) return s.cancel();
        self.freeSearch();
    }

    pub fn stop(self: *Scan) void {
        self.destroy();
    }

    pub fn free(self: *Scan) void {
        self.destroy();
        // The worker's landing, which is quick once it's cancelled
        while (true) {
            self.lock.lockShared();
            const busy = self.busy;
            self.lock.unlockShared();
            if (!busy) break;
            std.Thread.yield() catch {};
        }
        allocator.destroy(self);
    }

    fn freeSearch(self: *Scan) void {
        const s = self.search orelse return;
        self.search = null;
        s.deinit();
        allocator.destroy(s);
    }

    /// Under `lock`. Marks it busy, so `land` has to follow.
    pub fn claim(self: *Scan) error{ Busy, Cancelled }!*Search {
        if (self.gone) return error.Cancelled;
        if (self.busy) return error.Busy;
        const s = self.search orelse return error.Cancelled;
        self.busy = true;
        return s;
    }

    /// After a worker's step. `drop` discards a failed first search's results. Nothing of it can be touched after.
    pub fn land(self: *Scan, drop: bool) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.busy = false;
        if (drop) self.gone = true;
        if (self.gone) return self.freeSearch();
        if (self.search) |s| self.count.store(s.count, .release);
    }
};

var scans: host.Owned(Scan) = .{};

test "numbers compare as their type" {
    var search: Search = .init(.local);
    defer search.deinit();
    const words = try std.testing.allocator.alloc(u32, 3);
    defer std.testing.allocator.free(words);
    @memset(words, 7);
    const bytes = std.mem.sliceAsBytes(words);
    try run(.u32, &search, .{ .first = .{ .where = .{ .range = .{ .start = @intFromPtr(bytes.ptr), .len = bytes.len } }, .text = @constCast("7"), .options = .{} } });
    try std.testing.expectEqual(3, search.count);
    words[0] = 0x9000_0000;
    words[1] = 9;
    // Unsigned, so the big one is greater
    try run(.u32, &search, .{ .next = .{ .compare = .greater, .low = try boundOf(.u32, "8") } });
    try std.testing.expectEqual(2, search.count);
    try run(.u32, &search, .{ .next = .{ .compare = .between, .low = try boundOf(.u32, "9"), .high = try boundOf(.u32, "10") } });
    try std.testing.expectEqual(1, search.count);
    try std.testing.expectEqual(@intFromPtr(&words[1]), search.address(0));
}
