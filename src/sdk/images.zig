//! Images to draw in the overlay, and the CPU side: decoding, PNG and frame captures. The runtime's
//! images are `wraith.sal`'s `images` area. This adds loading a file on a worker, and drawing one.

const std = @import("std");

const api = @import("wraith_api");
const tuft_image = @import("tuft_image");
const ui = @import("wraith_ui");
const Owner = @import("Owner.zig");
const frame = @import("frame.zig");
const tasks = @import("tasks.zig");

pub const Image = api.wraith.Image;
pub const DrawOptions = ui.ImageOptions;
pub const Fit = ui.ImageFit;

/// Bigger files aren't images we'd want to load.
pub const max_file = 64 << 20;

pub const LoadError = frame.MoveError || std.Io.Dir.ReadFileAllocError || error{
    InvalidImage,
    TooBig,
    Failed,
    Gone,
    Unsupported,
    Cancelled,
    /// Not in a task, and on the render thread where reading would stall the game.
    OnRenderThread,
    /// Not in a task, and on the game thread, where it'd stall the game too.
    OnGameThread,
};

/// Reads and decodes a file on a worker. A task goes back where it was after. Elsewhere it runs right
/// there, so not on the render or game thread.
pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) LoadError!Image {
    const task = tasks.current();
    const was = if (task) |t| t.where else null;
    if (task == null and frame.onRenderThread()) return error.OnRenderThread;
    if (task == null and frame.onGameThread()) return error.OnGameThread;
    const owner = Owner.current() orelse return error.Gone;
    if (task != null) try frame.toWorker(io);
    defer if (was) |w| switch (w) {
        .render => frame.toRender(io) catch {},
        .game => frame.toGame(io) catch {},
        .worker => {},
    };
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file));
    defer allocator.free(bytes);
    return owner.root.images().decode(bytes);
}

/// Like `ImGui_Image`, at its own size by default, see `DrawOptions`. Render thread.
pub fn draw(image: Image, options: DrawOptions) void {
    if (!ui.isBound()) return;
    const s = image.size();
    const pixels: ui.Vec2 = .{ @floatFromInt(s.width), @floatFromInt(s.height) };
    const ref = image.texture();
    if (ref.data != 0) return ui.image(.{ ._TexData = @ptrFromInt(ref.data), ._TexID = ref.id }, pixels, options);
    const gap = ui.imageSize(pixels, options, ui.getContentRegionAvailPixels());
    ui.raw("ImGui_Dummy")(.{ .x = gap[0], .y = gap[1] });
}

// CPU work, done in the plugin. All of it's slow, so keep it off the render thread.

/// RGBA pixels, rows packed, 4 bytes each.
pub const Pixels = tuft_image.Image;
pub const PixelsError = tuft_image.Error;
/// A file's pixels, without making an `Image`.
pub const decodePixels = tuft_image.decode;
/// A PNG file from pixels. Free it with the same allocator.
pub const encodePng = tuft_image.encodePng;
/// An EXR file from a `Linear`, keeping HDR's full range. Free it with the same allocator.
pub const encodeExr = tuft_image.encodeExr;
/// A frame as linear light, before it's made SDR or written as HDR.
pub const Linear = tuft_image.Linear;
/// A capture, with its pixels as bytes, as linear light.
pub const linearFromCapture = tuft_image.linearFromCapture;
/// A capture as opaque SDR pixels. HDR gets tone-mapped, see `Linear.sdr`.
pub const fromCapture = tuft_image.fromCapture;

test "load reads on a worker" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const rgba: [4]u8 = .{ 1, 2, 3, 4 };
    const png = try encodePng(std.testing.allocator, .{ .width = 1, .height = 1, .pixels = @constCast(&rgba) });
    defer std.testing.allocator.free(png);
    try tmp.dir.writeFile(io, .{ .sub_path = "dot.png", .data = png });
    const path = try tmp.dir.realPathFileAlloc(io, "dot.png", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var fake: Fake = .{};
    fake.attach();
    defer fake.detach();

    const State = struct {
        done: @import("tuft_arch").atomic.Value(bool) = .init(false),
        result: anyerror!Image = error.NotRun,
        back_on_render: bool = false,

        fn run(self: *@This(), io_: std.Io, file: []const u8) !void {
            defer self.done.store(true, .release);
            self.result = load(io_, std.testing.allocator, file);
            self.back_on_render = tasks.current().?.where == .render;
        }
    };
    var group: std.Io.Group = .init;
    var scheduler = tasks.Scheduler.init(std.testing.allocator, io, Owner.own().?, &group);
    defer scheduler.deinit();
    defer scheduler.cancel();
    var state: State = .{};
    try scheduler.spawn(State.run, .{ &state, io, path });
    for (0..2000) |_| {
        if (state.done.load(.acquire)) break;
        fake.runFrame();
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(state.done.load(.acquire));
    const image = try state.result;
    defer image.destroy();
    try std.testing.expect(state.back_on_render);
    try std.testing.expectEqual(1, image.size().width);
}

const Fake = @import("testing.zig").Fake;
