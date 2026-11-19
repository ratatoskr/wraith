//! The built-in `native` kind, for native plugins: a DLL that exports `wraith_plugin`. It's provided in
//! Salamander's registry like any plugin's kind, so the loader finds every kind the same way.

const std = @import("std");

const core = @import("wraith_core");
const api = @import("wraith_api");
const sdk = @import("wraith_sdk");
const tuft_sys = @import("tuft_sys");

const host = @import("../host/root.zig");
const Loaded = @import("Loaded.zig");

const sal = api.salamander;
const log = core.log.scoped(.wraith_runtime);
const allocator = std.heap.page_allocator;

pub const name = "native";

/// One loaded native plugin.
const Instance = struct {
    library: usize,
    entry: ?*const api.NativeEntry = null,
};

const Kind = struct {
    pub fn start(_: *Kind, guest: host.wraith.Guest) sal.Plain(host.wraith.PluginKind, "start") {
        const loaded = loadedOf(guest) orelse return error.Failed;
        const instance = load(loaded) catch return error.Failed;
        errdefer free(instance);
        // It calls back through its own root, guarded by its own owner
        const entry = instance.entry.?;
        const services = allocator.alloc(api.wraith.raw.Service, guest.services.len) catch return error.Failed;
        defer allocator.free(services);
        for (guest.services, services) |s, *out| out.* = .{ .plugin = .init(s.plugin), .trait = .init(s.trait), .obj = s.obj };
        if (!entry.start(sal.host(), .{
            .wraith = host.wraith.root(loaded),
            .owner = host.salamander.owner(loaded),
            .render_queue = host.salamander.renderQueueOf(),
            .services = .init(services),
        })) {
            entry.stop();
            return error.Failed;
        }
        return sal.Object(host.wraith.Plugin).init(instance, running_table);
    }
};

/// Built-in kinds can trust the guest's root to be the runtime's, made for its loaded record.
fn loadedOf(guest: host.wraith.Guest) ?*Loaded {
    if (guest.wraith.table == null) return null;
    const loaded: *Loaded = @ptrFromInt(guest.wraith.data);
    const t = loaded.wraith orelse return null;
    return if (@intFromPtr(t.root) == @intFromPtr(guest.wraith.table)) loaded else null;
}

fn load(loaded: *Loaded) !*Instance {
    const file = try core.arch.native.dllNameAlloc(allocator, loaded.name);
    defer allocator.free(file);
    const path = try std.fs.path.join(allocator, &.{ loaded.copy_dir, file });
    defer allocator.free(path);

    const library = tuft_sys.module.load(allocator, path) catch |err| {
        log.err("Couldn't load {s}: {t}", .{ file, err });
        return err;
    };
    const instance = allocator.create(Instance) catch |err| {
        _ = tuft_sys.module.unload(library);
        return err;
    };
    instance.* = .{ .library = library };
    errdefer free(instance);

    const addr = tuft_sys.module.findExport(library, sdk.plugin_symbol) orelse {
        log.err("{s} isn't a Wraith plugin (it doesn't export {s})", .{ file, sdk.plugin_symbol });
        return error.NotAPlugin;
    };
    const get: *const sdk.PluginEntry = @ptrFromInt(addr);
    const entry = get();
    if (entry.version != api.native_version) {
        log.err("{s} was built for another Wraith (native version {d}, this is {d}): rebuild it", .{ file, entry.version, api.native_version });
        return error.IncompatiblePlugin;
    }
    instance.entry = entry;
    return instance;
}

fn free(instance: *Instance) void {
    if (!tuft_sys.module.unload(instance.library)) log.warn("A thread was still running in a plugin's code, so it's left loaded", .{});
    allocator.destroy(instance);
}

const Running = struct {
    pub fn stop(instance: *Instance) void {
        if (instance.entry) |entry| entry.stop();
    }

    pub fn unload(instance: *Instance) void {
        free(instance);
    }

    pub fn module(instance: *Instance) usize {
        return instance.library;
    }

    pub fn service(instance: *Instance, trait: []const u8) sal.AnyObject {
        const entry = instance.entry orelse return .{};
        return entry.service(.init(trait));
    }
};

var kind: Kind = .{};
var running_table: *const sal.Table(host.wraith.Plugin) = undefined;
var provided = std.atomic.Value(bool).init(false);

/// Provides the kind, once for the process. Its owner is the runtime's, which outlives every plugin.
pub fn provide() void {
    if (provided.swap(true, .acq_rel)) return;
    const h = sal.host();
    const owner = h.owner("wraith") catch return provided.store(false, .release);
    running_table = h.adopt(host.wraith.Plugin, sal.implement(host.wraith.Plugin, Running), owner) catch return provided.store(false, .release);
    const k = sal.Object(host.wraith.PluginKind).init(&kind, sal.implement(host.wraith.PluginKind, Kind));
    h.provide("wraith.kind." ++ name, 1, h.own(k, owner) catch return provided.store(false, .release)) catch |err| {
        log.err("Couldn't provide the {s} plugin kind: {t}", .{ name, err });
    };
}
