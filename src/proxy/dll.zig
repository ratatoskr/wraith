//! Proxy DLL that loads Wraith from a game folder and forwards to the real Windows DLL.

const std = @import("std");
const builtin = @import("builtin");

const proxy = @import("tuft_proxy");
const sys = @import("tuft_sys");
const win = sys.win;

const info = @import("wraith_proxy_info");
const options = @import("wraith_proxy_options");

export const wraith_proxy_marker: [info.marker.len:0]u8 = info.marker.*;
const init_export = "wraith_bootstrap_init";
const bootstrap_dll = switch (builtin.cpu.arch) {
    .x86 => "wraith_bootstrap_x86.dll",
    .x86_64 => "wraith_bootstrap_x64.dll",
    else => @compileError("x86 and x64 only"),
};

const dll = @field(proxy.Dll, options.dll);
const Windows = proxy.Forwarder(dll);

comptime {
    _ = Windows;
}

const DLL_PROCESS_ATTACH = 1;
const gate_timeout_ms = 15_000;

// Exported since with libc linked the C runtime startup calls it
pub export fn DllMain(_: *anyopaque, reason: u32, _: ?*anyopaque) callconv(.winapi) win.BOOL {
    if (reason != DLL_PROCESS_ATTACH) return .TRUE;
    var exe_buf: [win.MAX_PATH * 3]u8 = undefined;
    log(dll.fileName() ++ " loaded into {s} (pid {d})", .{ sys.module.pathOf(sys.module.mainBase(), &exe_buf) orelse "?", win.GetCurrentProcessId() });
    // The game can't use us without the real DLL behind us
    Windows.load() catch |err| {
        log("can't load Windows' " ++ dll.fileName() ++ ": {t}", .{err});
        return .FALSE;
    };
    proxy.EntryGate.hold(gate_timeout_ms) catch |err| log("can't hold the game until wraith is set up (it may miss what the game does first): {t}", .{err});
    proxy.startThread(loadWraith) catch |err| {
        log("can't start loading wraith: {t}", .{err});
        proxy.EntryGate.open();
    };
    return .TRUE;
}

/// Runs on its own thread once the loader lock is released.
fn loadWraith() void {
    // Let the game go no matter what
    defer proxy.EntryGate.open();
    run() catch |err| log("wraith not loaded: {t}", .{err});
}

fn log(comptime fmt: []const u8, args: anytype) void {
    var self_buf: [win.MAX_PATH * 3]u8 = undefined;
    const self_path = sys.module.pathOf(sys.module.selfBase(), &self_buf) orelse return;
    const dir = std.fs.path.dirname(self_path) orelse return;
    var path_buf: [win.MAX_PATH * 3]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}\\wraith_proxy.log", .{dir}) catch return;
    var wide: [win.MAX_PATH * 3:0]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, path) catch return;
    wide[n] = 0;
    const file = win.CreateFileW(&wide, win.FILE_APPEND_DATA, win.FILE_SHARE_READ, null, win.OPEN_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, null);
    if (file == win.INVALID_HANDLE_VALUE) return;
    defer win.CloseHandle(file);
    var line_buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "[pid {d}] " ++ fmt ++ "\r\n", .{win.GetCurrentProcessId()} ++ args) catch return;
    _ = win.WriteFile(file, line.ptr, @intCast(line.len), null, null);
}

fn run() !void {
    var self_buf: [win.MAX_PATH * 3]u8 = undefined;
    const self_path = sys.module.pathOf(sys.module.selfBase(), &self_buf) orelse return error.NoOwnPath;
    const self_dir = std.fs.path.dirname(self_path) orelse return error.NoOwnPath;

    var path_buf: [win.MAX_PATH * 3]u8 = undefined;
    const init_path = try std.fmt.bufPrint(&path_buf, "{s}\\{s}", .{ self_dir, info.init_file });
    var contents_buf: [16 << 10]u8 = undefined;
    // No heap yet
    var parse_buf: [64 << 10]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&parse_buf);
    const init = try readInit(fba.allocator(), init_path, &contents_buf);
    const install_dir = init.wraith_dir;

    // The launcher deletes old versions, so follow it to the current one if ours is gone
    var current_buf: [win.MAX_PATH * 3]u8 = undefined;
    const module = loadBootstrap(install_dir) orelse
        loadBootstrap(currentDir(install_dir, &current_buf) orelse return error.LoadFailed) orelse
        return error.LoadFailed;
    // On x86, stdcall exports get the argument byte count appended to the name
    const init_address = win.GetProcAddress(module, init_export) orelse
        win.GetProcAddress(module, init_export ++ "@4") orelse return error.NoInitExport;
    const bootstrap_init: *const fn (u32) callconv(.winapi) u32 = @ptrCast(init_address);
    // runtime_abi.BootstrapFlags. Wraith hooks device creation and holds the game until ready
    const started_with_game = 1;
    const wait_until_ready = 2;
    if (bootstrap_init(started_with_game | wait_until_ready) != 0) return error.BootstrapInitFailed;
    if (proxy.EntryGate.timedOut()) {
        log("wraith is set up, but the game didn't wait that long (it may have missed what the game did first)", .{});
    } else log("wraith is set up; letting the game start", .{});
}

fn loadBootstrap(dir: []const u8) ?win.HINSTANCE {
    var path_buf: [win.MAX_PATH * 3]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}\\{s}", .{ dir, bootstrap_dll }) catch return null;
    var wide: [win.MAX_PATH * 3:0]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, path) catch return null;
    wide[n] = 0;
    log("loading {s}", .{path});
    return win.LoadLibraryW(&wide) orelse {
        log("can't load {s}", .{path});
        return null;
    };
}

/// The launcher's current version beside `dir`, from its current.txt, like `...\framework\v0.2.0`.
fn currentDir(dir: []const u8, buf: []u8) ?[]const u8 {
    const root = std.fs.path.dirname(std.mem.trimEnd(u8, dir, "\\/")) orelse return null;
    var path_buf: [win.MAX_PATH * 3]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}\\current.txt", .{root}) catch return null;
    var text_buf: [64]u8 = undefined;
    const folder = std.mem.trim(u8, readSmallFile(path, &text_buf) catch return null, " \t\r\n");
    if (folder.len == 0 or std.mem.indexOfAny(u8, folder, "\\/:") != null or std.mem.startsWith(u8, folder, ".")) return null;
    return std.fmt.bufPrint(buf, "{s}\\{s}", .{ root, folder }) catch null;
}

fn readInit(allocator: std.mem.Allocator, path: []const u8, buf: []u8) !info.Init {
    const contents = try readSmallFile(path, buf[0 .. buf.len - 1]);
    buf[contents.len] = 0;
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(info.Init, .{
        .gpa = allocator,
        .arena = allocator,
        .source = buf[0..contents.len :0],
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch |err| {
        log("{s} isn't valid (run `wraith install` again): {t}", .{ path, err });
        return err;
    };
}

fn readSmallFile(path: []const u8, buf: []u8) ![]u8 {
    var wide: [win.MAX_PATH * 3:0]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, path) catch return error.BadPath;
    wide[n] = 0;
    const file = win.CreateFileW(&wide, win.GENERIC_READ, win.FILE_SHARE_READ, null, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, null);
    if (file == win.INVALID_HANDLE_VALUE) {
        log("can't open {s} (run `wraith install` again)", .{path});
        return error.NoPathFile;
    }
    defer win.CloseHandle(file);
    var read: u32 = 0;
    if (win.ReadFile(file, buf.ptr, @intCast(buf.len), &read, null) == .FALSE) return error.ReadFailed;
    return buf[0..read];
}
