//! Wraith's API from `src/api/schemas`, the same areas scripts get, with real methods:
//!
//!     const w = sdk.wraith.root() orelse return;
//!     const stats = w.frame().stats();
//!     const fov = try w.settings().add(.{ .id = .init("fov"), .kind = .number, .min = 60, .max = 120 }, null);
//!
//! Once the plugin's unloading its calls do nothing and give zero or `error.Gone`. Kept objects,
//! like a setting, go once they're released or the plugin unloads.

const api = @import("wraith_api");
const Owner = @import("Owner.zig");

/// Every type in `wraith.sal`, like `types.SettingValue` or `types.Clipboard`.
pub const types = api.wraith;

pub const Wraith = types.Wraith;

/// This plugin's root. Null outside a plugin.
pub fn root() ?Wraith {
    const o = Owner.current() orelse return null;
    if (o.root.table == null) return null;
    return o.root;
}
