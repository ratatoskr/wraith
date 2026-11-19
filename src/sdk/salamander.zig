//! Salamander, for traits shared with other plugins in any language. The runtime is the host: the plugin
//! gets it when it attaches, and objects it provides are owned by the plugin, so they stop being called
//! once it unloads. Traits come from the plugin's `schemas/` folder, as its `schema` import.
//!
//! A [Service] trait in its schemas is offered to plugins that depend on it. The plugin struct lists a
//! function for each, giving the object. The function's return type says which trait it's for:
//!
//!     pub const services = .{freecam};
//!     pub fn freecam(self: *Plugin) schema.Freecam {
//!         return .init(&self.cam, rt.implement(schema.Freecam, Cam));
//!     }
//!
//! A plugin that depends on it gets it with `sdk.salamander.service(schema.Freecam, "freecam")`.
//!
//! Everything else is Salamander's own, through `rt`, like `rt.host().provide` and `rt.host().get`.

const std = @import("std");

const api = @import("wraith_api");
pub const rt = @import("salamander_runtime");

pub const Error = error{SalamanderUnavailable};

var own_owner: ?*rt.Owner = null;
var render_queue: ?rt.Queue = null;
var services: []api.wraith.raw.Service = &.{};

/// The runtime's host from now on, for every Salamander call this plugin makes. Code its schemas
/// declare, like `Player.heal` in generated Zig, is found through its `Schema` area.
pub fn attach(h: rt.Host, o: ?*rt.Owner, queue: rt.Queue, offered: []const api.wraith.raw.Service) void {
    rt.setHost(h);
    own_owner = o;
    render_queue = if (queue.table != null) queue else null;
    rt.declared.setLocator(.{ .address = locate });
    // Only good during start, so it's copied. What it points at lives as long as those plugins
    services = std.heap.page_allocator.dupe(api.wraith.raw.Service, offered) catch &.{};
}

pub fn detach() void {
    own_owner = null;
    render_queue = null;
    std.heap.page_allocator.free(services);
    services = &.{};
}

/// What `plugin`, one this plugin depends on, offers as `T`, a [Service] trait in its schemas, like
/// `sdk.salamander.service(schema.Freecam, "freecam")`.
pub fn service(comptime T: type, plugin: []const u8) ?T {
    const name = T.salamander.name;
    for (services) |s| {
        if (std.mem.eql(u8, s.plugin.get(), plugin) and std.mem.eql(u8, s.trait.get(), name)) return rt.host().adapt(T, s.obj);
    }
    return null;
}

fn locate(_: ?*anyopaque, name: []const u8) anyerror!usize {
    const w = @import("wraith.zig").root() orelse return error.Unavailable;
    return w.schema().address(name);
}

/// This plugin's owner. What it guards stops being called once the plugin's unloading.
pub fn owner() ?*rt.Owner {
    return own_owner;
}

/// `obj` with the host's copy of its table, owned by this plugin.
pub fn own(obj: anytype) (Error || error{OutOfMemory})!@TypeOf(obj) {
    return rt.host().own(obj, owner() orelse return error.SalamanderUnavailable);
}

/// Owns `obj` and makes it findable as `name` at `major`, until the plugin goes or it's withdrawn.
pub fn provide(name: []const u8, major: u32, obj: anytype) (Error || rt.ProvideError)!void {
    try rt.host().provide(name, major, try own(obj));
}

/// A queue the render thread polls each frame.
pub fn renderQueue() Error!rt.Queue {
    return render_queue orelse error.SalamanderUnavailable;
}
