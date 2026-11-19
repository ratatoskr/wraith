//! Wraith's built-in fonts, Inter and JetBrains Mono, each with Lucide's icons and Simple Icons'
//! logos merged in, so `icons` and `brands` work in any text. The system's Chinese, Japanese or
//! Korean fonts go in after, for the ones this user reads or types, so those don't show as "?".

const std = @import("std");

const tuft_imgui = @import("tuft_imgui");
const wraith_platform = @import("wraith_platform");
const ui = @import("wraith_ui");

pub const icons = @import("icons.zig");
pub const brands = @import("brands.zig");

const system_fonts = wraith_platform.fonts;

const inter = @embedFile("fonts/Inter-Regular.ttf");
const inter_bold = @embedFile("fonts/Inter-SemiBold.ttf");
const mono = @embedFile("fonts/JetBrainsMono-Regular.ttf");
const lucide = @embedFile("fonts/Lucide.ttf");
/// Cut down to `brands`. Its codepoints don't overlap Lucide's.
const simple_icons = @embedFile("fonts/SimpleIcons.ttf");

/// Read by `loadSystem`, most wanted first. ImGui keeps pointing at them, so they stay till
/// `freeSystem`.
var system: [4]?[]u8 = @splat(null);
var system_allocator: ?std.mem.Allocator = null;
/// They're big, so not more than this many MB each.
const max_system_mb = 64;

/// `size` is unscaled. Once per context, before its first frame, on its thread.
pub fn load(size: f32) void {
    _ = withIcons(inter, size, "Inter", inter_caps);
    ui.setFonts(.{
        .bold = withIcons(inter_bold, size, "Inter SemiBold", inter_caps),
        .mono = withIcons(mono, size, "JetBrains Mono", mono_caps),
    });
}

/// Reads the system fonts `load` adds. Not on the render thread, and before any `load`.
pub fn loadSystem(allocator: std.mem.Allocator, io: std.Io) void {
    // std's file calls want more stack than the caller may have
    var reading = io.concurrent(readSystem, .{ allocator, io }) catch return;
    reading.await(io);
    system_allocator = allocator;
}

/// After every context using them is gone.
pub fn freeSystem() void {
    const allocator = system_allocator orelse return;
    for (&system) |*data| {
        if (data.*) |d| allocator.free(d);
        data.* = null;
    }
    system_allocator = null;
}

fn readSystem(allocator: std.mem.Allocator, io: std.Io) void {
    var scripts_buf: [4]system_fonts.Script = undefined;
    const scripts = system_fonts.scriptsInUse(&scripts_buf);
    var dir_buf: [512]u8 = undefined;
    const dir = system_fonts.dir(&dir_buf) orelse return;
    for (scripts, 0..) |script, i| {
        const slot = &system[i];
        for (system_fonts.files(script)) |name| {
            var path_buf: [600]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}\\{s}", .{ dir, name }) catch continue;
            slot.* = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_system_mb << 20)) catch continue;
            break;
        }
    }
}

/// Where the middle of a capital letter is, above the baseline, as a share of the font's size. ImGui
/// sizes a font by its ascent plus descent, so for Inter that's half its cap height of 1490 over
/// 1984 + 494, and for JetBrains Mono half of 730 over 1020 + 300.
const inter_caps = 745.0 / 2478.0;
const mono_caps = 365.0 / 1320.0;
/// Lucide's and Simple Icons' glyphs are centred half way up theirs.
const icons_middle = 0.5;

/// Inter has stylistic alternates where Lucide's icons are, and the first font with a glyph wins.
/// The icons are moved down to centre on the text's capitals, else they sit high and get clipped.
fn withIcons(data: []const u8, size: f32, name: [:0]const u8, caps: f32) ?*ui.c.ImFont {
    const font = tuft_imgui.addFont(data, size, name, .{ .skip_private_use = true }) orelse return null;
    const icons_offset: tuft_imgui.MergeOptions = .{ .offset_y = @round((icons_middle - caps) * size) };
    _ = tuft_imgui.mergeFont(lucide, size, font, "Lucide", icons_offset);
    _ = tuft_imgui.mergeFont(simple_icons, size, font, "Simple Icons", icons_offset);
    for (system) |s| if (s) |d| {
        _ = tuft_imgui.mergeFont(d, size, font, "System", .{});
    };
    return font;
}

test "the system's fonts cover what this user reads or types" {
    var scripts_buf: [4]system_fonts.Script = undefined;
    const scripts = system_fonts.scriptsInUse(&scripts_buf);
    loadSystem(std.testing.allocator, std.testing.io);
    defer freeSystem();
    if (scripts.len == 0) return error.SkipZigTest; // no Chinese, Japanese or Korean here
    try std.testing.expect(system[0] != null);

    const c = ui.c;
    const context = c.ImGui_CreateContext(null);
    defer c.ImGui_DestroyContext(context);
    const font = withIcons(inter, 13, "Inter", inter_caps).?;
    const sample: u16 = switch (scripts[0]) {
        .japanese => 0x3042, // あ
        .korean => 0xD55C, // 한
        .chinese_simplified, .chinese_traditional => 0x4E2D, // 中
    };
    try std.testing.expect(c.ImFont_IsGlyphInFont(font, sample));
    try std.testing.expect(c.ImFont_IsGlyphInFont(font, 'A'));
}
