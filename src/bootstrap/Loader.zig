const Loader = @This();

const std = @import("std");

const core = @import("wraith_core");
const platform = @import("wraith_platform");
const sys = @import("tuft_sys");
const temp = @import("temp.zig");

const log = core.log.scoped(.wraith_bootstrap);

/// Where an unloading runtime leaves the game's graphics for the next one.
var graphics_handover: core.runtime_abi.GraphicsHandover = .{};

allocator: std.mem.Allocator,
io: std.Io,
is_loaded: bool = false,
wraith_dir_path: []const u8,
session: temp.Session,
runtime_lib_dir_path: []const u8,
runtime_lib_file: []const u8,
runtime_temp_base_path: []const u8,
runtime_temp_dir_path: ?[]const u8,
runtime_temp_lib_path: ?[]const u8,
library_address: ?usize,
start_proc_address: ?usize,
stop_proc_address: ?usize,
before_rendering: bool = false,

pub fn init(allocator: std.mem.Allocator, io: std.Io) !*Loader {
    var session = try temp.Session.start(allocator, io);
    errdefer session.end(allocator, io);

    const loader = try allocator.create(Loader);
    errdefer allocator.destroy(loader);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const bootstrap_lib_path = sys.module.pathOf(sys.module.selfBase(), &path_buf) orelse return error.PathResolutionFailed;

    const wraith_dir_slice = std.fs.path.dirname(bootstrap_lib_path) orelse return error.PathResolutionFailed;
    const wraith_dir_path = try allocator.dupe(u8, wraith_dir_slice);
    errdefer allocator.free(wraith_dir_path);

    const runtime_dir_path = try allocator.dupe(u8, wraith_dir_path);
    errdefer allocator.free(runtime_dir_path);

    // `wraith_runtime_<arch>.dll` next to the bootstrap
    const runtime_lib_file = try core.arch.native.dllNameAlloc(allocator, "runtime");
    errdefer allocator.free(runtime_lib_file);

    const runtime_temp_base_path = try session.subdirAlloc(allocator, io, "runtime");
    errdefer allocator.free(runtime_temp_base_path);

    loader.* = .{
        .allocator = allocator,
        .io = io,
        .wraith_dir_path = wraith_dir_path,
        .session = session,
        .runtime_lib_dir_path = runtime_dir_path,
        .runtime_lib_file = runtime_lib_file,
        .runtime_temp_base_path = runtime_temp_base_path,
        .runtime_temp_dir_path = null,
        .runtime_temp_lib_path = null,
        .library_address = null,
        .start_proc_address = null,
        .stop_proc_address = null,
    };

    return loader;
}

pub fn load(self: *Loader) !void {
    var rand_bytes: [8]u8 = undefined;
    self.io.random(&rand_bytes);

    const random_hex = std.fmt.bytesToHex(rand_bytes, .lower);

    const name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ "r_", &random_hex });
    defer self.allocator.free(name);

    const runtime_temp_dir_path = try std.fs.path.join(self.allocator, &.{ self.runtime_temp_base_path, name });
    errdefer self.allocator.free(runtime_temp_dir_path);

    const runtime_temp_lib_path = try std.fs.path.join(self.allocator, &.{ runtime_temp_dir_path, self.runtime_lib_file });
    errdefer self.allocator.free(runtime_temp_lib_path);

    try self.copyRuntime(runtime_temp_dir_path);

    log.info("Loading runtime {s}...", .{self.runtime_lib_file});
    const library_address = try sys.module.load(self.allocator, runtime_temp_lib_path);
    errdefer _ = sys.module.unload(library_address);

    const start_proc_addr = sys.module.findExport(library_address, core.runtime_abi.init_symbol) orelse return error.ExportNotFound;
    const stop_proc_addr = sys.module.findExport(library_address, core.runtime_abi.shutdown_symbol) orelse return error.ExportNotFound;

    log.info("Starting Wraith runtime...", .{});
    const info: core.runtime_abi.RuntimeInfo = .{
        .wraith_dir = .from(self.wraith_dir_path),
        .temp_dir = .from(self.session.path),
        .flags = if (self.before_rendering) core.runtime_abi.RuntimeInfo.flag_before_rendering else 0,
        .handover = &graphics_handover,
    };
    // By reload time the game is already rendering
    self.before_rendering = false;
    const start_proc: *const core.runtime_abi.InitFn = @ptrFromInt(start_proc_addr);
    if (start_proc(&info) != 0)
        return error.StartProcFailed;

    self.runtime_temp_dir_path = runtime_temp_dir_path;
    self.runtime_temp_lib_path = runtime_temp_lib_path;
    self.library_address = library_address;
    self.start_proc_address = start_proc_addr;
    self.stop_proc_address = stop_proc_addr;

    self.is_loaded = true;
}

/// We load a copy so the original can be rebuilt and loaded again.
fn copyRuntime(self: *Loader, dir: []const u8) !void {
    try platform.fs.ensureDirectory(self.io, dir);
    const stem = self.runtime_lib_file[0 .. self.runtime_lib_file.len - ".dll".len];
    for ([_][]const u8{ ".dll", ".pdb" }) |ext| {
        const file = try std.mem.concat(self.allocator, u8, &.{ stem, ext });
        defer self.allocator.free(file);
        const from = try std.fs.path.join(self.allocator, &.{ self.runtime_lib_dir_path, file });
        defer self.allocator.free(from);
        const to = try std.fs.path.join(self.allocator, &.{ dir, file });
        defer self.allocator.free(to);
        const cwd = std.Io.Dir.cwd();
        cwd.copyFile(from, cwd, to, self.io, .{}) catch |err| switch (err) {
            error.FileNotFound => if (std.mem.eql(u8, ext, ".dll")) return err,
            else => return err,
        };
    }
}

pub fn reload(self: *Loader) !void {
    if (!self.is_loaded)
        return self.load();

    try self.unload();

    return self.load();
}

pub fn unload(self: *Loader) !void {
    if (!self.is_loaded) return error.NotLoaded;

    defer {
        if (self.runtime_temp_lib_path) |runtime_temp_lib_path| self.allocator.free(runtime_temp_lib_path);
        if (self.runtime_temp_dir_path) |runtime_temp_dir_path| self.allocator.free(runtime_temp_dir_path);
        self.runtime_temp_lib_path = null;
        self.runtime_temp_dir_path = null;
        self.library_address = null;
        self.start_proc_address = null;
        self.stop_proc_address = null;
        self.is_loaded = false;
    }

    log.info("Stopping Wraith runtime...", .{});
    if (self.stop_proc_address) |addr| {
        const stop_proc: *const core.runtime_abi.ShutdownFn = @ptrFromInt(addr);
        stop_proc();
    }
    log.info("Wraith runtime stopped.", .{});

    if (self.library_address) |library_address| {
        self.library_address = null;
        if (!sys.module.unload(library_address)) {
            // Still mapped, so its temp copy can't be deleted either
            log.warn("A thread was still running in the Wraith runtime, so it's left loaded", .{});
            return;
        }
    }

    if (self.runtime_temp_dir_path) |runtime_temp_dir_path|
        try platform.fs.deleteDirectory(self.io, runtime_temp_dir_path);
}

pub fn deinit(self: *Loader) void {
    self.allocator.free(self.wraith_dir_path);
    self.session.end(self.allocator, self.io);
    self.allocator.free(self.runtime_lib_dir_path);
    self.allocator.free(self.runtime_lib_file);
    self.allocator.free(self.runtime_temp_base_path);

    if (self.runtime_temp_lib_path) |runtime_temp_lib_path| self.allocator.free(runtime_temp_lib_path);
    if (self.runtime_temp_dir_path) |runtime_temp_dir_path| self.allocator.free(runtime_temp_dir_path);

    self.allocator.destroy(self);
}
