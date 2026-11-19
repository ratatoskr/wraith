//! A game's project, its addresses, tweaks, scripts and schemas in one `.rwp` file, like a cheat
//! table. Saved only when asked, and unsaved changes go when the game does, a crash included.

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
/// Where it's saved. Null until it is.
path: ?[]u8 = null,
lock: sync.RwLock = .{},
files: std.ArrayList(File) = .empty,
dirty: bool = false,
/// Bumped on every change, so views can catch up.
generation: Atomic(u32) = .init(1),
/// Bumped when it becomes another project, so views can start over.
epoch_counter: Atomic(u32) = .init(1),

/// An empty unsaved one.
pub fn create(allocator: std.mem.Allocator, io: std.Io, work_dir: []const u8) !*Project {
    const self = try allocator.create(Project);
    errdefer allocator.destroy(self);
    self.* = .{ .allocator = allocator, .io = io, .work_dir = try allocator.dupe(u8, work_dir) };
    return self;
}

/// `last` if it's there, else nothing.
pub fn startUp(self: *Project, last: ?[]const u8) void {
    self.dropOldRecovery();
    const path = last orelse return;
    if (path.len == 0) return;
    self.open(path) catch |err| log.warn("Couldn't open the project {s}: {t}", .{ path, err });
}

/// Unsaved changes are dropped.
pub fn destroy(self: *Project) void {
    self.clearFiles();
    self.files.deinit(self.allocator);
    if (self.path) |p| self.allocator.free(p);
    self.allocator.free(self.work_dir);
    self.allocator.destroy(self);
}

pub fn isUnnamed(self: *const Project) bool {
    return self.path == null;
}

/// The file's name without `.rwp`, or Untitled.
pub fn name(self: *const Project) []const u8 {
    const path = self.path orelse return "Untitled";
    const base = std.fs.path.basename(path);
    return if (std.ascii.endsWithIgnoreCase(base, ext.project)) base[0 .. base.len - ext.project.len] else base;
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

/// Changes `path`, or adds it.
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

/// Writes it to its file. It has to have one, see `saveAs`.
pub fn save(self: *Project) !void {
    const path = try self.allocator.dupe(u8, self.path orelse return error.Unnamed);
    defer self.allocator.free(path);
    try self.saveAs(path);
}

/// Writes it to `path` and carries on there.
pub fn saveAs(self: *Project, path: []const u8) !void {
    try self.writeZip(path);
    const copy = try self.allocator.dupe(u8, path);
    {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.path) |p| self.allocator.free(p);
        self.path = copy;
        self.dirty = false;
    }
    self.changed();
}

/// Becomes the project in `path`. Unsaved changes here are dropped.
pub fn open(self: *Project, path: []const u8) !void {
    var files = try self.unzip(path);
    errdefer {
        for (files.items) |f| self.freeFile(f);
        files.deinit(self.allocator);
    }
    const copy = try self.allocator.dupe(u8, path);
    self.replace(&files, copy, false);
}

/// An empty unsaved one. Unsaved changes here are dropped.
pub fn new(self: *Project) void {
    var files: std.ArrayList(File) = .empty;
    self.replace(&files, null, false);
}

/// Becomes an unsaved one of `files`, each with a `path` and `text`, like an import. Unsaved
/// changes here are dropped.
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
    self.replace(&copies, null, true);
}

/// Back to what's saved, or empty if it never was.
pub fn reload(self: *Project) !void {
    const path = if (self.path) |p| try self.allocator.dupe(u8, p) else return self.new();
    defer self.allocator.free(path);
    try self.open(path);
}

/// Brings in another project's files as unsaved changes. Address lists join, other files that
/// clash get a new name. Returns how many files came in.
pub fn mergeFrom(self: *Project, path: []const u8) !usize {
    var theirs = try self.unzip(path);
    defer {
        for (theirs.items) |f| self.freeFile(f);
        theirs.deinit(self.allocator);
    }
    var count: usize = 0;
    for (theirs.items) |f| {
        if (std.mem.eql(u8, f.path, manifest_file)) {
            if (try self.read(self.allocator, manifest_file)) |mine| self.allocator.free(mine) else {
                try self.write(manifest_file, f.text);
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

/// Takes in the game's address list from before projects, renamed `.old` after so it's taken
/// in once. Unsaved, like any change.
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

fn replace(self: *Project, files: *std.ArrayList(File), path: ?[]u8, dirty: bool) void {
    {
        self.lock.lock();
        defer self.lock.unlock();
        self.clearFiles();
        self.files.deinit(self.allocator);
        self.files = files.*;
        files.* = .empty;
        if (self.path) |p| self.allocator.free(p);
        self.path = path;
        self.dirty = dirty;
    }
    _ = self.epoch_counter.fetchAdd(1, .release);
    _ = self.generation.fetchAdd(1, .release);
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

/// A mod the hub takes and the mods folder installs: its files with `wraith.json` at the top, and
/// without the project's own manifest. It has to have a `wraith.json` already.
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

fn writeZip(self: *Project, path: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();
    {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        try zipTo(self.allocator, &out.writer, self.files.items);
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
    var out: std.ArrayList(File) = .empty;
    errdefer {
        for (out.items) |f| {
            gpa.free(f.path);
            gpa.free(f.text);
        }
        out.deinit(gpa);
    }
    var dir = try cwd.openDir(io, scratch, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const text = try dir.readFileAlloc(io, entry.path, gpa, .limited(max_file));
        errdefer gpa.free(text);
        const p = try gpa.dupe(u8, entry.path);
        std.mem.replaceScalar(u8, p, '\\', '/');
        try out.append(gpa, .{ .path = p, .text = text });
    }
    return out;
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
        const file = try std.fs.path.join(testing.allocator, &.{ work, "mine", "health.rwp" });
        defer testing.allocator.free(file);

        {
            const p = try create(testing.allocator, testing.io, work);
            defer p.destroy();
            try testing.expect(p.isUnnamed());
            try p.write("tweaks/god.rwt", "one");
            try p.write("tweaks/fly.rwt", "two");
            try testing.expectError(error.Unnamed, p.save());
            try p.saveAs(file);
            try testing.expect(!p.isDirty());
            try testing.expectEqualStrings("health", p.name());
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
            p.startUp(file);
            try testing.expect(!p.isDirty());
            const god = (try p.read(testing.allocator, "tweaks/god.rwt")).?;
            defer testing.allocator.free(god);
            try testing.expectEqualStrings("one", god);
            var tweaks = try p.list(testing.allocator, "tweaks", ext.tweak);
            defer freePaths(testing.allocator, &tweaks);
            try testing.expectEqual(2, tweaks.items.len);
            try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, old_recovery_name, .{}));
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
            try other.saveAs(theirs);
        }
        const p = try create(testing.allocator, testing.io, work);
        defer p.destroy();
        try p.write("tweaks/god.rwt", "ours");
        try p.write(addresses_file, ".{ .items = .{ .{ .name = \"x\" } } }");
        try testing.expectEqual(3, try p.mergeFrom(theirs));
        const kept = (try p.read(testing.allocator, "tweaks/god_2.rwt")).?;
        defer testing.allocator.free(kept);
        try testing.expectEqualStrings("theirs", kept);
        const joined = (try p.read(testing.allocator, addresses_file)).?;
        defer testing.allocator.free(joined);
        try testing.expectEqual(2, std.mem.count(u8, joined, ".name"));
    }
};

test {
    _ = tests;
}
