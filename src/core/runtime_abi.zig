//! Bootstrap/runtime contract. Keep it C-compatible and only append fields to `RuntimeInfo`.

/// Runtime export: `fn (info: *const RuntimeInfo) callconv(.c) u32`, returns 0 on success.
pub const init_symbol = "wraith_runtime_init";
/// Runtime export: `fn () callconv(.c) void`.
pub const shutdown_symbol = "wraith_runtime_shutdown";

pub const InitFn = fn (info: *const RuntimeInfo) callconv(.c) u32;

pub const BootstrapFlags = struct {
    pub const started_with_game: u32 = 1;
    /// Don't return until the runtime has loaded or failed.
    pub const wait_until_ready: u32 = 2;
    /// Open the console at startup, rather than only on request or load failure.
    pub const console: u32 = 4;
};
pub const ShutdownFn = fn () callconv(.c) void;

pub const Path = extern struct {
    ptr: [*]const u8,
    len: usize,

    pub fn from(s: []const u8) Path {
        return .{ .ptr = s.ptr, .len = s.len };
    }

    pub fn slice(self: Path) []const u8 {
        return self.ptr[0..self.len];
    }
};

/// Passed across reloads so the next runtime doesn't probe devices, which overlays like Special K misread.
pub const GraphicsHandover = extern struct {
    api: u32 = 0,
    /// Holds a reference, whoever takes it releases it.
    object: ?*anyopaque = null,
};

/// Only valid during `init`.
pub const RuntimeInfo = extern struct {
    size: u32 = @sizeOf(RuntimeInfo),
    wraith_dir: Path,
    temp_dir: Path,
    /// Use `flagsOf` since older bootstraps don't have it.
    flags: u32 = 0,
    /// Outlives every load. Use `handoverOf`.
    handover: ?*GraphicsHandover = null,

    /// Game hasn't started rendering, so graphics can hook device creation instead of probing.
    pub const flag_before_rendering: u32 = 1;

    /// Size of an older bootstrap's info.
    pub const min_size = @offsetOf(RuntimeInfo, "flags");

    pub fn flagsOf(self: *const RuntimeInfo) u32 {
        return if (self.size >= @offsetOf(RuntimeInfo, "flags") + @sizeOf(u32)) self.flags else 0;
    }

    pub fn handoverOf(self: *const RuntimeInfo) ?*GraphicsHandover {
        return if (self.size >= @offsetOf(RuntimeInfo, "handover") + @sizeOf(?*GraphicsHandover)) self.handover else null;
    }
};
