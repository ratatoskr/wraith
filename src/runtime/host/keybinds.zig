//! Keybinds service. Each is a key setting in the registry, its id the owner's name then the
//! action's, so it's listed in Wraith's settings and the key picked there wins.

const std = @import("std");

const core = @import("wraith_core");
const wraith_platform = @import("wraith_platform");
const api = @import("wraith_api");

const host = @import("root.zig");
const threads = @import("threads.zig");
const wraith = @import("wraith.zig");
const sync = @import("tuft_sys").sync;
const sal = api.salamander;
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
/// Null while plugins aren't loaded.
var gamepads: ?*tuft_input.Gamepads = null;

pub fn setKeybinds(k: ?*Keybinds) void {
    keybinds = k;
}

pub fn setGamepads(g: ?*tuft_input.Gamepads) void {
    gamepads = g;
}

/// Every connected controller merged, or null without one. Any thread.
pub fn gamepad() ?tuft_input.Axes {
    const g = gamepads orelse return null;
    if (!g.connected()) return null;
    return g.state().axes;
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
pub const Fired = W.Keybind.Fired;

pub const Record = struct {
    loaded: *Loaded,
    fired: Fired,
    setting: ?*Registry.Setting = null,
    /// What `next` gave out, settled at the next press. Under `waiting_lock`.
    waiting: std.ArrayList(NextResolver) = .empty,
    waiting_lock: sync.RwLock = .{},

    /// Render thread.
    fn fire(ctx: *anyopaque, phase: Keybinds.Phase) void {
        const self: *Record = @ptrCast(@alignCast(ctx));
        if (phase == .pressed) self.wake(null);
        self.fired.invoke(.{switch (phase) {
            .pressed => .pressed,
            .released => .released,
        }});
    }

    /// Settles every `next`, or fails them with `err`.
    fn wake(self: *Record, err: ?anyerror) void {
        var list = blk: {
            self.waiting_lock.lock();
            defer self.waiting_lock.unlock();
            const l = self.waiting;
            self.waiting = .empty;
            break :blk l;
        };
        defer list.deinit(gpa);
        for (list.items) |r| if (err) |e| r.fail(e) else r.settle({});
    }

    pub fn going(self: *Record) bool {
        return self.setting != null;
    }

    /// The key picked for it stays saved.
    pub fn stop(self: *Record) void {
        const setting = self.setting orelse return;
        if (registry) |r| r.remove(setting);
        self.setting = null;
        self.wake(error.Unavailable);
        // Won't be called again
        self.fired.release();
    }

    pub fn free(self: *Record) void {
        self.stop();
        self.loaded.allocator.destroy(self);
    }
};

const gpa = std.heap.page_allocator;
pub const NextPromise = sal.Plain(W.Keybind, "next");
const NextResolver = threads.Back(wraith.ResolverOf(NextPromise));

/// Through `input.sal`. Settles at its next press.
pub fn next(record: *Record) NextPromise {
    const pair = NextPromise.make() catch return .{};
    const r: NextResolver = .of(pair.resolver);
    record.waiting_lock.lock();
    defer record.waiting_lock.unlock();
    if (!record.going()) {
        r.fail(error.Unavailable);
        return pair.promise;
    }
    record.waiting.append(gpa, r) catch r.fail(error.Failed);
    return pair.promise;
}

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
    var defaults: tuft_input.Keys = .one(action.chord);
    for (action.also) |c| defaults = defaults.with(c);
    if (!defaults.isValid(action.held)) return error.InvalidChord;
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
        .kind = .{ .key = .{ .default = defaults, .consume = action.consume, .while_typing = action.while_typing, .held = action.held } },
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

/// Like someone picking them in Wraith's settings, so they're saved. Null leaves it without a key.
pub fn rebind(record: *Record, keys: ?tuft_input.Keys) api.KeybindError!void {
    const r = registry orelse return error.KeybindFailed;
    const setting = record.setting orelse return error.KeybindFailed;
    r.set(setting, .{ .key = keys }) catch |err| return switch (err) {
        error.InvalidChord => error.InvalidChord,
        error.OutOfMemory => error.OutOfMemory,
        else => error.KeybindFailed,
    };
}

/// What it's on now, the player's picks if they made some. Null once unbound or set to no key.
pub fn keysOf(record: *Record) ?tuft_input.Keys {
    const r = registry orelse return null;
    const setting = record.setting orelse return null;
    return r.get(setting).key;
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

        fn fired(self: *State, phase: api.wraith.Keybind.Phase) void {
            switch (phase) {
                .pressed => self.presses += 1,
                .released => self.releases += 1,
                else => {},
            }
        }

        fn bind(self: *State, id: []const u8, key: api.wraith.Key, consume: bool) !api.wraith.Keybind {
            return sdk.wraith.root().?.input().bind(.{ .id = id, .name = "Toggle", .chord = .{ .key = key }, .passthrough = !consume }, api.wraith.Keybind.Fired.init(self, fired));
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

    test "held keys can be modifiers, and say what they're on" {
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
        const input = sdk.wraith.root().?.input();
        const fast = try input.bind(.{ .id = "fast", .name = "Faster", .chord = .{ .key = .left_shift }, .also = &.{.{ .key = .gamepad_right_shoulder }}, .passthrough = true, .held = true }, api.wraith.Keybind.Fired.init(&state, State.fired));
        try testing.expectEqual(2, fast.chords().len);
        try testing.expectEqual(api.wraith.Key.left_shift, fast.chords()[0].key);
        try testing.expectEqual(api.wraith.Key.gamepad_right_shoulder, fast.chords()[1].key);
        // Modifiers on a held key don't make sense
        try testing.expectError(error.InvalidChord, fast.rebind(&.{.{ .key = .w, .mods = .{ .shift = true } }}));
        try fast.rebind(&.{ .{ .key = .left_ctrl }, .{ .key = .x } });
        try testing.expectEqual(api.wraith.Key.left_ctrl, fast.chords()[0].key);
        try testing.expectEqual(2, fast.chords().len);

        // Either does it
        _ = rig.send(win.WM_KEYDOWN, 0x11, 1);
        _ = rig.send(win.WM_KEYUP, 0x11, @bitCast(@as(usize, 0xC000_0001)));
        _ = rig.send(win.WM_KEYDOWN, 'X', 1);
        _ = rig.send(win.WM_KEYUP, 'X', @bitCast(@as(usize, 0xC000_0001)));
        rig.present();
        try testing.expectEqual(2, state.presses);
        try testing.expectEqual(2, state.releases);

        try fast.rebind(&.{});
        try testing.expectEqual(0, fast.chords().len);
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
        try kb.rebind(&.{.{ .key = .f9 }});
        try testing.expectError(error.InvalidChord, kb.rebind(&.{.{ .key = .left_shift }}));

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
        try testing.expectEqual(.f9, recordOf(kb).setting.?.binding.?.keys.key);
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

            fn fired(self: *@This(), phase: api.wraith.Keybind.Phase) void {
                switch (phase) {
                    .pressed => self.presses += 1,
                    .released => self.releases += 1,
                    else => {},
                }
            }
        };
        var seen: Seen = .{};
        const Fn = api.wraith.Keybind.Fired;
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
        try kb.rebind(&.{.{ .key = .f9, .mods = .{ .ctrl = true } }});
        try testing.expectError(error.InvalidChord, kb.rebind(&.{.{ .key = .left_shift }}));
        _ = rig.send(win.WM_KEYDOWN, VK_F8, 1);
        rig.present();
        try testing.expectEqual(1, seen.presses);
        try testing.expectEqual(1, Rig.game.count(win.WM_KEYDOWN));

        kb.unbind();
        kb.unbind();
        try testing.expectEqual(null, reg.find("kai.toggle"));
        fake.unload();
        host.wraith.forget(&fake.loaded);
        try testing.expectError(error.Gone, kb.rebind(&.{.{ .key = .f10 }}));
    }

    test "next settles at the next press, and fails once it's unbound" {
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
        const pressed = kb.next();
        rig.present();
        try testing.expect(!pressed.isSettled());
        _ = rig.send(win.WM_KEYDOWN, VK_F8, 1);
        rig.present();
        try testing.expect(pressed.isSettled());
        try pressed.take().?;

        const never = kb.next();
        kb.unbind();
        try testing.expectError(error.Unavailable, never.take().?);
        try testing.expectError(error.Unavailable, kb.next().take().?);
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
