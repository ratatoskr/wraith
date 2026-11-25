//! Logging through the runtime. Falls back to stderr with no owner.

const std = @import("std");

const core = @import("wraith_core");
const Owner = @import("Owner.zig");

pub const scoped = core.log.scoped;
pub const logFn = core.log.stdLogFn;
pub const max_message_len = core.log.max_message_len;

threadlocal var panicking: bool = false;

/// Logs it and traps, so Wraith shows it as a crash. Std's own loads debug info from disk to print a
/// trace, which needs more stack than game threads have. Use it with `pub const panic = sdk.panic;`.
pub fn onPanic(msg: []const u8, _: ?usize) noreturn {
    @branchHint(.cold);
    if (!panicking) {
        panicking = true;
        scoped(.default).err("Panicked: {s}", .{msg});
    }
    @trap();
}

const host_sink: core.log.Sink = .{ .enabled = hostEnabled, .write = hostWrite };
var previous_sink: ?*const core.log.Sink = null;
var saved_filter: core.log.Filter = .{};

pub fn attach() void {
    if (previous_sink != null) return;
    // The runtime decides which levels are shown
    saved_filter = core.log.filter();
    var all = saved_filter;
    all.levels = .full;
    core.log.setFilter(all);
    previous_sink = core.log.setSink(&host_sink);
}

pub fn detach() void {
    const previous = previous_sink orelse return;
    _ = core.log.setSink(previous);
    core.log.setFilter(saved_filter);
    previous_sink = null;
}

const LogLevel = @import("wraith_api").wraith.Log.Level;

fn levelOf(level: core.log.Level) LogLevel {
    return switch (level) {
        inline else => |l| @field(LogLevel, @tagName(l)),
    };
}

fn hostEnabled(level: core.log.Level, _: core.log.Subsystem) bool {
    const owner = Owner.current() orelse return false;
    return owner.root.log().enabled(levelOf(level));
}

fn hostWrite(record: *const core.log.Record) void {
    const owner = Owner.current() orelse return;
    owner.root.log().write(levelOf(record.level), record.scope, record.message);
}

const tests = struct {
    const Fake = @import("testing.zig").Fake;

    test "scoped logs" {
        var fake: Fake = .{};
        fake.attach();
        defer fake.detach();
        attach();
        defer detach();

        scoped(.example).warn("hello {d} from {s}", .{ 42, "zig" });
        try std.testing.expectEqual(1, fake.logs);
        try std.testing.expectEqual(.warn, fake.last_level);
        try std.testing.expectEqualStrings("example", fake.lastScope());
        try std.testing.expectEqualStrings("hello 42 from zig", fake.lastMessage());

        logFn(.info, .default, "from std.log", .{});
        try std.testing.expectEqual(2, fake.logs);
        try std.testing.expectEqualStrings("default", fake.lastScope());
    }

    test "runtime filters debug" {
        var fake: Fake = .{ .debug_enabled = false };
        fake.attach();
        defer fake.detach();
        attach();
        defer detach();

        scoped(.example).debug("noisy", .{});
        try std.testing.expectEqual(0, fake.logs);

        fake.debug_enabled = true;
        scoped(.example).debug("wanted", .{});
        try std.testing.expectEqual(1, fake.logs);
        try std.testing.expectEqual(.debug, fake.last_level);
    }

    test "logs use current owner" {
        var mine: Fake = .{};
        mine.attach();
        defer mine.detach();
        attach();
        defer detach();

        scoped(.example).info("mine", .{});
        try std.testing.expectEqual(1, mine.logs);

        var other: Fake = .{};
        const acting = (Owner{ .root = other.root() }).enter();
        scoped(.example).info("the script's", .{});
        acting.end();
        try std.testing.expectEqual(1, mine.logs);
        try std.testing.expectEqual(1, other.logs);
    }

    test "long messages truncated" {
        var fake: Fake = .{};
        fake.attach();
        defer fake.detach();
        attach();
        defer detach();

        const long: [max_message_len + 100]u8 = @splat('a');
        scoped(.example).info("{s}", .{&long});
        try std.testing.expectEqual(max_message_len, fake.lastMessage().len);
        try std.testing.expect(std.mem.endsWith(u8, fake.lastMessage(), "..."));
    }
};

test {
    _ = tests;
}
