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

/// Wraith's API, the same areas scripts get, like `sdk.wraith.root().?.frame().stats()`.
pub const wraith = @import("wraith.zig");
/// Traits shared with plugins in any language, through Salamander.
pub const salamander = @import("salamander.zig");

/// Typed native detours and mid hooks.
pub const hooks = @import("hooks.zig");
/// Dear ImGui, bound to the runtime's.
pub const overlay = @import("overlay.zig");
pub const frame = @import("frame.zig");
/// Plugin tasks as fibers. Spawn them with `ctx.spawn`, and wait for any `async` call with `tasks.wait`.
pub const tasks = @import("tasks.zig");
/// Keys tasks can wait on.
pub const keybinds = @import("keybinds.zig");
pub const timing = @import("timing.zig");
pub const ui = @import("wraith_ui");
/// Wraith's platform code, like `platform.fs` and `platform.clipboard`, to use as it is.
pub const platform = @import("wraith_platform");

/// Memory tools. See `memory` for addresses that hook themselves.
pub const mem = @import("tuft_mem");
/// `mem`'s `Address`, `Module` and `Range`, but they hook themselves.
pub const memory = mem.With(hooks);
pub const Address = memory.Address;
pub const Module = memory.Module;
pub const CpuContext = hooks.CpuContext;
pub const dyn = @import("tuft_arch").dyn;
/// Use `atomic.Value` for atomics, it stays lock-free for 64-bit values in 32-bit games.
pub const atomic = @import("tuft_arch").atomic;

pub const log = @import("log.zig");
pub const logFn = log.logFn;
/// For a plugin's root: `pub const panic = sdk.panic;`
pub const panic = std.debug.FullPanic(log.onPanic);

pub const signatures = @import("signatures.zig");
/// Images to draw, and decoding, PNG and frame captures on the CPU.
pub const images = @import("images.zig");

pub const testing = @import("testing.zig");

test {
    std.testing.refAllDecls(@This());
    _ = log;
    _ = hooks;
    _ = overlay;
    _ = frame;
    _ = tasks;
    _ = keybinds;
    _ = timing;
    _ = signatures;
    _ = salamander;
    _ = images;
    _ = Owner;
}
