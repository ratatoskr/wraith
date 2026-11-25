//! Wraith's API from `src/api/schemas`, the same areas scripts get, with real methods. A plugin has
//! it as `ctx.wraith`:
//!
//!     const stats = ctx.wraith.frame().stats();
//!     const fov = try ctx.wraith.settings().add(.{ .id = .init("fov"), .kind = .number, .min = 60, .max = 120 }, null);
//!
//! `root()` gives the same where there's no `ctx` to hand.
//!
//! Once the plugin's unloading its calls do nothing and give zero or `error.Gone`. Kept objects,
//! like a setting, go once they're released or the plugin unloads.

const api = @import("wraith_api");
const Owner = @import("Owner.zig");

/// Every type in `wraith.sal`, like `types.Setting.Value` or `types.Clipboard`.
pub const types = api.wraith;

pub const Wraith = types.Api;

/// This plugin's root. Null outside a plugin.
pub fn root() ?Wraith {
    const o = Owner.current() orelse return null;
    if (o.root.table == null) return null;
    return o.root;
}
