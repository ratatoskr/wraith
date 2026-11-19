const std = @import("std");

const win = @import("tuft_sys").win;
const string = @import("string.zig");

pub const MemoryInfo = struct {
    working_set: usize,
    peak_working_set: usize,
    private_bytes: usize,
};

pub fn memoryInfo() ?MemoryInfo {
    var counters: win.PROCESS_MEMORY_COUNTERS_EX = .{};
    if (!win.K32GetProcessMemoryInfo(std.os.windows.GetCurrentProcess(), &counters, counters.cb).toBool()) return null;
    return .{
        .working_set = counters.WorkingSetSize,
        .peak_working_set = counters.PeakWorkingSetSize,
        .private_bytes = counters.PrivateUsage,
    };
}

pub fn currentId() u32 {
    return win.GetCurrentProcessId();
}

/// `std.process` only gives the environment to executables, not DLLs.
pub fn envAlloc(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    const name_w = try string.utf8ToWin(allocator, name);
    defer allocator.free(name_w);
    const len = win.GetEnvironmentVariableW(name_w.ptr, null, 0);
    if (len == 0) return null;
    const buffer = try allocator.alloc(u16, len);
    defer allocator.free(buffer);
    const written = win.GetEnvironmentVariableW(name_w.ptr, buffer.ptr, len);
    if (written == 0 or written >= len) return null;
    return try std.unicode.utf16LeToUtf8Alloc(allocator, buffer[0..written]);
}

pub fn setEnv(allocator: std.mem.Allocator, name: []const u8, value: ?[]const u8) !void {
    const name_w = try string.utf8ToWin(allocator, name);
    defer allocator.free(name_w);
    const value_w = if (value) |v| try string.utf8ToWin(allocator, v) else null;
    defer if (value_w) |v| allocator.free(v);
    if (!win.SetEnvironmentVariableW(name_w.ptr, if (value_w) |v| v.ptr else null).toBool()) return error.SetEnvironmentFailed;
}

pub fn openUri(allocator: std.mem.Allocator, uri: []const u8) !void {
    const uri_w = try string.utf8ToWin(allocator, uri);
    defer allocator.free(uri_w);
    // Anything 32 or below is an error code
    if (win.ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("open"), uri_w.ptr, null, null, win.SW_SHOW) <= 32) return error.CantOpen;
}
