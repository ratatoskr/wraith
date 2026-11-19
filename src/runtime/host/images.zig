//! Images owners draw, see `Images`. Pixels get decoded and copied on the caller's thread.

const std = @import("std");

const Owner = @import("tuft_event").Owner;
const Texture = @import("tuft_imgui").Texture;
const tuft_image = @import("tuft_image");
const api = @import("wraith_api");

const Loaded = @import("../PluginLoader.zig").Loaded;
const Images = @import("../Images.zig");

pub fn create(loaded: *Loaded, width: u32, height: u32, rgba: []const u8) api.ImageError!*api.ImageHandle {
    if (width > Texture.max_side or height > Texture.max_side) return error.TooBig;
    const made = Texture.create(Images.global.allocator, width, height, rgba) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidSize => error.InvalidImage,
    };
    return keep(loaded, made);
}

pub fn decode(loaded: *Loaded, bytes: []const u8) api.ImageError!*api.ImageHandle {
    const gpa = Images.global.allocator;
    const image = tuft_image.decode(gpa, bytes) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooBig => error.TooBig,
        else => error.InvalidImage,
    };
    const made = Texture.adopt(gpa, image.width, image.height, image.pixels) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidSize => error.InvalidImage,
    };
    return keep(loaded, made);
}

fn keep(loaded: *Loaded, made: *Texture) api.ImageError!*api.ImageHandle {
    const lease = keeping(loaded) orelse {
        made.destroy();
        return error.OwnerGone;
    };
    defer lease.end();
    return @ptrFromInt(try Images.global.add(&loaded.owner, made));
}

pub fn destroy(loaded: *Loaded, image: *api.ImageHandle) void {
    Images.global.remove(&loaded.owner, idOf(image));
}

pub fn size(loaded: *Loaded, image: *api.ImageHandle) api.ImageSize {
    const s = Images.global.size(&loaded.owner, idOf(image)) orelse return .{};
    return .{ .width = s[0], .height = s[1] };
}

pub fn textureOf(loaded: *Loaded, image: *api.ImageHandle) api.TextureRef {
    const ref = Images.global.textureRef(&loaded.owner, idOf(image)) orelse return .{};
    return .{ .tex_data = ref._TexData, .tex_id = ref._TexID };
}

fn idOf(image: *api.ImageHandle) u32 {
    return std.math.cast(u32, @intFromPtr(image)) orelse 0;
}

fn keeping(loaded: *Loaded) ?Owner.Lease {
    return watch.lease(&listener, &loaded.owner, .data);
}

var watch: Owner.Watch(*u8, .{ .released = released }) = .{};
var listener: u8 = 0;

fn released(_: *u8, owner: *Owner) void {
    Images.global.removeOwner(owner);
}

const tests = struct {
    const testing = std.testing;
    const c = @import("tuft_imgui").c;

    test "images go with their plugin" {
        Images.global = .init(testing.allocator);
        defer Images.global.deinit();
        var a: Loaded = undefined;
        a.initForTest(testing.allocator, "a");
        var b: Loaded = undefined;
        b.initForTest(testing.allocator, "b");
        defer b.deinitForTest();

        const pixels: [2 * 1 * 4]u8 = @splat(9);
        const one = try create(&a, 2, 1, &pixels);
        try testing.expectEqual(api.ImageSize{ .width = 2, .height = 1 }, size(&a, one));
        // Only its owner can use it
        try testing.expectEqual(api.ImageSize{}, size(&b, one));
        destroy(&b, one);
        try testing.expectEqual(1, Images.global.count());
        try testing.expectError(error.InvalidImage, create(&a, 2, 2, &pixels));
        try testing.expectError(error.InvalidImage, decode(&a, "nope"));

        const png = try tuft_image.encodePng(testing.allocator, .{ .width = 2, .height = 1, .pixels = @constCast(&pixels) });
        defer testing.allocator.free(png);
        const two = try decode(&a, png);
        try testing.expectEqual(api.ImageSize{ .width = 2, .height = 1 }, size(&a, two));

        destroy(&a, one);
        destroy(&a, one);
        try testing.expectEqual(api.ImageSize{}, size(&a, one));
        // No ImGui context, so nothing to draw
        try testing.expectEqual(null, textureOf(&a, two).tex_data);
        a.deinitForTest();
        try testing.expectEqual(0, Images.global.count());
        try testing.expectEqual(api.ImageSize{}, size(&a, two));
    }

    test "drawn in a frame" {
        Images.global = .init(testing.allocator);
        defer Images.global.deinit();
        var a: Loaded = undefined;
        a.initForTest(testing.allocator, "a");
        defer a.deinitForTest();

        const context = c.ImGui_CreateContext(null) orelse return error.CreateContextFailed;
        c.ImGui_SetCurrentContext(context);
        defer c.ImGui_DestroyContext(context);
        const io = c.ImGui_GetIO();
        io.*.IniFilename = null;
        io.*.DisplaySize = .{ .x = 64, .y = 64 };
        io.*.DeltaTime = 1.0 / 60.0;
        @import("tuft_imgui").headless.init();

        const pixels: [4]u8 = @splat(255);
        const image = try create(&a, 1, 1, &pixels);
        c.ImGui_NewFrame();
        const ref = textureOf(&a, image);
        try testing.expect(ref.tex_data != null);
        c.ImGui_Image(.{ ._TexData = @ptrCast(@alignCast(ref.tex_data)), ._TexID = ref.tex_id }, .{ .x = 1, .y = 1 });
        c.ImGui_Render();
        destroy(&a, image);
        try testing.expectEqual(null, textureOf(&a, image).tex_data);
    }
};

test {
    _ = tests;
}
