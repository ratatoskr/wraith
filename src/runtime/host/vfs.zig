//! Virtual files and file watches for plugins. Callbacks run on the thread doing the I/O.

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const api = @import("wraith_api");

const host = @import("root.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;
const Files = @import("../Files.zig");
const Vfs = Files.Vfs;

const log = @import("wraith_core").log.scoped(.wraith_runtime);

fn vfsOrFail() api.VfsError!*Vfs {
    return Files.global.vfs orelse error.Unavailable;
}

const PathBuf = [1024]u8;

fn normalize(buf: *PathBuf, path: []const u8) api.VfsError![]u8 {
    return Vfs.paths.normalize(buf, path) catch error.InvalidPath;
}

/// A file or folder an owner put, removed when it goes unless someone else put it since.
const Put = struct {
    loaded: *Loaded,
    path: []u8,
    replaced: Atomic(bool) = .init(false),

    pub fn stop(self: *Put) void {
        if (self.replaced.load(.acquire)) return;
        if (Files.global.vfs) |vfs| _ = vfs.remove(self.path);
    }

    pub fn free(self: *Put) void {
        self.loaded.allocator.free(self.path);
        self.loaded.allocator.destroy(self);
    }

    fn samePath(self: *Put, path: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.path, path);
    }
};

var puts: host.Owned(Put) = .{};

/// Marks other owners' puts at `path` as replaced, and gives this owner's if it has one.
fn claim(loaded: *Loaded, path: []const u8) ?*Put {
    const Key = struct { path: []const u8, loaded: *Loaded };
    const Match = struct {
        fn other(p: *Put, key: Key) bool {
            return p.loaded != key.loaded and !p.replaced.load(.acquire) and p.samePath(key.path);
        }
    };
    while (puts.findAny(Key{ .path = path, .loaded = loaded }, Match.other)) |p| p.replaced.store(true, .release);
    const mine = puts.findWhere(&loaded.owner, path, Put.samePath) orelse return null;
    mine.replaced.store(false, .release);
    return mine;
}

fn record(loaded: *Loaded, path: []const u8) api.VfsError!void {
    if (claim(loaded, path) != null) return;
    const allocator = loaded.allocator;
    const p = try allocator.create(Put);
    errdefer allocator.destroy(p);
    p.* = .{ .loaded = loaded, .path = try allocator.dupe(u8, path) };
    puts.add(p) catch |err| {
        allocator.free(p.path);
        allocator.destroy(p);
        return if (err == error.OutOfMemory) error.OutOfMemory else error.OwnerGone;
    };
}

pub fn put(loaded: *Loaded, path: []const u8, bytes: []const u8) api.VfsError!void {
    const vfs = try vfsOrFail();
    var buf: PathBuf = undefined;
    const p = try normalize(&buf, path);
    vfs.store.put(p, bytes) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.IsDirectory, error.NotADirectory => error.WrongKind,
        else => error.InvalidPath,
    };
    try record(loaded, p);
}

pub fn putDir(loaded: *Loaded, path: []const u8) api.VfsError!void {
    const vfs = try vfsOrFail();
    var buf: PathBuf = undefined;
    const p = try normalize(&buf, path);
    vfs.putDir(p) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.IsDirectory, error.NotADirectory => error.WrongKind,
        else => error.InvalidPath,
    };
    try record(loaded, p);
}

pub fn remove(_: *Loaded, path: []const u8) bool {
    const vfs = Files.global.vfs orelse return false;
    return vfs.remove(path);
}

pub fn read(_: *Loaded, path: []const u8, out: []u8) api.VfsError!usize {
    const vfs = try vfsOrFail();
    var buf: PathBuf = undefined;
    const p = try normalize(&buf, path);
    const node = vfs.store.lookup(Vfs.paths.key(p, p)) orelse return error.NotFound;
    defer vfs.store.release(node);
    if (node.kind != .file) return error.WrongKind;
    node.lock.lockShared();
    defer node.lock.unlockShared();
    const n = @min(out.len, node.data.items.len);
    @memcpy(out[0..n], node.data.items[0..n]);
    return node.data.items.len;
}

const W = api.wraith;
/// From `vfs.sal`, kept till the watch stops.
pub const Handler = W.Vfs.Handler;

/// What a handler said, with a read's new bytes if it gave some.
const Reply = struct {
    reply: api.VfsReply = .{},
    data: []const u8 = &.{},
};

pub const Watch = struct {
    loaded: *Loaded,
    pattern: []u8,
    options: api.VfsWatchOptions,
    /// Null once it's not ours to release.
    handler: ?Handler,
    subs: Subs = .{},
    stopped: Atomic(bool) = .init(false),

    const Subs = struct {
        open: ?@FieldType(Vfs, "open").Subscription = null,
        opened: ?@FieldType(Vfs, "opened").Subscription = null,
        open_failed: ?@FieldType(Vfs, "open_failed").Subscription = null,
        read: ?@FieldType(Vfs, "read").Subscription = null,
        write: ?@FieldType(Vfs, "write").Subscription = null,
        closed: ?@FieldType(Vfs, "closed").Subscription = null,
    };

    /// Waits for callbacks in flight, unless it's from inside one.
    pub fn stop(self: *Watch) void {
        if (self.stopped.swap(true, .acq_rel)) return;
        inline for (@typeInfo(Subs).@"struct".field_names) |name| {
            if (@field(self.subs, name)) |s| s.unsubscribe();
            @field(self.subs, name) = null;
        }
        // Won't be called again
        if (self.handler) |f| f.release();
        self.handler = null;
    }

    pub fn free(self: *Watch) void {
        self.stop();
        self.loaded.allocator.free(self.pattern);
        self.loaded.allocator.destroy(self);
    }

    /// Either path matches, so a redirected file still counts as what the game asked for.
    fn wants(self: *Watch, path: []const u8, requested: ?[]const u8) bool {
        if (self.stopped.load(.acquire)) return false;
        if (!self.options.loader and Vfs.native.holdsLoaderLock()) return false;
        if (self.pattern.len == 0 or api.vfsMatches(self.pattern, path)) return true;
        return if (requested) |r| api.vfsMatches(self.pattern, r) else false;
    }

    fn call(self: *Watch, event: api.VfsEvent) Reply {
        const f = self.handler orelse return .{};
        const got = f.invoke(.{.{
            .kind = switch (event.kind) {
                inline else => |k| @field(W.Vfs.EventKind, @tagName(k)),
            },
            .path = .init(event.path),
            .requested = .init(event.requested),
            .file = event.file,
            .read_access = event.read_access,
            .write_access = event.write_access,
            .virtual = event.virtual,
            .directory = event.directory,
            .query = event.query,
            .thread = event.thread,
            .offset = event.offset,
            .data = .init(event.data),
            .status = event.status,
        }});
        var out: Reply = .{};
        switch (got.deny) {
            inline .access_denied, .not_found, .sharing_violation, .write_protected => |d| out.reply.refuse(@field(api.VfsDenial, @tagName(d))),
            else => {},
        }
        out.reply.redirectTo(got.redirect.get()) catch log.warn("{s} redirected {s} to a path that's too long", .{ self.loaded.name, event.path });
        if (got.replace) out.data = got.data.get();
        return out;
    }

    fn fileEvent(kind: api.VfsEventKind, f: *const Vfs.File) api.VfsEvent {
        return .{
            .kind = kind,
            .path = f.path,
            .requested = f.requested orelse f.path,
            .file = f.id,
            .read_access = f.access.read,
            .write_access = f.access.write or f.access.append,
            .virtual = f.kind == .virtual,
            .directory = f.directory,
            .thread = f.thread,
        };
    }

    fn onOpen(self: *Watch, req: *Vfs.OpenRequest) void {
        if (req.query and !self.options.queries) return;
        if (!self.wants(req.path, req.requested)) return;
        const reply = self.call(.{
            .kind = .open,
            .path = req.path,
            .requested = req.requested,
            .read_access = req.access.read,
            .write_access = req.access.write or req.access.append,
            .directory = req.directory orelse false,
            .query = req.query,
            .thread = req.thread,
        });
        if (reply.reply.denial()) |d| return req.deny(denialOf(d));
        if (reply.reply.redirected()) |to| req.redirect(to) catch log.warn("{s} redirected {s} to a path that isn't a full one: {s}", .{ self.loaded.name, req.path, to });
    }

    fn onOpened(self: *Watch, f: *const Vfs.File) void {
        if (self.wants(f.path, f.requested)) _ = self.call(fileEvent(.opened, f));
    }

    fn onFailed(self: *Watch, req: *const Vfs.OpenRequest, status: u32) void {
        if (req.query and !self.options.queries) return;
        if (!self.wants(req.path, req.requested)) return;
        _ = self.call(.{ .kind = .failed, .path = req.path, .requested = req.requested, .thread = req.thread, .query = req.query, .status = status });
    }

    fn onRead(self: *Watch, r: *Vfs.Read) void {
        if (r.pending or !self.wants(r.file.path, r.file.requested)) return;
        var e = fileEvent(.read, r.file);
        e.thread = Vfs.native.threadId();
        e.offset = if (r.offset) |o| @intCast(o) else -1;
        e.data = r.data;
        const reply = self.call(e);
        if (reply.data.len > 0) {
            const n = @min(reply.data.len, r.data.len);
            @memcpy(r.data[0..n], reply.data[0..n]);
        }
    }

    fn onWrite(self: *Watch, w: *Vfs.Write) void {
        if (w.denied != null or !self.wants(w.file.path, w.file.requested)) return;
        var e = fileEvent(.write, w.file);
        e.thread = Vfs.native.threadId();
        e.offset = if (w.offset) |o| @intCast(o) else -1;
        e.data = @constCast(w.data);
        const reply = self.call(e);
        if (reply.reply.denial()) |d| w.deny(denialOf(d));
    }

    fn onClosed(self: *Watch, f: *const Vfs.File) void {
        if (self.wants(f.path, f.requested)) _ = self.call(fileEvent(.closed, f));
    }
};

fn denialOf(d: api.VfsDenial) Vfs.Denial {
    return switch (d) {
        inline else => |tag| @field(Vfs.Denial, @tagName(tag)),
    };
}

var watches: host.Owned(Watch) = .{};

/// Through `vfs.sal`. Released if it fails.
pub fn watch(loaded: *Loaded, options: api.VfsWatchOptions, handler: Handler) api.VfsError!*Watch {
    return subscribe(loaded, options, handler) catch |err| {
        handler.release();
        return err;
    };
}

fn subscribe(loaded: *Loaded, options: api.VfsWatchOptions, handler: Handler) api.VfsError!*Watch {
    const vfs = try vfsOrFail();
    const allocator = loaded.allocator;
    const w = try allocator.create(Watch);
    const pattern = allocator.dupe(u8, options.pattern) catch {
        allocator.destroy(w);
        return error.OutOfMemory;
    };
    w.* = .{ .loaded = loaded, .pattern = pattern, .options = options, .handler = handler };
    w.options.pattern = pattern;
    // The handler's still the caller's
    errdefer {
        w.handler = null;
        w.free();
    }
    const k = options.kinds;
    if (k.open) w.subs.open = try vfs.open.subscribeUnscoped(w, Watch.onOpen);
    if (k.opened) w.subs.opened = try vfs.opened.subscribeUnscoped(w, Watch.onOpened);
    if (k.failed) w.subs.open_failed = try vfs.open_failed.subscribeUnscoped(w, Watch.onFailed);
    if (k.read) w.subs.read = try vfs.read.subscribeUnscoped(w, Watch.onRead);
    if (k.write) w.subs.write = try vfs.write.subscribeUnscoped(w, Watch.onWrite);
    if (k.closed) w.subs.closed = try vfs.closed.subscribeUnscoped(w, Watch.onClosed);
    watches.add(w) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.OwnerGone;
    return w;
}

const tests = struct {
    const testing = std.testing;
    const sdk = @import("wraith_sdk");
    const hook = @import("tuft_hook");

    const FakePlugin = struct {
        loaded: Loaded,

        fn init(self: *FakePlugin, name: []const u8) void {
            self.loaded.initForTest(testing.allocator, name);
        }

        fn owner(self: *FakePlugin) sdk.Owner {
            return .of(self.loaded.root());
        }
    };

    const k32 = struct {
        extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sa: ?*anyopaque, disposition: u32, flags: u32, template: ?*anyopaque) callconv(.winapi) std.os.windows.HANDLE;
        extern "kernel32" fn ReadFile(h: std.os.windows.HANDLE, buf: [*]u8, len: u32, read: ?*u32, ov: ?*anyopaque) callconv(.winapi) std.os.windows.BOOL;
        extern "kernel32" fn CloseHandle(h: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.BOOL;
    };

    fn readVia(path: [:0]const u16, buf: []u8) ?[]u8 {
        const h = k32.CreateFileW(path, 0x80000000, 1, null, 3, 0, null);
        if (h == std.os.windows.INVALID_HANDLE_VALUE) return null;
        defer _ = k32.CloseHandle(h);
        var got: u32 = 0;
        if (!k32.ReadFile(h, buf.ptr, @intCast(buf.len), &got, null).toBool()) return null;
        return buf[0..got];
    }

    const Replier = struct {
        opens: u32 = 0,
        reads: u32 = 0,

        fn handle(self: *Replier, event: W.Vfs.Event) W.Vfs.Reply {
            switch (event.kind) {
                .open => {
                    self.opens += 1;
                    return .{ .redirect = "C:/wraith_vfs_zy/b.txt" };
                },
                .read => {
                    self.reads += 1;
                    return .{ .replace = true, .data = "B" };
                },
                else => return .{},
            }
        }
    };

    test "through vfs.sal, with replies" {
        try hook.init(testing.allocator);
        defer hook.deinit();
        Files.global.start(testing.allocator);
        defer Files.global.stop();

        var a: FakePlugin = undefined;
        a.init("a");
        sdk.Owner.attach(a.loaded.root());
        defer sdk.Owner.detach();
        const vfs = sdk.wraith.root().?.vfs();
        try vfs.put("C:\\wraith_vfs_zy\\a.txt", "from a");
        try vfs.put("C:/wraith_vfs_zy/b.txt", "from b");
        const got = try vfs.read("C:/wraith_vfs_zy/a.txt");
        defer got.release();
        try testing.expectEqualStrings("from a", got.bytes());
        try testing.expectError(error.NotFound, vfs.read("C:/wraith_vfs_zy/c.txt"));
        try testing.expectError(error.InvalidPath, vfs.put("relative.txt", ""));

        var r: Replier = .{};
        const w = try vfs.addWatch(.{ .kinds = .{ .open = true, .read = true }, .pattern = "c:/wraith_vfs_zy/a.*" }, Handler.init(&r, Replier.handle));
        var buf: [16]u8 = undefined;
        try testing.expectEqualStrings("Brom b", readVia(std.unicode.utf8ToUtf16LeStringLiteral("C:\\wraith_vfs_zy\\a.txt"), &buf).?);
        try testing.expectEqual(1, r.opens);
        try testing.expectEqual(1, r.reads);

        w.cancel();
        try testing.expectEqualStrings("from a", readVia(std.unicode.utf8ToUtf16LeStringLiteral("C:\\wraith_vfs_zy\\a.txt"), &buf).?);
        try testing.expectEqual(1, r.opens);

        a.loaded.deinitForTest();
        host.wraith.forget(&a.loaded);
        try testing.expectEqual(null, Files.global.vfs.?.exists("C:/wraith_vfs_zy/a.txt"));
    }
};

test {
    _ = tests;
}
