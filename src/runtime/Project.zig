//! A game's project, saved only when asked as plain files in `workbench/`. A `.rwp` is a zip of one.

const Project = @This();

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const core = @import("wraith_core");
const sync = @import("tuft_sys").sync;

const log = core.log.scoped(.wraith_runtime);

pub const addresses_file = "addresses.rwa.zon";
pub const manifest_file = "project.rwp.zon";
/// What older versions kept unsaved changes in. Deleted when found.
const old_recovery_name = "recovery.rwp";
const scratch_name = ".unzip";
/// Where it's saved, in the game's settings folder.
pub const folder_name = "workbench";

/// Our extensions. The real format comes last, so editors still know them.
pub const ext = struct {
    pub const schema = ".sal";
    pub const tweak = ".rwt";
    pub const script = ".rws.js";
    pub const script_lua = ".rws.lua";
    pub const addresses = ".rwa.zon";
    pub const manifest = ".rwp.zon";
    /// A whole project.
    pub const project = ".rwp";
};
const max_file = 16 << 20;

pub const File = struct {
    /// Relative, with `/`.
    path: []u8,
    text: []u8,
};

allocator: std.mem.Allocator,
io: std.Io,
/// Scratch space, like the game's settings folder.
work_dir: []u8,
/// Where it's saved, `workbench/` in `work_dir`.
dir: []u8,
lock: sync.RwLock = .{},
files: std.ArrayList(File) = .empty,
dirty: bool = false,
/// Bumped on every change, so views can catch up.
generation: Atomic(u32) = .init(1),
/// Bumped when it becomes another project, so views can start over.
epoch_counter: Atomic(u32) = .init(1),
/// `name`, kept up as `wraith.json` changes. Under `lock`.
title_buf: [64]u8 = undefined,
title_len: usize = 0,
/// `name` without a title, see `setDefaultName`. Under `lock`.
default_buf: [64]u8 = undefined,
default_len: usize = 0,

/// An empty unsaved one.
pub fn create(allocator: std.mem.Allocator, io: std.Io, work_dir: []const u8) !*Project {
    const self = try allocator.create(Project);
    errdefer allocator.destroy(self);
    const work = try allocator.dupe(u8, work_dir);
    errdefer allocator.free(work);
    const dir = try std.fs.path.join(allocator, &.{ work_dir, folder_name });
    self.* = .{ .allocator = allocator, .io = io, .work_dir = work, .dir = dir };
    self.updateTitle();
    return self;
}

/// What's saved, else `last`, an `.rwp` older versions saved to.
pub fn startUp(self: *Project, last: ?[]const u8) void {
    self.dropOldRecovery();
    self.reload() catch |err| log.warn("Couldn't open the project in {s}: {t}", .{ self.dir, err });
    if (self.files.items.len > 0) return;
    const path = last orelse return;
    if (path.len == 0) return;
    self.open(path) catch |err| return log.warn("Couldn't open the project {s}: {t}", .{ path, err });
    self.save() catch |err| return log.warn("Couldn't save {s} into {s}: {t}", .{ path, self.dir, err });
    log.info("Moved the project {s} into {s}", .{ path, self.dir });
}

/// Unsaved changes are dropped.
pub fn destroy(self: *Project) void {
    self.clearFiles();
    self.files.deinit(self.allocator);
    self.allocator.free(self.dir);
    self.allocator.free(self.work_dir);
    self.allocator.destroy(self);
}

/// The title in its `wraith.json`, else the default, see `setDefaultName`.
pub fn name(self: *Project) []const u8 {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    return self.title_buf[0..self.title_len];
}

/// Its name till it has a title, like the game's exe without `.exe`. Untitled if empty.
pub fn setDefaultName(self: *Project, default: []const u8) void {
    const stem = if (std.ascii.endsWithIgnoreCase(default, ".exe")) default[0 .. default.len - 4] else default;
    {
        self.lock.lock();
        defer self.lock.unlock();
        const n = @min(stem.len, self.default_buf.len);
        @memcpy(self.default_buf[0..n], stem[0..n]);
        self.default_len = n;
        self.updateTitle();
    }
    self.changed();
}

pub fn isDirty(self: *Project) bool {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    return self.dirty;
}

pub fn version(self: *const Project) u32 {
    return self.generation.load(.acquire);
}

pub fn epoch(self: *const Project) u32 {
    return self.epoch_counter.load(.acquire);
}

/// A copy of `path`'s text, or null if there's no such file. The caller frees it.
pub fn read(self: *Project, gpa: std.mem.Allocator, path: []const u8) !?[]u8 {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    const f = self.find(path) orelse return null;
    return try gpa.dupe(u8, f.text);
}

pub fn write(self: *Project, path: []const u8, text: []const u8) !void {
    {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.find(path)) |f| {
            if (std.mem.eql(u8, f.text, text)) return;
            const copy = try self.allocator.dupe(u8, text);
            self.allocator.free(f.text);
            f.text = copy;
        } else {
            const copy = try self.allocator.dupe(u8, text);
            errdefer self.allocator.free(copy);
            const p = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(p);
            try self.files.append(self.allocator, .{ .path = p, .text = copy });
        }
        self.dirty = true;
        if (std.mem.eql(u8, path, core.manifest.file_name)) self.updateTitle();
    }
    self.changed();
}

pub fn delete(self: *Project, path: []const u8) void {
    {
        self.lock.lock();
        defer self.lock.unlock();
        const i = for (self.files.items, 0..) |f, i| {
            if (std.mem.eql(u8, f.path, path)) break i;
        } else return;
        self.freeFile(self.files.orderedRemove(i));
        self.dirty = true;
        if (std.mem.eql(u8, path, core.manifest.file_name)) self.updateTitle();
    }
    self.changed();
}

/// Paths under `folder/` ending in `suffix`, sorted. Free with `freePaths`.
pub fn list(self: *Project, gpa: std.mem.Allocator, folder: []const u8, suffix: []const u8) !std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .empty;
    errdefer freePaths(gpa, &out);
    self.lock.lockShared();
    defer self.lock.unlockShared();
    for (self.files.items) |f| {
        if (f.path.len <= folder.len + 1 or !std.mem.startsWith(u8, f.path, folder) or f.path[folder.len] != '/') continue;
        if (!std.ascii.endsWithIgnoreCase(f.path, suffix)) continue;
        try out.append(gpa, try gpa.dupe(u8, f.path));
    }
    std.mem.sort([]u8, out.items, {}, lessThan);
    return out;
}

pub fn freePaths(gpa: std.mem.Allocator, paths: *std.ArrayList([]u8)) void {
    for (paths.items) |p| gpa.free(p);
    paths.deinit(gpa);
}

/// `x` for `tweaks/x.rwt`, or `tweaks/x_2.rwt` and so on if that's taken. The caller frees it.
pub fn freeName(self: *Project, path: []const u8) ![]u8 {
    if (try self.read(self.allocator, path)) |there| self.allocator.free(there) else return self.allocator.dupe(u8, path);
    const base = std.fs.path.basename(path);
    const folder = path[0 .. path.len - base.len];
    const dot = std.mem.indexOfScalar(u8, base, '.') orelse base.len;
    var n: usize = 2;
    while (n < 1000) : (n += 1) {
        const candidate = try std.fmt.allocPrint(self.allocator, "{s}{s}_{d}{s}", .{ folder, base[0..dot], n, base[dot..] });
        const there = try self.read(self.allocator, candidate);
        if (there) |t| {
            self.allocator.free(t);
            self.allocator.free(candidate);
            continue;
        }
        return candidate;
    }
    return error.NoFreeName;
}

/// Writes its files to `dir` and deletes ones it no longer has, leaving dotfiles alone.
pub fn save(self: *Project) !void {
    {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        var saving = try self.io.concurrent(saveTree, .{ self.io, self.allocator, self.dir, self.files.items });
        try saving.await(self.io);
    }
    {
        self.lock.lock();
        defer self.lock.unlock();
        self.dirty = false;
    }
    self.changed();
}

/// A zip of it at `path`, to send someone. Doesn't count as saving.
pub fn exportTo(self: *Project, path: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();
    {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        try zipTo(self.allocator, &out.writer, self.files.items);
    }
    try core.files.write(self.io, path, out.written(), .{ .make_dir = true });
}

/// Becomes the `.rwp` in `path`, unsaved till `save`. Unsaved changes here are dropped.
pub fn open(self: *Project, path: []const u8) !void {
    var files = try self.unzip(path);
    errdefer {
        for (files.items) |f| self.freeFile(f);
        files.deinit(self.allocator);
    }
    self.replace(&files, true);
}

/// An empty one, unsaved till `save` empties the folder. Unsaved changes here are dropped.
pub fn new(self: *Project) void {
    var files: std.ArrayList(File) = .empty;
    self.replace(&files, true);
}

/// Becomes an unsaved one of `files`, each with a `path` and `text`. Unsaved changes are dropped.
pub fn load(self: *Project, files: anytype) !void {
    var copies: std.ArrayList(File) = .empty;
    errdefer {
        for (copies.items) |f| self.freeFile(f);
        copies.deinit(self.allocator);
    }
    for (files) |f| {
        const p = try self.allocator.dupe(u8, f.path);
        errdefer self.allocator.free(p);
        const text = try self.allocator.dupe(u8, f.text);
        errdefer self.allocator.free(text);
        try copies.append(self.allocator, .{ .path = p, .text = text });
    }
    self.replace(&copies, true);
}

/// Back to what's saved, or empty if it never was.
pub fn reload(self: *Project) !void {
    var reading = try self.io.concurrent(readSaved, .{ self.io, self.allocator, self.dir });
    var files = try reading.await(self.io);
    errdefer {
        for (files.items) |f| self.freeFile(f);
        files.deinit(self.allocator);
    }
    self.replace(&files, false);
}

/// Brings in another project's files as unsaved changes, renaming clashes. Returns how many came in.
pub fn mergeFrom(self: *Project, path: []const u8) !usize {
    var theirs = try self.unzip(path);
    defer {
        for (theirs.items) |f| self.freeFile(f);
        theirs.deinit(self.allocator);
    }
    var count: usize = 0;
    for (theirs.items) |f| {
        if (std.mem.eql(u8, f.path, manifest_file) or std.mem.eql(u8, f.path, core.manifest.file_name)) {
            if (try self.read(self.allocator, f.path)) |mine| self.allocator.free(mine) else {
                try self.write(f.path, f.text);
                count += 1;
            }
            continue;
        }
        if (std.mem.eql(u8, f.path, addresses_file)) {
            try self.mergeAddresses(f.text);
            count += 1;
            continue;
        }
        const mine = try self.read(self.allocator, f.path);
        if (mine) |m| {
            defer self.allocator.free(m);
            if (std.mem.eql(u8, m, f.text)) continue;
        }
        const at = try self.freeName(f.path);
        defer self.allocator.free(at);
        try self.write(at, f.text);
        count += 1;
    }
    return count;
}

/// Their entries after ours. Both are `.{ .items = .{ ... } }`.
fn mergeAddresses(self: *Project, theirs: []const u8) !void {
    const mine = (try self.read(self.allocator, addresses_file)) orelse return self.write(addresses_file, theirs);
    defer self.allocator.free(mine);
    const a = innerItems(mine) orelse return;
    const b = innerItems(theirs) orelse return;
    const joined = try std.fmt.allocPrint(self.allocator, ".{{ .items = .{{ {s}{s}{s} }} }}\n", .{ a, if (a.len > 0 and b.len > 0) ", " else "", b });
    defer self.allocator.free(joined);
    try self.write(addresses_file, joined);
}

/// What's between the braces of `.items = .{ ... }`.
fn innerItems(text: []const u8) ?[]const u8 {
    const key = std.mem.indexOf(u8, text, ".items") orelse return "";
    const open_brace = std.mem.indexOfScalarPos(u8, text, key, '{') orelse return null;
    var depth: usize = 0;
    var i = open_brace;
    while (i < text.len) : (i += 1) switch (text[i]) {
        '{' => depth += 1,
        '}' => {
            depth -= 1;
            if (depth == 0) return std.mem.trim(u8, text[open_brace + 1 .. i], " \t\r\n,");
        },
        else => {},
    };
    return null;
}

/// Takes in the pre-projects address list, then renames it `.old` so it's taken in once.
pub fn adopt(self: *Project, old: []const u8) !void {
    if (try self.read(self.allocator, addresses_file)) |there| {
        self.allocator.free(there);
        return;
    }
    var loading = try self.io.concurrent(readPlain, .{ self.io, self.allocator, old });
    const text = loading.await(self.io) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer self.allocator.free(text);
    try self.write(addresses_file, text);
    var renaming = try self.io.concurrent(renameOld, .{ self.io, self.allocator, old });
    renaming.await(self.io) catch |err| log.warn("Couldn't rename {s}: {t}", .{ old, err });
    log.info("Took {s} into the project", .{old});
}

fn changed(self: *Project) void {
    _ = self.generation.fetchAdd(1, .release);
}

fn replace(self: *Project, files: *std.ArrayList(File), dirty: bool) void {
    {
        self.lock.lock();
        defer self.lock.unlock();
        self.clearFiles();
        self.files.deinit(self.allocator);
        self.files = files.*;
        files.* = .empty;
        self.dirty = dirty;
        self.updateTitle();
    }
    _ = self.epoch_counter.fetchAdd(1, .release);
    _ = self.generation.fetchAdd(1, .release);
}

/// Under the write lock.
fn updateTitle(self: *Project) void {
    var title: []const u8 = if (self.default_len > 0) self.default_buf[0..self.default_len] else "Untitled";
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    if (self.find(core.manifest.file_name)) |f| {
        const Titled = struct { title: []const u8 = "" };
        if (std.json.parseFromSliceLeaky(Titled, fba.allocator(), f.text, .{ .ignore_unknown_fields = true })) |m| {
            if (m.title.len > 0) title = m.title;
        } else |_| {}
    }
    const n = @min(title.len, self.title_buf.len);
    @memcpy(self.title_buf[0..n], title[0..n]);
    self.title_len = n;
}

fn clearFiles(self: *Project) void {
    for (self.files.items) |f| self.freeFile(f);
    self.files.clearRetainingCapacity();
}

fn find(self: *Project, path: []const u8) ?*File {
    for (self.files.items) |*f| if (std.mem.eql(u8, f.path, path)) return f;
    return null;
}

fn freeFile(self: *Project, f: File) void {
    self.allocator.free(f.path);
    self.allocator.free(f.text);
}

fn lessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Unsaved changes an older version kept. Coming back unasked was confusing, so they're dropped.
fn dropOldRecovery(self: *Project) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const at = std.fmt.bufPrint(&buf, "{s}{c}{s}", .{ self.work_dir, std.fs.path.sep, old_recovery_name }) catch return;
    var deleting = self.io.concurrent(deleteFile, .{ self.io, at }) catch return;
    deleting.await(self.io) catch {};
}
// Zips

/// An `.rwp` that's also a hub mod. Needs a `wraith.json` already.
pub fn exportMod(self: *Project, path: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();
    {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        if (self.find(core.manifest.file_name) == null) return error.NoManifest;
        var files: std.ArrayList(File) = .empty;
        defer files.deinit(self.allocator);
        for (self.files.items) |f| if (!std.mem.eql(u8, f.path, manifest_file)) try files.append(self.allocator, f);
        try zipTo(self.allocator, &out.writer, files.items);
    }
    try core.files.write(self.io, path, out.written(), .{ .make_dir = true });
}

fn unzip(self: *Project, path: []const u8) !std.ArrayList(File) {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const scratch = try std.fmt.bufPrint(&buf, "{s}{c}{s}", .{ self.work_dir, std.fs.path.sep, scratch_name });
    var reading = try self.io.concurrent(unzipAll, .{ self.io, self.allocator, path, scratch });
    return reading.await(self.io);
}

// On an `Io` worker, since std's file calls need more stack than a game thread may have

fn unzipAll(io: std.Io, gpa: std.mem.Allocator, path: []const u8, scratch: []const u8) !std.ArrayList(File) {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, scratch) catch {};
    try cwd.createDirPath(io, scratch);
    defer cwd.deleteTree(io, scratch) catch {};
    {
        var dest = try cwd.openDir(io, scratch, .{});
        defer dest.close(io);
        var file = try cwd.openFile(io, path, .{});
        defer file.close(io);
        var read_buf: [4096]u8 = undefined;
        var reader = file.reader(io, &read_buf);
        try std.zip.extract(dest, &reader, .{ .allow_backslashes = true });
    }
    return readTree(io, gpa, scratch);
}

/// Empty if there's no folder yet.
fn readSaved(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !std.ArrayList(File) {
    return readTree(io, gpa, path) catch |err| switch (err) {
        error.FileNotFound => .empty,
        else => err,
    };
}

/// Every file under `path` but hidden ones, see `hidden`.
fn readTree(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !std.ArrayList(File) {
    var out: std.ArrayList(File) = .empty;
    errdefer {
        for (out.items) |f| {
            gpa.free(f.path);
            gpa.free(f.text);
        }
        out.deinit(gpa);
    }
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit(io);
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or hidden(entry.path)) continue;
        const text = try dir.readFileAlloc(io, entry.path, gpa, .limited(max_file));
        errdefer gpa.free(text);
        const p = try gpa.dupe(u8, entry.path);
        std.mem.replaceScalar(u8, p, '\\', '/');
        try out.append(gpa, .{ .path = p, .text = text });
    }
    return out;
}

/// Dotfiles, dot folders and half written `.tmp`s.
fn hidden(path: []const u8) bool {
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (parts.next()) |part| if (part[0] == '.') return true;
    return std.mem.endsWith(u8, path, ".tmp");
}

/// Writes `files` into `path`, then deletes the old ones and any folders left empty.
fn saveTree(io: std.Io, gpa: std.mem.Allocator, path: []const u8, files: []const File) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, path);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for (files) |f| {
        const at = try std.fmt.bufPrint(&buf, "{s}{c}{s}", .{ path, std.fs.path.sep, f.path });
        try core.files.writeHere(io, at, f.text, .{ .make_dir = true, .replace = true });
    }
    var stale: std.ArrayList([]u8) = .empty;
    defer freePaths(gpa, &stale);
    var folders: std.ArrayList([]u8) = .empty;
    defer freePaths(gpa, &folders);
    var dir = try cwd.openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    {
        var walker = try dir.walk(gpa);
        defer walker.deinit(io);
        while (try walker.next(io)) |entry| {
            if (hidden(entry.path)) continue;
            switch (entry.kind) {
                .directory => try folders.append(gpa, try gpa.dupe(u8, entry.path)),
                .file => {
                    const kept = for (files) |f| {
                        if (samePath(f.path, entry.path)) break true;
                    } else false;
                    if (!kept) try stale.append(gpa, try gpa.dupe(u8, entry.path));
                },
                else => {},
            }
        }
    }
    for (stale.items) |s| dir.deleteFile(io, s) catch |err| log.warn("Couldn't delete {s} from {s}: {t}", .{ s, path, err });
    // Deepest first, and only empty ones go
    var i = folders.items.len;
    while (i > 0) {
        i -= 1;
        dir.deleteDir(io, folders.items[i]) catch {};
    }
}

/// `/` and `\\` alike, since the walker gives Windows' own.
fn samePath(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const slash = (x == '/' or x == '\\') and (y == '/' or y == '\\');
        if (x != y and !slash) return false;
    }
    return true;
}

fn readPlain(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file));
}

fn deleteFile(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().deleteFile(io, path);
}

fn renameOld(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !void {
    const to = try std.mem.concat(gpa, u8, &.{ path, ".old" });
    defer gpa.free(to);
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(path, cwd, to, io);
}

/// Stored, not compressed. They're small text files.
fn zipTo(gpa: std.mem.Allocator, w: *std.Io.Writer, files: []const File) !void {
    const Entry = struct { crc: u32, offset: u32 };
    const entries = try gpa.alloc(Entry, files.len);
    defer gpa.free(entries);
    var offset: u32 = 0;
    for (files, entries) |f, *e| {
        e.* = .{ .crc = std.hash.Crc32.hash(f.text), .offset = offset };
        const size: u32 = @intCast(f.text.len);
        try w.writeInt(u32, 0x04034b50, .little);
        try w.writeInt(u16, 20, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0x21, .little);
        try w.writeInt(u32, e.crc, .little);
        try w.writeInt(u32, size, .little);
        try w.writeInt(u32, size, .little);
        try w.writeInt(u16, @intCast(f.path.len), .little);
        try w.writeInt(u16, 0, .little);
        try w.writeAll(f.path);
        try w.writeAll(f.text);
        offset += 30 + @as(u32, @intCast(f.path.len)) + size;
    }
    const central_start = offset;
    for (files, entries) |f, e| {
        const size: u32 = @intCast(f.text.len);
        try w.writeInt(u32, 0x02014b50, .little);
        try w.writeInt(u16, 20, .little);
        try w.writeInt(u16, 20, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0x21, .little);
        try w.writeInt(u32, e.crc, .little);
        try w.writeInt(u32, size, .little);
        try w.writeInt(u32, size, .little);
        try w.writeInt(u16, @intCast(f.path.len), .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u32, 0, .little);
        try w.writeInt(u32, e.offset, .little);
        try w.writeAll(f.path);
        offset += 46 + @as(u32, @intCast(f.path.len));
    }
    try w.writeInt(u32, 0x06054b50, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, @intCast(files.len), .little);
    try w.writeInt(u16, @intCast(files.len), .little);
    try w.writeInt(u32, offset - central_start, .little);
    try w.writeInt(u32, central_start, .little);
    try w.writeInt(u16, 0, .little);
}

const tests = struct {
    const testing = std.testing;

    fn workDir(tmp: *testing.TmpDir) ![:0]u8 {
        return tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    }

    test "saved only when asked, and unsaved changes don't come back" {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const work = try workDir(&tmp);
        defer testing.allocator.free(work);

        {
            const p = try create(testing.allocator, testing.io, work);
            defer p.destroy();
            p.startUp(null);
            try testing.expectEqualStrings("Untitled", p.name());
            p.setDefaultName("kai.exe");
            try testing.expectEqualStrings("kai", p.name());
            try p.write("tweaks/god.rwt", "one");
            try p.write("tweaks/fly.rwt", "two");
            try p.write("old/gone.rwt", "three");
            try p.write(core.manifest.file_name, "{ \"title\": \"Health\" }");
            try testing.expectEqualStrings("Health", p.name());
            try p.save();
            try testing.expect(!p.isDirty());
            // Things of yours that aren't the project's stay put
            try tmp.dir.createDirPath(testing.io, folder_name ++ "/.git");
            try tmp.dir.writeFile(testing.io, .{ .sub_path = folder_name ++ "/.git/HEAD", .data = "ref" });
            // Gone when saved again
            p.delete("old/gone.rwt");
            try p.save();
            try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, folder_name ++ "/old", .{}));
            // Plain files, as they are in the project
            const on_disk = try tmp.dir.readFileAlloc(testing.io, folder_name ++ "/tweaks/god.rwt", testing.allocator, .unlimited);
            defer testing.allocator.free(on_disk);
            try testing.expectEqualStrings("one", on_disk);
            // Changed after saving, then the game closes
            p.delete("tweaks/fly.rwt");
            try p.write("tweaks/god.rwt", "changed");
            try testing.expect(p.isDirty());
        }
        // What an older version would have brought back
        try tmp.dir.writeFile(testing.io, .{ .sub_path = old_recovery_name, .data = "not a zip" });
        {
            const p = try create(testing.allocator, testing.io, work);
            defer p.destroy();
            p.startUp(null);
            try testing.expect(!p.isDirty());
            try testing.expectEqualStrings("Health", p.name());
            const god = (try p.read(testing.allocator, "tweaks/god.rwt")).?;
            defer testing.allocator.free(god);
            try testing.expectEqualStrings("one", god);
            var tweaks = try p.list(testing.allocator, "tweaks", ext.tweak);
            defer freePaths(testing.allocator, &tweaks);
            try testing.expectEqual(2, tweaks.items.len);
            try testing.expectEqual(null, try p.read(testing.allocator, ".git/HEAD"));
            try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, old_recovery_name, .{}));
            try tmp.dir.access(testing.io, folder_name ++ "/.git/HEAD", .{});
        }
    }
    test "an rwp older versions saved to moves into the folder" {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const work = try workDir(&tmp);
        defer testing.allocator.free(work);
        const file = try std.fs.path.join(testing.allocator, &.{ work, "mine", "health.rwp" });
        defer testing.allocator.free(file);
        {
            const p = try create(testing.allocator, testing.io, work);
            defer p.destroy();
            try p.write("tweaks/god.rwt", "one");
            try p.exportTo(file);
            // Exporting isn't saving
            try testing.expect(p.isDirty());
            try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, folder_name, .{}));
        }
        {
            const p = try create(testing.allocator, testing.io, work);
            defer p.destroy();
            p.startUp(file);
            try testing.expect(!p.isDirty());
            try tmp.dir.access(testing.io, folder_name ++ "/tweaks/god.rwt", .{});
        }
        // Once there, the folder wins
        try tmp.dir.writeFile(testing.io, .{ .sub_path = folder_name ++ "/tweaks/god.rwt", .data = "edited" });
        {
            const p = try create(testing.allocator, testing.io, work);
            defer p.destroy();
            p.startUp(file);
            const god = (try p.read(testing.allocator, "tweaks/god.rwt")).?;
            defer testing.allocator.free(god);
            try testing.expectEqualStrings("edited", god);
            // Opening one is a change to save
            try p.open(file);
            try testing.expect(p.isDirty());
        }
    }
    test "merging another in" {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const work = try workDir(&tmp);
        defer testing.allocator.free(work);
        const theirs = try std.fs.path.join(testing.allocator, &.{ work, "theirs.rwp" });
        defer testing.allocator.free(theirs);
        {
            const other = try create(testing.allocator, testing.io, work);
            defer other.destroy();
            try other.write("tweaks/god.rwt", "theirs");
            try other.write("tweaks/fly.rwt", "fly");
            try other.write(addresses_file, ".{ .items = .{ .{ .name = \"y\" } } }");
            try other.write(core.manifest.file_name, "{ \"title\": \"Theirs\" }");
            try other.exportTo(theirs);
        }
        const p = try create(testing.allocator, testing.io, work);
        defer p.destroy();
        try p.write("tweaks/god.rwt", "ours");
        try p.write(addresses_file, ".{ .items = .{ .{ .name = \"x\" } } }");
        try testing.expectEqual(4, try p.mergeFrom(theirs));
        const kept = (try p.read(testing.allocator, "tweaks/god_2.rwt")).?;
        defer testing.allocator.free(kept);
        try testing.expectEqualStrings("theirs", kept);
        const joined = (try p.read(testing.allocator, addresses_file)).?;
        defer testing.allocator.free(joined);
        try testing.expectEqual(2, std.mem.count(u8, joined, ".name"));
        // Without a wraith.json of its own, it takes theirs
        try testing.expectEqualStrings("Theirs", p.name());

        // With one, it keeps its own
        const q = try create(testing.allocator, testing.io, work);
        defer q.destroy();
        try q.write(core.manifest.file_name, "{ \"title\": \"Ours\" }");
        try testing.expectEqual(3, try q.mergeFrom(theirs));
        try testing.expectEqualStrings("Ours", q.name());
        try testing.expectEqual(null, try q.read(testing.allocator, "wraith_2.json"));
    }
};

test {
    _ = tests;
}
