//! Log service. Owners log under the `plugin` subsystem.

const std = @import("std");

const core = @import("wraith_core");

const Loaded = @import("../PluginLoader.zig").Loaded;

pub fn write(loaded: *Loaded, level: std.log.Level, scope: []const u8, message: []const u8) void {
    if (loaded.echo) |e| e.write(e.ctx, level, message);
    var buffer: [core.log.max_message_len]u8 = undefined;
    const text = if (std.mem.eql(u8, scope, @tagName(std.log.default_log_scope)))
        core.log.formatInto(&buffer, "[{s}] {s}", .{ loaded.name, message })
    else
        core.log.formatInto(&buffer, "[{s}/{s}] {s}", .{ loaded.name, scope, message });
    core.log.write(.{ .level = level, .subsystem = .plugin, .scope = "wraith_plugin", .message = text });
}

pub fn enabled(_: *Loaded, level: std.log.Level) bool {
    return core.log.enabledAt(level, .plugin);
}

const tests = struct {
    test "enabled follows the mask" {
        const saved = core.log.filter();
        defer core.log.setFilter(saved);

        var loaded: Loaded = undefined;
        core.log.setFilter(.{ .levels = .full, .subsystems = .full });
        try std.testing.expect(enabled(&loaded, .err));
        try std.testing.expect(enabled(&loaded, .debug));

        core.log.setFilter(.{ .levels = core.log.Filter.atLeast(.info) });
        try std.testing.expect(!enabled(&loaded, .debug));

        var no_plugins: core.log.Filter = .{ .levels = .full, .subsystems = .full };
        no_plugins.subsystems.remove(.plugin);
        core.log.setFilter(no_plugins);
        try std.testing.expect(!enabled(&loaded, .err));
    }
};

test {
    _ = tests;
}
