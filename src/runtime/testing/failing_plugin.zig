//! A plugin whose `start` fails.

const std = @import("std");
const sdk = @import("wraith_sdk");

// Logs go through the host so tests can filter them
pub const std_options: std.Options = .{ .logFn = sdk.logFn };
pub const panic = sdk.panic;

pub const Plugin = struct {
    pub fn start(_: *Plugin, _: *sdk.Context) !void {
        return error.StartFailed;
    }
};

comptime {
    sdk.exportPlugin(Plugin);
}
