//! The system's fonts for scripts our own fonts don't have, like Japanese.

const std = @import("std");
const builtin = @import("builtin");

pub const native = switch (builtin.os.tag) {
    .windows => @import("win/fonts.zig"),
    else => @compileError("Unsupported operating system"),
};

/// Han characters look different in each, so which comes first matters.
pub const Script = enum { japanese, chinese_simplified, chinese_traditional, korean };

/// The display language's first, then the keyboards'. Each once.
pub const scriptsInUse = native.scriptsInUse;

/// File names in `dir` that could have `script`, best first.
pub const files = native.files;

/// Where the system keeps its fonts.
pub const dir = native.dir;

pub fn scriptOf(langid: u16) ?Script {
    return switch (langid & 0x3FF) {
        0x11 => .japanese,
        0x12 => .korean,
        // Chinese, by where. Taiwan, Hong Kong and Macau write it traditional
        0x04 => switch (langid) {
            0x0404, 0x0C04, 0x1404 => .chinese_traditional,
            else => .chinese_simplified,
        },
        else => null,
    };
}

test scriptOf {
    try std.testing.expectEqual(Script.japanese, scriptOf(0x0411).?);
    try std.testing.expectEqual(Script.chinese_simplified, scriptOf(0x0804).?);
    try std.testing.expectEqual(Script.chinese_traditional, scriptOf(0x0C04).?);
    try std.testing.expectEqual(Script.korean, scriptOf(0x0412).?);
    try std.testing.expectEqual(null, scriptOf(0x0409));
}

test dir {
    var buf: [512]u8 = undefined;
    try std.testing.expect(std.mem.endsWith(u8, dir(&buf).?, "\\Fonts"));
    for (std.enums.values(Script)) |s| try std.testing.expect(files(s).len > 0);
    var scripts: [4]Script = undefined;
    _ = scriptsInUse(&scripts);
}
