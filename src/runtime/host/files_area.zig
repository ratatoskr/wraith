//! The `Vfs` and `Images` areas, from `vfs.sal` and `images.sal`.

const std = @import("std");

const api = @import("wraith_api");

const host = @import("root.zig");
const scratch = @import("scratch.zig");
const threads = @import("threads.zig");
const wraith = @import("wraith.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;
const c = @import("wraith_ui").c;

const sal = api.salamander;
const W = api.wraith;
pub const Vfs = W.Vfs;
pub const VfsWatch = W.Vfs.Watch;
pub const Images = W.Images;
pub const Image = W.Image;

const allocator = std.heap.page_allocator;

// Vfs

fn vfsError(err: api.VfsError) error{ Unavailable, InvalidPath, WrongKind, NotFound, Failed } {
    return switch (err) {
        error.Unavailable => error.Unavailable,
        error.InvalidPath => error.InvalidPath,
        error.WrongKind => error.WrongKind,
        error.NotFound => error.NotFound,
        error.OutOfMemory, error.OwnerGone => error.Failed,
    };
}

pub const VfsImpl = struct {
    pub fn put(loaded: *Loaded, path: []const u8, bytes: []const u8) sal.Plain(Vfs, "put") {
        host.vfs.put(loaded, path, bytes) catch |err| return vfsError(err);
    }

    pub fn putDir(loaded: *Loaded, path: []const u8) sal.Plain(Vfs, "putDir") {
        host.vfs.putDir(loaded, path) catch |err| return vfsError(err);
    }

    pub fn remove(loaded: *Loaded, path: []const u8) bool {
        return host.vfs.remove(loaded, path);
    }

    pub fn read(loaded: *Loaded, path: []const u8) sal.Plain(Vfs, "read") {
        // Asked for its size first, and again if it changed in between
        var len = host.vfs.read(loaded, path, &.{}) catch |err| return vfsError(err);
        while (true) {
            const b = sal.blobs.make(len) catch return error.Failed;
            const got = host.vfs.read(loaded, path, sal.blobs.mutable(b)) catch |err| {
                b.release();
                return vfsError(err);
            };
            if (got == len) return b;
            b.release();
            len = got;
        }
    }

    pub fn addWatch(loaded: *Loaded, options: W.Vfs.WatchOptions, handler: host.vfs.Handler) sal.Plain(Vfs, "addWatch") {
        const t = wraith.tablesOf(loaded) orelse {
            handler.release();
            return error.Failed;
        };
        const k = options.kinds;
        const w = host.vfs.watch(loaded, .{
            .kinds = .{ .open = k.open, .opened = k.opened, .failed = k.failed, .read = k.read, .write = k.write, .closed = k.closed },
            .pattern = options.pattern,
            .loader = options.loader,
            .queries = options.queries,
        }, handler) catch |err| return vfsError(err);
        return .init(w, t.vfs_watch);
    }
};

pub const WatchImpl = struct {
    pub fn cancel(w: *host.vfs.Watch) void {
        w.stop();
    }
};

// Images

/// What an `Image` object points at. Kept till the plugin's freed, since the object can outlive it.
pub const Held = struct {
    loaded: *Loaded,
    image: *api.ImageHandle,

    pub fn stop(_: *Held) void {}

    pub fn free(self: *Held) void {
        allocator.destroy(self);
    }
};

var held: host.Owned(Held) = .{};

fn ownsResolved(loaded: *Loaded, path: []const u8) bool {
    const resolved = std.fs.path.resolve(allocator, &.{path}) catch return false;
    defer allocator.free(resolved);
    return loaded.ownsPath(resolved);
}

fn imageError(err: api.ImageError) error{ InvalidImage, TooBig, Failed } {
    return switch (err) {
        error.InvalidImage => error.InvalidImage,
        error.TooBig => error.TooBig,
        error.OutOfMemory, error.OwnerGone => error.Failed,
    };
}

fn hold(loaded: *Loaded, image: *api.ImageHandle) sal.Plain(Images, "create") {
    const t = wraith.tablesOf(loaded) orelse {
        host.images.destroy(loaded, image);
        return error.Failed;
    };
    const h = allocator.create(Held) catch {
        host.images.destroy(loaded, image);
        return error.Failed;
    };
    h.* = .{ .loaded = loaded, .image = image };
    held.add(h) catch {
        host.images.destroy(loaded, image);
        allocator.destroy(h);
        return error.Failed;
    };
    return .init(h, t.image);
}

pub const ImagesImpl = struct {
    pub fn create(loaded: *Loaded, width: u32, height: u32, rgba: []const u8) sal.Plain(Images, "create") {
        const image = host.images.create(loaded, width, height, rgba) catch |err| return imageError(err);
        return hold(loaded, image);
    }

    pub fn decode(loaded: *Loaded, bytes: []const u8) sal.Plain(Images, "decode") {
        const image = host.images.decode(loaded, bytes) catch |err| return imageError(err);
        return hold(loaded, image);
    }

    pub fn load(loaded: *Loaded, path: []const u8) LoadPromise {
        const pair = LoadPromise.make() catch return .{};
        const t = wraith.tablesOf(loaded) orelse {
            pair.resolver.drop();
            return pair.promise;
        };
        const resolver: LoadResolver = .of(pair.resolver, loaded);
        const full = if (std.fs.path.isAbsolute(path))
            allocator.dupe(u8, path)
        else
            std.fs.path.join(allocator, &.{ loaded.copy_dir, path });
        // Elsewhere, like with "..", it needs to say so
        if (full) |f| {
            if (!loaded.allows(.files) and !ownsResolved(loaded, f)) {
                allocator.free(f);
                resolver.fail(wraith.undeclared(error.NotDeclared, "files"));
                return pair.promise;
            }
        } else |_| {}
        const job = allocator.create(Load) catch {
            resolver.fail(error.Failed);
            return pair.promise;
        };
        job.* = .{ .owner = t.owner, .loaded = loaded, .path = full catch {
            allocator.destroy(job);
            resolver.fail(error.Failed);
            return pair.promise;
        }, .resolver = resolver };
        threads.post(.worker, sal.Task.init(job, Load.run)) catch {
            job.free();
            resolver.fail(error.Failed);
        };
        return pair.promise;
    }

    pub fn draw(_: *Loaded, image: W.Image, size: W.ImVec2) void {
        if (!host.ui.inFrame() or image.table == null) return;
        const s = image.dimensions();
        const want: c.ImVec2 = if (size.x == 0 and size.y == 0)
            .{ .x = @floatFromInt(s.width), .y = @floatFromInt(s.height) }
        else
            .{ .x = size.x, .y = size.y };
        const ref = image.texture();
        // Not uploaded yet, so it keeps its space
        if (ref.data == 0) return c.ImGui_Dummy(want);
        c.ImGui_Image(.{ ._TexData = @ptrFromInt(ref.data), ._TexID = ref.id }, want);
    }
};

const LoadPromise = sal.Plain(Images, "load");
const LoadResolver = threads.Back(wraith.ResolverOf(LoadPromise));

/// Bigger files aren't images anyone would draw.
const max_file = 64 << 20;

/// Reads and decodes a file on a worker. Gives up once the plugin's gone.
const Load = struct {
    owner: *sal.Owner,
    loaded: *Loaded,
    path: []u8,
    resolver: LoadResolver,

    fn free(self: *Load) void {
        allocator.free(self.path);
        allocator.destroy(self);
    }

    fn run(self: *Load) void {
        defer self.free();
        if (!self.owner.enter()) return self.resolver.drop();
        defer self.owner.leave();
        const io = wraith.ioOf() orelse return self.resolver.fail(error.Failed);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, self.path, allocator, .limited(max_file)) catch |err|
            return self.resolver.fail(if (err == error.FileNotFound) error.NotFound else error.Failed);
        defer allocator.free(bytes);
        const image = host.images.decode(self.loaded, bytes) catch |err| return self.resolver.fail(imageError(err));
        self.resolver.settle(hold(self.loaded, image) catch |err| return self.resolver.fail(err));
    }
};

pub const ImageImpl = struct {
    pub fn dimensions(h: *Held) W.Image.Size {
        const s = host.images.size(h.loaded, h.image);
        return .{ .width = s.width, .height = s.height };
    }

    pub fn texture(h: *Held) W.TextureRef {
        const ref = host.images.textureOf(h.loaded, h.image);
        return .{ .data = @intFromPtr(ref.tex_data), .id = ref.tex_id };
    }

    pub fn destroy(h: *Held) void {
        host.images.destroy(h.loaded, h.image);
    }
};

const tests = struct {
    const testing = std.testing;
    const sdk = @import("wraith_sdk");
    const tuft_image = @import("tuft_image");
    const ImagesStore = @import("../Images.zig");

    test "images through a plugin's Wraith" {
        ImagesStore.global = .init(testing.allocator);
        defer ImagesStore.global.deinit();
        var loaded: Loaded = undefined;
        loaded.initForTest(testing.allocator, "kai");
        sdk.Owner.attach(loaded.root());
        defer sdk.Owner.detach();
        const images = sdk.wraith.root().?.images();

        const pixels: [2 * 1 * 4]u8 = @splat(9);
        const one = try images.create(2, 1, &pixels);
        try testing.expectEqual(2, one.dimensions().width);
        try testing.expectError(error.InvalidImage, images.create(2, 2, &pixels));
        try testing.expectError(error.InvalidImage, images.decode("nope"));
        const png = try tuft_image.encodePng(testing.allocator, .{ .width = 2, .height = 1, .pixels = @constCast(&pixels) });
        defer testing.allocator.free(png);
        const two = try images.decode(png);
        try testing.expectEqual(1, two.dimensions().height);
        // No ImGui frame, so nothing to draw
        try testing.expectEqual(0, two.texture().data);

        one.destroy();
        one.destroy();
        try testing.expectEqual(0, one.dimensions().width);
        loaded.deinitForTest();
        wraith.forget(&loaded);
        try testing.expectEqual(0, ImagesStore.global.count());
        try testing.expectError(error.Gone, images.create(2, 1, &pixels));
    }

    test "load reads a file in the plugin's folder on a worker" {
        ImagesStore.global = .init(testing.allocator);
        defer ImagesStore.global.deinit();
        wraith.setIo(testing.io);
        defer wraith.setIo(null);
        defer threads.stop();
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const pixels: [2 * 1 * 4]u8 = @splat(9);
        const png = try tuft_image.encodePng(testing.allocator, .{ .width = 2, .height = 1, .pixels = @constCast(&pixels) });
        defer testing.allocator.free(png);
        try tmp.dir.createDirPath(testing.io, "images");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "images/dot.png", .data = png });
        const dir = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
        defer testing.allocator.free(dir);

        var loaded: Loaded = undefined;
        loaded.initForTest(testing.allocator, "kai");
        loaded.copy_dir = dir;
        sdk.Owner.attach(loaded.root());
        defer sdk.Owner.detach();
        const images = sdk.wraith.root().?.images();
        const image = try images.load("images/dot.png").wait();
        try testing.expectEqual(2, image.dimensions().width);
        try testing.expectError(error.NotFound, images.load("images/none.png").wait());
        loaded.deinitForTest();
        wraith.forget(&loaded);
    }
};

test {
    _ = tests;
}
