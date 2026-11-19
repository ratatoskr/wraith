//! The game's rendering as API-agnostic events. Subscribers must be gone before `destroy`.

const Graphics = @This();

const std = @import("std");

const core = @import("wraith_core");
const gfx = @import("tuft_gfx");
const sys = @import("tuft_sys");

pub const Frame = gfx.Frame;
pub const Api = gfx.Api;

pub const FrameEvent = core.Event(fn (*const Frame) void);

const log = core.log.scoped(.wraith_graphics);

allocator: std.mem.Allocator,
attach: FrameEvent,
frame: FrameEvent,
resize: FrameEvent,
detach: FrameEvent,
paths: *gfx.Paths,
/// Render thread only.
api: ?Api = null,
/// Render thread only.
dlls: ?gfx.dlls.Report = null,
handover: ?*core.runtime_abi.GraphicsHandover = null,
presenting: ?gfx.Paths.Known = null,
presenting_lock: sys.sync.RwLock = .{},

pub const Options = struct {
    early: bool = false,
    /// Bootstrap's slot for handing the game's graphics to the next runtime.
    handover: ?*core.runtime_abi.GraphicsHandover = null,
};

/// Hooks start disabled. `enable` starts delivering frames.
pub fn create(allocator: std.mem.Allocator, options: Options) !*Graphics {
    const self = try allocator.create(Graphics);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .attach = .init(allocator),
        .frame = .init(allocator),
        .resize = .init(allocator),
        .detach = .init(allocator),
        .paths = undefined,
    };
    errdefer self.deinitEvents();
    self.handover = options.handover;
    const known = self.takeHandover();
    // Drop the reference it came with, attaching takes its own
    defer if (known) |k| if (k.object) |o| gfx.com.release(o);
    self.paths = try gfx.Paths.create(allocator, .of(Graphics, self), .{ .early = options.early, .known = known });
    return self;
}

fn takeHandover(self: *Graphics) ?gfx.Paths.Known {
    const slot = self.handover orelse return null;
    defer slot.* = .{};
    if (slot.api == 0) return null;
    return .{ .api = @fromBackingInt(@intCast(slot.api)), .object = slot.object };
}

fn leaveHandover(self: *Graphics) void {
    const slot = self.handover orelse return;
    self.presenting_lock.lock();
    defer self.presenting_lock.unlock();
    const known = self.presenting orelse return;
    if (known.object) |o| gfx.com.addRef(o);
    slot.* = .{ .api = @backingInt(known.api), .object = known.object };
    log.debug("Handing the game's {t} graphics over to the next runtime", .{known.api});
}

pub fn enable(self: *Graphics) !void {
    try self.paths.enable();
}

/// Waits for frames in flight.
pub fn destroy(self: *Graphics) void {
    // Grab a reference before the paths let go of it
    self.leaveHandover();
    self.paths.destroy();
    if (self.dlls) |*d| d.deinit();
    self.deinitEvents();
    self.allocator.destroy(self);
}

fn deinitEvents(self: *Graphics) void {
    self.attach.deinit();
    self.frame.deinit();
    self.resize.deinit();
    self.detach.deinit();
}

// gfx.Listener
pub fn onAttach(self: *Graphics, f: *const Frame) void {
    if (self.api == null) self.noteDlls(f.api);
    self.api = f.api;
    self.setPresenting(.{ .api = f.api, .object = switch (f.api) {
        .d3d9 => f.device,
        .d3d10, .d3d11, .d3d12 => f.swap_chain,
        else => null,
    } });
    self.attach.fire(.{f});
}
pub fn onFrame(self: *Graphics, f: *const Frame) void {
    self.frame.fire(.{f});
}
pub fn onResize(self: *Graphics, f: *const Frame) void {
    self.resize.fire(.{f});
}
pub fn onDetach(self: *Graphics, f: *const Frame) void {
    self.setPresenting(null);
    self.detach.fire(.{f});
}

fn setPresenting(self: *Graphics, known: ?gfx.Paths.Known) void {
    self.presenting_lock.lock();
    defer self.presenting_lock.unlock();
    self.presenting = known;
}

fn noteDlls(self: *Graphics, api: Api) void {
    self.dlls = gfx.dlls.scan(self.allocator) catch |err| {
        log.warn("Rendering with {t}; couldn't check its DLLs: {t}", .{ api, err });
        return;
    };
    log.info("Rendering with {t}", .{api});
    for (self.dlls.?.dlls) |*d| {
        if (d.replaced()) log.info("  {s}: {f} ({s})", .{ d.name, Described{ .dll = d }, d.path }) else log.debug("  {s}: {f} ({s})", .{ d.name, Described{ .dll = d }, d.path });
    }
}

pub const Described = struct {
    dll: *const gfx.dlls.Dll,

    pub fn format(self: Described, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const d = self.dll;
        if (d.known) |k| try w.print("{t}", .{k}) else try w.writeAll(if (d.system) "Windows'" else "not Windows'");
        const info = d.info orelse return w.writeAll(", no version resource");
        if (d.replaced()) {
            if (info.description.len != 0) try w.print(", \"{s}\"", .{info.description});
            if (info.product_name.len != 0) try w.print(", product \"{s}\"", .{info.product_name});
        }
        if (info.versions) |v| try w.print(", version {f}", .{v.product});
    }
};

const tests = struct {
    const testing = std.testing;
    const hook = @import("tuft_hook");

    const Recorder = struct {
        attaches: u32 = 0,
        frames: u32 = 0,
        resizes: u32 = 0,
        detaches: u32 = 0,
        last: ?Frame = null,

        fn onAttach(self: *Recorder, f: *const Frame) void {
            self.attaches += 1;
            self.last = f.*;
        }
        fn onFrame(self: *Recorder, f: *const Frame) void {
            self.frames += 1;
            self.last = f.*;
        }
        fn onResize(self: *Recorder, _: *const Frame) void {
            self.resizes += 1;
        }
        fn onDetach(self: *Recorder, _: *const Frame) void {
            self.detaches += 1;
        }
    };

    test "reload hands over the swap chain" {
        const saved = core.log.mute(&.{.graphics});
        defer core.log.setFilter(saved);
        try hook.init(testing.allocator);
        defer hook.deinit();

        const owned = try gfx.d3d11.OwnedSwapChain.create();
        defer owned.destroy();
        var slot: core.runtime_abi.GraphicsHandover = .{};

        const first = try Graphics.create(testing.allocator, .{ .handover = &slot });
        try first.enable();
        _ = owned.swap_chain.present(0, 0);
        first.destroy();
        try testing.expectEqual(@backingInt(Api.d3d11), slot.api);
        try testing.expectEqual(@as(?*anyopaque, owned.swap_chain), slot.object);

        const next = try Graphics.create(testing.allocator, .{ .handover = &slot });
        defer next.destroy();
        try testing.expectEqual(0, slot.api);
        var scope = core.Scope.init(testing.allocator);
        defer scope.deinit();
        var recorder: Recorder = .{};
        try next.attach.subscribe(&scope, &recorder, Recorder.onAttach);
        try next.enable();
        _ = owned.swap_chain.present(0, 0);
        try testing.expectEqual(1, recorder.attaches);
        try testing.expectEqual(Api.d3d11, recorder.last.?.api);
    }

    test "reports arrive as events" {
        const saved = core.log.mute(&.{.graphics});
        defer core.log.setFilter(saved);
        try hook.init(testing.allocator);
        defer hook.deinit();

        const owned = try gfx.d3d11.OwnedSwapChain.create();
        defer owned.destroy();

        const g = try Graphics.create(testing.allocator, .{});
        var scope = core.Scope.init(testing.allocator);
        var recorder: Recorder = .{};
        try g.attach.subscribe(&scope, &recorder, Recorder.onAttach);
        try g.frame.subscribe(&scope, &recorder, Recorder.onFrame);
        try g.resize.subscribe(&scope, &recorder, Recorder.onResize);
        try g.enable();

        _ = owned.swap_chain.present(0, 0);
        _ = owned.swap_chain.present(0, 0);
        try testing.expectEqual(1, recorder.attaches);
        try testing.expectEqual(2, recorder.frames);
        try testing.expectEqual(Api.d3d11, recorder.last.?.api);
        try testing.expectEqual(@as(*anyopaque, owned.swap_chain), recorder.last.?.swap_chain);

        try testing.expect(gfx.com.succeeded(owned.swap_chain.resizeBuffers(0, 128, 96, 0, 0)));
        try testing.expectEqual(1, recorder.resizes);

        try testing.expectEqual(Api.d3d11, g.api.?);
        const d3d11 = g.dlls.?.find("d3d11.dll").?;
        try testing.expect(!d3d11.replaced());

        scope.deinit();
        g.destroy();
        _ = owned.swap_chain.present(0, 0);
        try testing.expectEqual(2, recorder.frames);
    }
};

test {
    _ = tests;
}
