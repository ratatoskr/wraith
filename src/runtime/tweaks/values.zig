//! Your values, keys and which tweaks are on, kept per game. Values are fitted to their field.

const std = @import("std");

const api = @import("wraith_api");
const core = @import("wraith_core");

const GameSettings = @import("../GameSettings.zig");
const Tweak = @import("Tweak.zig");

const format = api.tweak;
const Settings = GameSettings.Tweaks;

/// Values are saved once they've stopped changing this long, not every frame of a drag.
const save_delay_ns = 500 * std.time.ns_per_ms;

/// Under the tweaks' lock.
pub const Kept = struct {
    allocator: std.mem.Allocator,
    /// Ours, in `arena`.
    settings: Settings = .{},
    arena: std.heap.ArenaAllocator,
    /// Your values, apart from `settings` so a drag changes one in place. Names in `arena`.
    values: std.ArrayList(Settings.Value) = .empty,
    /// When values changed since they were last saved. They're saved once they settle.
    changed_ns: ?u64 = null,
    /// Something turned off by itself, like an edited tweak, so the settings change.
    persist_needed: bool = false,

    pub fn init(self: *Kept, allocator: std.mem.Allocator, settings: Settings) void {
        self.* = .{ .allocator = allocator, .arena = .init(allocator) };
        self.settings = copySettings(self.arena.allocator(), settings) catch .{};
        self.values.appendSlice(allocator, self.settings.values) catch {};
    }

    pub fn deinit(self: *Kept) void {
        self.values.deinit(self.allocator);
        self.arena.deinit();
    }

    /// Turns `name` on when it shows up.
    pub fn remember(self: *Kept, name: []const u8) void {
        const a = self.arena.allocator();
        for (self.settings.on) |n| if (std.mem.eql(u8, n, name)) return;
        const on = a.alloc([]const u8, self.settings.on.len + 1) catch return;
        @memcpy(on[0..self.settings.on.len], self.settings.on);
        on[self.settings.on.len] = a.dupe(u8, name) catch return;
        self.settings.on = on;
    }

    pub fn wasOn(self: *const Kept, name: []const u8) bool {
        for (self.settings.on) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }

    /// In place if it's there, so a drag doesn't pile up copies.
    pub fn keep(self: *Kept, tweak: []const u8, field: []const u8, value: f64) !void {
        for (self.values.items) |*v| if (isValue(v.*, tweak, field)) {
            v.value = value;
            return;
        };
        const a = self.arena.allocator();
        try self.values.append(self.allocator, .{ .tweak = try a.dupe(u8, tweak), .field = try a.dupe(u8, field), .value = value });
    }

    /// Back to the tweak's own.
    pub fn forget(self: *Kept, tweak: []const u8, field: []const u8) void {
        for (self.values.items, 0..) |v, i| if (isValue(v, tweak, field)) {
            _ = self.values.orderedRemove(i);
            return;
        };
    }

    pub fn stored(self: *const Kept, tweak: []const u8, field: format.Field) f64 {
        for (self.values.items) |v| if (isValue(v, tweak, field.name)) return fit(field, v.value);
        return field.value;
    }

    /// A value changed. Saved once they settle.
    pub fn touch(self: *Kept) void {
        self.changed_ns = core.timing.now();
    }

    pub fn settled(self: *const Kept) bool {
        if (self.persist_needed) return true;
        const at = self.changed_ns orelse return false;
        return core.timing.now() -| at > save_delay_ns;
    }

    /// Takes in what's on now and gives a copy in `a` to save.
    pub fn forSave(self: *Kept, a: std.mem.Allocator, list: []const *Tweak) !Settings {
        var on: std.ArrayList([]const u8) = .empty;
        for (list) |t| if (if (t.is_group) t.own else (t.state.wanted() and t.def.mode == .toggle)) try on.append(a, try a.dupe(u8, t.name));
        // Ones not in this project stay on for when they're back
        for (self.settings.on) |name| {
            const listed = for (list) |t| {
                if (std.mem.eql(u8, t.name, name)) break true;
            } else false;
            if (!listed) try on.append(a, try a.dupe(u8, name));
        }
        self.settings.on = try copyNames(self.arena.allocator(), on.items);
        self.settings.values = self.values.items;
        self.changed_ns = null;
        self.persist_needed = false;
        return copySettings(a, self.settings);
    }
};

fn isValue(v: Settings.Value, tweak: []const u8, field: []const u8) bool {
    return std.mem.eql(u8, v.tweak, tweak) and std.mem.eql(u8, v.field, field);
}

/// Within its range and type, whole for integers.
pub fn fit(field: format.Field, value: f64) f64 {
    if (std.math.isNan(value)) return field.value;
    if (field.toggle or field.type == .bool) return if (value != 0) 1 else 0;
    var v = value;
    if (field.min) |m| v = @max(v, m);
    if (field.max) |m| v = @min(v, m);
    if (field.type.isFloat()) return v;
    v = @round(v);
    return switch (field.type) {
        inline .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64 => |t| std.math.clamp(
            v,
            @as(f64, @floatFromInt(std.math.minInt(TypeOf(t)))),
            @as(f64, @floatFromInt(std.math.maxInt(TypeOf(t)))),
        ),
        else => v,
    };
}

pub fn TypeOf(comptime t: format.Type) type {
    return switch (t) {
        .u8, .bool => u8,
        .u16 => u16,
        .u32 => u32,
        .u64 => u64,
        .i8 => i8,
        .i16 => i16,
        .i32 => i32,
        .i64 => i64,
        .f32 => f32,
        .f64 => f64,
    };
}

fn copyNames(a: std.mem.Allocator, names: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, names.len);
    for (out, names) |*dst, src| dst.* = try a.dupe(u8, src);
    return out;
}

pub fn copySettings(a: std.mem.Allocator, s: Settings) !Settings {
    const values = try a.alloc(Settings.Value, s.values.len);
    for (values, s.values) |*dst, src| dst.* = .{ .tweak = try a.dupe(u8, src.tweak), .field = try a.dupe(u8, src.field), .value = src.value };
    return .{ .on = try copyNames(a, s.on), .project_keys = s.project_keys, .values = values };
}

const tests = struct {
    const testing = std.testing;
    const Tweaks = @import("../Tweaks.zig");
    const Names = @import("../Names.zig");
    const support = @import("test_support.zig");
    const protocol = api.script;

    test "data values are kept, sent and live while it's on" {
        // Its bad run warns, which tests treat as noise
        const saved = core.log.mute(&.{.runtime});
        defer core.log.setFilter(saved);
        var s: support.Setup = try .init(&.{.{ "tweaks/xp.rwt", "@data\n  [Min(1), Max(50)] u32 times = 10\n  [Toggle] u8 on\n@js\n" }});
        defer s.deinit();

        var fake: support.Fake = .{ .ready = true };
        const tweaks = try Tweaks.create(testing.allocator, s.project, null, .{}, fake.env());
        defer tweaks.destroy();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();

        var info = (try tweaks.snapshot(arena.allocator()))[0];
        try testing.expectEqual(10, info.fields[0].value);
        try testing.expect(!info.fields[0].live and info.fields[1].toggle);

        // Kept and fitted while off, saved once it settles, then sent with the run
        tweaks.setValue("xp", "times", 99.6);
        tweaks.setValue("xp", "times", 99.7);
        try testing.expectEqual(0, fake.saved_values);
        try testing.expectEqual(1, tweaks.kept.values.items.len);
        tweaks.kept.changed_ns = 0;
        tweaks.tick();
        try testing.expectEqual(1, fake.saved_values);
        tweaks.setOn("xp", true);
        tweaks.tick();
        try testing.expectEqual(50, fake.last_value.?);

        var times: u32 = 0;
        try support.hear(tweaks, protocol.topics.tweak, protocol.TweakState{ .session = fake.last_session, .fields = &.{.{ .name = "times", .address = @intFromPtr(&times) }}, .names = &.{.{ .name = "times", .address = @intFromPtr(&times), .type = "u32" }} });
        times = 7;
        info = (try tweaks.snapshot(arena.allocator()))[0];
        try testing.expect(info.fields[0].live and info.running);
        try testing.expectEqual(7, info.fields[0].value);
        tweaks.setValue("xp", "times", 3);
        try testing.expectEqual(3, times);
        // Its names are the game's while it runs
        try testing.expectEqual(@intFromPtr(&times), try Names.global.get("xp.times"));
        var named: [32]u8 = undefined;
        try testing.expectEqualStrings("xp.times+0x2", Names.global.describe(@intFromPtr(&times) + 2, &named).?);

        // Thrown while starting stops it and turns it off, but the problem stays
        tweaks.rerun("xp");
        tweaks.tick();
        try testing.expectError(error.NotFound, Names.global.get("xp.times"));
        try support.hear(tweaks, protocol.topics.output, protocol.Output{ .session = fake.last_session, .kind = .thrown, .text = "line 2: nope" });
        info = (try tweaks.snapshot(arena.allocator()))[0];
        try testing.expect(!info.on and !info.running and !info.fields[0].live);
        try testing.expectEqualStrings("line 2: nope", info.problem.?);
        tweaks.resetValue("xp", "times");
        try testing.expectEqual(10, (try tweaks.snapshot(arena.allocator()))[0].fields[0].value);
        try testing.expectEqual(0, tweaks.kept.values.items.len);

        // The provider going takes its memory, so it's not live, and it runs again once it's back
        tweaks.setOn("xp", true);
        tweaks.tick();
        try testing.expectEqual(null, (try tweaks.snapshot(arena.allocator()))[0].problem);
        try support.hear(tweaks, protocol.topics.tweak, protocol.TweakState{ .session = fake.last_session, .fields = &.{.{ .name = "times", .address = @intFromPtr(&times) }} });
        fake.ready = false;
        tweaks.tick();
        info = (try tweaks.snapshot(arena.allocator()))[0];
        try testing.expect(info.on and !info.running and !info.fields[0].live);
        const runs = fake.runs;
        fake.ready = true;
        tweaks.tick();
        try testing.expectEqual(runs + 1, fake.runs);

        // Editing it turns it off, since what runs isn't what's written anymore
        try support.hear(tweaks, protocol.topics.tweak, protocol.TweakState{ .session = fake.last_session, .fields = &.{.{ .name = "times", .address = @intFromPtr(&times) }} });
        try testing.expect((try tweaks.snapshot(arena.allocator()))[0].fields[0].live);
        const stops = fake.stops;
        const saves = fake.saves;
        try s.project.write("tweaks/xp.rwt", "@data\n  [Max(5)] u64 times = 10\n");
        tweaks.tick();
        info = (try tweaks.snapshot(arena.allocator()))[0];
        try testing.expect(!info.on and !info.running and !info.fields[0].live);
        try testing.expectEqual(stops + 1, fake.stops);
        try testing.expectEqual(saves + 1, fake.saves);

        // A value kept before the range shrank goes in fitted
        tweaks.setValue("xp", "times", 4);
        try s.project.write("tweaks/xp.rwt", "@data\n  [Max(2)] u64 times = 1\n");
        tweaks.tick();
        tweaks.setOn("xp", true);
        tweaks.tick();
        try testing.expectEqual(2, fake.last_value.?);
    }
};

test {
    _ = tests;
}
