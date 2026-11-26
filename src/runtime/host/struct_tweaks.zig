//! Structs marked `[Tweak("..")]` in schemas or a tweak file's `@schema`, shown in the Tweaks window
//! with live-edited fields. They need `[Instance]`. Kept till the plugin closes or the file changes.

const std = @import("std");

const tuft_sys = @import("tuft_sys");
const Owner = @import("tuft_event").Owner;
const OnGone = @import("Owned.zig").OnGone;
const SalSchema = @import("salamander_schema").Schema;

const Loaded = @import("../PluginLoader.zig").Loaded;
const schemas_api = @import("schemas.zig");
const Schemas = schemas_api.Schemas;
const StructEditor = @import("../ui/StructEditor.zig");
const addresses = @import("addresses.zig");

pub const Entry = struct {
    /// A plugin's, or null for a tweak file's.
    owner: ?*Owner,
    /// The tweak file's, by its `key`. 0 for a plugin's.
    file: usize = 0,
    /// Where it's from, a plugin or mod id or "" for your project, and its name for people. Both live as long as it does.
    source: []const u8,
    source_title: []const u8,
    /// In `schemas`.
    title: []const u8,
    type_name: []const u8,
    schemas: *Schemas,
};

const allocator = std.heap.page_allocator;
const tweak_file = "tweak/tweak.sal";

var lock: tuft_sys.sync.RwLock = .{};
var entries: std.ArrayList(Entry) = .empty;
/// What tweak files' entries point into.
var files: std.ArrayList(*File) = .empty;

const File = struct {
    key: usize,
    arena: std.heap.ArenaAllocator,
    schemas: std.ArrayList(*Schemas) = .empty,

    fn destroy(f: *File) void {
        for (f.schemas.items) |s| s.destroy();
        var arena = f.arena;
        arena.deinit();
        allocator.destroy(f);
    }
};

var cleanup: OnGone(.closing, closing) = .{};

/// The `[Tweak]`s in its own files, replacing what it had. Dependencies' show under their own.
pub fn publish(loaded: *Loaded) void {
    // A tweak's script session isn't a plugin, and its file lists its own
    if (loaded.session) return;
    const lease = cleanup.lease(&loaded.owner) orelse return;
    defer lease.end();
    lock.lock();
    defer lock.unlock();
    removeLocked(&loaded.owner);
    const s = loaded.schemas orelse return;
    const schema = s.schema();
    for (schema.types) |*t| {
        const a = SalSchema.findAnnotation(t.annotations, "wraith", "Tweak") orelse continue;
        if (a.args.len != 1 or a.args[0] != .string) continue;
        if (!addresses.ownFile(loaded, SalSchema.fileOf(s.parsed.source, t.at))) continue;
        entries.append(allocator, .{
            .owner = &loaded.owner,
            .source = loaded.project orelse loaded.name,
            .source_title = loaded.displayName(),
            .title = a.args[0].string,
            .type_name = t.name,
            .schemas = s,
        }) catch return;
    }
}

/// A tweak file's `@schema` texts, replacing what `key` had. Each comes after `base`, but only its own
/// structs are listed. Ones that don't parse are left out.
pub fn publishFile(key: usize, source: []const u8, source_title: []const u8, base: []const schemas_api.File, texts: []const []const u8) void {
    const made = allocator.create(File) catch return;
    made.* = .{ .key = key, .arena = .init(allocator) };
    var added: std.ArrayList(Entry) = .empty;
    defer added.deinit(allocator);
    const a = made.arena.allocator();
    const owned_source = a.dupe(u8, source) catch "";
    const owned_title = a.dupe(u8, source_title) catch "";
    var with: std.ArrayList(schemas_api.File) = .empty;
    defer with.deinit(allocator);
    with.appendSlice(allocator, base) catch return made.destroy();
    for (texts) |text| {
        with.items.len = base.len;
        with.append(allocator, .{ .name = tweak_file, .text = text }) catch continue;
        const s = schemas_api.fromFiles(with.items) catch continue;
        made.schemas.append(a, s) catch {
            s.destroy();
            continue;
        };
        for (s.schema().types) |*t| {
            const ann = SalSchema.findAnnotation(t.annotations, "wraith", "Tweak") orelse continue;
            if (ann.args.len != 1 or ann.args[0] != .string) continue;
            if (!std.mem.eql(u8, SalSchema.fileOf(s.parsed.source, t.at), tweak_file)) continue;
            // The same struct from the file's shared part shows once
            const seen = for (added.items) |e| {
                if (std.mem.eql(u8, e.type_name, t.name)) break true;
            } else false;
            if (seen) continue;
            added.append(allocator, .{ .owner = null, .file = key, .source = owned_source, .source_title = owned_title, .title = ann.args[0].string, .type_name = t.name, .schemas = s }) catch {};
        }
    }
    const old = blk: {
        lock.lock();
        defer lock.unlock();
        removeFileLocked(key);
        const gone = for (files.items, 0..) |f, i| {
            if (f.key == key) break files.swapRemove(i);
        } else null;
        if (added.items.len > 0) {
            entries.appendSlice(allocator, added.items) catch {};
            files.append(allocator, made) catch {};
        }
        break :blk gone;
    };
    // Nobody's reading them now
    if (old) |f| f.destroy();
    if (added.items.len == 0 or std.mem.indexOfScalar(*File, files.items, made) == null) made.destroy();
}

/// What the Tweaks window lists, copied into `arena`. `query` marks which mention it.
pub const Summary = struct {
    source: []const u8,
    source_title: []const u8,
    title: []const u8,
    type_name: []const u8,
    matches: bool,
};

pub fn snapshot(arena: std.mem.Allocator, query: []const u8) []Summary {
    lock.lockShared();
    defer lock.unlockShared();
    const out = arena.alloc(Summary, entries.items.len) catch return &.{};
    for (entries.items, out) |e, *o| o.* = .{
        .source = arena.dupe(u8, e.source) catch "",
        .source_title = arena.dupe(u8, e.source_title) catch "",
        .title = arena.dupe(u8, e.title) catch "",
        .type_name = arena.dupe(u8, e.type_name) catch "",
        .matches = query.len == 0 or std.ascii.findIgnoreCase(e.title, query) != null or
            std.ascii.findIgnoreCase(e.source_title, query) != null or
            StructEditor.mentions(&e.schemas.parsed.schema, e.type_name, query),
    };
    return out;
}

pub const Drawn = enum { drawn, not_there_yet, gone };

/// Its fields, if still listed. Holds the list while drawing, so don't call into `Tweaks`. Render thread.
pub fn drawFields(source: []const u8, type_name: []const u8) Drawn {
    lock.lockShared();
    defer lock.unlockShared();
    const e = for (entries.items) |*e| {
        if (std.mem.eql(u8, e.source, source) and std.mem.eql(u8, e.type_name, type_name)) break e;
    } else return .gone;
    const at = StructEditor.instanceOf(&e.schemas.parsed.schema, e.type_name) orelse return .not_there_yet;
    _ = StructEditor.draw(&e.schemas.parsed.schema, e.type_name, at);
    return .drawn;
}

/// How many are listed, for tests.
pub fn count() usize {
    lock.lockShared();
    defer lock.unlockShared();
    return entries.items.len;
}

fn removeLocked(owner: *const Owner) void {
    var i: usize = 0;
    while (i < entries.items.len) {
        if (entries.items[i].owner == owner) _ = entries.orderedRemove(i) else i += 1;
    }
}

fn removeFileLocked(key: usize) void {
    var i: usize = 0;
    while (i < entries.items.len) {
        if (entries.items[i].owner == null and entries.items[i].file == key) _ = entries.orderedRemove(i) else i += 1;
    }
}

fn closing(owner: *Owner) void {
    lock.lock();
    defer lock.unlock();
    removeLocked(owner);
}
