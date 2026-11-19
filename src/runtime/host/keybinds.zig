//! Keybinds service. Each is a key setting in the registry, its id the owner's name then the
//! action's, so it's listed in Wraith's settings and the key picked there wins.

const std = @import("std");

const core = @import("wraith_core");
const wraith_platform = @import("wraith_platform");
const api = @import("wraith_api");

const host = @import("root.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;
const Keybinds = @import("tuft_input").Keybinds;
const Registry = @import("../settings/Registry.zig");
const Window = @import("tuft_input").Window;
const tuft_input = @import("tuft_input");

const log = core.log.scoped(.wraith_input);

/// Null while plugins aren't loaded.
var keybinds: ?*Keybinds = null;
/// Where they're registered. Null before the runtime's up.
var registry: ?*Registry = null;

pub fn setRegistry(r: ?*Registry) void {
    registry = r;
}
/// For where the mouse is before the window's said.
var window: ?*Window = null;

pub fn setKeybinds(k: ?*Keybinds) void {
    keybinds = k;
}

pub fn setWindow(w: ?*Window) void {
    window = w;
}

pub fn keyDown(_: *Loaded, key: tuft_input.Key) bool {
    const k = keybinds orelse return false;
    return k.isDown(key);
}

pub fn buttonDown(_: *Loaded, button: tuft_input.MouseButton) bool {
    const k = keybinds orelse return false;
    return k.isButtonDown(button);
}

pub fn mousePos(_: *Loaded) ?tuft_input.Point {
    if (keybinds) |k| if (k.mousePos()) |p| return p;
    const w = window orelse return null;
    return tuft_input.cursorPosition(w.handle() orelse return null);
}

const W = api.wraith;
/// From `input.sal`, kept till it's unbound.
pub const Fired = W.KeybindFired;

pub const Record = struct {
    loaded: *Loaded,
    fired: Fired,
    setting: ?*Registry.Setting = null,

    /// Render thread.
    fn fire(ctx: *anyopaque, phase: Keybinds.Phase) void {
        const self: *Record = @ptrCast(@alignCast(ctx));
        self.fired.invoke(.{switch (phase) {
            .pressed => .pressed,
            .released => .released,
        }});
    }

    pub fn going(self: *Record) bool {
        return self.setting != null;
    }

    /// The key picked for it stays saved.
    pub fn stop(self: *Record) void {
        const setting = self.setting orelse return;
        if (registry) |r| r.remove(setting);
        self.setting = null;
        // Won't be called again
        self.fired.release();
    }

    pub fn free(self: *Record) void {
        self.stop();
        self.loaded.allocator.destroy(self);
    }
};

var records: host.Owned(Record) = .{};

/// Its keys that are still bound.
pub fn countOf(loaded: *Loaded) u32 {
    return records.count(&loaded.owner);
}

/// Through `input.sal`. Released if it fails.
pub fn bind(loaded: *Loaded, action: api.Action, fired: Fired) api.KeybindError!*Record {
    return register(loaded, action, fired) catch |err| {
        fired.release();
        return err;
    };
}

fn register(loaded: *Loaded, action: api.Action, fired: Fired) api.KeybindError!*Record {
    if (keybinds == null) return error.KeybindsUnavailable;
    const r = registry orelse return error.KeybindsUnavailable;
    if (tuft_input.isModifier(action.chord.key)) return error.InvalidChord;
    var id_buf: [256]u8 = undefined;
    const id = std.fmt.bufPrint(&id_buf, "{s}.{s}", .{ loaded.name, action.id }) catch {
        log.warn("{s}'s keybind id is too long", .{loaded.name});
        return error.KeybindFailed;
    };

    const allocator = loaded.allocator;
    const record = try allocator.create(Record);
    record.* = .{ .loaded = loaded, .fired = fired };
    record.setting = r.add(.{
        .id = id,
        .name = action.name,
        .group = loaded.displayName(),
        .scope = switch (action.scope) {
            .global => .global,
            .game => .game,
        },
        .kind = .{ .key = .{ .default = action.chord, .consume = action.consume, .while_typing = action.while_typing } },
    }, .{ .key = .{ .ctx = record, .call = Record.fire } }) catch |err| {
        allocator.destroy(record);
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.AlreadyAdded => error.AlreadyBound,
        };
    };
    records.add(record) catch |err| {
        // Not `free`, since the callback's still the caller's
        r.remove(record.setting.?);
        allocator.destroy(record);
        return if (err == error.OutOfMemory) error.OutOfMemory else error.KeybindFailed;
    };
    return record;
}

/// Like someone picking it in Wraith's settings, so it's saved.
pub fn rebind(record: *Record, chord: wraith_platform.input.Chord) api.KeybindError!void {
    const r = registry orelse return error.KeybindFailed;
    const setting = record.setting orelse return error.KeybindFailed;
    r.set(setting, .{ .key = chord }) catch |err| return switch (err) {
        error.InvalidChord => error.InvalidChord,
        error.OutOfMemory => error.OutOfMemory,
        else => error.KeybindFailed,
    };
}

const tests = struct {
    const testing = std.testing;
    const sdk = @import("wraith_sdk");
    const win = wraith_platform.win.api;
    const Rig = @import("../testing/Rig.zig");

    const VK_F8 = 0x77;
    const VK_F9 = 0x78;

    const FakePlugin = struct {
        loaded: Loaded,

        fn init(self: *FakePlugin, name: []const u8) void {
            self.loaded.initForTest(testing.allocator, name);
            sdk.Owner.attach(self.loaded.root());
        }

        fn unload(self: *FakePlugin) void {
            self.loaded.deinitForTest();
            sdk.Owner.detach();
        }
    };

    fn recordOf(kb: api.wraith.Keybind) *Record {
        return @ptrFromInt(kb.data);
    }

    /// Keybinds and a registry that saves nothing, like the runtime gives plugins.
    fn attach(rig: *Rig) !*Registry {
        setKeybinds(rig.keybinds);
        const r = try Registry.create(testing.allocator, .{ .keybinds = rig.keybinds });
        setRegistry(r);
        return r;
    }

    fn detach(r: *Registry) void {
        setRegistry(null);
        r.destroy();
        setKeybinds(null);
    }

    const State = struct {
        presses: u32 = 0,
        releases: u32 = 0,

        fn fired(self: *State, phase: api.wraith.KeyPhase) void {
            switch (phase) {
                .pressed => self.presses += 1,
                .released => self.releases += 1,
                else => {},
            }
        }

        fn bind(self: *State, id: []const u8, key: api.wraith.Key, consume: bool) !api.wraith.Keybind {
            return sdk.wraith.root().?.input().bind(.{ .id = id, .name = "Toggle", .chord = .{ .key = key }, .passthrough = !consume }, api.wraith.KeybindFired.init(self, fired));
        }
    };

    test "plugin keybind" {
        var rig: Rig = undefined;
        try rig.init(.{ .overlay = false });
        defer rig.deinit();
        rig.present(); // attaches
        const reg = try attach(&rig);
        defer detach(reg);

        var fake: FakePlugin = undefined;
        fake.init("kai");
        var state: State = .{};
        const kb = try state.bind("toggle", .f8, true);
        try testing.expectError(error.AlreadyBound, state.bind("toggle", .f9, true));
        try testing.expectError(error.InvalidChord, state.bind("ctrl", .left_ctrl, true));
        try testing.expectEqualStrings("kai.toggle", recordOf(kb).setting.?.binding.?.id);

        _ = rig.send(win.WM_KEYDOWN, VK_F8, 1);
        _ = rig.send(win.WM_KEYUP, VK_F8, @bitCast(@as(usize, 0xC000_0001)));
        rig.present();
        try testing.expectEqual(1, state.presses);
        try testing.expectEqual(1, state.releases);
        try testing.expectEqual(0, Rig.game.count(win.WM_KEYDOWN));

        fake.unload();
        _ = rig.send(win.WM_KEYDOWN, VK_F8, 1);
        rig.present();
        try testing.expectEqual(1, state.presses);
        try testing.expectEqual(1, Rig.game.count(win.WM_KEYDOWN));
        try testing.expectEqual(0, rig.keybinds.bindings.items.len);
    }

    test "rebind live and pause" {
        var rig: Rig = undefined;
        try rig.init(.{ .overlay = false });
        defer rig.deinit();
        rig.present();
        const reg = try attach(&rig);
        defer detach(reg);

        var fake: FakePlugin = undefined;
        fake.init("kai");
        defer fake.unload();
        var state: State = .{};
        const kb = try state.bind("toggle", .f8, true);
        try kb.rebind(.{ .key = .f9 });
        try testing.expectError(error.InvalidChord, kb.rebind(.{ .key = .left_shift }));

        _ = rig.send(win.WM_KEYDOWN, VK_F8, 1);
        _ = rig.send(win.WM_KEYUP, VK_F8, @bitCast(@as(usize, 0xC000_0001)));
        _ = rig.send(win.WM_KEYDOWN, VK_F9, 1);
        _ = rig.send(win.WM_KEYUP, VK_F9, @bitCast(@as(usize, 0xC000_0001)));
        rig.present();
        try testing.expectEqual(1, state.presses);
        try testing.expectEqual(1, Rig.game.count(win.WM_KEYDOWN));

        // Paused, like while a chord input takes keys, so the game gets it
        rig.keybinds.setPaused(true);
        _ = rig.send(win.WM_KEYDOWN, VK_F9, 1);
        _ = rig.send(win.WM_KEYUP, VK_F9, @bitCast(@as(usize, 0xC000_0001)));
        rig.present();
        try testing.expectEqual(1, state.presses);
        try testing.expectEqual(2, Rig.game.count(win.WM_KEYDOWN));
    }

    test "the key picked in settings beats the plugin's, and stays" {
        var rig: Rig = undefined;
        try rig.init(.{ .overlay = false });
        defer rig.deinit();
        rig.present();
        const reg = try attach(&rig);
        defer detach(reg);

        var state: State = .{};
        {
            var fake: FakePlugin = undefined;
            fake.init("kai");
            defer fake.unload();
            _ = try state.bind("toggle", .f8, true);
            // What Wraith's settings do
            try reg.set(reg.find("kai.toggle").?, .{ .key = .{ .key = .f9 } });
        }
        // Loaded again, asking for F8 again
        var fake: FakePlugin = undefined;
        fake.init("kai");
        defer fake.unload();
        const kb = try state.bind("toggle", .f8, true);
        try testing.expectEqual(.f9, recordOf(kb).setting.?.binding.?.chord.key);
    }

    test "through input.sal" {
        var rig: Rig = undefined;
        try rig.init(.{ .overlay = false });
        defer rig.deinit();
        rig.present();
        const reg = try attach(&rig);
        defer detach(reg);

        var fake: FakePlugin = undefined;
        fake.init("kai");
        const Seen = struct {
            presses: u32 = 0,
            releases: u32 = 0,

            fn fired(self: *@This(), phase: api.wraith.KeyPhase) void {
                switch (phase) {
                    .pressed => self.presses += 1,
                    .released => self.releases += 1,
                    else => {},
                }
            }
        };
        var seen: Seen = .{};
        const Fn = api.wraith.KeybindFired;
        const input = sdk.wraith.root().?.input();
        const kb = try input.bind(.{ .id = "toggle", .name = "Toggle", .chord = .{ .key = .f8 } }, Fn.init(&seen, Seen.fired));
        try testing.expectError(error.AlreadyBound, input.bind(.{ .id = "toggle", .chord = .{ .key = .f9 } }, Fn.init(&seen, Seen.fired)));
        try testing.expectError(error.InvalidChord, input.bind(.{ .id = "ctrl", .chord = .{ .key = .left_ctrl } }, Fn.init(&seen, Seen.fired)));
        try testing.expectEqualStrings("Toggle", reg.find("kai.toggle").?.def.name);

        _ = rig.send(win.WM_KEYDOWN, VK_F8, 1);
        _ = rig.send(win.WM_KEYUP, VK_F8, @bitCast(@as(usize, 0xC000_0001)));
        rig.present();
        try testing.expectEqual(1, seen.presses);
        try testing.expectEqual(1, seen.releases);
        try testing.expect(!input.keyDown(.f8));

        // Rebound, then the old key goes to the game
        try kb.rebind(.{ .key = .f9, .mods = .{ .ctrl = true } });
        try testing.expectError(error.InvalidChord, kb.rebind(.{ .key = .left_shift }));
        _ = rig.send(win.WM_KEYDOWN, VK_F8, 1);
        rig.present();
        try testing.expectEqual(1, seen.presses);
        try testing.expectEqual(1, Rig.game.count(win.WM_KEYDOWN));

        kb.unbind();
        kb.unbind();
        try testing.expectEqual(null, reg.find("kai.toggle"));
        fake.unload();
        host.wraith.forget(&fake.loaded);
        try testing.expectError(error.Gone, kb.rebind(.{ .key = .f10 }));
    }

    test "unbind early" {
        var rig: Rig = undefined;
        try rig.init(.{ .overlay = false });
        defer rig.deinit();
        rig.present();
        const reg = try attach(&rig);
        defer detach(reg);

        var fake: FakePlugin = undefined;
        fake.init("kai");
        defer fake.unload();
        var state: State = .{};
        const kb = try state.bind("toggle", .f8, false);
        kb.unbind();
        kb.unbind();

        _ = rig.send(win.WM_KEYDOWN, VK_F8, 1);
        rig.present();
        try testing.expectEqual(0, state.presses);
        try testing.expectEqual(1, Rig.game.count(win.WM_KEYDOWN));
    }

    test "plugins see what's held" {
        var rig: Rig = undefined;
        try rig.init(.{ .overlay = false });
        defer rig.deinit();
        rig.present();
        const reg = try attach(&rig);
        defer detach(reg);

        var fake: FakePlugin = undefined;
        fake.init("kai");
        defer fake.unload();
        const input = sdk.wraith.root().?.input();
        try testing.expect(!input.keyDown(.f9));
        _ = rig.send(win.WM_KEYDOWN, VK_F9, 1);
        _ = rig.send(win.WM_KEYDOWN, 0xA2, 1); // left ctrl
        _ = rig.send(win.WM_RBUTTONDOWN, 2, 0);
        _ = rig.send(win.WM_MOUSEMOVE, 0, (7 << 16) | 5);
        try testing.expect(input.keyDown(.f9));
        try testing.expect(input.keyDown(.left_ctrl));
        try testing.expect(input.buttonDown(.right));
        try testing.expectEqual(5, input.mousePos().?.x);
        try testing.expectEqual(7, input.mousePos().?.y);
        _ = rig.send(win.WM_KEYUP, VK_F9, @bitCast(@as(usize, 0xC000_0001)));
        try testing.expect(!input.keyDown(.f9));
    }
};

test {
    _ = tests;
}
