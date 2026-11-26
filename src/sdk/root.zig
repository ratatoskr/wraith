//! The Zig SDK for plugins. Wraith's API is `wraith.sal`, called directly:
//!
//!     const w = sdk.wraith.root().?;
//!     _ = w.ui().toast(.{ .text = "Saved" });
//!     const fov = try w.settings().add(.{ .id = "fov", .kind = .number, .min = 60, .max = 120 }, null);
//!
//! The SDK adds what Zig plugins need on top: the DLL's entry and `Context`, tasks that wait for
//! frames, typed native hooks, logging and timing through Wraith, and image and file helpers.

const std = @import("std");

pub const api = @import("wraith_api");

const plugin = @import("plugin.zig");
pub const Config = @import("wraith_core").Config;
pub const arch = @import("wraith_core").arch;
pub const Context = plugin.Context;
pub const exportPlugin = plugin.exportPlugin;
pub const plugin_symbol = plugin.symbol;
pub const PluginEntry = plugin.Entry;

pub const Owner = @import("Owner.zig");

pub const wraith = @import("wraith.zig");
pub const salamander = @import("salamander.zig");

pub const hooks = @import("hooks.zig");
pub const overlay = @import("overlay.zig");
pub const threads = @import("threads.zig");
pub const display = @import("display.zig");
pub const tasks = @import("tasks.zig");
/// A lock that tasks wait for by parking. See `sync.Mutex`.
pub const sync = @import("sync.zig");
pub const keybinds = @import("keybinds.zig");
pub const tweaks = @import("tweaks.zig");
pub const timing = @import("timing.zig");
pub const ui = @import("wraith_ui");
pub const math = @import("tuft_math");
pub const platform = @import("wraith_platform");
pub const mem = @import("tuft_mem");
pub const memory = mem.With(hooks);
pub const Address = memory.Address;
pub const Module = memory.Module;
pub const CpuContext = hooks.CpuContext;
pub const dyn = @import("tuft_arch").dyn;
pub const atomic = @import("tuft_arch").atomic;
pub const log = @import("log.zig");
pub const logFn = log.logFn;
pub const panic = std.debug.FullPanic(log.onPanic);
pub const signatures = @import("signatures.zig");
pub const images = @import("images.zig");
pub const workbench = @import("workbench.zig");
pub const testing = @import("testing.zig");

test {
    std.testing.refAllDecls(@This());
    _ = log;
    _ = hooks;
    _ = overlay;
    _ = threads;
    _ = display;
    _ = tasks;
    _ = keybinds;
    _ = timing;
    _ = signatures;
    _ = salamander;
    _ = images;
    _ = workbench;
    _ = Owner;
}
