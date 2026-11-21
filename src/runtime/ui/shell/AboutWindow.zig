//! The overlay's About window. Render thread.

const std = @import("std");
const build_info = @import("build_info");

const core = @import("wraith_core");
const wraith_platform = @import("wraith_platform");
const ui = @import("wraith_ui");

const fonts = @import("../fonts.zig");
const icons = fonts.icons;
const brands = fonts.brands;
const markdown = @import("../markdown.zig");

const c = ui.c;
const log = core.log.scoped(.wraith_ui);

const AboutWindow = @This();

/// Which part's showing.
window: ui.Window = .{ .title = "About Wraith###wraith.about", .size = .{ 680, 520 } },
section: Section = .about,

pub const Section = enum { about, license, third_party };

const sections = [_]struct { section: Section, label: [:0]const u8 }{
    .{ .section = .about, .label = icons.info ++ "  About" },
    .{ .section = .license, .label = icons.scale ++ "  License" },
    .{ .section = .third_party, .label = icons.blocks ++ "  Third-party" },
};

const Link = struct {
    label: [:0]const u8,
    url: [:0]const u8,
    colour: ui.Color,
};

const links = [_]Link{
    .{ .label = icons.globe ++ "  wraith.io", .url = "https://wraith.io", .colour = rgb(56, 116, 203) },
    .{ .label = brands.github ++ "  Ratatoskr", .url = "https://github.com/ratatoskr", .colour = rgb(64, 70, 84) },
    .{ .label = brands.github ++ "  Asgard", .url = "https://github.com/asgardkat", .colour = rgb(64, 70, 84) },
    .{ .label = brands.kofi ++ "  Ko-fi", .url = "https://ko-fi.com/asgard", .colour = rgb(255, 100, 51) },
};

const license_text = @embedFile("LICENSE");
const notices_text = @embedFile("THIRD_PARTY_NOTICES.md");

const tagline_colour: ui.Color = .{ 0.55, 0.9, 0.6, 1 };
const heart_colour: ui.Color = .{ 0.95, 0.35, 0.45, 1 };
/// Unscaled.
const title_size = 30;

pub fn onOpen(self: *AboutWindow) void {
    self.section = .about;
}

pub fn draw(self: *AboutWindow) void {
    self.drawSections();
    ui.spacing();
    switch (self.section) {
        .about => drawAbout(),
        .license => drawText("##license", license_text),
        .third_party => drawText("##notices", notices_text),
    }
}

/// One row of buttons sharing the width, the picked one lit.
fn drawSections(self: *AboutWindow) void {
    const style = ui.raw("ImGui_GetStyle")();
    const n: f32 = @floatFromInt(sections.len);
    const width = (ui.getContentRegionAvailPixels()[0] - style.*.ItemSpacing.x * (n - 1)) / n;
    for (sections, 0..) |s, i| {
        if (i > 0) ui.sameLine();
        const picked = s.section == self.section;
        const colour = ui.raw("ImGui_GetStyleColorVec4")(if (picked) c.ImGuiCol_ButtonActive else c.ImGuiCol_FrameBg);
        ui.raw("ImGui_PushStyleColorImVec4")(c.ImGuiCol_Button, colour.*);
        defer ui.raw("ImGui_PopStyleColor")();
        if (ui.buttonSized(s.label, .{ width, 0 })) self.section = s.section;
    }
}

/// Scrolls on its own, under the buttons.
fn drawText(id: [:0]const u8, text: []const u8) void {
    const box = ui.child(id, .{ 0, 0 }, .{ .border = true }) orelse return;
    defer box.end();
    markdown.draw(text, openSlice);
}

fn drawAbout() void {
    ui.spacing();
    {
        const bold = ui.bold();
        defer bold.end();
        ui.raw("ImGui_PushFontFloat")(null, title_size);
        defer ui.raw("ImGui_PopFont")();
        ui.text("Wraith", .{});
    }
    ui.sameLine();
    ui.raw("ImGui_AlignTextToFramePadding")();
    ui.textDisabled("{s}", .{build_info.version});

    ui.textColored(tagline_colour, "Mod your Windows games.", .{});
    ui.sameLine();
    ui.textDisabled("Find the thing you want to change, then change it.", .{});
    ui.spacing();
    ui.separator();
    ui.spacing();

    ui.textWrapped("Wraith is the mod loader inside the game. It draws this overlay and the Workbench, and runs your plugins and tweaks. The Wraith app on your desktop installs it and your plugins, and starts your games with Wraith in them.", .{});
    ui.spacing();
    ui.textWrapped("It's all open source. Wraith itself is AGPL, so anything you share that's built on it is open too.", .{});
    ui.spacing();
    ui.spacing();

    drawLinks();
    ui.spacing();
    ui.spacing();
    drawCredit();
}

/// Evenly across the window, in their own colours.
fn drawLinks() void {
    const style = ui.raw("ImGui_GetStyle")();
    const gap = style.*.ItemSpacing.x;
    const n: f32 = @floatFromInt(links.len);
    const width = (ui.getContentRegionAvailPixels()[0] - gap * (n - 1)) / n;
    const height = ui.raw("ImGui_GetFrameHeight")() * 1.4;
    for (links, 0..) |link, i| {
        if (i > 0) ui.sameLine();
        ui.raw("ImGui_PushStyleColorImVec4")(c.ImGuiCol_Button, vec4(link.colour, 0.85));
        ui.raw("ImGui_PushStyleColorImVec4")(c.ImGuiCol_ButtonHovered, vec4(link.colour, 1));
        ui.raw("ImGui_PushStyleColorImVec4")(c.ImGuiCol_ButtonActive, vec4(lighter(link.colour), 1));
        ui.raw("ImGui_PushStyleColorImVec4")(c.ImGuiCol_Text, .{ .x = 1, .y = 1, .z = 1, .w = 1 });
        defer ui.raw("ImGui_PopStyleColorEx")(4);
        if (ui.buttonSized(link.label, .{ width, height })) open(link.url);
        ui.tooltip("{s}", .{link.url});
    }
}

/// "Made with <heart> by Asgard", in the middle.
fn drawCredit() void {
    const before = "Made with ";
    const after = " by Asgard";
    const width = ui.calcTextSize(before)[0] + ui.calcTextSize(icons.heart)[0] + ui.calcTextSize(after)[0];
    const free = ui.getContentRegionAvailPixels()[0] - width;
    if (free > 0) ui.raw("ImGui_SetCursorPosX")(ui.raw("ImGui_GetCursorPosX")() + free / 2);
    ui.textDisabled(before, .{});
    ui.sameLineWith(0, 0);
    ui.textColored(heart_colour, icons.heart, .{});
    ui.sameLineWith(0, 0);
    ui.textDisabled(after, .{});
}

/// In the browser. Off the render thread, since the shell can take a while.
fn openSlice(url: []const u8) void {
    open(url);
}

fn open(url: []const u8) void {
    const thread = std.Thread.spawn(.{}, openOnThread, .{url}) catch |err| {
        log.warn("Couldn't open {s}: {t}", .{ url, err });
        return;
    };
    thread.detach();
}

fn openOnThread(url: []const u8) void {
    wraith_platform.process.openUri(std.heap.page_allocator, url) catch |err| log.warn("Couldn't open {s}: {t}", .{ url, err });
}

fn rgb(r: u8, g: u8, b: u8) ui.Color {
    return .{ @as(f32, @floatFromInt(r)) / 255, @as(f32, @floatFromInt(g)) / 255, @as(f32, @floatFromInt(b)) / 255, 1 };
}

fn lighter(colour: ui.Color) ui.Color {
    return .{ @min(colour[0] * 1.2, 1), @min(colour[1] * 1.2, 1), @min(colour[2] * 1.2, 1), 1 };
}

fn vec4(colour: ui.Color, alpha: f32) c.ImVec4 {
    return .{ .x = colour[0], .y = colour[1], .z = colour[2], .w = alpha };
}
