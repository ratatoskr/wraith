//! The game's unhooked code: a snapshot at startup, and the exe read from disk for earlier hooks.

const OriginalCode = @This();

const std = @import("std");

const core = @import("wraith_core");
const memory = @import("tuft_mem");
const Atomic = @import("tuft_arch").atomic.Value;
const tuft_sys = @import("tuft_sys");

const log = core.log.scoped(.wraith_runtime);

pub const heap_name = "game code copy";
pub const disk_heap_name = "game exe from disk";

/// How long a lookup waits for the exe to be read, the first time it needs it.
const disk_wait_ms = 5000;

tracked: core.heap.TrackedAllocator = undefined,
disk_tracked: core.heap.TrackedAllocator = undefined,
snapshot: ?memory.CodeSnapshot = null,
disk: ?memory.DiskImage = null,
/// Set once reading the exe is done, whether it worked or not.
disk_done: Atomic(bool) = .init(true),
reader: ?std.Thread = null,
previous_disk: ?memory.originals.Provider = null,

pub var global: OriginalCode = .{};

/// Must not move until `release`. With `io`, the exe's read from disk too, on a worker.
pub fn take(self: *OriginalCode, child: std.mem.Allocator, io: ?std.Io) void {
    self.* = .{};
    self.tracked.init(child, heap_name);
    core.heap.registry.add(&self.tracked.usage);
    self.disk_tracked.init(child, disk_heap_name);
    core.heap.registry.add(&self.disk_tracked.usage);
    self.snapshot = memory.CodeSnapshot.take(self.tracked.allocator(), memory.Module.main().base) catch |err| blk: {
        log.warn("Couldn't copy the game's code: {t}", .{err});
        break :blk null;
    };
    if (self.snapshot) |*snapshot| {
        snapshot.install();
        log.info("Copied {d} code section(s) of the game ({Bi:.1}) for scans of its original code", .{ snapshot.sections.items.len, snapshot.size() });
    }
    const i = io orelse return;
    self.disk_done.store(false, .release);
    self.previous_disk = memory.originals.setProvider(.disk, provideDisk);
    self.reader = std.Thread.spawn(.{}, readDisk, .{ self, i }) catch |err| {
        log.warn("Couldn't read the game's exe: {t}", .{err});
        self.disk_done.store(true, .release);
        return;
    };
}

pub fn release(self: *OriginalCode) void {
    if (self.reader) |t| t.join();
    if (!self.disk_done.load(.acquire) or self.reader != null) _ = memory.originals.setProvider(.disk, self.previous_disk);
    if (self.disk) |*d| d.deinit();
    if (self.snapshot) |*s| s.deinit();
    core.heap.registry.remove(&self.tracked.usage);
    core.heap.registry.remove(&self.disk_tracked.usage);
    self.* = .{};
}

/// `source`'s copy of `start..start+len`. Waits for the exe to be read, for the disk one.
pub fn find(self: *const OriginalCode, source: memory.AddressSource, start: usize, len: usize) ?[*]const u8 {
    return switch (source) {
        .live => null,
        .snapshot => (self.snapshot orelse return null).find(start, len),
        .disk => blk: {
            self.waitForDisk();
            break :blk (self.disk orelse return null).find(start, len);
        },
    };
}

fn waitForDisk(self: *const OriginalCode) void {
    var waited: u32 = 0;
    while (!self.disk_done.load(.acquire) and waited < disk_wait_ms) : (waited += 5) tuft_sys.thread.sleepMs(5);
}

fn provideDisk(start: usize, len: usize) ?[*]const u8 {
    return global.find(.disk, start, len);
}

fn readDisk(self: *OriginalCode, io: std.Io) void {
    defer self.disk_done.store(true, .release);
    const main = memory.Module.main();
    var path_buf: [1024]u8 = undefined;
    const path = main.path(&path_buf) orelse {
        log.warn("Couldn't find the game's exe to read", .{});
        return;
    };
    const gpa = self.disk_tracked.allocator();
    const file = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| {
        log.warn("Couldn't read the game's exe from disk: {t}", .{err});
        return;
    };
    defer gpa.free(file);
    const image = memory.DiskImage.fromFile(gpa, file, main.base) catch |err| {
        log.warn("Couldn't lay out the game's exe from disk: {t}", .{err});
        return;
    };
    self.disk = image;
    log.info("Read the game's exe from disk ({Bi:.1} of code) for scans of code hooked before Wraith started", .{image.size()});
}

test "scans read the copy" {
    global.take(std.testing.allocator, std.testing.io);
    defer global.release();
    const snapshot = &global.snapshot.?;
    try std.testing.expect(snapshot.sections.items.len > 0);

    var heaps: [64]core.heap.Stats = undefined;
    var listed = false;
    for (heaps[0..core.heap.registry.snapshot(&heaps)]) |h| {
        if (std.mem.eql(u8, h.name(), heap_name)) {
            listed = true;
            try std.testing.expect(h.live_bytes >= snapshot.size());
        }
    }
    try std.testing.expect(listed);

    const text = try memory.Module.main().text();
    try std.testing.expect(global.find(.snapshot, text.start, text.len) != null);
    try std.testing.expectEqual(null, global.find(.snapshot, text.start, text.len + 1));
    // The disk copy waits for the exe to be read, then has the same code
    const disk = global.find(.disk, text.start, text.len).?;
    try std.testing.expectEqualSlices(u8, @as([*]const u8, @ptrFromInt(text.start))[0..64], disk[0..64]);

    // The code is read-only, so "hook" it by changing the copy instead
    const copy = snapshot.sections.items[0];
    const offset = copy.copy.len / 2;
    const marker = [_]u8{ 0xF1, 0xE2, 0xD3, 0xC4, 0xB5, 0xA6, 0x97, 0x88, 0x79, 0x6A, 0x5B, 0x4C };
    @memcpy(copy.copy[offset..][0..marker.len], &marker);
    const range: memory.Range = .{ .start = copy.start, .len = copy.copy.len };
    const signature = "F1 E2 D3 C4 B5 A6 97 88 79 6A 5B 4C";
    try std.testing.expectEqual(copy.start + offset, try range.original().scan("marker", signature).unwrap());
    try std.testing.expectError(error.PatternNotFound, range.scan("marker", signature).unwrap());
    try std.testing.expectError(error.PatternNotFound, range.from(.disk).scan("marker", signature).unwrap());
}
