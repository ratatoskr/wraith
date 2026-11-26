//! File > Import Cheat Engine table. Read and converted on its own thread; the render thread only
//! takes the finished files as the project.

const CeImport = @This();

const std = @import("std");

const ce = @import("wraith_importer").ce;
const ui = @import("wraith_ui");
const sync = @import("tuft_sys").sync;

const StatusBar = @import("StatusBar.zig");
const Workbench = @import("Workbench.zig");

const done_popup = "Imported##ce";

lock: sync.RwLock = .{},
worker: ?std.Thread = null,
running: bool = false,
/// Left by the worker for the render thread.
finished: ?*Result = null,
allocator: ?std.mem.Allocator = null,
/// How the last one went, for its popup.
summary: std.ArrayList(u8) = .empty,
open_popup: bool = false,

const Result = struct {
    arena: std.heap.ArenaAllocator,
    files: []const ce.File = &.{},
    stats: ce.Stats = .{},
    err: ?anyerror = null,
};

pub fn deinit(self: *CeImport) void {
    if (self.worker) |w| w.join();
    self.worker = null;
    const gpa = self.allocator orelse return;
    if (self.finished) |r| free(gpa, r);
    self.finished = null;
    self.summary.deinit(gpa);
}

pub fn busy(self: *CeImport) bool {
    self.lock.lock();
    defer self.lock.unlock();
    return self.running;
}

/// Render thread. Unless one's already going.
pub fn start(self: *CeImport, wb: *Workbench, path: []const u8) void {
    const io = wb.io orelse return;
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
    const result = gpa.create(Result) catch return self.failed(wb, error.OutOfMemory);
    result.* = .{ .arena = .init(gpa) };
    const owned = result.arena.allocator().dupe(u8, path) catch {
        free(gpa, result);
        return self.failed(wb, error.OutOfMemory);
    };
    self.worker = std.Thread.spawn(.{}, work, .{ self, io, gpa, result, owned }) catch |err| {
        free(gpa, result);
        return self.failed(wb, err);
    };
}

/// In the status bar while it's going.
pub fn status(self: *CeImport, bar: *StatusBar) void {
    if (!self.busy()) return;
    _ = bar.item(.{ .id = "##ce_import", .text = "Importing Cheat Engine table", .color = .{ 1, 0.75, 0.3, 1 }, .tooltip = "It becomes the project once it's done" });
}

fn failed(self: *CeImport, wb: *Workbench, err: anyerror) void {
    self.lock.lock();
    self.running = false;
    self.lock.unlock();
    wb.fail("Couldn't import it: {t}", .{err});
}

fn free(gpa: std.mem.Allocator, result: *Result) void {
    result.arena.deinit();
    gpa.destroy(result);
}

// The worker. File calls and the import stay off the render thread

fn work(self: *CeImport, io: std.Io, gpa: std.mem.Allocator, result: *Result, path: []const u8) void {
    convert(io, gpa, result, path) catch |err| {
        result.err = err;
    };
    self.lock.lock();
    defer self.lock.unlock();
    self.finished = result;
    self.running = false;
}

fn convert(io: std.Io, gpa: std.mem.Allocator, result: *Result, path: []const u8) !void {
    const arena = result.arena.allocator();
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20));
    const project = try ce.import(arena, gpa, source, .{ .name = std.fs.path.basename(path) });
    result.files = project.files;
    result.stats = project.stats;
}

/// Render thread, every frame, inside the workbench's window. True when an import became the project.
pub fn poll(self: *CeImport, wb: *Workbench) bool {
    const result = blk: {
        self.lock.lock();
        defer self.lock.unlock();
        const r = self.finished orelse break :blk null;
        self.finished = null;
        break :blk r;
    };
    var loaded = false;
    if (result) |r| {
        const gpa = self.allocator.?;
        defer free(gpa, r);
        if (r.err) |err| {
            wb.fail("Couldn't import it: {t}", .{err});
        } else if (wb.project) |project| {
            wb.dropEditors();
            if (project.load(r.files)) {
                loaded = true;
                const s = r.stats;
                self.summary.clearRetainingCapacity();
                self.summary.print(gpa, "{d} scripts became tweaks, {d} are off for review and {d} are Lua that runs with the CE layer.\n{d} records went to the Addresses list.\n\nWhat needs a look is in import-report.md in the project. Save it to keep it.", .{ s.clean, s.review, s.lua, s.records }) catch {};
                self.open_popup = true;
            } else |err| wb.fail("Couldn't import it: {t}", .{err});
        }
    }
    if (self.open_popup) {
        self.open_popup = false;
        ui.openPopup(done_popup);
    }
    if (ui.modal(done_popup, .{ .remember = true })) |done| {
        defer done.end();
        ui.text("{s}", .{self.summary.items});
        if (ui.button("OK") or ui.isKeyPressed(.escape, false)) ui.closePopup();
    }
    return loaded;
}
