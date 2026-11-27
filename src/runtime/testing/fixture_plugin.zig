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
const generated = @import("schema");
// Its own types are in its namespace, its id in PascalCase
const schema = generated.Fixture;
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
const PluginKind = W.Plugin.Kind;

const Kind = struct {
    pub fn start(_: *Kind, _: W.Plugin.Guest) sdk.salamander.rt.Plain(PluginKind, "start") {
        return error.Failed;
    }
};

var kind: Kind = .{};

/// The Notes tab, many at once, which the loader's tests call like the Workbench does.
const Notes = struct {
    made: u32 = 0,
    drawn: u32 = 0,
    id: [8]u8 = undefined,
    title: [32]u8 = undefined,

    pub fn describe(_: *Notes) W.WorkbenchTab.Info {
        return .{ .title = "Notes", .kind = "notes", .place = .bottom, .multi = true };
    }

    pub fn draw(self: *Notes, _: []const u8) void {
        self.drawn += 1;
    }

    /// Not saved
    pub fn status(self: *Notes, id: []const u8) W.WorkbenchTab.State {
        const title = std.fmt.bufPrint(&self.title, "Note {s} drawn {d}", .{ id, self.drawn }) catch "";
        return .{ .title = title, .unsaved = true };
    }

    pub fn create(self: *Notes) []const u8 {
        self.made += 1;
        return std.fmt.bufPrint(&self.id, "{d}", .{self.made}) catch "";
    }

    /// The first stays open
    pub fn keepOpen(_: *Notes, id: []const u8) bool {
        return std.mem.eql(u8, id, "1");
    }
};

var notes: Notes = .{};

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
        notes = .{};
        _ = try sdk.workbench.addTab(&notes, Notes);
        // A slot of its own, which plugins depending on it add counters to
        _ = try ctx.wraith.ui().defineSlot(.{ .id = "counters", .title = "Counters", .help = "Counts things", .trait = "Fixture.FixtureCounter" });
        try ctx.spawn(waitForever, .{ self, ctx.io });
    }

    fn waitForever(self: *Plugin, io: std.Io) !void {
        sdk.threads.delay(io, .fromSeconds(3600)) catch |err| {
            self.settings.value.cancelled_tasks += 1;
            return err;
        };
    }
};

comptime {
    sdk.exportPlugin(Plugin);
    // A plugin's schemas have Wraith's types, and they're the SDK's own
    std.debug.assert(generated.Wraith.Vec3 == sdk.api.wraith.Vec3);
    std.debug.assert(generated.Wraith.Point == sdk.api.wraith.Point);
}
