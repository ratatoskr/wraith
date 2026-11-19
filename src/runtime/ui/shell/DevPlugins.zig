//! The dev plugins list in Settings. The file's read and changed on a worker, then the loader
//! rescans, so the render thread never touches it.

const DevPlugins = @This();

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const core = @import("wraith_core");
const Message = @import("tuft_text").Message;

const Shell = @import("Shell.zig");

const log = core.log.scoped(.wraith_ui);

pub const Entry = struct {
    folder: []const u8,
    /// Its plugin's id. Null if its wraith.json can't be read.
    id: ?[]const u8,
    problem: ?anyerror = null,
};

group: std.Io.Group = .init,
lock: std.Io.Mutex = .init,
/// Under `lock`, in `arena`.
entries: []const Entry = &.{},
arena: ?std.heap.ArenaAllocator = null,
/// Under `lock`. The last add or remove that failed.
problem: Message(160) = .{},
loaded: bool = false,
busy: Atomic(bool) = .init(false),

const Op = union(enum) {
    load,
    add: []u8,
    remove: []u8,
};

/// Waits for a change in flight.
pub fn deinit(self: *DevPlugins, io: std.Io) void {
    self.group.await(io) catch {};
    if (self.arena) |*a| a.deinit();
    self.* = .{};
}

/// Reads the list again. Any thread.
pub fn refresh(self: *DevPlugins, shell: *Shell) void {
    self.start(shell, .load);
}

/// Copied. Takes effect right away, with a rescan.
pub fn add(self: *DevPlugins, shell: *Shell, folder: []const u8) void {
    const copy = shell.allocator.dupe(u8, folder) catch return;
    self.start(shell, .{ .add = copy });
}

pub fn remove(self: *DevPlugins, shell: *Shell, folder: []const u8) void {
    const copy = shell.allocator.dupe(u8, folder) catch return;
    self.start(shell, .{ .remove = copy });
}

pub fn isBusy(self: *const DevPlugins) bool {
    return self.busy.load(.acquire);
}

/// One at a time. Another while one's going is dropped.
fn start(self: *DevPlugins, shell: *Shell, op: Op) void {
    const io = shell.options.io orelse return freeOp(shell, op);
    if (self.busy.swap(true, .acq_rel)) return freeOp(shell, op);
    self.group.concurrent(io, run, .{ self, shell, io, op }) catch {
        self.busy.store(false, .release);
        freeOp(shell, op);
    };
}

fn freeOp(shell: *Shell, op: Op) void {
    switch (op) {
        .load => {},
        .add, .remove => |f| shell.allocator.free(f),
    }
}

fn run(self: *DevPlugins, shell: *Shell, io: std.Io, op: Op) void {
    defer self.busy.store(false, .release);
    defer freeOp(shell, op);
    const loader = shell.acquireLoader() orelse return;
    defer shell.releaseLoader();

    var problem: Message(160) = .{};
    var changed = false;
    var scratch: std.heap.ArenaAllocator = .init(shell.allocator);
    defer scratch.deinit();
    switch (op) {
        .load => {},
        .add => |folder| changed = core.dev_plugins.add(scratch.allocator(), io, loader.dev_file, folder) catch |err| blk: {
            problem.print("Couldn't add {s}: {t}", .{ folder, err });
            break :blk false;
        },
        .remove => |folder| changed = core.dev_plugins.remove(scratch.allocator(), io, loader.dev_file, folder) catch |err| blk: {
            problem.print("Couldn't remove {s}: {t}", .{ folder, err });
            break :blk false;
        },
    }

    var arena: std.heap.ArenaAllocator = .init(shell.allocator);
    const entries = list(arena.allocator(), io, loader.dev_file) catch |err| blk: {
        log.warn("Couldn't read the dev plugins in {s}: {t}", .{ loader.dev_file, err });
        break :blk &.{};
    };
    if (changed) _ = loader.rescan() catch |err| log.warn("Couldn't rescan plugins: {t}", .{err});

    self.lock.lockUncancelable(io);
    defer self.lock.unlock(io);
    if (self.arena) |*old| old.deinit();
    self.arena = arena;
    self.entries = entries;
    self.loaded = true;
    if (op != .load) self.problem = problem;
}

fn list(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]const Entry {
    const folders = try core.dev_plugins.load(a, io, path);
    const out = try a.alloc(Entry, folders.len);
    for (out, folders) |*e, folder| {
        e.* = .{ .folder = folder, .id = null };
        e.id = core.dev_plugins.nameOf(a, io, folder) catch |err| blk: {
            e.problem = err;
            break :blk null;
        };
    }
    return out;
}

/// Holds the list for drawing. Render thread.
pub fn view(self: *DevPlugins, io: std.Io) View {
    self.lock.lockUncancelable(io);
    return .{ .owner = self, .io = io };
}

pub const View = struct {
    owner: *DevPlugins,
    io: std.Io,

    pub fn entries(self: View) []const Entry {
        return self.owner.entries;
    }

    pub fn loaded(self: View) bool {
        return self.owner.loaded;
    }

    pub fn problem(self: View) []const u8 {
        return self.owner.problem.message();
    }

    pub fn end(self: View) void {
        self.owner.lock.unlock(self.io);
    }
};
