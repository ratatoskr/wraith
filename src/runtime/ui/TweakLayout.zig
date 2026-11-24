//! How the tweak lists are laid out: the order things go in and what's folded. The Tweaks window
//! and the workbench's Tweaks panel share it, and it's kept per game. Things only move among the
//! ones next to them, since what's in a group is up to its file. Any thread.

const TweakLayout = @This();

const std = @import("std");

const ui = @import("wraith_ui");
const sync = @import("tuft_sys").sync;

const Tweaks = @import("../Tweaks.zig");
const GameSettings = @import("../GameSettings.zig");
const struct_tweaks = @import("../host/struct_tweaks.zig");

const Info = Tweaks.Info;
const Summary = struct_tweaks.Summary;

lock: sync.RwLock = .{},
arrangement: ui.Reorder.Arrangement = .{},

/// A row in a tweak list, depth first, with its source's heading at the top.
pub const Entry = struct {
    id: u64,
    /// 0 for a heading.
    parent: u64,
    depth: u32,
    /// Folded itself, whatever it's in.
    folded: bool = false,
    what: union(enum) {
        source: Source,
        /// A plugin's heading inside its own, with its tweaks after it
        section: []const u8,
        tweak: *const Info,
        structure: *const Summary,
    },
};

/// Your project, an installed mod or a plugin, as a heading.
pub const Source = struct {
    /// Empty for your project.
    id: []const u8,
    title: []const u8,
};

pub fn deinit(self: *TweakLayout) void {
    self.arrangement.deinit();
}

pub fn load(self: *TweakLayout, saved: GameSettings.Layout) void {
    self.lock.lock();
    defer self.lock.unlock();
    self.arrangement.load(saved.order, saved.folded);
}

/// Copied into `a` if it changed since the last time.
pub fn takeChanged(self: *TweakLayout, a: std.mem.Allocator) ?GameSettings.Layout {
    self.lock.lock();
    defer self.lock.unlock();
    if (!self.arrangement.changed) return null;
    const out: GameSettings.Layout = .{
        .order = a.dupe(u64, self.arrangement.orderIds()) catch return null,
        .folded = a.dupe(u64, self.arrangement.foldedIds()) catch return null,
    };
    self.arrangement.changed = false;
    return out;
}

pub fn sourceId(id: []const u8) u64 {
    return hashed(&.{ "source", id });
}

pub fn tweakId(name: []const u8) u64 {
    return hashed(&.{ "tweak", name });
}

pub fn structId(source: []const u8, type_name: []const u8) u64 {
    return hashed(&.{ "struct", source, type_name });
}

pub fn sectionId(source: []const u8, section: []const u8) u64 {
    return hashed(&.{ "section", source, section });
}

fn hashed(parts: []const []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    for (parts) |p| {
        h.update(p);
        h.update(&.{0});
    }
    // 0 is the top
    return h.final() | 1;
}

pub fn isFolded(self: *TweakLayout, id: u64) bool {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    return self.arrangement.isFolded(id);
}

pub fn toggle(self: *TweakLayout, id: u64) void {
    self.lock.lock();
    defer self.lock.unlock();
    self.arrangement.toggle(id);
}

/// A move among `all`, as `entries` gave them. True if it moved.
pub fn apply(self: *TweakLayout, all: []const Entry, move: ui.Reorder.Move) bool {
    self.lock.lock();
    defer self.lock.unlock();
    return self.arrangement.apply(Entry, all, Ctx{}, move);
}

const Ctx = struct {
    pub fn id(_: Ctx, e: *const Entry) u64 {
        return e.id;
    }
    pub fn depth(_: Ctx, e: *const Entry) u32 {
        return e.depth;
    }
};

/// Every row, in `arena`, under a heading for each source and in the order kept.
pub fn entries(self: *TweakLayout, arena: std.mem.Allocator, list: []const Info, structs: []const Summary) ![]Entry {
    var sources: std.ArrayList(Source) = .empty;
    for (list) |*t| try addSource(arena, &sources, .{ .id = t.source_id, .title = t.source_title });
    for (structs) |*s| try addSource(arena, &sources, .{ .id = s.source, .title = s.source_title });

    var out: std.ArrayList(Entry) = try .initCapacity(arena, sources.items.len + 2 * list.len + structs.len);
    for (sources.items) |s| {
        const heading = sourceId(s.id);
        out.appendAssumeCapacity(.{ .id = heading, .parent = 0, .depth = 0, .what = .{ .source = s } });
        for (list) |*t| {
            if (!std.mem.eql(u8, t.source_id, s.id) or t.section.len > 0) continue;
            const parent = if (t.group) |g| tweakId(g) else heading;
            out.appendAssumeCapacity(.{ .id = tweakId(t.name), .parent = parent, .depth = t.depth + 1, .what = .{ .tweak = t } });
        }
        // A plugin's headings, each where its first tweak is, with its tweaks after it
        for (list, 0..) |*first, i| {
            if (!std.mem.eql(u8, first.source_id, s.id) or first.section.len == 0) continue;
            const seen = for (list[0..i]) |*t| {
                if (std.mem.eql(u8, t.source_id, s.id) and std.mem.eql(u8, t.section, first.section)) break true;
            } else false;
            if (seen) continue;
            const section = sectionId(s.id, first.section);
            out.appendAssumeCapacity(.{ .id = section, .parent = heading, .depth = 1, .what = .{ .section = first.section } });
            for (list[i..]) |*t| {
                if (!std.mem.eql(u8, t.source_id, s.id) or !std.mem.eql(u8, t.section, first.section)) continue;
                out.appendAssumeCapacity(.{ .id = tweakId(t.name), .parent = section, .depth = 2, .what = .{ .tweak = t } });
            }
        }
        // A plugin's structs go after its other tweaks, to start with
        for (structs) |*e| {
            if (!std.mem.eql(u8, e.source, s.id)) continue;
            out.appendAssumeCapacity(.{ .id = structId(e.source, e.type_name), .parent = heading, .depth = 1, .what = .{ .structure = e } });
        }
    }
    self.lock.lockShared();
    defer self.lock.unlockShared();
    self.arrangement.arrange(Entry, out.items, Ctx{});
    for (out.items) |*e| e.folded = self.arrangement.isFolded(e.id);
    return out.items;
}

fn addSource(arena: std.mem.Allocator, sources: *std.ArrayList(Source), s: Source) !void {
    for (sources.items) |have| if (std.mem.eql(u8, have.id, s.id)) return;
    try sources.append(arena, s);
}

test "a plugin's sections are headings in its own, each with its tweaks" {
    const testing = std.testing;
    var layout: TweakLayout = .{};
    defer layout.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const off: Info = .{ .name = "", .title = "", .path = "", .mode = .toggle, .on = false, .running = false, .key = null, .own_key = false, .problem = null, .fields = &.{}, .source = .plugin, .source_id = "kai", .source_title = "Kai" };
    var list = [_]Info{ off, off, off, off };
    list[0].name = "kai:hit";
    list[0].section = "Combat";
    list[1].name = "kai:spawn";
    list[2].name = "kai:exp";
    list[2].section = "Experience";
    list[3].name = "kai:guard";
    list[3].section = "Combat";

    const all = try layout.entries(arena.allocator(), &list, &.{});
    const want = [_][]const u8{ "Kai", "kai:spawn", "Combat", "kai:hit", "kai:guard", "Experience", "kai:exp" };
    try testing.expectEqual(want.len, all.len);
    for (want, all) |w, e| try testing.expectEqualStrings(w, switch (e.what) {
        .source => |s| s.title,
        .section => |s| s,
        .tweak => |t| t.name,
        .structure => |s| s.type_name,
    });
    try testing.expectEqual(sectionId("kai", "Combat"), all[3].parent);
    try testing.expectEqual(2, all[3].depth);
}

test "sources, groups and structs keep the order they're put in" {
    const testing = std.testing;
    var layout: TweakLayout = .{};
    defer layout.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const off: Info = .{ .name = "", .title = "", .path = "", .mode = .toggle, .on = false, .running = false, .key = null, .own_key = false, .problem = null, .fields = &.{} };
    var list = [_]Info{ off, off, off, off, off };
    list[0].name = "speed";
    list[1].name = "kai";
    list[1].is_group = true;
    list[2].name = "kai/One";
    list[2].group = "kai";
    list[2].depth = 1;
    list[3].name = "kai/Two";
    list[3].group = "kai";
    list[3].depth = 1;
    list[4].name = "plugin:fly";
    list[4].source = .plugin;
    list[4].source_id = "fly";
    list[4].source_title = "Fly";
    const structs = [_]Summary{.{ .source = "fly", .source_title = "Fly", .title = "Bank", .type_name = "Bank", .matches = true }};

    var all = try layout.entries(a, &list, &structs);
    try testing.expectEqual(8, all.len);
    try testing.expectEqual(sourceId("fly"), all[5].id);
    try testing.expectEqual(tweakId("kai"), all[3].parent);

    // The plugin's heading goes up top, then a tweak in the group goes first in it
    try testing.expect(layout.apply(all, .{ .dragged = sourceId("fly"), .target = sourceId(""), .place = .before }));
    all = try layout.entries(a, &list, &structs);
    try testing.expect(layout.apply(all, .{ .dragged = tweakId("kai/Two"), .target = tweakId("kai/One"), .place = .before }));
    // Out of its group, it stays put
    try testing.expect(!layout.apply(all, .{ .dragged = tweakId("kai/Two"), .target = tweakId("speed"), .place = .before }));
    layout.toggle(tweakId("kai"));

    // Kept for next time
    const saved = layout.takeChanged(a).?;
    try testing.expectEqual(null, layout.takeChanged(a));
    var again: TweakLayout = .{};
    defer again.deinit();
    again.load(saved);
    all = try again.entries(a, &list, &structs);
    var names: [8][]const u8 = undefined;
    for (all, &names) |e, *n| n.* = switch (e.what) {
        .source => |s| s.title,
        .section => |s| s,
        .tweak => |t| t.name,
        .structure => |s| s.type_name,
    };
    const want = [_][]const u8{ "Fly", "plugin:fly", "Bank", "", "speed", "kai", "kai/Two", "kai/One" };
    for (want, names) |w, n| try testing.expectEqualStrings(w, n);
    try testing.expect(all[5].folded);
}
