//! Make signature, from the code and memory views. It's worked out on a thread of its own, since
//! it scans the module's code over and over. The shortest one found is copied as a location, and
//! the menu bar says so.

const SigMaker = @This();

const std = @import("std");

const core = @import("wraith_core");
const tuft_arch = @import("tuft_arch");
const Atomic = tuft_arch.atomic.Value;
const sig_maker = @import("tuft_mem").sig_maker;
const sync = @import("tuft_sys").sync;
const Text = @import("tuft_text").Text;
const ui = @import("wraith_ui");

const Workbench = @import("Workbench.zig");

const log = core.log.scoped(.wraith_ui);

/// How long the menu bar says what was copied.
const notice_ns = 6 * std.time.ns_per_s;

lock: sync.RwLock = .{},
worker: ?std.Thread = null,
running: bool = false,
cancel: Atomic(bool) = .init(false),
progress: Atomic(u32) = .init(0),
/// Left by the worker for the render thread.
finished: ?*Result = null,
allocator: ?std.mem.Allocator = null,
/// What was copied, till `notice_until`.
notice: Text(320) = .{},
notice_until: u64 = 0,

const Result = struct {
    arena: std.heap.ArenaAllocator,
    address: usize,
    /// Location text, like `sig("E8 ?? ?? ?? ??", Rip)`.
    location: [:0]const u8 = "",
    found: ?sig_maker.Found = null,
    ms: u64 = 0,
    err: ?anyerror = null,
};

pub fn deinit(self: *SigMaker) void {
    self.cancel.store(true, .monotonic);
    if (self.worker) |w| w.join();
    self.worker = null;
    const gpa = self.allocator orelse return;
    if (self.finished) |r| free(gpa, r);
    self.finished = null;
}

pub fn busy(self: *SigMaker) bool {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    return self.running;
}

/// Render thread. Unless one's already going.
pub fn start(self: *SigMaker, wb: *Workbench, address: usize) void {
    const gpa = wb.allocator;
    self.allocator = gpa;
    {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.running) return;
        self.running = true;
    }
    // The last one's done, so this doesn't wait
    if (self.worker) |w| w.join();
    self.worker = null;
    self.cancel.store(false, .monotonic);
    self.progress.store(0, .monotonic);
    self.notice_until = 0;
    const result = gpa.create(Result) catch return self.failed(wb, error.OutOfMemory);
    result.* = .{ .arena = .init(gpa), .address = address };
    self.worker = std.Thread.spawn(.{}, work, .{ self, result }) catch |err| {
        free(gpa, result);
        return self.failed(wb, err);
    };
}

fn failed(self: *SigMaker, wb: *Workbench, err: anyerror) void {
    self.lock.lock();
    self.running = false;
    self.lock.unlock();
    wb.problem = .init("Couldn't make a signature: {t}", .{err});
}

fn free(gpa: std.mem.Allocator, result: *Result) void {
    result.arena.deinit();
    gpa.destroy(result);
}

// The worker

fn work(self: *SigMaker, result: *Result) void {
    const started = core.timing.now();
    make(self, result) catch |err| {
        result.err = err;
    };
    result.ms = (core.timing.now() -| started) / std.time.ns_per_ms;
    self.lock.lock();
    defer self.lock.unlock();
    self.finished = result;
    self.running = false;
}

fn make(self: *SigMaker, result: *Result) !void {
    const arena = result.arena.allocator();
    const made = try sig_maker.forAddress(arena, result.address, .{ .cancel = &self.cancel, .progress = &self.progress }) orelse return;
    result.found = made.found;
    result.location = try std.fmt.allocPrintSentinel(arena, "{f}", .{made.sig}, 0);
}

/// Render thread, every frame. Copies a finished one.
pub fn poll(self: *SigMaker, wb: *Workbench) void {
    const r = blk: {
        self.lock.lock();
        defer self.lock.unlock();
        const r = self.finished orelse return;
        self.finished = null;
        break :blk r;
    };
    defer free(self.allocator.?, r);
    if (r.err) |err| {
        if (err != error.Canceled) wb.problem = .init("Couldn't make a signature for 0x{x}: {t}", .{ r.address, err });
        return;
    }
    const f = r.found orelse {
        wb.problem = .init("Nothing unique at 0x{x} or the code that points to it", .{r.address});
        return;
    };
    ui.setClipboard(r.location);
    wb.problem = null;
    self.notice.set(r.location);
    self.notice_until = core.timing.now() + notice_ns;
    if (f.resolve.len == 0)
        log.info("Signature for 0x{x}, {d} bytes, in {d} ms: {s}", .{ r.address, f.pattern.len, r.ms, r.location })
    else
        log.info("Signature for 0x{x}, {d} bytes at code that points to it (0x{x}), in {d} ms: {s}", .{ r.address, f.pattern.len, f.at, r.ms, r.location });
}

/// In the menu bar. How it's going, or what was copied.
pub fn drawStatus(self: *SigMaker) void {
    if (self.busy()) {
        ui.sameLine();
        ui.textColored(.{ 1, 0.75, 0.3, 1 }, "Making a signature, {d} places tried", .{self.progress.load(.monotonic)});
        ui.sameLine();
        if (ui.smallButton("x##cancel_sig")) self.cancel.store(true, .monotonic);
        ui.tooltip("Stop looking", .{});
        return;
    }
    if (self.notice_until == 0) return;
    if (core.timing.now() > self.notice_until) {
        self.notice_until = 0;
        return;
    }
    ui.sameLine();
    ui.textColored(.{ 0.45, 0.85, 0.45, 1 }, "Copied {s}", .{self.notice.get()});
}
