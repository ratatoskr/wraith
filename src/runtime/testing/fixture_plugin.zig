//! A test plugin, so loader tests don't depend on real ones.

const std = @import("std");
const sdk = @import("wraith_sdk");

pub const std_options: std.Options = .{ .logFn = sdk.logFn };
pub const panic = sdk.panic;

pub const Settings = struct {
    starts: u32 = 0,
    /// Its task only ends by being cancelled, before `stop`.
    cancelled_tasks: u32 = 0,
};

/// What it provides through Salamander, so tests can call into it from another binary.
const schema = @import("schema");
const Counter = schema.FixtureCounter;

const Count = struct {
    n: u32 = 0,

    pub fn next(self: *Count) u32 {
        self.n += 1;
        return self.n;
    }
};

var count: Count = .{};

/// A plugin kind, `wraith.kind.fixture`, which the loader refuses, since only Wraith's own run plugins.
const W = sdk.wraith.types;
const PluginKind = W.PluginKind;

const Kind = struct {
    pub fn start(_: *Kind, _: W.Guest) sdk.salamander.rt.Plain(PluginKind, "start") {
        return error.Failed;
    }
};

var kind: Kind = .{};

pub const Plugin = struct {
    settings: *sdk.Config(Settings) = undefined,

    pub const services = .{counterService};

    pub fn counterService(_: *Plugin) schema.FixtureService {
        return .init(&count, sdk.salamander.rt.implement(schema.FixtureService, Count));
    }

    pub fn start(self: *Plugin, ctx: *sdk.Context) !void {
        self.settings = try ctx.config(Settings);
        self.settings.value.starts += 1;
        sdk.log.scoped(.default).debug("Fixture debug start", .{});
        const rt = sdk.salamander.rt;
        try sdk.salamander.provide("fixture.counter", 1, Counter.init(&count, rt.implement(Counter, Count)));
        try sdk.salamander.provide("wraith.kind.fixture", 1, PluginKind.init(&kind, rt.implement(PluginKind, Kind)));
        try ctx.spawn(waitForever, .{ self, ctx.io });
    }

    fn waitForever(self: *Plugin, io: std.Io) !void {
        sdk.frame.delay(io, .fromSeconds(3600)) catch |err| {
            self.settings.value.cancelled_tasks += 1;
            return err;
        };
    }
};

comptime {
    sdk.exportPlugin(Plugin);
    // A plugin's schemas have Wraith's types, and they're the SDK's own
    std.debug.assert(schema.Vec3 == sdk.api.wraith.Vec3);
    std.debug.assert(schema.Point == sdk.api.wraith.Point);
}
