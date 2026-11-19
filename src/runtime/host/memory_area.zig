//! The `Memory` area, from `memory.sal`. Reads and writes go through `tuft_mem`, which checks pages
//! first. Value scans run on workers, see `scans.zig`.

const std = @import("std");

const api = @import("wraith_api");
const mem = @import("tuft_mem");

const host = @import("root.zig");
const scans = @import("scans.zig");
const scratch = @import("scratch.zig");
const wraith = @import("wraith.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;

const sal = api.salamander;
const W = api.wraith;
pub const Memory = W.Memory;
pub const MemoryScan = W.MemoryScan;
const ModuleInfo = W.Module;
const Region = W.Region;

const local = mem.Memory.local;
const allocator = std.heap.page_allocator;
/// Bigger than anyone should read at once.
const max_read = 16 << 20;
const default_text = 4096;

fn Read(comptime name: []const u8) type {
    return sal.Plain(Memory, name);
}

fn reader(comptime T: type, comptime name: []const u8) fn (*Loaded, usize) Read(name) {
    return struct {
        fn f(_: *Loaded, address: usize) Read(name) {
            return local.load(T, address) catch error.Unreadable;
        }
    }.f;
}

fn writer(comptime T: type, comptime name: []const u8) fn (*Loaded, usize, T) Read(name) {
    return struct {
        fn f(_: *Loaded, address: usize, value: T) Read(name) {
            local.store(T, address, value) catch return error.Unwritable;
        }
    }.f;
}

fn moduleError(err: anyerror) error{ NoModule, Failed } {
    return if (err == error.ModuleNotFound) error.NoModule else error.Failed;
}

/// The exe for an empty name.
fn moduleNamed(name: []const u8) error{ NoModule, Failed }!mem.Module {
    if (name.len == 0) return mem.Module.main();
    return mem.Module.find(name) catch |err| moduleError(err);
}

fn infoOf(a: std.mem.Allocator, m: mem.Module) ModuleInfo {
    var buf: [260]u8 = undefined;
    const name = a.dupe(u8, m.name(&buf) orelse "") catch "";
    return .{ .name = name, .base = m.base, .size = m.size() catch 0 };
}

pub const Impl = struct {
    pub const readU8 = reader(u8, "readU8");
    pub const readU16 = reader(u16, "readU16");
    pub const readU32 = reader(u32, "readU32");
    pub const readU64 = reader(u64, "readU64");
    pub const readI8 = reader(i8, "readI8");
    pub const readI16 = reader(i16, "readI16");
    pub const readI32 = reader(i32, "readI32");
    pub const readI64 = reader(i64, "readI64");
    pub const readF32 = reader(f32, "readF32");
    pub const readF64 = reader(f64, "readF64");
    pub const readPointer = reader(usize, "readPointer");

    pub const writeU8 = writer(u8, "writeU8");
    pub const writeU16 = writer(u16, "writeU16");
    pub const writeU32 = writer(u32, "writeU32");
    pub const writeU64 = writer(u64, "writeU64");
    pub const writeI8 = writer(i8, "writeI8");
    pub const writeI16 = writer(i16, "writeI16");
    pub const writeI32 = writer(i32, "writeI32");
    pub const writeI64 = writer(i64, "writeI64");
    pub const writeF32 = writer(f32, "writeF32");
    pub const writeF64 = writer(f64, "writeF64");
    pub const writePointer = writer(usize, "writePointer");

    pub fn readString(_: *Loaded, address: usize, max: u32) Read("readString") {
        return readUntilZero(scratch.begin(), u8, address, if (max == 0) default_text else max) catch |err| switch (err) {
            error.Unreadable => error.Unreadable,
            error.OutOfMemory => error.Failed,
        };
    }

    /// Unpaired surrogates survive as WTF-8.
    pub fn readUtf16(_: *Loaded, address: usize, max: u32) Read("readUtf16") {
        const a = scratch.begin();
        const units = readUntilZero(a, u16, address, if (max == 0) default_text else max) catch |err| return switch (err) {
            error.Unreadable => error.Unreadable,
            error.OutOfMemory => error.Failed,
        };
        return std.unicode.wtf16LeToWtf8Alloc(a, units) catch error.Failed;
    }

    pub fn writeString(_: *Loaded, address: usize, value: []const u8) Read("writeString") {
        local.write(address, value) catch return error.Unwritable;
        local.store(u8, address + value.len, 0) catch return error.Unwritable;
    }

    pub fn writeUtf16(_: *Loaded, address: usize, value: []const u8) Read("writeUtf16") {
        const units = std.unicode.wtf8ToWtf16LeAllocZ(allocator, value) catch return error.Failed;
        defer allocator.free(units);
        local.write(address, std.mem.sliceAsBytes(units[0 .. units.len + 1])) catch return error.Unwritable;
    }

    pub fn readBytes(_: *Loaded, address: usize, length: u32) Read("readBytes") {
        if (length > max_read) return error.TooBig;
        const b = sal.blobs.make(length) catch return error.Failed;
        local.read(address, sal.blobs.mutable(b)) catch {
            b.release();
            return error.Unreadable;
        };
        return b;
    }

    pub fn writeBytes(_: *Loaded, address: usize, bytes: []const u8) Read("writeBytes") {
        local.write(address, bytes) catch return error.Unwritable;
    }

    pub fn isReadable(_: *Loaded, address: usize, length: usize) bool {
        return mem.isReadable(address, @max(length, 1));
    }

    pub fn main(_: *Loaded) ModuleInfo {
        return infoOf(scratch.begin(), mem.Module.main());
    }

    pub fn module(_: *Loaded, name: []const u8) Read("module") {
        if (name.len == 0) return error.NoModule;
        return infoOf(scratch.begin(), try moduleNamed(name));
    }

    pub fn containing(_: *Loaded, address: usize) Read("containing") {
        const m = mem.Module.containing(address) catch |err| return moduleError(err);
        return infoOf(scratch.begin(), m);
    }

    pub fn find(_: *Loaded, module_name: []const u8, name: []const u8, pattern: []const u8) Read("find") {
        const range = (try moduleNamed(module_name)).range() catch return error.Failed;
        var buf: [512]?u8 = undefined;
        const p = mem.pattern.parseInto(pattern, &buf) catch return error.InvalidPattern;
        return range.scanPattern(name, p).unwrap() catch |err| switch (err) {
            error.PatternNotFound => error.NotFound,
            error.PatternNotUnique => error.NotUnique,
            error.Unreadable => error.Unreadable,
            else => error.Failed,
        };
    }

    pub fn findAll(_: *Loaded, module_name: []const u8, pattern: []const u8, max: u32) Read("findAll") {
        const range = (try moduleNamed(module_name)).range() catch return error.Failed;
        var buf: [512]?u8 = undefined;
        const p = mem.pattern.parseInto(pattern, &buf) catch return error.InvalidPattern;
        const found = scratch.begin().alloc(usize, @min(if (max == 0) 1000 else max, 1 << 20)) catch return error.Failed;
        const n = range.findAll(p, found) catch |err| return if (err == error.Unreadable) error.Unreadable else error.Failed;
        return found[0..n];
    }

    pub fn regions(_: *Loaded, module_name: []const u8, all: bool) Read("regions") {
        var start: usize = 0;
        var end: usize = std.math.maxInt(usize);
        if (module_name.len > 0) {
            const range = (try moduleNamed(module_name)).range() catch return error.Failed;
            start = range.start;
            end = range.end();
        }
        const a = scratch.begin();
        var out: std.ArrayList(Region) = .empty;
        var names: ModuleNames = .{};
        var at = start;
        while (at < end) {
            var r = (if (all) mem.committedFrom(at) else local.regionFrom(at)) orelse break;
            if (r.start >= end) break;
            const r_end = r.start +| r.len;
            // Past the top ends it
            at = if (r_end > r.start) r_end else end;
            r.len = @min(r_end, end) - r.start;
            out.append(a, .{
                .start = r.start,
                .length = r.len,
                .readable = r.readable,
                .writable = r.writable,
                .executable = r.executable,
                .module = names.of(a, r.start),
            }) catch return error.Failed;
        }
        return out.items;
    }

    pub fn protect(loaded: *Loaded, address: usize, length: usize, protection: W.Protection) Read("protect") {
        const p: api.Protection = switch (protection) {
            inline .no_access, .read, .read_write, .read_execute, .read_write_execute => |x| @field(api.Protection, @tagName(x)),
            else => return error.Failed,
        };
        const old = host.memory.protect(loaded, address, length, p) catch |err| return switch (err) {
            error.ProtectFailed => error.ProtectFailed,
            error.OutOfMemory => error.Failed,
        };
        return switch (old) {
            inline else => |x| @field(W.Protection, @tagName(x)),
        };
    }

    pub fn scan(loaded: *Loaded, options: W.ScanOptions) ScanPromise {
        const pair = ScanPromise.make() catch return .{};
        startFirst(loaded, options, pair.resolver) catch |err| pair.resolver.fail(err);
        return pair.promise;
    }
};

const ScanPromise = sal.Plain(Memory, "scan");
const NextPromise = sal.Plain(MemoryScan, "next");
const ScanError = error{ InvalidValue, NoModule, Busy, Failed, Cancelled };

fn typeOf(t: W.ScanType) error{InvalidValue}!scans.Type {
    return switch (t) {
        inline .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64, .f32, .f64, .string, .utf16, .bytes => |x| @field(scans.Type, @tagName(x)),
        else => error.InvalidValue,
    };
}

fn startFirst(loaded: *Loaded, options: W.ScanOptions, resolver: wraith.ResolverOf(ScanPromise)) ScanError!void {
    const tables = wraith.tablesOf(loaded) orelse return error.Cancelled;
    const t = try typeOf(options.type);
    const text = options.value;
    _ = scans.boundOf(t, text) catch return error.InvalidValue;
    const where: mem.Search.Where = if (options.module.len > 0) blk: {
        const range = (moduleNamed(options.module) catch |err| return err).range() catch return error.Failed;
        break :blk .{ .range = .{ .start = range.start, .len = range.len } };
    } else if (options.length > 0)
        .{ .range = .{ .start = options.start, .len = options.length } }
    else
        .{ .all = .{ .writable_only = !options.read_only } };
    const step: scans.Step = .{ .first = .{
        .where = where,
        .text = allocator.dupe(u8, text) catch return error.Failed,
        .options = .{ .aligned = !options.unaligned, .limit = if (options.limit == 0) 1_000_000 else options.limit },
    } };
    const s = scans.Scan.create(loaded, t) catch {
        step.deinit();
        return error.Failed;
    };
    try Job.start(s, tables, step, .{ .first = resolver });
}

/// A scan's step on a worker. Only enters the plugin's owner to settle, so unloading doesn't wait
/// for a long search, it cancels it.
const Job = struct {
    scan: *scans.Scan,
    search: *mem.Search,
    value_type: scans.Type,
    owner: *sal.Owner,
    table: *const sal.Table(MemoryScan),
    step: scans.Step,
    done: union(enum) {
        first: wraith.ResolverOf(ScanPromise),
        next: wraith.ResolverOf(NextPromise),
    },

    /// Takes `step` either way.
    fn start(s: *scans.Scan, tables: *wraith.Tables, step: scans.Step, done: @FieldType(Job, "done")) ScanError!void {
        const search = blk: {
            s.lock.lock();
            defer s.lock.unlock();
            break :blk s.claim() catch |err| {
                step.deinit();
                return err;
            };
        };
        const job = allocator.create(Job) catch {
            step.deinit();
            s.land(done == .first);
            return error.Failed;
        };
        job.* = .{ .scan = s, .search = search, .value_type = s.value_type, .owner = tables.owner, .table = tables.memory_scan, .step = step, .done = done };
        const thread = std.Thread.spawn(.{}, run, .{job}) catch {
            step.deinit();
            allocator.destroy(job);
            s.land(done == .first);
            return error.Failed;
        };
        thread.detach();
    }

    fn run(job: *Job) void {
        defer {
            job.step.deinit();
            allocator.destroy(job);
        }
        const result = scans.run(job.value_type, job.search, job.step);
        const failed = if (result) |_| false else |_| true;
        job.scan.land(failed and job.done == .first);
        if (!job.owner.enter()) return switch (job.done) {
            inline else => |r| r.drop(),
        };
        defer job.owner.leave();
        if (result) |_| switch (job.done) {
            .first => |r| r.settle(.init(job.scan, job.table)),
            .next => |r| r.settle({}),
        } else |err| {
            const e: ScanError = switch (err) {
                error.Cancelled => error.Cancelled,
                error.NotComparable => error.InvalidValue,
                else => error.Failed,
            };
            switch (job.done) {
                inline else => |r| r.fail(e),
            }
        }
    }
};

pub const ScanImpl = struct {
    pub fn count(s: *scans.Scan) u64 {
        return s.count.load(.acquire);
    }

    pub fn next(s: *scans.Scan, compare: W.ScanCompare, value: []const u8, high: []const u8) NextPromise {
        const pair = NextPromise.make() catch return .{};
        startNext(s, compare, value, high, pair.resolver) catch |err| pair.resolver.fail(err);
        return pair.promise;
    }

    pub fn results(s: *scans.Scan, offset: u64, limit: u32) []const usize {
        s.lock.lockShared();
        defer s.lock.unlockShared();
        if (s.busy or s.gone) return &.{};
        const search = s.search orelse return &.{};
        const from: usize = @intCast(@min(offset, search.count));
        const n = @min(@as(usize, if (limit == 0) 1000 else limit), search.count - from);
        const out = scratch.begin().alloc(usize, n) catch return &.{};
        for (out, from..) |*o, i| o.* = search.address(i);
        return out;
    }

    pub fn destroy(s: *scans.Scan) void {
        s.destroy();
    }
};

fn startNext(s: *scans.Scan, compare: W.ScanCompare, value: []const u8, high: []const u8, resolver: wraith.ResolverOf(NextPromise)) ScanError!void {
    const tables = wraith.tablesOf(s.loaded) orelse return error.Cancelled;
    const t = s.value_type;
    const step: scans.Step = switch (compare) {
        .changed => .{ .next = .{ .compare = .changed } },
        .unchanged => .{ .next = .{ .compare = .unchanged } },
        .increased, .decreased => blk: {
            if (!scans.isNumber(t)) return error.InvalidValue;
            break :blk .{ .next = .{ .compare = if (compare == .increased) .increased else .decreased } };
        },
        .exact => blk: {
            _ = scans.boundOf(t, value) catch return error.InvalidValue;
            break :blk .{ .next = .{ .compare = .exact, .text = allocator.dupe(u8, value) catch return error.Failed } };
        },
        .greater, .less, .between => blk: {
            if (!scans.isNumber(t)) return error.InvalidValue;
            const low = scans.boundOf(t, value) catch return error.InvalidValue;
            const top: scans.Bound = if (compare == .between) scans.boundOf(t, high) catch return error.InvalidValue else .{};
            break :blk .{ .next = .{ .compare = switch (compare) {
                .greater => .greater,
                .less => .less,
                else => .between,
            }, .low = low, .high = top } };
        },
        else => return error.InvalidValue,
    };
    try Job.start(s, tables, step, .{ .next = resolver });
}

/// Names regions' modules, looking each one up once.
const ModuleNames = struct {
    base: usize = 0,
    end: usize = 0,
    name: []const u8 = "",

    fn of(self: *ModuleNames, a: std.mem.Allocator, at: usize) []const u8 {
        if (at >= self.base and at < self.end) return self.name;
        const m = mem.Module.containing(at) catch {
            self.* = .{};
            return "";
        };
        const range = m.range() catch return "";
        var buf: [260]u8 = undefined;
        self.* = .{ .base = range.start, .end = range.end(), .name = a.dupe(u8, m.name(&buf) orelse "") catch "" };
        return self.name;
    }
};

/// Excludes the 0. An unreadable page ends it, unless it's the first.
fn readUntilZero(a: std.mem.Allocator, comptime T: type, address: usize, max: u32) error{ Unreadable, OutOfMemory }![]T {
    var out: std.ArrayList(T) = .empty;
    var at = address;
    while (out.items.len < max) {
        const page_end = (at | 0xFFF) + 1;
        const n = @min((page_end - at) / @sizeOf(T), max - out.items.len);
        if (n == 0) {
            // A T that straddles two pages
            const v = local.load(T, at) catch break;
            if (v == 0) break;
            try out.append(a, v);
            at += @sizeOf(T);
            continue;
        }
        var chunk: [4096 / @sizeOf(T)]T = undefined;
        local.read(at, std.mem.sliceAsBytes(chunk[0..n])) catch {
            if (out.items.len == 0 and at == address) return error.Unreadable;
            break;
        };
        if (std.mem.indexOfScalar(T, chunk[0..n], 0)) |end| {
            try out.appendSlice(a, chunk[0..end]);
            break;
        }
        try out.appendSlice(a, chunk[0..n]);
        at += n * @sizeOf(T);
    }
    return out.items;
}

test "strings stop at 0 and max" {
    const text = "hello\x00world";
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    try std.testing.expectEqualStrings("hello", try readUntilZero(aa, u8, @intFromPtr(text.ptr), 100));
    try std.testing.expectEqualStrings("hel", try readUntilZero(aa, u8, @intFromPtr(text.ptr), 3));
    const wide = std.unicode.utf8ToUtf16LeStringLiteral("hi");
    try std.testing.expectEqualSlices(u16, wide, try readUntilZero(aa, u16, @intFromPtr(wide), 100));
    try std.testing.expectError(error.Unreadable, readUntilZero(aa, u8, 0x10, 100));
}

const tests = struct {
    const testing = std.testing;
    const sdk = @import("wraith_sdk");

    /// Something only this test has, to find in the exe.
    export const memory_area_marker = [_]u8{ 0x5A, 0xA5, 0x3C, 0xC3, 0x0F, 0xF0, 0x69, 0x96, 0x11, 0x77 };

    test "the game's memory, through a plugin's Wraith" {
        var loaded: Loaded = undefined;
        loaded.initForTest(testing.allocator, "kai");
        sdk.Owner.attach(loaded.root());
        defer sdk.Owner.detach();
        const m = sdk.wraith.root().?.memory();

        var words = [_]u32{ 7, 7, 7, 7 };
        const at = @intFromPtr(&words);
        try testing.expectEqual(7, try m.readU32(at));
        try m.writeU32(at, 9);
        try testing.expectEqual(9, words[0]);
        try m.writeF32(at + 4, 1.5);
        try testing.expectEqual(1.5, try m.readF32(at + 4));
        try m.writeI64(at + 8, -2);
        try testing.expectEqual(-2, try m.readI64(at + 8));
        try testing.expectEqual(at, try m.readPointer(@intFromPtr(&at)));
        try testing.expectError(error.Unreadable, m.readU32(0x10));
        try testing.expectError(error.Unwritable, m.writeU32(0x10, 1));
        try testing.expect(m.isReadable(at, 16));
        try testing.expect(!m.isReadable(0x10, 0));

        var text: [32]u8 = @splat(0xFF);
        try m.writeString(@intFromPtr(&text), "hello");
        try testing.expectEqualStrings("hello", try m.readString(@intFromPtr(&text), 0));
        try testing.expectEqualStrings("hel", try m.readString(@intFromPtr(&text), 3));
        try m.writeUtf16(@intFromPtr(&text), "hé");
        try testing.expectEqualStrings("hé", try m.readUtf16(@intFromPtr(&text), 0));
        try m.writeBytes(@intFromPtr(&text), &[_]u8{ 1, 2, 3 });
        const read = try m.readBytes(@intFromPtr(&text), 3);
        defer read.release();
        try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, read.bytes());
        try testing.expectError(error.Unreadable, m.readBytes(0x10, 3));

        const exe = m.main();
        try testing.expect(exe.base != 0 and exe.size > 0);
        try testing.expect(std.mem.endsWith(u8, exe.name, ".exe"));
        const name = try testing.allocator.dupe(u8, exe.name);
        defer testing.allocator.free(name);
        try testing.expectEqual(exe.base, (try m.module(name)).base);
        try testing.expectEqual(exe.base, (try m.containing(@intFromPtr(&memory_area_marker))).base);
        try testing.expectError(error.NoModule, m.module("nope.dll"));
        try testing.expectError(error.NoModule, m.containing(0x10));

        const found = try m.findAll("", "5A A5 3C C3 0F F0 69 96 11 77", 0);
        try testing.expect(std.mem.indexOfScalar(usize, found, @intFromPtr(&memory_area_marker)) != null);
        try testing.expectError(error.InvalidPattern, m.find("", "marker", "ZZ"));
        try testing.expectError(error.NoModule, m.find("nope.dll", "marker", "5A"));

        const regions = try m.regions(name, false);
        try testing.expect(regions.len > 0);
        try testing.expectEqual(exe.base, regions[0].start);
        try testing.expectEqualStrings(name, regions[0].module);

        // Protection's put back once the plugin goes
        const page = try std.heap.page_allocator.alloc(u8, 4096);
        defer std.heap.page_allocator.free(page);
        try testing.expectEqual(.read_write, try m.protect(@intFromPtr(page.ptr), 4096, .read));
        try testing.expectEqual(.read, try m.protect(@intFromPtr(page.ptr), 4096, .read_execute));
        loaded.deinitForTest();
        wraith.forget(&loaded);
        try testing.expectEqual(.read_write, try mem.protect(@intFromPtr(page.ptr), 4096, .read_write));
    }

    test "value scans narrow down on workers" {
        var loaded: Loaded = undefined;
        loaded.initForTest(testing.allocator, "kai");
        sdk.Owner.attach(loaded.root());
        defer sdk.Owner.detach();
        const m = sdk.wraith.root().?.memory();

        const words = try testing.allocator.alloc(u32, 64);
        defer testing.allocator.free(words);
        @memset(words, 1234);
        const bytes = std.mem.sliceAsBytes(words);
        const s = try m.scan(.{ .type = .u32, .value = .init("1234"), .start = @intFromPtr(bytes.ptr), .length = bytes.len }).wait();
        try testing.expectEqual(64, s.count());
        try testing.expectError(error.InvalidValue, m.scan(.{ .type = .u32, .value = .init("lots") }).wait());

        words[3] = 2000;
        words[9] = 3000;
        try s.next(.increased, "", "").wait();
        try testing.expectEqual(2, s.count());
        try s.next(.between, "2500", "3000").wait();
        try testing.expectEqualSlices(usize, &.{@intFromPtr(&words[9])}, s.results(0, 0));
        try testing.expectError(error.InvalidValue, s.next(.greater, "x", "").wait());

        s.destroy();
        try testing.expectEqual(0, s.count());
        try testing.expectError(error.Cancelled, s.next(.changed, "", "").wait());

        // What a plugin leaves goes with it
        const left = try m.scan(.{ .type = .u32, .value = .init("1234"), .start = @intFromPtr(bytes.ptr), .length = bytes.len }).wait();
        loaded.deinitForTest();
        wraith.forget(&loaded);
        try testing.expectEqual(0, left.count());
    }
};

test {
    _ = tests;
}
