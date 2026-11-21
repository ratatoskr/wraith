//! Keys for tweaks and their fields. A tweak's key turns it on and off or runs it, a field's flips
//! it. The callbacks only set a flag that the next tick acts on, since unbinding waits for them.

const std = @import("std");

const core = @import("wraith_core");
const input = @import("wraith_platform").input;
const Keybinds = @import("tuft_input").Keybinds;
const Message = @import("tuft_text").Message;

const Tweaks = @import("../Tweaks.zig");
const Registry = @import("../settings/Registry.zig");
const Tweak = @import("Tweak.zig");
const running = @import("running.zig");
const definitions = @import("definitions.zig");

const log = core.log.scoped(.wraith_runtime);

/// Under the lock. Each key is a setting in the registry, for just this game, listed under where
/// the tweak's from, like your project, a mod or a plugin, with a heading for each tweak, its own
/// key then its fields'. The project's key is its default if they're used, and the one picked in
/// Settings wins.
pub fn apply(tw: *Tweaks) void {
    for (tw.list.items) |t| {
        const group = tw.sourceTitle(t);
        const key: ?input.Chord = if (tw.kept.settings.project_keys) t.def.key else null;
        var id_buf: [192]u8 = undefined;
        var section_buf: [192]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "wraith.tweak.{s}", .{t.name}) catch continue;
        const section = labelOf(&section_buf, t) orelse continue;
        const own = if (!t.is_group and t.def.mode == .action) "Run" else "On and off";
        bind(tw, &t.setting, &t.key, key, id, group, section, own, .{ .ctx = t, .call = keyPressed });
        for (t.fields) |*f| {
            const field_key = if (tw.kept.settings.project_keys) f.def.key else null;
            const field_id = std.fmt.bufPrint(&id_buf, "wraith.tweak.{s}.{s}", .{ t.name, f.def.name }) catch continue;
            bind(tw, &f.setting, &f.key, field_key, field_id, group, section, f.def.label, .{ .ctx = f, .call = fieldKeyPressed });
        }
    }
}

/// Registered again if its default changed, which keeps a key picked for it.
fn bind(tw: *Tweaks, setting: *?*Registry.Setting, default: *?input.Chord, key: ?input.Chord, id: []const u8, group: []const u8, section: []const u8, label: []const u8, action: Registry.KeyAction) void {
    const registry = tw.registry orelse return;
    if (setting.* != null and std.meta.eql(key, default.*)) return;
    if (setting.*) |s| registry.remove(s);
    setting.* = null;
    default.* = key;
    setting.* = registry.add(.{
        .id = id,
        .name = label,
        .group = group,
        .section = section,
        .scope = .game,
        .kind = .{ .key = .{ .default = key } },
    }, .{ .key = action }) catch |err| blk: {
        log.warn("Couldn't add the key for {s}, {s}: {t}", .{ section, label, err });
        break :blk null;
    };
}

/// What its key is now, picked or the project's.
pub fn keyOf(tw: *Tweaks, setting: ?*Registry.Setting) ?input.Chord {
    const s = setting orelse return null;
    const registry = tw.registry orelse return null;
    return registry.get(s).key;
}

/// `Kai / Combat / Max bravery`, from the groups it's in down.
fn labelOf(buf: []u8, t: *const Tweak) ?[]const u8 {
    var chain: [32]*const Tweak = undefined;
    var n: usize = 0;
    var at: ?*const Tweak = t;
    while (at) |p| : (at = p.group) {
        if (n == chain.len) return null;
        chain[n] = p;
        n += 1;
    }
    var w: std.Io.Writer = .fixed(buf);
    while (n > 0) {
        n -= 1;
        w.print("{s}{s}", .{ chain[n].title(), if (n > 0) " / " else "" }) catch return null;
    }
    return w.buffered();
}

/// Their picked keys stay saved.
pub fn unbindFields(tw: *Tweaks, t: *Tweak) void {
    const registry = tw.registry orelse return;
    for (t.fields) |*f| if (f.setting) |s| {
        registry.remove(s);
        f.setting = null;
    };
}

pub fn unbindAll(tw: *Tweaks, t: *Tweak) void {
    if (t.setting) |s| if (tw.registry) |r| r.remove(s);
    t.setting = null;
    unbindFields(tw, t);
}

fn keyPressed(ctx: *anyopaque, phase: Keybinds.Phase) void {
    const t: *Tweak = @ptrCast(@alignCast(ctx));
    if (phase == .pressed) t.toggle_requested.store(true, .release);
}

fn fieldKeyPressed(ctx: *anyopaque, phase: Keybinds.Phase) void {
    const f: *Tweak.Field = @ptrCast(@alignCast(ctx));
    if (phase == .pressed) f.flip_requested.store(true, .release);
}

const Request = struct {
    name: Message(64) = .{},
    field: Message(64) = .{},

    fn of(tweak: []const u8, field: []const u8) Request {
        var r: Request = .{};
        r.name.set(tweak);
        r.field.set(field);
        return r;
    }
};

/// Not under the lock. Does what keys asked for since the last tick.
pub fn handlePresses(tw: *Tweaks) void {
    var requests: [16]Request = undefined;
    var count: usize = 0;
    {
        tw.lock.lock();
        defer tw.lock.unlock();
        for (tw.list.items) |t| {
            if (t.toggle_requested.swap(false, .acq_rel) and count < requests.len) {
                requests[count] = .of(t.name, "");
                count += 1;
            }
            for (t.fields) |*f| if (f.flip_requested.swap(false, .acq_rel) and count < requests.len) {
                requests[count] = .of(t.name, f.def.name);
                count += 1;
            };
        }
    }
    for (requests[0..count]) |r| {
        const name = r.name.message();
        if (r.field.len == 0) {
            tw.toggle(name);
            announce(tw, name);
        } else flip(tw, name, r.field.message());
    }
}

/// Tells the env what its key did.
fn announce(tw: *Tweaks, name: []const u8) void {
    var title_buf: [128]u8 = undefined;
    const title, const now = blk: {
        tw.lock.lock();
        defer tw.lock.unlock();
        const t = definitions.find(tw, name) orelse return;
        const n = @min(t.title().len, title_buf.len);
        @memcpy(title_buf[0..n], t.title()[0..n]);
        const now: Tweaks.Keyed = if (!t.is_group and t.def.mode == .action) .ran else if (t.isOn()) .on else .off;
        break :blk .{ title_buf[0..n], now };
    };
    tw.env.keyed(tw.env.context, title, now);
}

/// For a field's key.
fn flip(tw: *Tweaks, name: []const u8, field: []const u8) void {
    const now = blk: {
        tw.lock.lock();
        defer tw.lock.unlock();
        const t = definitions.find(tw, name) orelse return;
        const d = t.def.field(field) orelse return;
        break :blk running.readLive(t, d.*) orelse tw.kept.stored(t.name, d.*);
    };
    tw.setValue(name, field, if (now != 0) 0 else 1);
}

const tests = struct {
    const testing = std.testing;
    const support = @import("test_support.zig");

    test "keys come from the tweak unless yours" {
        var s: support.Setup = try .init(&.{.{ "tweaks/health.rwt", "@tweak Infinite health\n@key F1\n" }});
        defer s.deinit();
        const registry = try Registry.create(testing.allocator, .{});
        defer registry.destroy();

        var fake: support.Fake = .{};
        const tweaks = try Tweaks.create(testing.allocator, s.project, registry, .{}, fake.env());
        defer tweaks.destroy();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const first = (try tweaks.snapshot(arena.allocator()))[0];
        try testing.expectEqual(.f1, first.key.?.key);
        try testing.expectEqualStrings("Infinite health", first.title);
        // Listed in Settings under where it's from, for just this game
        const setting = registry.find("wraith.tweak.health").?;
        try testing.expectEqual(.game, setting.def.scope);
        try testing.expectEqualStrings("Your project", setting.def.group);
        try testing.expectEqualStrings("Infinite health", setting.def.section);
        try testing.expectEqualStrings("On and off", setting.def.name);

        tweaks.setKey("health", .{ .key = .f2 });
        const own = (try tweaks.snapshot(arena.allocator()))[0];
        try testing.expectEqual(.f2, own.key.?.key);
        try testing.expect(own.own_key);
        tweaks.clearKey("health");
        try testing.expectEqual(.f1, (try tweaks.snapshot(arena.allocator()))[0].key.?.key);
        tweaks.setProjectKeys(false);
        try testing.expectEqual(null, (try tweaks.snapshot(arena.allocator()))[0].key);
    }
};

test {
    _ = tests;
}
