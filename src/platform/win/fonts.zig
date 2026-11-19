const std = @import("std");

const api = @import("tuft_sys").win;
const fonts = @import("../fonts.zig");
const Script = fonts.Script;

pub fn scriptsInUse(out: *[4]Script) []Script {
    var len: usize = 0;
    add(out, &len, api.GetUserDefaultUILanguage());
    var layouts: [32]?*anyopaque = undefined;
    const count = api.GetKeyboardLayoutList(layouts.len, &layouts);
    for (layouts[0..@intCast(@max(count, 0))]) |hkl| add(out, &len, @truncate(@intFromPtr(hkl)));
    return out[0..len];
}

fn add(out: *[4]Script, len: *usize, langid: u16) void {
    const script = fonts.scriptOf(langid) orelse return;
    if (std.mem.indexOfScalar(Script, out[0..len.*], script) != null) return;
    out[len.*] = script;
    len.* += 1;
}

/// Newest first, since older Windows only has the later ones.
pub fn files(script: Script) []const []const u8 {
    return switch (script) {
        .japanese => &.{ "YuGothM.ttc", "meiryo.ttc", "msgothic.ttc" },
        .chinese_simplified => &.{ "msyh.ttc", "simsun.ttc" },
        .chinese_traditional => &.{ "msjh.ttc", "mingliu.ttc" },
        .korean => &.{ "malgun.ttf", "gulim.ttc" },
    };
}

pub fn dir(buf: []u8) ?[]const u8 {
    var wide: [260]u16 = undefined;
    const len = api.GetWindowsDirectoryW(&wide, wide.len);
    if (len == 0 or len >= wide.len) return null;
    var windows: [780]u8 = undefined;
    const n = std.unicode.utf16LeToUtf8(&windows, wide[0..len]) catch return null;
    return std.fmt.bufPrint(buf, "{s}\\Fonts", .{windows[0..n]}) catch null;
}
