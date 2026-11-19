const std = @import("std");

pub fn winToUtf8(allocator: std.mem.Allocator, utf16_input: []const u16) ![]const u8 {
    return try std.unicode.utf16LeToUtf8Alloc(allocator, utf16_input);
}

pub fn utf8ToWin(allocator: std.mem.Allocator, utf8_input: []const u8) ![:0]const u16 {
    return try std.unicode.utf8ToUtf16LeAllocZ(allocator, utf8_input);
}

pub fn fileOrModuleCompare(allocator: std.mem.Allocator, candidate: []const u8, utf16Value: []const u16, comptime without_stem: bool) !bool {
    const value = try winToUtf8(allocator, std.mem.sliceTo(utf16Value, 0));
    defer allocator.free(value);

    if (std.mem.eql(u8, candidate, value)) return true;

    if (std.ascii.eqlIgnoreCase(candidate, value)) return true;

    if (without_stem) {
        const candidate_stem = std.fs.path.stem(candidate);
        const value_stem = std.fs.path.stem(value);

        // Same again without extensions
        if (std.mem.eql(u8, candidate_stem, value_stem)) return true;

        if (std.ascii.eqlIgnoreCase(candidate_stem, value_stem)) return true;
    }

    return false;
}

const tests = struct {
    test "round trip" {
        const allocator = std.testing.allocator;
        const text = "module-\xc3\xa9-\xf0\x9f\x98\x80.dll";
        const wide = try utf8ToWin(allocator, text);
        defer allocator.free(wide);
        try std.testing.expectEqual(0, wide[wide.len]);
        const utf8 = try winToUtf8(allocator, wide);
        defer allocator.free(utf8);
        try std.testing.expectEqualStrings(text, utf8);
    }

    fn testCompare(allocator: std.mem.Allocator) !void {
        const wide = [_]u16{ 'T', 'e', 's', 't', '.', 'd', 'l', 'l', 0, 'X' };
        try std.testing.expect(try fileOrModuleCompare(allocator, "Test.dll", &wide, false));
        try std.testing.expect(try fileOrModuleCompare(allocator, "test.DLL", &wide, false));
        try std.testing.expect(try fileOrModuleCompare(allocator, "test", &wide, true));
        try std.testing.expect(!try fileOrModuleCompare(allocator, "test", &wide, false));
        try std.testing.expect(!try fileOrModuleCompare(allocator, "other.dll", &wide, true));
    }

    test "comparison frees" {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, testCompare, .{});
    }

    test "invalid Unicode" {
        const invalid = [_]u16{0xd800};
        try std.testing.expectError(error.DanglingSurrogateHalf, winToUtf8(std.testing.allocator, &invalid));
        try std.testing.expectError(error.InvalidUtf8, utf8ToWin(std.testing.allocator, "\xff"));
    }
};
test {
    _ = tests;
}
