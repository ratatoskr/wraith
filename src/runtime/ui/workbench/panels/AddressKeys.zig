//! The address list's hotkeys. Each is a key setting in the registry, for just this game, listed
//! under Address list in Wraith's settings, where a key picked for it wins. A press only counts
//! up, and whoever ticks the list does what it asks, so the list is only ever touched from one
//! thread.

const AddressKeys = @This();

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const core = @import("wraith_core");
const devtools = @import("tuft_devtools");
const Keybinds = @import("tuft_input").Keybinds;

const Registry = @import("../../../settings/Registry.zig");

const AddressList = devtools.AddressList;
const log = core.log.scoped(.wraith_ui);

allocator: std.mem.Allocator,
/// Null till the shell hands it over, and in tests without one.
registry: ?*Registry = null,
slots: std.ArrayList(*Slot) = .empty,
/// Of what was registered last, to tell when the list's hotkeys change.
bound_hash: u64 = 0,

const Slot = struct {
    node: u64,
    index: u8,
    setting: ?*Registry.Setting = null,
    presses: Atomic(u32) = .init(0),

    fn pressed(ctx: *anyopaque, phase: Keybinds.Phase) void {
        const self: *Slot = @ptrCast(@alignCast(ctx));
        if (phase == .pressed) _ = self.presses.fetchAdd(1, .acq_rel);
    }
};

/// Registers the list's hotkeys from the next tick.
pub fn attach(self: *AddressKeys, registry: *Registry) void {
    self.unbindAll();
    self.registry = registry;
    self.bound_hash = 0;
}

pub fn deinit(self: *AddressKeys) void {
    self.unbindAll();
    self.slots.deinit(self.allocator);
}

/// Does what was pressed since last time, then registers again if the hotkeys changed.
pub fn tick(self: *AddressKeys, list: *AddressList) void {
    for (self.slots.items) |s| {
        var n = s.presses.swap(0, .acq_rel);
        while (n > 0) : (n -= 1) list.pressHotkey(s.node, s.index);
    }
    self.sync(list);
}

/// How many are bound, for tests.
pub fn boundCount(self: *const AddressKeys) usize {
    var n: usize = 0;
    for (self.slots.items) |s| {
        if (s.setting) |setting| n += @intFromBool(setting.binding != null);
    }
    return n;
}

fn sync(self: *AddressKeys, list: *const AddressList) void {
    const registry = self.registry orelse return;
    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();
    const bound = list.boundHotkeys(arena.allocator()) catch return;
    var hash = std.hash.Wyhash.init(0);
    for (bound) |b| {
        const mods: u8 = @bitCast(b.chord.mods);
        hash.update(std.mem.asBytes(&b.node));
        hash.update(&.{ b.index, mods, 0 });
        hash.update(@tagName(b.chord.key));
        hash.update(b.label);
        hash.update(&.{0});
        hash.update(b.owner);
        hash.update(&.{0});
    }
    // Never 0, so the first time always registers
    const digest = hash.final() | 1;
    if (digest == self.bound_hash) return;
    self.bound_hash = digest;

    self.unbindAll();
    for (bound) |b| {
        var id_buf: [192]u8 = undefined;
        var id = std.fmt.bufPrint(&id_buf, "wraith.address.{s}.{d}", .{ b.owner, b.index }) catch continue;
        var n: usize = 2;
        while (registry.find(id) != null) : (n += 1) {
            id = std.fmt.bufPrint(&id_buf, "wraith.address.{s}#{d}.{d}", .{ b.owner, n, b.index }) catch break;
        }
        const slot = self.allocator.create(Slot) catch return;
        slot.* = .{ .node = b.node, .index = b.index };
        self.slots.append(self.allocator, slot) catch {
            self.allocator.destroy(slot);
            return;
        };
        slot.setting = registry.add(.{
            .id = id,
            .name = b.label,
            .group = "Address list",
            .scope = .game,
            .kind = .{ .key = .{ .default = b.chord } },
        }, .{ .key = .{ .ctx = slot, .call = Slot.pressed } }) catch |err| blk: {
            log.warn("Couldn't add the key for {s}: {t}", .{ b.label, err });
            break :blk null;
        };
    }
}

/// Their picked keys stay saved. Waits for a press in flight.
fn unbindAll(self: *AddressKeys) void {
    for (self.slots.items) |s| {
        if (s.setting) |setting| if (self.registry) |r| r.remove(setting);
        self.allocator.destroy(s);
    }
    self.slots.clearRetainingCapacity();
}

const tests = struct {
    const testing = std.testing;
    const win = @import("wraith_platform").win.api;
    const Rig = @import("../../../testing/Rig.zig");

    const VK_F8 = 0x77;
    const VK_F9 = 0x78;
    const key_up: isize = @bitCast(@as(usize, 0xC000_0001));

    fn press(rig: *Rig, vk: usize) void {
        _ = rig.send(win.WM_KEYDOWN, vk, 1);
        _ = rig.send(win.WM_KEYUP, vk, key_up);
        rig.present();
    }

    test "picked keys win and are kept" {
        var rig: Rig = undefined;
        try rig.init(.{ .overlay = false });
        defer rig.deinit();
        rig.present();
        const registry = try Registry.create(testing.allocator, .{ .keybinds = rig.keybinds });
        defer registry.destroy();

        var value: u32 = 1;
        var buf: [32]u8 = undefined;
        var list: AddressList = .{ .allocator = testing.allocator, .memory = .local, .symbols = .local };
        defer list.deinit();
        try list.load(&.{.{ .name = "Mira", .id = "mira", .address = try std.fmt.bufPrint(&buf, "0x{x}", .{@intFromPtr(&value)}), .hotkeys = &.{.{ .chord = .{ .key = .f8 }, .action = .set, .value = "999999" }} }});

        {
            var keys: AddressKeys = .{ .allocator = testing.allocator };
            defer keys.deinit();
            keys.attach(registry);
            keys.tick(&list);
            try testing.expectEqual(1, keys.boundCount());
            const setting = registry.find("wraith.address.mira.0").?;
            try testing.expectEqualStrings("Mira: set 999999", setting.def.name);
            try testing.expectEqual(.game, setting.def.scope);
            // Like Wraith's settings would
            try registry.set(setting, .{ .key = .{ .key = .f9 } });
        }

        // Next time it's on yours
        var again: AddressKeys = .{ .allocator = testing.allocator };
        defer again.deinit();
        again.attach(registry);
        again.tick(&list);
        press(&rig, VK_F8);
        again.tick(&list);
        try testing.expectEqual(1, value);
        press(&rig, VK_F9);
        again.tick(&list);
        try testing.expectEqual(999999, value);
    }
};

test {
    _ = tests;
}
