//! A plugin that looks like a NativeAOT build, by exporting what .NET's runtime does.

const std = @import("std");
const sdk = @import("wraith_sdk");

pub const std_options: std.Options = .{ .logFn = sdk.logFn };
pub const panic = sdk.panic;

export var DotNetRuntimeDebugHeader: [64]u8 = @splat(0);

pub const Plugin = struct {
    pub fn start(_: *Plugin, _: *sdk.Context) !void {}
};

comptime {
    sdk.exportPlugin(Plugin);
}
