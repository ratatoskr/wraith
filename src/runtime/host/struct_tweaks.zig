//! Structs a plugin's schemas mark `[Tweak("..")]`. The Tweaks window shows each one, its fields
//! edited live, under its plugin. They need `[Instance]` so Wraith can find them. Kept till the
//! plugin closes.

const std = @import("std");

const core = @import("wraith_core");
const tuft_sys = @import("tuft_sys");
const mem = @import("tuft_mem");
const Owner = @import("tuft_event").Owner;
const SalSchema = @import("salamander_schema").Schema;

const Loaded = @import("../PluginLoader.zig").Loaded;
const Schemas = @import("schemas.zig").Schemas;

pub const Entry = struct {
    owner: *Owner,
    /// Its plugin's id and name for people. Both live as long as it does.
    plugin: []const u8,
    plugin_title: []const u8,
    /// In `schemas`.
    title: []const u8,
    type_name: []const u8,
    schemas: *Schemas,
};

const allocator = std.heap.page_allocator;

var lock: tuft_sys.sync.RwLock = .{};
var entries: std.ArrayList(Entry) = .empty;

var watch: Owner.Watch(*u8, .{ .closing = closing }) = .{};
var listener: u8 = 0;

/// The `[Tweak]`s in the plugin's own files, in place of what it had. Not ones from plugins it
/// depends on, which show under their own.
pub fn publish(loaded: *Loaded) void {
    const s = loaded.schemas orelse return;
    const lease = watch.lease(&listener, &loaded.owner, .calls) orelse return;
    defer lease.end();
    lock.lock();
    defer lock.unlock();
    removeLocked(&loaded.owner);
    const schema = s.schema();
    for (schema.types) |*t| {
        const a = SalSchema.findAnnotation(t.annotations, "wraith", "Tweak") orelse continue;
        if (a.args.len != 1 or a.args[0] != .string) continue;
        const file = SalSchema.fileOf(s.parsed.source, t.at);
        if (!(file.len > loaded.name.len and std.mem.startsWith(u8, file, loaded.name) and file[loaded.name.len] == '/')) continue;
        entries.append(allocator, .{
            .owner = &loaded.owner,
            .plugin = loaded.name,
            .plugin_title = loaded.displayName(),
            .title = a.args[0].string,
            .type_name = t.name,
            .schemas = s,
        }) catch return;
    }
}

/// Owners can't close until `end`, so keep it short. Render thread only.
pub fn read() Reading {
    lock.lockShared();
    return .{ .entries = entries.items };
}

pub const Reading = struct {
    entries: []const Entry,

    pub fn end(_: Reading) void {
        lock.unlockShared();
    }
};

fn removeLocked(owner: *const Owner) void {
    var i: usize = 0;
    while (i < entries.items.len) {
        if (entries.items[i].owner == owner) _ = entries.orderedRemove(i) else i += 1;
    }
}

fn closing(_: *u8, owner: *Owner) void {
    lock.lock();
    defer lock.unlock();
    removeLocked(owner);
}

/// Where the game has `type_name` now, through its `[Instance]`. Null till the game makes it. The
/// signature's only looked for every few seconds while it isn't found. Render thread.
pub fn instance(schemas: *Schemas, type_name: []const u8) ?usize {
    var name_buf: [160]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s}.instance", .{type_name}) catch return null;
    const key = std.hash.Wyhash.hash(@intFromPtr(schemas), name);
    const now = core.timing.now();
    for (&misses) |m| if (m.key == key and now < m.until) return null;
    const at = schemas.address(name) catch {
        misses[next_miss] = .{ .key = key, .until = now + retry_ns };
        next_miss = (next_miss + 1) % misses.len;
        return null;
    };
    var value: usize = 0;
    mem.Memory.local.read(at, std.mem.asBytes(&value)) catch return null;
    return if (value == 0) null else value;
}

const retry_ns = 3 * std.time.ns_per_s;

const Miss = struct { key: u64 = 0, until: u64 = 0 };
var misses: [16]Miss = @splat(.{});
var next_miss: usize = 0;
