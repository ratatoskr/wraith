//! Which tweaks there are and what they say: the project's files, parsed again when they change,
//! and what plugins added. A group's file is an entry of its own, for its shared part, with an
//! entry after it for each of its tweaks and nested groups, in the file's order.

const std = @import("std");

const api = @import("wraith_api");

const Tweaks = @import("../Tweaks.zig");
const Tweak = @import("Tweak.zig");
const Project = @import("../Project.zig");
const Names = @import("../Names.zig");
const plugin_tweaks = @import("../host/tweaks.zig");
const running = @import("running.zig");
const bindings = @import("bindings.zig");

const format = api.tweak;

/// If the project's files, the mods' or the plugins' tweaks changed since last time.
pub fn stale(tw: *const Tweaks) bool {
    return tw.project.version() != tw.seen_version or plugin_tweaks.version() != tw.plugins_seen or
        tw.mods_version.load(.acquire) != tw.mods_seen;
}

/// A tweak file, the project's or a mod's.
const Source = struct {
    mod: ?[]const u8,
    path: []const u8,
};

fn sameMod(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// Matches the list to the project's files and reads any that changed. New ones start as the
/// settings say.
pub fn refresh(tw: *Tweaks) void {
    tw.seen_version = tw.project.version();
    var paths = tw.project.list(tw.allocator, "tweaks", Project.ext.tweak) catch return;
    defer Project.freePaths(tw.allocator, &paths);
    tw.lock.lock();
    defer tw.lock.unlock();
    const mods_now = tw.mods_version.load(.acquire);
    const mods_changed = mods_now != tw.mods_seen;
    tw.mods_seen = mods_now;
    var sources: std.ArrayList(Source) = .empty;
    defer sources.deinit(tw.allocator);
    for (paths.items) |p| sources.append(tw.allocator, .{ .mod = null, .path = p }) catch return;
    for (tw.mods) |m| for (m.files) |f| {
        if (!std.mem.startsWith(u8, f.path, "tweaks/") or !std.mem.endsWith(u8, f.path, Project.ext.tweak)) continue;
        sources.append(tw.allocator, .{ .mod = m.id, .path = f.path }) catch return;
    };
    var i: usize = 0;
    while (i < tw.list.items.len) {
        const t = tw.list.items[i];
        const still = t.plugin != null or t.file != null or for (sources.items) |s| {
            if (sameMod(s.mod, t.mod) and std.mem.eql(u8, s.path, t.path)) break true;
        } else false;
        if (still) {
            i += 1;
            continue;
        }
        running.turnOff(tw, t);
        removeChildren(tw, t);
        remove(tw, t);
        // A group's tweaks could have been before it
        i = 0;
    }
    for (sources.items) |s| {
        if (findPath(tw, s.mod, s.path) != null) continue;
        const t = newTweak(tw, s.mod, s.path) catch continue;
        tw.list.append(tw.allocator, t) catch {
            freeTweak(tw, t);
            continue;
        };
    }
    // Files only, since reading a group's adds and takes away its tweaks
    var files: std.ArrayList(*Tweak) = .empty;
    defer files.deinit(tw.allocator);
    for (tw.list.items) |t| if (t.plugin == null and t.file == null) files.append(tw.allocator, t) catch {};
    for (files.items) |t| {
        const fresh = t.source_hash == null;
        // A mod's file only changes when it's updated, and what was on stays on
        if (t.mod != null and !mods_changed and !fresh) continue;
        _ = reparse(tw, t, if (t.mod != null) .restart else .turn_off);
        if (fresh) startIfWanted(tw, t);
    }
    syncPlugins(tw);
    // The project's, then mods', then plugins', each grouped by where it's from, and what's in a
    // group's file after it in the file's order
    std.mem.sort(*Tweak, tw.list.items, {}, struct {
        fn rank(t: *const Tweak) u8 {
            return if (t.plugin != null) 2 else if (t.mod != null) 1 else 0;
        }

        fn before(_: void, a: *Tweak, b: *Tweak) bool {
            if (rank(a) != rank(b)) return rank(a) < rank(b);
            const ap = a.plugin orelse a.mod orelse "";
            const bp = b.plugin orelse b.mod orelse "";
            if (!std.mem.eql(u8, ap, bp)) return std.mem.lessThan(u8, ap, bp);
            const ar = (a.file orelse a).name;
            const br = (b.file orelse b).name;
            if (!std.mem.eql(u8, ar, br)) return std.mem.lessThan(u8, ar, br);
            if ((a.file == null) != (b.file == null)) return a.file == null;
            return a.index < b.index;
        }
    }.before);
    bindings.apply(tw);
    tw.changed();
}

/// Under the lock. On if the settings say it was, for one that just showed up. Actions only run
/// when asked.
fn startIfWanted(tw: *Tweaks, t: *Tweak) void {
    if (!tw.kept.wasOn(t.name)) return;
    if (t.is_group or t.def.mode == .toggle) running.request(t);
}

/// Under the lock. Takes it out of the list and frees it.
fn remove(tw: *Tweaks, t: *Tweak) void {
    if (std.mem.indexOfScalar(*Tweak, tw.list.items, t)) |i| _ = tw.list.orderedRemove(i);
    freeTweak(tw, t);
}

/// Under the lock. Everything in a group's file, off and gone.
fn removeChildren(tw: *Tweaks, g: *Tweak) void {
    if (g.is_group) running.turnOff(tw, g);
    // Nothing's looked at through the groups they're in from here, since those go too
    var i: usize = 0;
    while (i < tw.list.items.len) {
        const c = tw.list.items[i];
        if (c.file != g) {
            i += 1;
            continue;
        }
        _ = tw.list.orderedRemove(i);
        freeTweak(tw, c);
    }
}

/// Under the lock. What's at `part` in a group's file.
pub fn findPart(tw: *Tweaks, file: *const Tweak, part: []const u8) ?*Tweak {
    for (tw.list.items) |t| if (t.file == file and std.mem.eql(u8, t.part, part)) return t;
    return null;
}

/// Under the lock. Anything in its file is on or up.
fn fileActive(tw: *Tweaks, t: *Tweak) bool {
    if (running.active(tw, t)) return true;
    for (tw.list.items) |c| if (c.file == t and running.active(tw, c)) return true;
    return false;
}

/// Under the lock. Matches the list to what plugins added.
fn syncPlugins(tw: *Tweaks) void {
    tw.plugins_seen = plugin_tweaks.version();
    const reading = plugin_tweaks.read();
    defer reading.end();
    var i: usize = 0;
    while (i < tw.list.items.len) {
        const t = tw.list.items[i];
        const still = t.plugin == null or for (reading.entries) |e| {
            if (std.mem.eql(u8, e.name, t.name)) break true;
        } else false;
        if (still) {
            i += 1;
            continue;
        }
        // Its plugin took it back or went, so there's nothing to tell
        freeTweak(tw, t);
        _ = tw.list.orderedRemove(i);
    }
    for (reading.entries) |e| {
        const t = find(tw, e.name) orelse blk: {
            const t = newPluginTweak(tw, e) catch continue;
            tw.list.append(tw.allocator, t) catch {
                freeTweak(tw, t);
                continue;
            };
            break :blk t;
        };
        const fresh = t.source_hash == null;
        copyDefinition(tw, t, e.def);
        if (fresh) startIfWanted(tw, t);
    }
}

/// Under the lock. Ours, since the plugin's goes away with it.
fn copyDefinition(tw: *Tweaks, t: *Tweak, def: format.Tweak) void {
    t.source_hash = 0;
    bindings.unbindFields(tw, t);
    _ = t.parsed.reset(.free_all);
    t.def = .{};
    t.fields = &.{};
    const a = t.parsed.allocator();
    const fields = a.alloc(format.Field, def.fields.len) catch return;
    for (fields, def.fields) |*dst, src| {
        dst.* = src;
        dst.name = a.dupe(u8, src.name) catch return;
        dst.label = a.dupe(u8, src.label) catch return;
        dst.choices = copyChoices(a, src.choices) catch return;
    }
    t.fields = a.alloc(Tweak.Field, fields.len) catch return;
    const title = if (def.title) |text| a.dupe(u8, text) catch null else null;
    t.def = .{ .title = title, .key = def.key, .mode = def.mode, .fields = fields };
    for (t.fields, t.def.fields) |*f, *d| f.* = .{ .tweak = t, .def = d };
}

pub const Edited = enum {
    turn_off,
    keep,
    /// Off while it's read again, then back on as it was. For a mod's update.
    restart,
};

/// Under the lock. If its file changed, which for anything in a group's file is the file's. An
/// edit turns it off with `.turn_off`, since what's running isn't what's written anymore. `.keep`
/// is for running it as it is now, which starts a group's file again if it's up. True if it
/// changed. What's in a group's file can come and go, so look one up again after.
pub fn reparse(tw: *Tweaks, t: *Tweak, edited: Edited) bool {
    if (t.plugin != null) return false;
    if (t.file) |f| return reparse(tw, f, edited);
    const text = tw.readFile(t.mod, t.path) orelse return false;
    defer tw.allocator.free(text);
    const hash = std.hash.Wyhash.hash(0, text);
    if (t.source_hash == hash) return false;
    // What was on, by name, to turn back on after a `.restart`
    var was_on: std.ArrayList([]u8) = .empty;
    defer {
        for (was_on.items) |n| tw.allocator.free(n);
        was_on.deinit(tw.allocator);
    }
    if (t.source_hash != null and fileActive(tw, t)) switch (edited) {
        .turn_off => {
            running.turnOff(tw, t);
            running.clearProblem(tw, t);
            tw.kept.persist_needed = true;
        },
        // Its shared parts would be what was written before
        .keep => if (t.is_group) running.restart(tw, t),
        .restart => {
            for (tw.list.items) |c| if ((c == t or c.file == t) and c.state.wanted() and (c.is_group or c.def.mode == .toggle)) {
                const n = tw.allocator.dupe(u8, c.name) catch continue;
                was_on.append(tw.allocator, n) catch tw.allocator.free(n);
            };
            running.turnOff(tw, t);
            running.clearProblem(tw, t);
        },
    };
    defer for (was_on.items) |n| if (find(tw, n)) |c| running.request(c);
    t.source_hash = hash;
    // Its session laid out the fields it had, so new ones can't be read or written there
    const before = fieldsHash(t.def.fields);
    defer if (fieldsHash(t.def.fields) != before) {
        t.live = &.{};
    };
    // Its tweaks' definitions are in its arena too
    var child_hashes: std.ArrayList(u64) = .empty;
    defer child_hashes.deinit(tw.allocator);
    for (tw.list.items) |c| if (c.file == t) {
        child_hashes.append(tw.allocator, fieldsHash(c.def.fields)) catch {};
        bindings.unbindFields(tw, c);
        c.def = .{};
        c.fields = &.{};
        c.group_title = null;
    };
    bindings.unbindFields(tw, t);
    _ = t.parsed.reset(.free_all);
    t.def = .{};
    t.fields = &.{};
    t.invalid = null;
    t.group_title = null;
    const a = t.parsed.allocator();
    const file = parseInto(t, a, text) orelse {
        if (t.is_group) ungroup(tw, t);
        return true;
    };
    if (!file.grouped) {
        if (t.is_group) ungroup(tw, t);
        t.def = file.tweaks[0];
    } else {
        // A lone tweak that's now a group stops being one
        if (!t.is_group) running.turnOff(tw, t);
        t.is_group = true;
        t.group_title = file.group;
        t.children = file.groups[0].children;
        t.def = file.shared;
    }
    t.fields = makeFields(a, t) orelse {
        t.def = .{};
        return true;
    };
    if (t.is_group) syncChildren(tw, t, file, child_hashes.items);
    return true;
}

/// In `a`. Null if it's invalid, which `t.invalid` says.
fn parseInto(t: *Tweak, a: std.mem.Allocator, text: []const u8) ?format.File {
    const source = a.dupe(u8, text) catch return null;
    var problem: format.Problem = .{};
    return format.parseFile(a, source, &problem) catch |err| {
        t.invalid = switch (err) {
            error.Invalid => std.fmt.allocPrint(a, "line {d}: {s}", .{ problem.line, problem.message() }) catch null,
            error.OutOfMemory => "Out of memory",
        };
        return null;
    };
}

fn makeFields(a: std.mem.Allocator, t: *Tweak) ?[]Tweak.Field {
    const fields = a.alloc(Tweak.Field, t.def.fields.len) catch return null;
    for (fields, t.def.fields) |*f, *d| f.* = .{ .tweak = t, .def = d };
    return fields;
}

/// Under the lock. A group's file that isn't one anymore.
fn ungroup(tw: *Tweaks, g: *Tweak) void {
    removeChildren(tw, g);
    g.is_group = false;
    g.own = false;
    g.children = .{};
}

/// Under the lock. An entry for each of the file's `@tweak`s and nested `@group`s, by path, so
/// one that's still there keeps its state. `before` is their fields' hashes before, in list order.
fn syncChildren(tw: *Tweaks, root: *Tweak, file: format.File, before: []const u64) void {
    const a = root.parsed.allocator();
    var k: usize = 0;
    for (tw.list.items) |c| if (c.file == root) {
        defer k += 1;
        const still = define(c, file, a);
        if (!still or (k < before.len and before[k] != fieldsHash(c.def.fields))) c.live = &.{};
    };
    // Gone from the file, or not the same kind anymore. All are off before any goes, since
    // turning off looks through the groups they're in
    for (tw.list.items) |c| if (c.file == root and !matches(c, file)) running.turnOff(tw, c);
    var i: usize = 0;
    while (i < tw.list.items.len) {
        const c = tw.list.items[i];
        if (c.file != root or matches(c, file)) {
            i += 1;
            continue;
        }
        _ = tw.list.orderedRemove(i);
        freeTweak(tw, c);
    }
    // New ones, groups first so what's in them has them
    for (file.groups[1..], 1..) |g, n| {
        if (findGroup(tw, root, g.path) != null) continue;
        addChild(tw, root, file, .{ .group = n }, a);
    }
    for (file.tweaks, 0..) |t, n| {
        if (findTweak(tw, root, t.path) != null) continue;
        addChild(tw, root, file, .{ .tweak = n }, a);
    }
    // The groups they're in, which can change with an edit
    for (tw.list.items) |c| if (c.file == root) {
        c.group = parentEntry(tw, root, file, c);
    };
    running.settle(tw, root);
}

/// Under the lock. Gives it its part of `file`. False if that's not there, or not the same kind.
fn define(c: *Tweak, file: format.File, a: std.mem.Allocator) bool {
    if (!matches(c, file)) return false;
    switch (file.resolve(c.part).?) {
        .whole => unreachable,
        .tweak => |i| {
            c.def = file.tweaks[i];
            c.index = file.tweaks[i].sections[0].line;
        },
        .group => |g| {
            c.def = file.groups[g].shared;
            c.index = file.groups[g].line;
            c.children = file.groups[g].children;
            c.group_title = file.groups[g].title;
        },
    }
    c.fields = makeFields(a, c) orelse &.{};
    return true;
}

/// It's still in `file` as what it was.
fn matches(c: *const Tweak, file: format.File) bool {
    const at = file.resolve(c.part) orelse return false;
    return switch (at) {
        .whole => false,
        .tweak => !c.is_group,
        .group => |g| c.is_group and g != 0,
    };
}

/// Under the lock. The entry for the group it's in.
fn parentEntry(tw: *Tweaks, root: *Tweak, file: format.File, c: *const Tweak) *Tweak {
    const at = file.resolve(c.part) orelse return root;
    const p = file.parentOf(at) orelse return root;
    if (p == 0) return root;
    return findGroup(tw, root, file.groups[p].path) orelse root;
}

fn findGroup(tw: *Tweaks, root: *const Tweak, path: []const u8) ?*Tweak {
    for (tw.list.items) |t| if (t.file == root and t.is_group and std.mem.eql(u8, t.part, path)) return t;
    return null;
}

fn findTweak(tw: *Tweaks, root: *const Tweak, path: []const u8) ?*Tweak {
    for (tw.list.items) |t| if (t.file == root and !t.is_group and std.mem.eql(u8, t.part, path)) return t;
    return null;
}

/// Under the lock. A new entry for `part` of `file`, on if it was.
fn addChild(tw: *Tweaks, root: *Tweak, file: format.File, part: format.Part, a: std.mem.Allocator) void {
    const c = newChild(tw, root, file.pathOf(part), part == .group) catch return;
    tw.list.append(tw.allocator, c) catch {
        freeTweak(tw, c);
        return;
    };
    _ = define(c, file, a);
    startIfWanted(tw, c);
}

/// Names and types, in order, which is what decides where each one goes.
fn fieldsHash(fields: []const format.Field) u64 {
    var h: std.hash.Wyhash = .init(0);
    for (fields) |f| {
        h.update(f.name);
        h.update(&.{ 0, @backingInt(f.type) });
    }
    return h.final();
}

/// A mod's is named `mod:file`, like a plugin's.
fn newTweak(tw: *Tweaks, mod: ?[]const u8, path: []const u8) !*Tweak {
    const t = try tw.allocator.create(Tweak);
    errdefer tw.allocator.destroy(t);
    const p = try tw.allocator.dupe(u8, path);
    errdefer tw.allocator.free(p);
    const base = std.fs.path.basename(path);
    const stem = base[0 .. base.len - Project.ext.tweak.len];
    const n = if (mod) |m| try std.fmt.allocPrint(tw.allocator, "{s}:{s}", .{ m, stem }) else try tw.allocator.dupe(u8, stem);
    errdefer tw.allocator.free(n);
    const owned_mod = if (mod) |m| try tw.allocator.dupe(u8, m) else null;
    t.* = .{ .path = p, .name = n, .mod = owned_mod, .session = running.newSession(tw), .parsed = .init(tw.allocator), .live_arena = .init(tw.allocator) };
    return t;
}

/// `root/Combat/Title`, with no session of its own.
fn newChild(tw: *Tweaks, root: *Tweak, path: []const u8, is_group: bool) !*Tweak {
    const t = try tw.allocator.create(Tweak);
    errdefer tw.allocator.destroy(t);
    const p = try tw.allocator.dupe(u8, root.path);
    errdefer tw.allocator.free(p);
    const n = try std.fmt.allocPrint(tw.allocator, "{s}/{s}", .{ root.name, path });
    errdefer tw.allocator.free(n);
    const part = try tw.allocator.dupe(u8, path);
    errdefer tw.allocator.free(part);
    const mod = if (root.mod) |m| try tw.allocator.dupe(u8, m) else null;
    t.* = .{ .path = p, .name = n, .mod = mod, .group = root, .file = root, .is_group = is_group, .part = part, .session = 0, .parsed = .init(tw.allocator), .live_arena = .init(tw.allocator) };
    return t;
}

fn newPluginTweak(tw: *Tweaks, entry: *const plugin_tweaks.Entry) !*Tweak {
    const t = try tw.allocator.create(Tweak);
    errdefer tw.allocator.destroy(t);
    const n = try tw.allocator.dupe(u8, entry.name);
    errdefer tw.allocator.free(n);
    const plugin = try tw.allocator.dupe(u8, entry.plugin);
    errdefer tw.allocator.free(plugin);
    const plugin_title = try tw.allocator.dupe(u8, entry.plugin_title);
    t.* = .{ .path = &.{}, .name = n, .plugin = plugin, .plugin_title = plugin_title, .session = running.newSession(tw), .parsed = .init(tw.allocator), .live_arena = .init(tw.allocator) };
    return t;
}

/// Its session or plugin should be done with it by now.
pub fn freeTweak(tw: *Tweaks, t: *Tweak) void {
    bindings.unbindAll(tw, t);
    Names.global.removeGroup(.tweak, t.name);
    if (t.problem) |p| tw.allocator.free(p);
    if (t.plugin) |p| tw.allocator.free(p);
    if (t.plugin_title) |p| tw.allocator.free(p);
    if (t.mod) |m| tw.allocator.free(m);
    tw.allocator.free(t.part);
    t.parsed.deinit();
    t.live_arena.deinit();
    tw.allocator.free(t.path);
    tw.allocator.free(t.name);
    tw.allocator.destroy(t);
}

pub fn find(tw: *Tweaks, name: []const u8) ?*Tweak {
    for (tw.list.items) |t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

fn findPath(tw: *Tweaks, mod: ?[]const u8, path: []const u8) ?*Tweak {
    for (tw.list.items) |t| if (t.file == null and t.plugin == null and sameMod(t.mod, mod) and std.mem.eql(u8, t.path, path)) return t;
    return null;
}

pub fn copyChoices(a: std.mem.Allocator, choices: []const format.Choice) ![]const format.Choice {
    const out = try a.alloc(format.Choice, choices.len);
    for (out, choices) |*dst, src| dst.* = .{ .value = src.value, .label = try a.dupe(u8, src.label) };
    return out;
}
