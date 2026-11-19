const std = @import("std");

const api = @import("tuft_sys").win;
const string = @import("string.zig");
const process = @import("process.zig");

pub fn picturesDirAlloc(allocator: std.mem.Allocator) ![]u8 {
    const pictures = std.os.windows.GUID.parse("{33E28130-4E1E-4676-835A-98395C3BC3BB}");
    var path: ?[*:0]u16 = null;
    if (api.SHGetKnownFolderPath(&pictures, 0, null, &path) < 0) return error.NoPicturesDirectory;
    const wide = path orelse return error.NoPicturesDirectory;
    defer api.CoTaskMemFree(wide);
    return std.unicode.wtf16LeToWtf8Alloc(allocator, std.mem.span(wide));
}

pub fn appDataDirAlloc(allocator: std.mem.Allocator) ![]u8 {
    return (try process.envAlloc(allocator, "APPDATA")) orelse error.NoAppData;
}

pub fn localAppDataDirAlloc(allocator: std.mem.Allocator) ![]u8 {
    return (try process.envAlloc(allocator, "LOCALAPPDATA")) orelse error.NoLocalAppData;
}

pub fn tempDirAlloc(allocator: std.mem.Allocator) ![]const u8 {
    var buffer: [1024]u16 = undefined;

    const path_length = api.GetTempPathW(buffer.len, @ptrCast(&buffer));
    if (path_length == 0) return error.FailedToGetTempPathOs;
    if (path_length >= buffer.len) return error.PathBufferTooSmall;

    // GetTempPathW adds a trailing backslash
    var end = path_length;
    while (end > 0 and (buffer[end - 1] == '\\' or buffer[end - 1] == '/')) end -= 1;

    return string.winToUtf8(allocator, buffer[0..end]);
}

pub fn fixedDriveRoots(buf: *[26][3]u8) []const [3]u8 {
    const mask = api.GetLogicalDrives();
    var n: usize = 0;
    for (0..26) |i| {
        if (mask & (@as(u32, 1) << @intCast(i)) == 0) continue;
        const letter: u8 = 'A' + @as(u8, @intCast(i));
        const root_w = [_:0]u16{ letter, ':', '\\' };
        // One with no media could make us wait
        if (api.GetDriveTypeW(&root_w) != api.DRIVE_FIXED) continue;
        buf[n] = .{ letter, ':', '\\' };
        n += 1;
    }
    return buf[0..n];
}

pub const AppendFile = struct {
    handle: api.HANDLE,

    pub fn open(path: []const u8) !AppendFile {
        var wide: [1024:0]u16 = undefined;
        const n = std.unicode.wtf8ToWtf16Le(&wide, path) catch return error.BadPath;
        wide[n] = 0;
        const handle = api.CreateFileW(&wide, api.FILE_APPEND_DATA, api.FILE_SHARE_READ, null, api.OPEN_ALWAYS, api.FILE_ATTRIBUTE_NORMAL, null);
        if (handle == api.INVALID_HANDLE_VALUE) return error.CantOpenFile;
        return .{ .handle = handle };
    }

    /// Best effort. Failed writes are dropped.
    pub fn write(self: AppendFile, bytes: []const u8) void {
        _ = api.WriteFile(self.handle, bytes.ptr, @intCast(bytes.len), null, null);
    }

    pub fn close(self: AppendFile) void {
        api.CloseHandle(self.handle);
    }
};

const tests = struct {
    test "APPDATA" {
        const a = std.testing.allocator;
        const saved = try process.envAlloc(a, "APPDATA");
        defer if (saved) |s| a.free(s);
        defer process.setEnv(a, "APPDATA", saved) catch {};

        try process.setEnv(a, "APPDATA", "C:\\appdata_test");
        const dir = try appDataDirAlloc(a);
        defer a.free(dir);
        try std.testing.expectEqualStrings("C:\\appdata_test", dir);

        try process.setEnv(a, "APPDATA", null);
        try std.testing.expectError(error.NoAppData, appDataDirAlloc(a));
    }

    test "env round trip" {
        const a = std.testing.allocator;
        try process.setEnv(a, "WRAITH_OS_ENV_TEST", "value");
        const value = (try process.envAlloc(a, "WRAITH_OS_ENV_TEST")).?;
        defer a.free(value);
        try std.testing.expectEqualStrings("value", value);
        try process.setEnv(a, "WRAITH_OS_ENV_TEST", null);
        try std.testing.expectEqual(null, try process.envAlloc(a, "WRAITH_OS_ENV_TEST"));
    }

    test "system drive is fixed" {
        const a = std.testing.allocator;
        const system = (try process.envAlloc(a, "SystemDrive")).?;
        defer a.free(system);
        var buf: [26][3]u8 = undefined;
        for (fixedDriveRoots(&buf)) |root| {
            if (std.ascii.eqlIgnoreCase(root[0..2], system)) return;
        }
        return error.TestUnexpectedResult;
    }

    test "temp dir path" {
        const a = std.testing.allocator;
        const path = try tempDirAlloc(a);
        defer a.free(path);

        try std.testing.expect(path.len != 0);
        try std.testing.expect(std.fs.path.isAbsolute(path));
        const last = path[path.len - 1];
        try std.testing.expect(last != '\\' and last != '/');
    }

    test "Pictures known folder" {
        const path = try picturesDirAlloc(std.testing.allocator);
        defer std.testing.allocator.free(path);
        try std.testing.expect(path.len > 0 and std.fs.path.isAbsolute(path));
    }
};

test {
    _ = tests;
}
