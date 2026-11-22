//! Keys tasks can wait on. Binding a key with a callback is `wraith.sal`'s `input` area, which calls
//! it on the render thread at the start of the next frame. `api.tweak.parseChord` reads one from text.

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const input = @import("wraith_platform").input;

const api = @import("wraith_api");
const Owner = @import("Owner.zig");
const frame = @import("frame.zig");
const tasks = @import("tasks.zig");

pub const Key = input.Key;
pub const Mods = input.Mods;
pub const Chord = input.Chord;
const W = api.wraith;

/// A chord as `wraith.sal`'s, like one from `parseChord`. Its keys are tuft's, in the same order.
pub fn chord(c: Chord) W.Chord {
    return .{
        .key = @fromBackingInt(@backingInt(c.key)),
        .mods = .{ .ctrl = c.mods.ctrl, .shift = c.mods.shift, .alt = c.mods.alt, .super = c.mods.super },
    };
}

/// A keybind tasks can wait on, like `try presses.next(io)`. Must not move once bound.
pub const Presses = struct {
    io: std.Io,
    keybind: ?W.Keybind = null,
    count: Atomic(u32) = .init(0),
    seen: u32 = 0,
    /// A task parked in `next`.
    waiter: Atomic(?*tasks.Task) = .init(null),

    pub fn init(io: std.Io) Presses {
        return .{ .io = io };
    }

    /// Gone with the plugin, if not unbound first.
    pub fn bind(self: *Presses, action: W.Action) !void {
        const owner = Owner.current() orelse return error.KeybindsUnavailable;
        self.keybind = try owner.root.input().bind(action, W.KeybindFired.init(self, fired));
    }

    pub fn unbind(self: *Presses) void {
        if (self.keybind) |k| k.unbind();
        self.keybind = null;
    }

    /// Like `bind`, but if it's bound already it just moves to the action's keys.
    pub fn rebind(self: *Presses, action: W.Action) !void {
        if (self.keybind) |k| {
            var buf: [4]W.Chord = undefined;
            buf[0] = action.chord;
            const n = @min(action.also.len, buf.len - 1);
            @memcpy(buf[1..][0..n], action.also[0..n]);
            return k.rebind(buf[0 .. n + 1]);
        }
        try self.bind(action);
    }

    fn fired(self: *Presses, phase: W.KeyPhase) void {
        if (phase == .pressed) self.pressed();
    }

    fn pressed(self: *Presses) void {
        _ = self.count.fetchAdd(1, .release);
        self.io.futexWake(u32, &self.count.raw, std.math.maxInt(u32));
        if (self.waiter.load(.acquire)) |t| t.wake();
    }

    /// Waits for a press since the last `next` returned, so ones while you were busy aren't lost.
    /// From one task at a time. A task carries on on the render thread at the frame of the press.
    /// Other threads block, so never the render thread, where presses come in, or the game thread.
    pub fn next(self: *Presses, io: std.Io) (std.Io.Cancelable || error{ OnRenderThread, OnGameThread })!void {
        if (tasks.current()) |t| {
            while (true) {
                const now = self.count.load(.acquire);
                if (now != self.seen) {
                    self.seen = now;
                    return;
                }
                t.prepareSignal();
                self.waiter.store(t, .release);
                // A press between the check and here would be missed otherwise
                if (self.count.load(.acquire) == now) {
                    const parked = t.park(.render, .{ .signal = true });
                    self.waiter.store(null, .release);
                    try parked;
                } else self.waiter.store(null, .release);
            }
        }
        if (frame.onRenderThread()) return error.OnRenderThread;
        if (frame.onGameThread()) return error.OnGameThread;
        while (true) {
            const now = self.count.load(.acquire);
            if (now != self.seen) {
                self.seen = now;
                return;
            }
            try io.futexWait(u32, &self.count.raw, now);
        }
    }

    /// Like `next` without waiting. True if there's been a press since.
    pub fn take(self: *Presses) bool {
        const now = self.count.load(.acquire);
        defer self.seen = now;
        return now != self.seen;
    }
};

test "tasks wait for presses" {
    const io = std.testing.io;
    var presses: Presses = .init(io);
    try std.testing.expect(!presses.take());
    presses.pressed();
    presses.pressed();
    // Both while busy count as one
    try presses.next(io);
    try std.testing.expect(!presses.take());

    const Waiter = struct {
        fn run(p: *Presses, io_: std.Io) !void {
            try p.next(io_);
        }
    };
    var waiting = try io.concurrent(Waiter.run, .{ &presses, io });
    try io.sleep(.fromMilliseconds(2), .awake);
    presses.pressed();
    try waiting.await(io);
}
