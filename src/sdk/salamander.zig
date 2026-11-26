//! Salamander traits shared with plugins in any language, from `schemas/` as the `schema` import.
//! Provided objects stop being called once the plugin unloads.
//!
//! Offer a [Service] trait with a function per service; its return type picks the trait:
//!
//!     pub const services = .{freecam};
//!     pub fn freecam(self: *Plugin) schema.Freecam {
//!         return .init(&self.cam, rt.implement(schema.Freecam, Cam));
//!     }
//!
//! Dependents get it with `sdk.salamander.service(schema.Freecam, "freecam")`.

const std = @import("std");

const api = @import("wraith_api");
pub const rt = @import("salamander_runtime");
/// Follows generated structs' pointers, like `follow(manager, "items.table.data")`. Null if unreadable.
pub const follow = rt.follow;
const Memory = @import("tuft_mem").Memory;

pub const Error = error{SalamanderUnavailable};

var own_owner: ?*rt.Owner = null;
var render_queue: ?rt.Queue = null;
var services: []api.wraith_raw.Wraith_Plugin_Service = &.{};

/// Makes the runtime the host for this plugin's Salamander calls.
pub fn attach(h: rt.Host, o: ?*rt.Owner, queue: rt.Queue, offered: []const api.wraith_raw.Wraith_Plugin_Service) void {
    rt.setHost(h);
    own_owner = o;
    render_queue = if (queue.table != null) queue else null;
    rt.declared.setLocator(locator(null, locate));
    // Only good during start, so it's copied. What it points at lives as long as those plugins
    services = std.heap.page_allocator.dupe(api.wraith_raw.Wraith_Plugin_Service, offered) catch &.{};
}

pub fn detach() void {
    own_owner = null;
    render_queue = null;
    std.heap.page_allocator.free(services);
    services = &.{};
}

/// What dependency `plugin` offers as [Service] trait `T`, like `service(schema.Freecam, "freecam")`.
pub fn service(comptime T: type, plugin: []const u8) ?T {
    const name = T.salamander.name;
    for (services) |s| {
        if (std.mem.eql(u8, s.plugin.get(), plugin) and std.mem.eql(u8, s.trait.get(), name)) return rt.host().adapt(T, s.obj);
    }
    return null;
}

/// Resolves names with `address` and reads this process's memory without faulting.
pub fn locator(ctx: ?*anyopaque, address: *const fn (ctx: ?*anyopaque, name: []const u8) anyerror!usize) rt.declared.Locator {
    return .{ .ctx = ctx, .address = address, .read = readMemory, .write = writeMemory };
}

fn readMemory(_: ?*anyopaque, at: usize, out: []u8) bool {
    Memory.local.read(at, out) catch return false;
    return true;
}

fn writeMemory(_: ?*anyopaque, at: usize, bytes: []const u8) bool {
    Memory.local.write(at, bytes) catch return false;
    return true;
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
