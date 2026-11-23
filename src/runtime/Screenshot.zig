//! Screenshots on a key. A PNG always, an EXR too in HDR games that keeps the full range, and a
//! copy on the clipboard. The frame's copied on the render thread and saved on a thread of its own,
//! with a toast saying how it went. It was a plugin once, whose settings it takes over.

const Screenshot = @This();

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const core = @import("wraith_core");
const api = @import("wraith_api");
const platform = @import("wraith_platform");
const tuft_image = @import("tuft_image");
const Toasts = @import("wraith_ui").Toasts;
const Keybinds = @import("tuft_input").Keybinds;
const Keys = @import("tuft_input").Keys;

const Registry = @import("settings/Registry.zig");
const Settings = @import("Settings.zig");
const capture = @import("host/capture.zig");
const frame = @import("host/frame.zig");

const log = core.log.scoped(.wraith_runtime);

/// In Pictures, when no folder's picked.
pub const default_folder = "Wraith";
/// The plugin it used to be, whose settings it takes over.
const old_plugin = "screenshot";
const title = "Screenshot";
const section = "Screenshots";

const State = enum(u8) {
    idle,
    /// Asked the overlay for a frame.
    waiting,
    /// The overlay's copying it.
    copying,
    /// The saver has it.
    saving,
};

allocator: std.mem.Allocator,
io: std.Io,
registry: *Registry,
toasts: *Toasts,
key: *Registry.Setting,
folder: *Registry.Setting,
clipboard: *Registry.Setting,
exr: *Registry.Setting,
overlay: *Registry.Setting,
state: Atomic(State) = .init(.idle),
/// Which one it asked for, and when. Set while idle, on the render thread.
point: capture.Point = .before_overlay,
asked_ns: u64 = 0,
subscription: capture.Subscription = undefined,
/// The last one saving. Joined before the next starts, and when it goes.
saver: ?std.Thread = null,

/// Wraith's settings, carried over from the plugin.
const ids = struct {
    const key = "wraith.screenshot.take";
    const folder = "wraith.screenshot.folder";
    const clipboard = "wraith.screenshot.clipboard";
    const exr = "wraith.screenshot.exr";
    const overlay = "wraith.screenshot.overlay";
};
const carried = [_][2][]const u8{
    .{ old_plugin ++ ".take", ids.key },
    .{ old_plugin ++ ".folder", ids.folder },
    .{ old_plugin ++ ".clipboard", ids.clipboard },
    .{ old_plugin ++ ".exr", ids.exr },
    .{ old_plugin ++ ".include_overlay", ids.overlay },
};

/// Keep it where it is, since the key and the capture point at it.
pub fn init(self: *Screenshot, allocator: std.mem.Allocator, io: std.Io, registry: *Registry, toasts: *Toasts) !void {
    for (carried) |c| registry.rename(.global, c[0], c[1]) catch |err| log.warn("Couldn't carry over the Screenshot plugin's {s}: {t}", .{ c[0], err });
    self.* = .{
        .allocator = allocator,
        .io = io,
        .registry = registry,
        .toasts = toasts,
        .key = undefined,
        .folder = undefined,
        .clipboard = undefined,
        .exr = undefined,
        .overlay = undefined,
    };
    self.key = try registry.add(.{
        .id = ids.key,
        .name = "Take a screenshot",
        .group = Settings.group,
        .section = section,
        .kind = .{ .key = .{ .default = .one(.{ .key = .f10 }) } },
    }, .{ .key = .{ .ctx = self, .call = keyPressed } });
    errdefer registry.remove(self.key);
    self.folder = try registry.add(.{
        .id = ids.folder,
        .name = "Folder",
        .help = "Where screenshots go.",
        .group = Settings.group,
        .section = section,
        .kind = .{ .path = .{ .placeholder = "Pictures\\" ++ default_folder } },
    }, .{});
    errdefer registry.remove(self.folder);
    self.clipboard = try registry.add(.{
        .id = ids.clipboard,
        .name = "Copy to the clipboard",
        .help = "Each one's ready to paste too.",
        .group = Settings.group,
        .section = section,
        .kind = .{ .toggle = true },
    }, .{});
    errdefer registry.remove(self.clipboard);
    self.exr = try registry.add(.{
        .id = ids.exr,
        .name = "Save an EXR too in HDR games",
        .help = "Keeps the full HDR range, next to the PNG.",
        .group = Settings.group,
        .section = section,
        .kind = .{ .toggle = true },
    }, .{});
    errdefer registry.remove(self.exr);
    self.overlay = try registry.add(.{
        .id = ids.overlay,
        .name = "Include the overlay",
        .help = "Keeps Wraith's own windows in the shot.",
        .group = Settings.group,
        .section = section,
        .kind = .{ .toggle = false },
    }, .{});
    errdefer registry.remove(self.overlay);
    self.subscription = try capture.watch(self, fire);
}

/// Waits for one that's saving.
pub fn deinit(self: *Screenshot) void {
    // Waits for the key's callback in flight
    self.registry.remove(self.key);
    self.subscription.unsubscribe();
    if (self.state.cmpxchgStrong(.waiting, .idle, .acq_rel, .acquire) == null) capture.unwant(self.point);
    if (self.saver) |t| t.join();
    self.saver = null;
    inline for (.{ "folder", "clipboard", "exr", "overlay" }) |name| self.registry.remove(@field(self, name));
}

fn keyPressed(ctx: *anyopaque, phase: Keybinds.Phase) void {
    if (phase != .pressed) return;
    const self: *Screenshot = @ptrCast(@alignCast(ctx));
    self.take();
}

/// The next frame. Render thread, like the key.
pub fn take(self: *Screenshot) void {
    if (!frame.framesOn()) {
        _ = self.toasts.push(.{ .kind = .@"error", .title = title, .text = "There's no frame to take yet." });
        return;
    }
    // The overlay may have stopped drawing since, so it'd never come
    if (core.timing.now() -| self.asked_ns > give_up_ns and self.state.cmpxchgStrong(.waiting, .idle, .acq_rel, .acquire) == null) {
        capture.unwant(self.point);
    }
    if (self.state.load(.acquire) != .idle) {
        _ = self.toasts.push(.{ .kind = .info, .title = title, .text = "Still saving the last one.", .seconds = 2 });
        return;
    }
    self.point = if (self.registry.get(self.overlay).toggle) .after_overlay else .before_overlay;
    self.asked_ns = core.timing.now();
    self.state.store(.waiting, .release);
    capture.want(self.point);
}

const give_up_ns = 2 * std.time.ns_per_s;

/// The overlay's capture events, on the render thread.
fn fire(self: *Screenshot, event: *const capture.Event) void {
    switch (event.*) {
        .started => |point| if (point == self.point and self.state.cmpxchgStrong(.waiting, .copying, .acq_rel, .acquire) == null) {
            capture.unwant(point);
        },
        .done => |d| if (d.point == self.point and self.state.load(.acquire) == .copying) self.startSaving(d.image),
        .failed => |point| if (point == self.point) {
            if (self.state.cmpxchgStrong(.waiting, .idle, .acq_rel, .acquire) == null) {
                capture.unwant(point);
            } else if (self.state.cmpxchgStrong(.copying, .idle, .acq_rel, .acquire) != null) return;
            _ = self.toasts.push(.{ .kind = .@"error", .title = title, .text = "Couldn't capture the frame." });
        },
    }
}

/// A copy of the frame, since the overlay's goes once `done` returns.
const Shot = struct {
    width: u32,
    height: u32,
    pitch: u32,
    format: api.PixelFormat,
    color_space: api.ColorSpace,
    sdr_white_nits: f32,
    pixels: []u8,
};

fn startSaving(self: *Screenshot, image: *const api.Image) void {
    const pixels = self.allocator.dupe(u8, image.pixels) catch {
        self.state.store(.idle, .release);
        _ = self.toasts.push(.{ .kind = .@"error", .title = title, .text = "Not enough memory for the screenshot." });
        return;
    };
    const shot: Shot = .{
        .width = image.width,
        .height = image.height,
        .pitch = image.pitch,
        .format = image.format,
        .color_space = image.color_space,
        .sdr_white_nits = image.sdr_white_nits,
        .pixels = pixels,
    };
    // It set idle as its very last step, so this is quick
    if (self.saver) |t| t.join();
    self.state.store(.saving, .release);
    self.saver = std.Thread.spawn(.{}, saveShot, .{ self, shot }) catch |err| {
        self.saver = null;
        self.allocator.free(pixels);
        self.state.store(.idle, .release);
        log.err("Couldn't start saving the screenshot: {t}", .{err});
        _ = self.toasts.push(.{ .kind = .@"error", .title = title, .text = "Couldn't save the screenshot." });
        return;
    };
}

/// On its own thread.
fn saveShot(self: *Screenshot, shot: Shot) void {
    defer self.state.store(.idle, .release);
    defer self.allocator.free(shot.pixels);
    const busy = self.toasts.push(.{ .kind = .info, .title = title, .text = "Saving the screenshot...", .seconds = 0 });
    const options: Options = .{
        .folder = self.registry.get(self.folder).path,
        .clipboard = self.registry.get(self.clipboard).toggle,
        .exr = self.registry.get(self.exr).toggle,
    };
    const result: Toasts.Toast = if (save(self.allocator, self.io, shot, options)) |saved|
        .{ .kind = .success, .title = title, .text = if (saved.exr) "Saved, with an EXR." else "Saved." }
    else |err| blk: {
        log.err("Couldn't save the screenshot: {t}", .{err});
        break :blk .{ .kind = .@"error", .title = title, .text = "Couldn't save the screenshot." };
    };
    if (!self.toasts.update(busy, result)) _ = self.toasts.push(result);
}

const Options = struct {
    /// Empty is `Pictures\Wraith`.
    folder: []const u8,
    clipboard: bool,
    exr: bool,
};

const Saved = struct { exr: bool };

fn save(allocator: std.mem.Allocator, io: std.Io, shot: Shot, options: Options) !Saved {
    const linear = try tuft_image.linearFromCapture(allocator, shot);
    defer linear.deinit(allocator);

    const folder = if (options.folder.len > 0) try allocator.dupe(u8, options.folder) else blk: {
        const pictures = try platform.fs.picturesDirAlloc(allocator);
        defer allocator.free(pictures);
        break :blk try std.fs.path.join(allocator, &.{ pictures, default_folder });
    };
    defer allocator.free(folder);
    try platform.fs.ensureDirectory(io, folder);
    const stamp = std.Io.Clock.real.now(io).toMilliseconds();

    const rgba = try linear.sdr(allocator, .{});
    defer rgba.deinit(allocator);
    if (options.clipboard) platform.clipboard.setImage(io, .{ .width = rgba.width, .height = rgba.height, .pixels = rgba.pixels }) catch |err| {
        log.warn("Couldn't copy the screenshot to the clipboard: {t}", .{err});
    };
    const png = try tuft_image.encodePng(allocator, rgba);
    defer allocator.free(png);
    try write(allocator, io, folder, stamp, "png", png);

    if (!options.exr or !linear.hdr) return .{ .exr = false };
    const exr = try tuft_image.encodeExr(allocator, linear);
    defer allocator.free(exr);
    try write(allocator, io, folder, stamp, "exr", exr);
    return .{ .exr = true };
}

fn write(allocator: std.mem.Allocator, io: std.Io, folder: []const u8, stamp: i64, extension: []const u8, bytes: []const u8) !void {
    const name = try std.fmt.allocPrint(allocator, "Screenshot-{d}.{s}", .{ stamp, extension });
    defer allocator.free(name);
    const path = try std.fs.path.join(allocator, &.{ folder, name });
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    log.info("Saved {s}", .{path});
}

const testing = std.testing;

test "a key press saves the next frame, with an EXR for HDR, and carries the plugin's folder over" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const global_path = try std.fs.path.join(a, &.{ root, "global.zon" });
    defer a.free(global_path);
    const shots = try std.fs.path.join(a, &.{ root, "shots" });
    defer a.free(shots);
    // What the plugin saved, so the clipboard stays the user's own
    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    try text.writer.print(".{{ .values = .{{ .{{ .id = \"screenshot.folder\", .value = .{{ .path = \"{f}\" }} }}, .{{ .id = \"screenshot.clipboard\", .value = .{{ .toggle = false }} }} }} }}\n", .{std.zig.fmtString(shots)});
    try tmp.dir.writeFile(io, .{ .sub_path = "global.zon", .data = text.written() });

    const registry = try Registry.create(a, .{ .io = io, .global_path = global_path });
    defer registry.destroy();
    var toasts: Toasts = .{};
    var shot: Screenshot = undefined;
    try shot.init(a, io, registry, &toasts);
    defer shot.deinit();
    try testing.expectEqualStrings(shots, registry.get(shot.folder).path);
    try testing.expect(!registry.get(shot.clipboard).toggle);

    // No frames yet
    shot.take();
    try testing.expect(!capture.wants(.before_overlay));

    frame.setFrames(true);
    defer frame.setFrames(false);
    shot.take();
    try testing.expect(capture.wants(.before_overlay));
    // Busy till it's saved
    shot.take();
    capture.deliver(.{ .started = .before_overlay });
    try testing.expect(!capture.wants(.before_overlay));

    // Two scRGB half-float pixels, one brighter than SDR
    var pixels: [16]u8 = undefined;
    for ([_]f16{ 0.5, 0.25, 0.125, 1, 4, 2, 1, 1 }, 0..) |v, i| std.mem.writeInt(u16, pixels[i * 2 ..][0..2], @bitCast(v), .little);
    const image: api.Image = .{ .width = 2, .height = 1, .pitch = 16, .format = .rgba16f, .graphics_api = .d3d11, .color_space = .scrgb, .sdr_white_nits = 80, .pixels = &pixels };
    capture.deliver(.{ .done = .{ .point = .before_overlay, .image = &image } });
    shot.saver.?.join();
    shot.saver = null;
    try testing.expectEqual(.idle, shot.state.load(.acquire));

    var dir = try std.Io.Dir.openDirAbsolute(io, shots, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var found: [2]bool = @splat(false);
    while (try it.next(io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".png")) found[0] = true;
        if (std.mem.endsWith(u8, entry.name, ".exr")) found[1] = true;
    }
    try testing.expect(found[0] and found[1]);
    try testing.expectEqualStrings("Saved, with an EXR.", lastToast(&toasts));

    // A frame that couldn't be copied says so, and the next works again
    shot.take();
    capture.deliver(.{ .failed = .before_overlay });
    try testing.expect(!capture.wants(.before_overlay));
    try testing.expectEqualStrings("Couldn't capture the frame.", lastToast(&toasts));
    try testing.expectEqual(.idle, shot.state.load(.acquire));

    // One the overlay never copied is given up on by a press a while later
    shot.take();
    shot.asked_ns = 0;
    shot.take();
    try testing.expect(capture.wants(.before_overlay));
    capture.deliver(.{ .failed = .before_overlay });
    try testing.expect(!capture.wants(.before_overlay));
    try testing.expectEqual(.idle, shot.state.load(.acquire));
}

fn lastToast(toasts: *const Toasts) []const u8 {
    const s = &toasts.slots[toasts.len - 1];
    return s.text_buf[0..s.text_len];
}
