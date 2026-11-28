//! A command's arguments, taken in order, and saying what's wrong with them.

const std = @import("std");

const core = @import("wraith_core");

const log = core.log.scoped(.wraith_cli);

pub const Args = struct {
    items: []const []const u8,
    at: usize = 0,

    pub fn next(self: *Args) ?[]const u8 {
        if (self.at >= self.items.len) return null;
        defer self.at += 1;
        return self.items[self.at];
    }

    /// What's left, taken.
    pub fn rest(self: *Args) []const []const u8 {
        defer self.at = self.items.len;
        return self.items[self.at..];
    }

    /// The value after a flag like `--out`, or null after saying it's missing.
    pub fn value(self: *Args, flag: []const u8) ?[]const u8 {
        return self.next() orelse {
            log.err("{s} needs a value", .{flag});
            return null;
        };
    }
};

pub fn isFlag(arg: []const u8) bool {
    return arg.len > 1 and arg[0] == '-';
}

pub fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

/// 1, after showing how it's used.
pub fn usageError(usage: []const u8) u8 {
    log.err("Usage:\n{s}", .{usage});
    return 1;
}

/// 1, after saying `arg` isn't one it takes and how it's used.
pub fn unexpected(arg: []const u8, usage: []const u8) u8 {
    if (isFlag(arg)) log.err("There's no {s} option here", .{arg}) else log.err("Didn't expect {s}", .{arg});
    return usageError(usage);
}

test "takes them in order, and the rest at once" {
    var args: Args = .{ .items = &.{ "a", "--out", "b", "c" } };
    try std.testing.expectEqualStrings("a", args.next().?);
    try std.testing.expectEqualStrings("--out", args.next().?);
    try std.testing.expectEqualStrings("b", args.value("--out").?);
    try std.testing.expectEqual(1, args.rest().len);
    try std.testing.expectEqual(null, args.next());
    try std.testing.expect(isFlag("--x") and !isFlag("-") and !isFlag("x"));
}
