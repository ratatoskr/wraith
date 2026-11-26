//! A real game's C# runtime for tests, started once. Off unless `WRAITH_MANAGED_GAME` names a Unity game.

const std = @import("std");

const platform = @import("wraith_platform");
const tuft_managed = @import("tuft_managed");
const sys = @import("tuft_sys");

const Managed = @import("../Managed.zig");

var started: ?struct { kind: tuft_managed.Kind, base: usize } = null;

/// Starts `Managed.global` on it, or skips the test if there's no game. Stop it after.
pub fn start() !tuft_managed.Kind {
    const s = started orelse blk: {
        const a = std.testing.allocator;
        const game = (try platform.process.envAlloc(a, "WRAITH_MANAGED_GAME")) orelse return error.SkipZigTest;
        defer a.free(game);
        const path = try std.fs.path.join(a, &.{ game, "GameAssembly.dll" });
        defer a.free(path);
        const kind: tuft_managed.Kind = if (std.Io.Dir.accessAbsolute(std.testing.io, path, .{})) .il2cpp else |_| .mono;
        const got = try tuft_managed.standalone.start(std.heap.smp_allocator, std.testing.io, kind, game, null);
        started = .{ .kind = kind, .base = got.base };
        break :blk started.?;
    };
    Managed.global.startOn(s.kind, s.base);
    var waited: u32 = 0;
    while (!Managed.global.running() and waited < 5000) : (waited += 10) sys.thread.sleepMs(10);
    if (!Managed.global.running()) return error.NotRunning;
    return s.kind;
}
